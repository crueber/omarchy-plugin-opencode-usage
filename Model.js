.pragma library

// Pure helpers for the OpenCode Go usage widget. Kept out of Panel.qml so the
// parsing and formatting rules stay readable and testable.

function number(value) {
  var n = typeof value === "number" ? value : Number(value)
  return isFinite(n) ? n : null
}

function clamp(value, low, high) {
  return Math.min(high, Math.max(low, value))
}

function clampInt(value, low, high, fallback) {
  var n = number(value)
  if (n === null) return fallback
  return Math.round(clamp(n, low, high))
}

function text(value, max) {
  if (typeof value !== "string") return ""
  return value.slice(0, max || 200)
}

// Neutralise markup-shaped names before they reach an Omarchy-owned text
// component whose format this plugin cannot set (PanelHero). Our own Text
// elements all use Text.PlainText.
function plain(value, max) {
  return text(value, max).replace(/</g, "\u2039").replace(/>/g, "\u203A")
}

// API percentages are nominally 0-100 but never trust the wire.
function percent(value) {
  var n = number(value)
  return n === null ? 0 : clamp(n, 0, 100)
}

function parseJson(raw) {
  var source = String(raw || "").replace(/^\uFEFF+/, "").trim()
  if (source === "" || source.length > 200000) return null
  try {
    return JSON.parse(source)
  } catch (e) {
    // `opencode api` normally prints one JSON document, but tolerate a log
    // line before it by slicing the outermost object.
    var start = source.indexOf("{")
    var end = source.lastIndexOf("}")
    if (start < 0 || end <= start) return null
    try {
      return JSON.parse(source.slice(start, end + 1))
    } catch (e2) {
      return null
    }
  }
}

function meter(value) {
  if (!value || typeof value !== "object") return null
  return {
    percent: percent(value.percent),
    limited: value.limited === true,
    resetsAt: number(value.resetsAt) || 0
  }
}

// Returns null when the response is not a usage-limits document at all, and
// { signedOut: true } when the local service answered but has no workspace.
function parseReport(raw) {
  var obj = parseJson(raw)
  if (!obj || typeof obj !== "object") return null

  var data = Object.prototype.hasOwnProperty.call(obj, "data") ? obj.data : obj
  if (data === null || data === undefined) {
    return { signedOut: true, workspace: null, go: null, budgets: [] }
  }
  if (typeof data !== "object") return null

  var ws = data.workspace && typeof data.workspace === "object" ? data.workspace : null
  var go = data.go && typeof data.go === "object" ? data.go : null

  return {
    signedOut: false,
    workspace: ws ? {
      id: text(ws.id, 80),
      name: plain(ws.name, 80),
      usageURL: text(ws.usageURL, 300)
    } : null,
    go: go ? {
      rolling: meter(go.rolling),
      weekly: meter(go.weekly),
      monthly: meter(go.monthly)
    } : null,
    budgets: parseBudgets(data.budgets)
  }
}

function parseBudgets(list) {
  if (!Array.isArray(list)) return []
  var out = []
  for (var i = 0; i < list.length && out.length < 8; i++) {
    var item = list[i]
    if (!item || typeof item !== "object") continue
    var limit = number(item.limit)
    var spent = number(item.spent)
    if (limit === null || spent === null || limit <= 0) continue
    out.push({
      id: text(item.id, 80),
      label: plain(item.id, 80),
      limit: limit,
      spent: spent,
      percent: percent((spent / limit) * 100),
      resetsAt: number(item.resetsAt) || 0
    })
  }
  return out
}

var WINDOW_DEFS = [
  { key: "rolling", label: "Session", short: "5h", detail: "5-hour session" },
  { key: "weekly", label: "Week", short: "7d", detail: "Weekly" },
  { key: "monthly", label: "Month", short: "1m", detail: "Monthly" }
]

