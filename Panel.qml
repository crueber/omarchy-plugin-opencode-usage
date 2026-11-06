import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// OpenCode Go allowance in the bar: the OpenCode mark plus one meter per
// limit window (5-hour session, week, month), and a popup with percentages,
// reset countdowns, Console budgets, and local activity.
//
// The numbers come from the OpenCode service already running on this machine
// (`opencode api GET /api/experimental/usage/limits`), which reads the
// workspace your installed OpenCode is signed in to. No API key or second
// login is needed. If the background service is not up, the widget retries
// once with `--standalone`, which starts a private server for the request.
Panel {
  id: root
  moduleName: "crueber.opencode-usage"
  ipcTarget: "opencode-usage"
  manageIpc: false
  // The custom ShellIpc below owns the target. `omarchy-shell shell toggle
  // crueber.opencode-usage` also routes here through the bar's summon path.

  // ------------------------------------------------------------------ theme

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical : false

  // --------------------------------------------------------------- settings
  // Inline on the widget's shell.json layout entry; see manifest.json.

  readonly property int refreshIntervalSec: Model.clampInt(setting("refreshIntervalSec", 300), 60, 3600, 300)
  readonly property int warnPercent: Model.clampInt(setting("warnPercent", 70), 0, 100, 70)
  readonly property int criticalPercent: Model.clampInt(setting("criticalPercent", 90), 0, 100, 90)
  readonly property string barStyleRaw: String(setting("barStyle", "bars"))
  readonly property string barStyle: ["bars", "text", "icon"].indexOf(barStyleRaw) >= 0 ? barStyleRaw : "bars"
  readonly property bool showSession: setting("showSession", true) !== false
  readonly property bool showWeekly: setting("showWeekly", true) !== false
  readonly property bool showMonthly: setting("showMonthly", true) !== false
  readonly property bool showLocalStats: setting("showLocalStats", true) !== false
  readonly property string warningColor: String(setting("warningColor", "#f67400"))
  readonly property string criticalColor: String(setting("criticalColor", ""))
  readonly property string opencodeCommand: String(setting("opencodeCommand", ""))
  readonly property string rightClickCommand: String(setting("onRightClick", ""))

  readonly property string executable: opencodeCommand !== "" ? opencodeCommand : "opencode"

  // ------------------------------------------------------------------- data

  property var report: null
  property bool signedOut: false
  property string errorText: ""
  property string lastErrorMessage: ""
  property string stderrText: ""
  property bool gotOutput: false
  property bool usedFallback: false
  property double lastFetchMs: 0
  property double lastAttemptMs: 0
  property int fetchFailures: 0
  property double nowMs: Date.now()

  property var stats: null
  property double lastStatsMs: 0

  property bool cacheLoadAttempted: false
  property bool settingsReady: false
  property bool startupDone: false
  property bool pollLeader: false
  property int consumedSeq: 0

  // Last successful response and last attempt time, kept on disk so a shell
  // restart paints immediately and waits out the rest of the interval instead
  // of asking again. See Model.js for the cache and poll-coordination rules.
  readonly property string cacheHome: {
    var xdg = Quickshell.env("XDG_CACHE_HOME")
    if (xdg) return xdg
    var home = Quickshell.env("HOME")
    return home ? home + "/.cache" : "/tmp"
  }
  readonly property string cacheDir: root.cacheHome + "/opencode-usage"
  readonly property string cachePath: root.cacheDir + "/usage.json"

  readonly property var allWindows: Model.windows(report, warnPercent, criticalPercent)
  readonly property var barWindows: Model.filterWindows(allWindows, {
    rolling: showSession,
    weekly: showWeekly,
    monthly: showMonthly
  })
  readonly property var highest: Model.highest(barWindows.length > 0 ? barWindows : allWindows)
  readonly property bool hasData: allWindows.length > 0 || budgets.length > 0
  readonly property bool alarming: highest !== null && (highest.state === "critical" || highest.limited)
  readonly property bool busy: fetchProc.running
  readonly property string compactText: Model.compactText(barWindows)
  readonly property string refreshNote: report !== null && lastErrorMessage !== "" ? "refresh failed" : ""
  readonly property string tooltipText: hasData
    ? Model.tooltip(allWindows, nowMs)
    : (errorText !== "" ? "OpenCode Go usage: " + errorText : "OpenCode Go usage: fetching limits")
  readonly property string footerText: {
    var parts = []
    var updated = Model.updatedText(root.lastFetchMs, root.nowMs)
    if (updated !== "") parts.push(updated)
    if (root.refreshNote !== "") parts.push(root.refreshNote)
    parts.push("via local login")
    return parts.join(" · ")
  }

  readonly property string heroMeta: {
    if (!report || !report.workspace) return signedOut ? "Not signed in" : "Unavailable"
    var parts = []
    if (report.workspace.name !== "") parts.push(report.workspace.name)
    if (report.go) parts.push("Go")
    return parts.join(" · ")
  }
  readonly property string heroDetail: highest !== null && hasData ? Model.percentText(highest.percent) : ""
  readonly property var budgets: report && Array.isArray(report.budgets) ? report.budgets : []

  function stateColor(state) {
    if (state === "critical") return criticalColor !== "" ? criticalColor : urgent
    if (state === "warning") return warningColor !== "" ? warningColor : foreground
    return foreground
  }

  // Absolute reset clock beside the countdown. Same-day resets only need the
  // time; anything further out gets the day as well. `toLocaleString` takes
  // the live Omarchy locale, so a language switch changes the formatting.
  function clockAt(ms) {
    var target = Number(ms) || 0
    if (target <= 0) return ""
    var date = new Date(target)
    var now = new Date()
    var sameDay = date.getFullYear() === now.getFullYear()
      && date.getMonth() === now.getMonth()
      && date.getDate() === now.getDate()
    return date.toLocaleString(Qt.locale(Commons.I18n.formatLocale), sameDay ? "HH:mm" : "d MMM HH:mm")
  }

  // ------------------------------------------------------------ cache & fetch

  function loadCache(raw) {
    var cached = Model.parseCache(raw, Date.now())
    if (!cached) return
    root.lastFetchMs = Math.max(root.lastFetchMs, cached.fetchedAt)
    root.lastAttemptMs = Math.max(root.lastAttemptMs, cached.attemptedAt)
    root.fetchFailures = Math.max(root.fetchFailures, cached.failures)
    Model.pollSeed(cached.fetchedAt, cached.attemptedAt, cached.failures)

    if (cached.report) {
      root.report = cached.report
      root.signedOut = false
      root.lastErrorMessage = cached.error
      root.errorText = cached.report.go
        || (cached.report.budgets && cached.report.budgets.length > 0)
        ? "" : "No OpenCode Go subscription on this workspace."
      root.nowMs = Date.now()
    } else if (cached.signedOut) {
      root.signedOut = true
      root.errorText = cached.error !== ""
        ? cached.error
        : "OpenCode is not signed in. Run `opencode auth login`."
      root.lastErrorMessage = cached.error
    } else if (cached.error !== "") {
      root.lastErrorMessage = cached.error
      root.errorText = cached.error
    }
  }

  function writeCache() {
    if (!root.cacheLoadAttempted) return
    cacheFile.setText(Model.serializeCache(
      root.report,
      root.lastFetchMs,
      root.lastAttemptMs,
      root.fetchFailures,
      root.lastErrorMessage,
      root.signedOut
    ))
  }

  function nextAutoDelayMs() {
    var fetchedAt = Math.max(root.lastFetchMs, Model.pollState.fetchedAt)
    var attemptedAt = Math.max(root.lastAttemptMs, Model.pollState.attemptedAt)
    var failures = Math.max(root.fetchFailures, Model.pollState.failures)
    return Model.autoDelayMs(fetchedAt, attemptedAt, failures, root.refreshIntervalSec * 1000, Date.now())
  }

  function scheduleNextPoll(delayMs) {
    if (!root.pollLeader) return
    poll.interval = Math.max(250, Math.round(Number(delayMs) || 0))
    poll.restart()
  }

  function startPolling() {
    // Settings arrive a beat after construction, and the cache file is read
    // synchronously but reported on the next turn; retry rather than
    // scheduling with defaults.
    if (!root.cacheLoadAttempted || !root.settingsReady) {
      Qt.callLater(root.startPolling)
      return
    }
    root.scheduleNextPoll(root.nextAutoDelayMs())
  }

  function applyResult(result) {
    root.report = result.report || null
    root.signedOut = result.signedOut === true
    root.lastFetchMs = Number(result.fetchedAt) || 0
    root.lastAttemptMs = Number(result.attemptedAt) || 0
    root.fetchFailures = Math.round(Number(result.failures) || 0)
    root.errorText = String(result.errorText || "")
    root.lastErrorMessage = String(result.error || "")
    root.nowMs = Date.now()
  }

  function publishResult(result) {
    root.applyResult(result)
    Model.pollPublish(root, result)
    root.writeCache()
    root.scheduleNextPoll(root.nextAutoDelayMs())
  }

  function handleSuccess(parsed, now) {
    var noGo = !parsed.go && parsed.budgets.length === 0
    root.publishResult({
      report: parsed,
      signedOut: false,
      fetchedAt: now,
      attemptedAt: now,
      failures: 0,
      errorText: noGo ? "No OpenCode Go subscription on this workspace." : "",
      error: ""
    })
  }

  function handleFailure(message, now) {
    var failures = Math.min(20, root.fetchFailures + 1)
    var dataPresent = root.report !== null && (root.allWindows.length > 0 || root.budgets.length > 0)
    root.publishResult({
      report: root.report,
      signedOut: root.signedOut,
      fetchedAt: root.lastFetchMs,
      attemptedAt: now,
      failures: failures,
      errorText: dataPresent ? "" : message,
      error: message
    })
  }

  function fetchCommand(kind) {
    var standalone = kind === "fallback" ? " --standalone" : ""
    return Model.shellQuote(executable) + " api" + standalone + " GET /api/experimental/usage/limits"
  }

  // The one place that starts a process. The attempt timestamp is written to
  // disk before the request so even a crash or shell restart within the
  // cooldown is remembered.
  function spawnFetch(kind) {
    root.gotOutput = false
    root.stderrText = ""
    if (kind !== "fallback") root.usedFallback = false
    root.lastAttemptMs = Date.now()
    root.writeCache()
    fetchProc.command = ["/bin/sh", "-lc", fetchCommand(kind)]
    fetchProc.running = true
  }

  // All fetch paths (scheduled poll, panel open, manual refresh) funnel through
  // here so the cooldowns are enforced once. A manual refresh inside the
  // 30-second floor is deferred, not dropped.
  function requestFetch(kind) {
    if (!root.pollLeader || fetchProc.running) return

    var now = Date.now()
    if (root.lastAttemptMs > 0) {
      var gap = now - root.lastAttemptMs
      var minGap = kind === "manual" ? Model.FORCE_MIN_MS : Model.AUTO_MIN_MS
      if (gap < minGap) {
        if (kind === "manual") {
          manualCatchup.interval = Math.max(1000, Math.round(minGap - gap) + 250)
          manualCatchup.restart()
        } else {
          root.scheduleNextPoll(minGap - gap)
        }
        return
      }
    }

    if (kind === "auto") {
      var delay = root.nextAutoDelayMs()
      if (delay > 1500) {
        root.scheduleNextPoll(delay)
        return
      }
    }
    root.spawnFetch(kind)
  }

  function refreshNow() {
    if (root.pollLeader) {
      root.requestFetch("manual")
      return
    }
    // A widget on another monitor may own the fetch loop. Ask it, and fall
    // back to claiming leadership when there is no live leader (single
    // instance, or mid re-election).
    var leader = Model.pollLeaderInstance()
    if (leader && leader !== root) {
      try {
        if (typeof leader.refreshNow === "function") {
          leader.refreshNow()
          return
        }
      } catch (e) {
        // The leader was destroyed; the heartbeat re-elects shortly.
      }
    }
    if (Model.pollClaim(root, Date.now())) {
      root.pollLeader = true
      root.requestFetch("manual")
    }
  }

  function applyOutput(raw) {
    var parsed = Model.parseReport(raw)
    if (parsed === null) {
      if (String(raw || "").trim() !== "") {
        root.errorText = "Unreadable response from the local OpenCode service"
        root.lastErrorMessage = root.errorText
      }
      return
    }
    root.gotOutput = true
    var now = Date.now()
    if (parsed.signedOut) {
      root.publishResult({
        report: null,
        signedOut: true,
        fetchedAt: 0,
        attemptedAt: now,
        // Back off like a failure so a signed-out session is not polled every
        // minute across restarts, while still noticing a new login within
        // ten minutes.
        failures: Math.min(20, root.fetchFailures + 1),
        errorText: "OpenCode is not signed in. Run `opencode auth login`.",
        error: "OpenCode is not signed in"
      })
      return
    }
    root.handleSuccess(parsed, now)
  }

  function lastStderrLine() {
    var lines = stderrText.split("\n")
    for (var i = lines.length - 1; i >= 0; i--) {
      var line = String(lines[i] || "").trim()
      if (line !== "") return line.slice(0, 240)
    }
    return ""
  }

  Process {
    id: fetchProc
    running: false

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyOutput(text)
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.stderrText = String(text || "").trim()
    }

    onExited: function(exitCode, exitStatus) {
      if (root.gotOutput && exitCode === 0) root.usedFallback = false
      if (!root.gotOutput) {
        // The background service may not be running yet; a private server can
        // answer the same request from the same credentials.
        if (exitCode !== 0 && !root.usedFallback) {
          root.usedFallback = true
          root.spawnFetch("fallback")
          return
        }
        var line = root.lastStderrLine()
        var message = line !== ""
          ? line
          : (exitCode === 127 ? "opencode not found; set the executable in the widget settings"
            : exitCode === 0 ? (root.lastErrorMessage !== "" ? root.lastErrorMessage : "opencode api returned no data")
            : "opencode api failed (exit " + exitCode + ")")
        root.handleFailure(message, Date.now())
      }
    }
  }

  // Read the cache synchronously so the first frame already has data, then wait
  // out whatever remains of the interval instead of fetching on every restart.
  FileView {
    id: cacheFile
    path: root.cachePath
    blockLoading: true
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: if (root.startupDone) root.loadCache(text())
    onLoadFailed: if (root.startupDone) root.loadCache("")
  }

  // FileView's writer needs the parent directory to exist. mkdir -p is
  // idempotent and finishes long before the first fetch can succeed.
  Process {
    id: cacheDirProc
    command: ["install", "-d", "-m", "700", root.cacheDir]
    running: true
  }

  Component.onCompleted: {
    root.loadCache(cacheFile.loaded ? cacheFile.text() : "")
    root.cacheLoadAttempted = true
    root.startupDone = true
    Qt.callLater(function() {
      root.settingsReady = true
      if (root.pollLeader) root.startPolling()
    })
  }

  Component.onDestruction: Model.pollRelease(root)

  function runStats() {
    if (!showLocalStats || statsProc.running) return
    statsProc.command = ["/bin/sh", "-lc", Model.shellQuote(executable) + " stats --days 30 --json"]
    statsProc.running = true
  }

  Process {
    id: statsProc
    running: false

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = Model.parseStats(text)
        if (parsed !== null) {
          root.stats = parsed
          root.lastStatsMs = Date.now()
        }
      }
    }
  }

  // One-shot, re-armed after every result. Its interval is derived from the
  // cache timestamps, so a restart inherits the previous process's schedule.
  Timer {
    id: poll
    repeat: false
    running: root.pollLeader
    triggeredOnStart: false
    onTriggered: root.requestFetch("auto")
  }

  // A manual refresh inside the cooldown runs once the floor opens.
  Timer {
    id: manualCatchup
    repeat: false
    onTriggered: root.requestFetch("manual")
  }

  // Leadership heartbeat and result fan-out across monitors. Followers see
  // success and failure publishes because seq moves on both.
  Timer {
    id: pollCoordination
    interval: 5000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: {
      var wasLeader = root.pollLeader
      root.pollLeader = Model.pollClaim(root, Date.now())
      if (root.pollLeader && !wasLeader) root.startPolling()
      if (root.pollLeader || wasLeader) return
      var shared = Model.pollConsume(root)
      if (shared && shared.seq > root.consumedSeq) {
        root.consumedSeq = shared.seq
        root.applyResult(shared)
      }
    }
  }

  // Keeps "Resets in" and "Updated" honest while the popup is open.
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  // Local history is cheap to read but pointless to poll while closed.
  Timer {
    interval: 300000
    running: root.opened
    repeat: true
    onTriggered: root.runStats()
  }

  onOpenedChanged: if (opened) {
    nowMs = Date.now()
    // A fresh cache is enough for the popup; only ask when the interval has
    // actually elapsed. The leader's scheduled timer usually does this alone.
    if (root.pollLeader) {
      if (!root.hasData && !fetchProc.running) root.requestFetch("auto")
      else if (root.lastFetchMs > 0 && Date.now() - root.lastFetchMs > root.refreshIntervalSec * 1000) root.requestFetch("auto")
    }
    if (showLocalStats && Date.now() - lastStatsMs > 300000) runStats()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function openConsole() {
    Qt.openUrlExternally(Model.consoleURL(root.report))
  }

  function handleClick(buttonCode) {
    if (buttonCode === Qt.MiddleButton) root.refreshNow()
    else if (buttonCode === Qt.RightButton) {
      if (rightClickCommand !== "" && root.bar) root.bar.run(rightClickCommand)
      else root.openConsole()
    } else {
      root.toggle()
    }
  }

  // ShellIpc (not a bare IpcHandler) so both `omarchy-shell <target> …` and
  // `qs ipc` reach the widget. The base Panel handler is off to avoid two
  // registrations for the same target.
  ShellIpc {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
    function text(): string { return root.compactText }
  }

  // -------------------------------------------------------------------- bar

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    dimmed: !root.hasData
    active: root.alarming
    tooltipText: root.tooltipText
    fixedWidth: root.vertical ? -1 : Math.ceil(content.implicitWidth + button.scaledHorizontalMargin * 2)
    fixedHeight: root.vertical ? Math.ceil(content.implicitHeight + button.scaledVerticalPadding * 2) : -1

    onPressed: function(buttonCode) { root.handleClick(buttonCode) }

    Grid {
      id: content
      anchors.centerIn: parent
      columns: root.vertical ? 1 : 2
      rows: root.vertical ? 2 : 1
      columnSpacing: Style.space(5)
      rowSpacing: Style.space(3)
      verticalItemAlignment: Grid.AlignVCenter
      horizontalItemAlignment: Grid.AlignHCenter

      OpencodeMark {
        markSize: Style.bar.iconFont + 3
        color: root.alarming ? root.stateColor("critical") : root.foreground
      }

      Text {
        textFormat: Text.PlainText
        visible: root.barStyle === "text" && root.compactText !== ""
        text: root.compactText
        color: root.highest ? root.stateColor(root.highest.state) : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        renderType: Text.NativeRendering
      }

      Column {
        visible: root.barStyle === "bars" && root.barWindows.length > 0
        spacing: Style.space(2)

        Repeater {
          model: root.barStyle === "bars" ? root.barWindows : []

          Item {
            id: miniMeter
            required property var modelData
            width: Style.space(20)
            height: Style.space(3)

            Rectangle {
              anchors.fill: parent
              radius: height / 2
              color: root.track
            }

            Rectangle {
              width: Math.max(height, parent.width * miniMeter.modelData.percent / 100)
              height: parent.height
              radius: height / 2
              color: root.stateColor(miniMeter.modelData.state)

              Behavior on width {
                NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic }
              }
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------------------------ popup

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTextKey: function(text) {
        if (text === "r") root.refreshNow()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: panelColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height

        Column {
          id: panelColumn
          width: panelFlick.width
          spacing: Style.space(14)

          PanelHero {
            width: parent.width
            title: "OpenCode Go"
            meta: root.heroMeta
            detail: root.heroDetail
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              OpencodeMark {
                markSize: Style.font.display
                color: root.alarming ? root.stateColor("critical") : root.foreground
              }
            }

            trailingControl: Component {
              Row {
                spacing: Style.spacing.sm

                PanelActionButton {
                  iconText: "󰏌"
                  tooltipText: "Open Console usage"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.openConsole()
                }

                PanelActionButton {
                  iconText: "󰑐"
                  tooltipText: root.busy ? "Refreshing…" : "Refresh (r)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  enabled: !root.busy
                  onClicked: root.refreshNow()
                }
              }
            }
          }

          PanelSeparator {
            foreground: root.foreground
          }

          // Empty / error state. The copy points at the fix rather than just
          // saying the fetch failed.
          Column {
            visible: !root.hasData
            width: parent.width
            spacing: Style.space(4)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.errorText !== "" ? "No usage data" : "Fetching limits"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.errorText !== ""
                ? root.errorText
                : "Asking the OpenCode service for your Go allowance."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              textFormat: Text.PlainText
              visible: root.errorText !== ""
              width: parent.width
              text: "The widget reads the account already signed in to the installed OpenCode (`opencode auth list`)."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Repeater {
            model: root.hasData ? root.allWindows : []

            LimitRow {
              required property var modelData
              width: panelColumn.width
              window: modelData
            }
          }

          Column {
            visible: root.budgets.length > 0
            width: parent.width
            spacing: Style.space(10)

            PanelSeparator {
              foreground: root.foreground
            }

            PanelSectionHeader {
              foreground: root.foreground
              fontFamily: root.fontFamily
              text: "Console budgets"
            }

            Repeater {
              model: root.budgets

              BudgetRow {
                required property var modelData
                width: parent.width
                budget: modelData
              }
            }
          }

          Column {
            visible: root.showLocalStats && root.stats !== null
            width: parent.width
            spacing: Style.space(5)

            PanelSeparator {
              foreground: root.foreground
            }

            PanelSectionHeader {
              foreground: root.foreground
              fontFamily: root.fontFamily
              text: "Local activity · 30 days"
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: {
                if (!root.stats) return ""
                var sessions = root.stats.sessions === 1 ? "1 session" : root.stats.sessions + " sessions"
                var prompts = root.stats.prompts === 1 ? "1 prompt" : root.stats.prompts + " prompts"
                return prompts + " · " + sessions + " · " + Model.formatCost(root.stats.cost) + " est."
              }
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: {
                if (!root.stats) return ""
                return Model.formatCount(root.stats.input) + " input · "
                  + Model.formatCount(root.stats.output) + " output · "
                  + Model.formatCount(root.stats.cacheRead) + " cached"
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.footerText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  // One limit window: label and percentage, meter, reset countdown.
  component LimitRow: Column {
    id: limitRow
    property var window: null

    readonly property color valueColor: root.stateColor(window ? window.state : "normal")
    readonly property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

    width: parent ? parent.width : implicitWidth
    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(limitLabel.implicitHeight, limitValue.implicitHeight)

      Text {
        id: limitLabel
        textFormat: Text.PlainText
        text: limitRow.window ? limitRow.window.detail : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        anchors.left: parent.left
        anchors.right: limitValue.left
        anchors.rightMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: limitValue
        textFormat: Text.PlainText
        text: limitRow.window ? Model.percentText(limitRow.window.percent) : "—"
        color: limitRow.valueColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Item {
      width: parent.width
      implicitHeight: limitRow.thickness

      Rectangle {
        id: meterTrack
        anchors.fill: parent
        radius: height / 2
        color: root.track
      }

      Rectangle {
        anchors.left: meterTrack.left
        anchors.verticalCenter: meterTrack.verticalCenter
        height: meterTrack.height
        radius: meterTrack.radius
        width: Math.max(height, meterTrack.width * (limitRow.window ? limitRow.window.percent : 0) / 100)
        color: limitRow.valueColor

        Behavior on width {
          NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic }
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: {
        if (!limitRow.window) return ""
        var reset = Model.resetText(limitRow.window.resetsAt, root.nowMs)
        var clock = root.clockAt(limitRow.window.resetsAt)
        var when = clock !== "" ? reset + " (" + clock + ")" : reset
        if (limitRow.window.limited) return when !== "" ? "Limit reached · " + when : "Limit reached"
        return when
      }
      color: limitRow.window && limitRow.window.limited ? limitRow.valueColor : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }

  // Console budget: dollars rather than a percentage allowance.
  component BudgetRow: Column {
    id: budgetRow
    property var budget: null

    readonly property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

    width: parent ? parent.width : implicitWidth
    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(budgetLabel.implicitHeight, budgetValue.implicitHeight)

      Text {
        id: budgetLabel
        textFormat: Text.PlainText
        text: budgetRow.budget && budgetRow.budget.label !== "" ? budgetRow.budget.label : "Console budget"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        anchors.left: parent.left
        anchors.right: budgetValue.left
        anchors.rightMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: budgetValue
        textFormat: Text.PlainText
        text: budgetRow.budget
          ? Model.formatCost(budgetRow.budget.spent) + " / " + Model.formatCost(budgetRow.budget.limit)
          : "—"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Item {
      width: parent.width
      implicitHeight: budgetRow.thickness

      Rectangle {
        id: budgetTrack
        anchors.fill: parent
        radius: height / 2
        color: root.track
      }

      Rectangle {
        anchors.left: budgetTrack.left
        anchors.verticalCenter: budgetTrack.verticalCenter
        height: budgetTrack.height
        radius: budgetTrack.radius
        width: Math.max(height, budgetTrack.width * (budgetRow.budget ? budgetRow.budget.percent : 0) / 100)
        color: root.stateColor(Model.stateOf(budgetRow.budget ? budgetRow.budget.percent : 0, root.warnPercent, root.criticalPercent))

        Behavior on width {
          NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic }
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: {
        if (!budgetRow.budget) return ""
        var reset = Model.resetText(budgetRow.budget.resetsAt, root.nowMs)
        var clock = root.clockAt(budgetRow.budget.resetsAt)
        return clock !== "" ? reset + " (" + clock + ")" : reset
      }
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }
}
