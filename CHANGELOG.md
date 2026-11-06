# Changelog

## Unreleased

- Document that Console credits/balance are not exposed by the local OpenCode
  API; the popup continues to show Console budgets only.
- README: add removal steps, explicit requirements/dependencies, and a privacy
  note; add the standard `omarchy plugin add` install command.
- Add `demo/` screenshot tooling: an offline `opencode` fixture plus a capture
  script that backs up and restores the widget entry and cache, and refuses to
  write a preview that still contains real account data.

## 1.0.0 — 2026-11-05

Initial release.

- Omarchy bar widget for OpenCode Go: custom QML OpenCode mark plus meters for
  the 5-hour session, weekly, and monthly limits.
- Bar styles: `bars`, `text`, and `icon`.
- Popup with percentage, meter, reset countdown, absolute reset clock, Console
  budgets, and local 30-day activity (prompts, sessions, tokens, estimated cost).
- Uses the installed OpenCode login through
  `opencode api GET /api/experimental/usage/limits`; no API key or second login.
  Falls back to `opencode api --standalone` when the background service is down.
- Persistent disk cache at `~/.cache/opencode-usage/usage.json`; restarts paint
  cached data and wait out the remaining refresh interval.
- Request pacing: 5-minute default refresh (minimum 60 s), 30-second manual
  floor with deferred refreshes, 1–10 minute failure backoff, and one fetch per
  interval across monitors through leader election.
- Failed refreshes keep the last good data and annotate the footer.