function windows(report, warnPercent, criticalPercent) {
  if (!report || !report.go) return []
  var out = []
  for (var i = 0; i < WINDOW_DEFS.length; i++) {
    var def = WINDOW_DEFS[i]
    var source = report.go[def.key]
    if (!source) continue
    out.push({
      key: def.key,
      label: def.label,
      short: def.short,
      detail: def.detail,
      percent: percent(source.percent),
      limited: source.limited === true,
      resetsAt: source.resetsAt,
      state: stateOf(source.percent, warnPercent, criticalPercent)
    })
  }
  return out
}

function filterWindows(list, visible) {
  if (!Array.isArray(list)) return []
  var out = []
  for (var i = 0; i < list.length; i++) {
    if (visible[list[i].key] !== false) out.push(list[i])
  }
  return out
}

function stateOf(value, warnPercent, criticalPercent) {
  var p = percent(value)
  if (p >= criticalPercent) return "critical"
  if (p >= warnPercent) return "warning"
  return "normal"
}

function highest(list) {
  if (!Array.isArray(list) || list.length === 0) return null
  var best = list[0]
  for (var i = 1; i < list.length; i++) {
    if (list[i].percent > best.percent) best = list[i]
  }
  return best
}

function percentText(value) {
  var p = percent(value)
  var rounded = Math.round(p * 10) / 10
  return (rounded % 1 === 0 ? String(Math.round(rounded)) : rounded.toFixed(1)) + "%"
}

function resetText(resetsAt, now) {
  var target = number(resetsAt) || 0
  if (target <= 0) return ""
  var diff = target - now
  if (diff <= 0) return "Reset is due"
  var minutes = Math.floor(diff / 60000)
  var days = Math.floor(minutes / 1440)
  var hours = Math.floor((minutes % 1440) / 60)
  var mins = minutes % 60
  if (days >= 1) return "Resets in " + days + "d " + hours + "h"
  if (hours >= 1) return "Resets in " + hours + "h " + mins + "m"
  return "Resets in " + Math.max(1, mins) + "m"
}

function tooltip(list, now) {
  if (!Array.isArray(list) || list.length === 0) return "OpenCode Go usage"
  var lines = []
  for (var i = 0; i < list.length; i++) {
    var w = list[i]
    var line = w.detail + ": " + percentText(w.percent)
    if (w.limited) line += " · limit reached"
    lines.push(line)
    var reset = resetText(w.resetsAt, now)
    if (reset !== "") lines.push("  " + reset)
  }
  return lines.join("\n")
}

function compactText(list) {
  if (!Array.isArray(list) || list.length === 0) return ""
  var parts = []
  for (var i = 0; i < list.length; i++) parts.push(list[i].short + " " + percentText(list[i].percent))
  return parts.join(" · ")
}

function updatedText(lastFetchMs, now) {
  var last = number(lastFetchMs) || 0
  if (last <= 0) return ""
  var seconds = Math.max(0, Math.floor((now - last) / 1000))
  if (seconds < 5) return "Updated just now"
  if (seconds < 60) return "Updated " + seconds + "s ago"
  var minutes = Math.floor(seconds / 60)
  if (minutes < 60) return "Updated " + minutes + "m ago"
  var hours = Math.floor(minutes / 60)
  return "Updated " + hours + "h ago"
}

