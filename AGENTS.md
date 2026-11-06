# AGENTS.md

OpenCode Go Usage — an Omarchy shell bar widget for OpenCode Go limits
(5-hour session, week, month) with a detail popup and a request-friendly cache.

## Layout

- `manifest.json` — plugin id, bar-widget entry point, settings schema.
- `Panel.qml` — bar widget and popup; owns lifecycle, fetching, and cache wiring.
- `OpencodeMark.qml` — the OpenCode mark drawn as QML rectangles.
- `Model.js` — pure parsing, formatting, cache, and poll-coordination helpers.
- `preview.png`, `screenshots/bar.png` — README images.
- `scripts/install.sh` — deploy to the live plugin directory.
- `scripts/validate.sh` — manifest + required-file check used by CI.

## Source and deploy

- Source of truth: this repository.
- Live copy: `~/.config/omarchy/plugins/crueber.opencode-usage/`.
- Deploy with `./scripts/install.sh`; it copies the runtime files, validates the
  manifest, rescans plugins, and enables the widget if needed.
- Do **not** put a `.git` directory inside the live plugin folder. Quickshell
  watches that tree and a git checkout can trigger reload races. Keep the repo
  here and copy files in.
- GitHub `crueber/omarchy-plugin-opencode-usage` is the push target. The
  Forgejo repo `git.packden.us/crueber/omarchy-plugin-opencode-usage` is a
  read-only daily pull mirror; do not push to it.

## Invariants

1. **No API keys.** Data comes from the installed OpenCode service:
   `opencode api GET /api/experimental/usage/limits`. A failure retries once
   with `--standalone`. Never read or copy `auth.json` into this repo.
2. **One fetch choke point.** Scheduled polls, panel opens, middle click, `r`,
   and IPC all go through `requestFetch()`. Do not spawn `fetchProc` elsewhere;
   that bypasses the 60 s automatic / 30 s manual floors.
3. **Persistent cache.** `~/.cache/opencode-usage/usage.json` stores the last
   success, last attempt (including failures), failure count, and error. The
   attempt time is written before a request so a restart mid-fetch is
   remembered. Keep the schema versioned and validate with `Model.parseCache`.
4. **One leader per engine.** `Model.js` is a `.pragma library`; `pollState` is
   shared by every monitor's widget instance. The elected leader fetches and
   publishes by sequence number; followers consume. Leadership is heartbeat
   based, so a destroyed leader is replaced.
5. **Failed refresh keeps old data.** Do not clear `report` on a failed check.
   The popup should show the last numbers with a `refresh failed` note.
6. **Text safety.** Every dynamic string in a `Text` uses
   `textFormat: Text.PlainText`. Workspace names passed to Omarchy-owned
   components are sanitized by `Model.plain()`. URLs are restricted to
   `https://opencode.ai/`.
7. **Theme first.** Use `Style`/`Color` tokens (sizes, spacing, font, urgent
   colour); QML files use two-space indentation.

## Testing

- `./scripts/validate.sh` — manifest and file presence.
- `omarchy plugin validate ~/.config/omarchy/plugins/crueber.opencode-usage`
- Restart before judging QML changes: `omarchy restart shell` (the plugin file
  watcher reloads unreliable; stale panels are a known artifact).
- IPC: `omarchy-shell opencode-usage text` and `omarchy-shell
  opencode-usage refresh`; shell summon: `omarchy-shell shell toggle
  crueber.opencode-usage`.
- Logs: `journalctl --user -t omarchy-shell --since "-2 min" | grep -i opencode`.
- Cache checks: note `attemptedAt` in `~/.cache/opencode-usage/usage.json`,
  restart the shell, and confirm it did not change. Delete the cache to force
  a fresh check.
- Visual checks without input synthesis: `grim` a crop of the bar or popup and
  inspect it; `omarchy capture screenshot` also works.

## Notes

- The usage endpoint is experimental; update `Model.parseReport` if its shape
  changes.
- Default refresh is 5 minutes. If you lower it, keep the automatic floor at
  60 seconds and the manual floor at 30 seconds.
- Bump `manifest.json` `version` for user-visible changes.
