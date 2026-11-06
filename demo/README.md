# Demo fixture and screenshot capture

The preview image in this repository is a capture of the real widget filled
with **invented** data. This directory reproduces it without touching a real
OpenCode account, workspace, or cache.

- `opencode-demo` — a stand-in for the `opencode` CLI. It answers exactly the
  two invocations the widget makes (`api GET …/usage/limits` and
  `stats --days 30 --json`) with a fixed demo report: workspace `demo`,
  24 / 41 / 9 %, relative reset times, and invented local activity. Anything
  else exits non-zero. No network, no credentials, no filesystem reads.
- `capture-preview.sh` — points the widget's `opencodeCommand` setting at the
  shim, backs up the widget entry and usage cache, captures the bar and popup,
  composes a clean `preview.png` plus `screenshots/bar.png`, runs the
  anonymisation check, and restores everything on every exit path.

## Why a fixture instead of redaction

`Panel.qml` builds both calls from one setting, so pointing `opencodeCommand`
at the shim replaces the limits request and the local-stats request at once.
Nothing in the plugin needs a demo mode, no fixture code ships to users, and no
pixel-level blurring can miss a number.

## Run it

```bash
chmod +x demo/opencode-demo demo/capture-preview.sh
demo/capture-preview.sh --help

# Normal capture (writes preview.png and screenshots/bar.png in the repo root):
demo/capture-preview.sh

# While another session is using the shell, rescan-only (the default) is safe;
# if the widget does not pick up the fixture, opt in to one restart:
demo/capture-preview.sh --allow-restart
```

The script needs `grim`, ImageMagick (`magick`), `tesseract`, `jq`, and the
Omarchy CLI. It opens and closes the popup once and takes about two seconds.

## What it changes, and what it puts back

| Touched | Backup | Restore |
| --- | --- | --- |
| `~/.config/omarchy/shell.json` widget entry | `$TMPDIR/opencode-usage-capture/backup/entry.json` + full `shell.json` copy | the two changed keys (`opencodeCommand`, `showLocalStats`) via `omarchy bar set` |
| `~/.cache/opencode-usage/usage.json` | `backup/usage.json` | byte-for-byte copy back, or removed if there was none |

A `trap` runs the restore on success, failure, Ctrl-C, and `SIGTERM`. A
successful run removes its temporary directory; a failed one keeps the raw
shots and backups for diagnosis. `--keep-raw` keeps them in both cases.

## Quality gate

`capture-preview.sh` runs OCR on the result and **fails** if it finds
`crueber`, any e-mail address, `$15`/`15.52`, the old token or prompt counts,
or an account id prefix (`ws_…`). It also requires the demo workspace name and
the three limit labels to be readable, checks that the preview carries no EXIF
data, and confirms the cache held the demo report.

## Changing the fixture

Edit `opencode-demo`. Keep the workspace name `demo`, keep the values clearly
invented, and keep reset times relative to `date +%s` so countdowns stay
realistic. Then re-run the capture and commit the new `preview.png`.