function consoleURL(report) {
  var url = report && report.workspace ? report.workspace.usageURL : ""
  if (typeof url === "string" && /^https:\/\/opencode\.ai\//.test(url) && url.length < 300) return url
  return "https://opencode.ai/console"
}

function formatCount(value) {
  var n = number(value)
  if (n === null) return "—"
  if (n >= 1000000000) return (n / 1000000000).toFixed(1) + "B"
  if (n >= 1000000) return (n / 1000000).toFixed(1) + "M"
  if (n >= 1000) return (n / 1000).toFixed(0) + "K"
  return String(Math.round(n))
}

function formatCost(value) {
  var n = number(value)
  if (n === null || n < 0) return "—"
  if (n > 0 && n < 0.01) return "<$0.01"
  return "$" + n.toFixed(2)
}

function parseStats(raw) {
  var obj = parseJson(raw)
  if (!obj || typeof obj !== "object") return null
  var tokens = obj.tokens && typeof obj.tokens === "object" ? obj.tokens : null
  var cache = tokens && tokens.cache && typeof tokens.cache === "object" ? tokens.cache : null
  return {
    sessions: number(obj.sessions) || 0,
    prompts: number(obj.prompts) || 0,
    cost: number(obj.cost) || 0,
    input: tokens ? (number(tokens.input) || 0) : 0,
    output: tokens ? (number(tokens.output) || 0) : 0,
    cacheRead: cache ? (number(cache.read) || 0) : 0,
    cacheWrite: cache ? (number(cache.write) || 0) : 0
  }
}

// Single-quote a value for /bin/sh. Only used for the user's own configured
// executable path, never for data from the network.
function shellQuote(value) {
  var s = String(value || "")
  return "'" + s.replace(/'/g, "'\\''") + "'"
}

// ------------------------------------------------------------ local cache
//
// A shell restart creates a fresh QML engine, so nothing survives in memory.
// The disk cache keeps the last successful response and the last attempt
// time, letting a fresh start paint immediately and wait out the rest of the
// refresh interval instead of asking the service again.

var CACHE_VERSION = 1
var AUTO_MIN_MS = 60000
var FORCE_MIN_MS = 30000
var FAILURE_CAP_MS = 600000

// The parsed report is already the sanitized subset we display; serialize it
// back to the API's `data` shape so a reload re-runs the same validation.
function slimReport(report) {
  if (!report) return null
  function slimMeter(m) {
    return m ? {
      percent: percent(m.percent),
      limited: m.limited === true,
      resetsAt: number(m.resetsAt) || 0
    } : null
  }
  var budgets = Array.isArray(report.budgets) ? report.budgets.slice(0, 8) : []
  var slimBudgets = []
  for (var i = 0; i < budgets.length; i++) {
    var b = budgets[i]
    if (!b) continue
    slimBudgets.push({
      id: text(b.id, 80),
      limit: number(b.limit) || 0,
      spent: number(b.spent) || 0,
      resetsAt: number(b.resetsAt) || 0
    })
  }
  return {
    workspace: report.workspace ? {
      id: text(report.workspace.id, 80),
      name: text(report.workspace.name, 80),
      usageURL: text(report.workspace.usageURL, 300)
    } : null,
    go: report.go ? {
      rolling: slimMeter(report.go.rolling),
      weekly: slimMeter(report.go.weekly),
      monthly: slimMeter(report.go.monthly)
    } : null,
    budgets: slimBudgets
  }
}

function serializeCache(report, fetchedAt, attemptedAt, failures, error, signedOut) {
  var cache = {
    version: CACHE_VERSION,
    fetchedAt: Math.max(0, Math.round(number(fetchedAt) || 0)),
    attemptedAt: Math.max(0, Math.round(number(attemptedAt) || 0)),
    failures: Math.round(clamp(number(failures) || 0, 0, 20)),
    error: text(error, 240),
    signedOut: signedOut === true,
    data: slimReport(report)
  }
  return JSON.stringify(cache) + "\n"
}

function parseCache(raw, nowMs) {
  var obj = parseJson(raw)
  if (!obj || obj.version !== CACHE_VERSION) return null

  var now = number(nowMs) || Date.now()
  var fetchedAt = number(obj.fetchedAt) || 0
  var attemptedAt = number(obj.attemptedAt) || 0
  // A clock change must not freeze polling for hours.
  if (fetchedAt > now + 300000) fetchedAt = 0
  if (attemptedAt > now + 300000) attemptedAt = 0
  if (fetchedAt < 0) fetchedAt = 0
  if (attemptedAt < 0) attemptedAt = 0

  var report = null
  var data = obj.data && typeof obj.data === "object" ? obj.data : null
  if (data !== null) {
    report = parseReport(JSON.stringify({ data: data }))
    if (report && report.signedOut) report = null
  }

  return {
    fetchedAt: fetchedAt,
    attemptedAt: attemptedAt,
    failures: Math.round(clamp(number(obj.failures) || 0, 0, 20)),
    error: text(obj.error, 240),
    signedOut: obj.signedOut === true,
    report: report
  }
}

// Milliseconds until the next automatic attempt. A successful check waits the
// configured interval; a failed check waits an escalating 1–10 minute cooldown
// from its own attempt time, so a restart loop that keeps failing cannot hammer
// the service. `attemptedAt` throttles even the first failure after a reload.
function autoDelayMs(fetchedAt, attemptedAt, failures, refreshMs, nowMs) {
  var now = number(nowMs) || Date.now()
  var interval = Math.max(AUTO_MIN_MS, number(refreshMs) || 300000)
  var last = number(fetchedAt) || 0
  var attempt = number(attemptedAt) || 0
  var fails = Math.max(0, Math.round(number(failures) || 0))
  var delay = 0

  if (last > 0) delay = Math.max(delay, last + interval - now)
  if (attempt > 0) {
    var cooldown = AUTO_MIN_MS
    if (fails > 0) cooldown = Math.min(FAILURE_CAP_MS, AUTO_MIN_MS * Math.pow(2, Math.min(fails - 1, 4)))
    delay = Math.max(delay, attempt + cooldown - now)
  }
  return Math.max(0, delay)
}

// --------------------------------------------------------- poll coordination
//
// The shell runs one QML engine for every monitor, and a .pragma library is
// loaded once per engine, so this state is shared by all widget instances.
// One instance (the "leader") owns the fetch loop; the others consume its
// published result. That keeps one request per interval no matter how many
// monitors show the widget. Leadership is heartbeat-based so a destroyed
// leader is replaced.

var pollState = {
  leader: null,
  beat: 0,
  seq: 0,
  report: null,
  signedOut: false,
  fetchedAt: 0,
  attemptedAt: 0,
  failures: 0,
  error: "",
  errorText: ""
}

function pollClaim(widget, nowMs) {
  if (pollState.leader === widget) {
    pollState.beat = nowMs
    return true
  }
  if (pollState.leader === null || nowMs - pollState.beat > 20000) {
    pollState.leader = widget
    pollState.beat = nowMs
    return true
  }
  return false
}

function pollRelease(widget) {
  if (pollState.leader === widget) pollState.leader = null
}

function pollPublish(widget, result) {
  if (pollState.leader !== widget) return
  pollState.report = result.report || null
  pollState.signedOut = result.signedOut === true
  pollState.fetchedAt = number(result.fetchedAt) || 0
  pollState.attemptedAt = number(result.attemptedAt) || 0
  pollState.failures = Math.round(number(result.failures) || 0)
  pollState.error = text(result.error, 240)
  pollState.errorText = text(result.errorText, 300)
  pollState.beat = Date.now()
  pollState.seq++
}

function pollConsume(widget) {
  if (pollState.leader === widget) return null
  return {
    seq: pollState.seq,
    report: pollState.report,
    signedOut: pollState.signedOut,
    fetchedAt: pollState.fetchedAt,
    attemptedAt: pollState.attemptedAt,
    failures: pollState.failures,
    error: pollState.error,
    errorText: pollState.errorText
  }
}

function pollLeaderInstance() {
  return pollState.leader
}

// A cache hit seeds the shared clock so the leader's first schedule respects
// an attempt made by the previous shell process.
function pollSeed(fetchedAt, attemptedAt, failures) {
  var last = number(fetchedAt) || 0
  var attempt = number(attemptedAt) || 0
  var fails = Math.round(number(failures) || 0)
  if (last > pollState.fetchedAt) pollState.fetchedAt = last
  if (attempt > pollState.attemptedAt) pollState.attemptedAt = attempt
  if (fails > pollState.failures) pollState.failures = fails
}
