# OpenCode Go Usage

[![validate](https://github.com/crueber/omarchy-plugin-opencode-usage/actions/workflows/validate.yml/badge.svg)](https://github.com/crueber/omarchy-plugin-opencode-usage/actions/workflows/validate.yml)

An Omarchy bar widget for your OpenCode Go allowance. It draws the OpenCode
mark in the bar with three small meters — 5-hour session, week, and month — and
opens a popup with percentages, reset countdowns, Console budgets, and local
activity.

![OpenCode mark and three limit meters in the Omarchy bar](screenshots/bar.png)

The numbers come from the OpenCode service already running on your machine, so
there is no API key to paste and no second login:

```bash
opencode api GET /api/experimental/usage/limits
```

That endpoint reports the Go allowance and Console budgets of the workspace
your installed OpenCode is signed in to. If the background service is not
running, the widget retries once with `--standalone`, which starts a private
server for the request and reads the same credentials.

The endpoint is experimental, so a future OpenCode release may change its shape.

![OpenCode Go Usage popup](preview.png)

## What it shows

In the bar (default `bars` style):

- the OpenCode mark, drawn in QML so it follows the theme colour and stays crisp
- one meter per visible limit window, in session → week → month order
- the meters turn the warning colour at `warnPercent` and the urgent colour at
  `criticalPercent`

In the popup:

- **5-hour session**, **Weekly**, and **Monthly** rows with percentage, meter,
  and a reset countdown plus the absolute reset clock
- **Console budgets**, when the workspace has any
- **Local activity · 30 days**: prompts, sessions, tokens, and estimated cost
  from your local OpenCode history (`opencode stats --json`)
- links to your Console usage page, and a refresh action

### Credits and balance

The popup shows Console budgets when your workspace has them, but it does not
show a dollar credit balance. The local OpenCode API reports Go limits and
Console budgets only; the Console credit balance lives behind the Console web
session, not the installed CLI login. Open **Console → Settings › Billing** to
check credits, or the **Go** page to turn on **Extra Usage**. The widget never
invents an amount when the API does not report one.

## Install

Install it the standard Omarchy way:

```bash
omarchy plugin add https://github.com/crueber/omarchy-plugin-opencode-usage --enable
```

Or clone the repo and run the installer, which also places the widget in the
right bar section:

```bash
git clone https://github.com/crueber/omarchy-plugin-opencode-usage.git
cd omarchy-plugin-opencode-usage
./scripts/install.sh
```

The installer copies the runtime files to
`~/.config/omarchy/plugins/crueber.opencode-usage/`, validates the manifest, and
enables the widget in the right bar section. Pass another section as the first
argument (`left`, `centerBegin`, `center`, `centerEnd`, `right`).

To place it beside another widget after installing:

```bash
omarchy plugin enable crueber.opencode-usage --section right --after nino.tailscale
```

The widget hot-reloads when files are saved. If the popup keeps showing an old
build after a change, restart the shell once with `omarchy restart shell`.

## Use

- **Left click** — open or close the popup
- **Middle click** — refresh now
- **Right click** — open your Console usage page (or `onRightClick` if set)
- **`r`** — refresh while the popup is open

## Remove

Disable and remove the widget, then clear its cache:

```bash
omarchy plugin disable crueber.opencode-usage
omarchy plugin remove crueber.opencode-usage
rm -rf ~/.cache/opencode-usage
```

`omarchy plugin remove` deletes the plugin directory after disabling it. The
`rm` is optional — it only discards the cached response, so the last numbers do
not linger on disk. The plugin writes nothing outside
`~/.config/omarchy/plugins/crueber.opencode-usage/` and
`~/.cache/opencode-usage/`; the bar layout itself lives in `shell.json` and is
managed by Omarchy. A clone of this repository can be deleted as well.

## Caching and request pacing

A shell restart creates a fresh QML engine, so the widget keeps its last
successful response on disk:

```
~/.cache/opencode-usage/usage.json
```

On startup it paints that response immediately and waits out the rest of the
refresh interval instead of asking again. The same file records the last
attempt time even when the request failed, so a restart loop — or a machine
where OpenCode is not running yet — does not hammer the service.

- Automatic refresh: `refreshIntervalSec`, default **5 minutes** (minimum 60
  seconds), measured from the last successful check.
- Manual refresh (`click`, `r`, middle click): at most once every **30
  seconds**; a click inside that window is deferred, not dropped.
- Failed checks back off from **1 minute up to 10 minutes**.
- One bar surface per monitor, but only the elected leader fetches; the others
  consume the published result.

## Privacy

No telemetry, no analytics, and no network requests of the widget's own. Every
number comes from the local `opencode` CLI; with `--standalone` it starts a
private server for that single request. The widget itself never reads, copies,
or stores your OpenCode credentials — authentication stays with the CLI — and it
has no API key or token of its own.

The only file it writes is the cache:

```
~/.cache/opencode-usage/usage.json
```

It is created inside a mode-`0700` directory and holds the last reported
workspace name, id, and usage URL, the limit percentages and reset timestamps,
any Console budget amounts, the last request time, and the failure count.
Nothing else — no prompts, session content, message text, or file paths.
Delete the file or the directory at any time to clear it; the widget re-fetches
on its next check.

## Development

This repository is the source of truth; the live plugin is
`~/.config/omarchy/plugins/crueber.opencode-usage/` and should be updated with
`./scripts/install.sh` rather than editing in place. `AGENTS.md` documents the
architecture invariants (fetch gate, cache schema, leader election, text
safety) for anyone — human or agent — changing the plugin.

```bash
./scripts/validate.sh   # manifest + required files; also runs in CI
./scripts/install.sh    # copy to the live plugin dir and enable
```

`demo/` holds an offline fixture that impersonates the `opencode` CLI so the
preview and bar screenshots can be captured with invented data — no workspace,
account, or usage numbers of a real install. See `demo/README.md`.

## Settings

Settings live inline on the widget's `shell.json` entry and are described in
`manifest.json`:

| Key | Default | Meaning |
| --- | --- | --- |
| `barStyle` | `bars` | `bars`, `text`, or `icon` |
| `showSession` | `true` | Show the 5-hour session meter |
| `showWeekly` | `true` | Show the weekly meter |
| `showMonthly` | `true` | Show the monthly meter |
| `refreshIntervalSec` | `300` | Poll interval (60–3600) |
| `warnPercent` | `70` | Warning threshold |
| `criticalPercent` | `90` | Critical threshold |
| `warningColor` | `#f67400` | Empty keeps the theme foreground |
| `criticalColor` | `""` | Empty uses the theme urgent colour |
| `opencodeCommand` | `""` | Optional path to the `opencode` binary |
| `showLocalStats` | `true` | Show local activity in the popup |
| `onRightClick` | `""` | Optional shell command |

For example:

```bash
omarchy bar set crueber.opencode-usage refreshIntervalSec 300
omarchy bar set crueber.opencode-usage barStyle text
```

## Requirements and dependencies

- Omarchy Quattro with the Omarchy shell bar.
- OpenCode v2.x, signed in to a workspace (`opencode auth list`), with the
  `opencode` executable on your login-shell PATH — or an absolute path in the
  `opencodeCommand` setting.

Nothing else is required: no API key, no extra packages, no service of its own,
no sudo, and no network access beyond the local `opencode` CLI. The helper
scripts use the tools Omarchy already ships (`bash`, `jq`).

## Licence

MIT
