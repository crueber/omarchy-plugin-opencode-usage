#!/usr/bin/env bash
set -euo pipefail

# Deploy the runtime files to the live Omarchy plugin directory.
# Usage: ./scripts/install.sh [bar-section]   (default: right)

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
plugin_id="crueber.opencode-usage"
section="${1:-right}"
dest="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$plugin_id"

command -v omarchy >/dev/null 2>&1 || {
  echo "omarchy is not on PATH; this script is for an Omarchy install" >&2
  exit 1
}

install -d "$dest"
for file in manifest.json Panel.qml OpencodeMark.qml Model.js README.md LICENSE preview.png; do
  install -m 0644 "$repo_dir/$file" "$dest/$file"
done

omarchy plugin validate "$dest"
omarchy-shell -q shell rescanPlugins || true

if ! omarchy plugin list --json | jq -e --arg id "$plugin_id" \
  'any(.[]; .id == $id and .enabled)' >/dev/null 2>&1; then
  omarchy plugin enable "$plugin_id" --section "$section"
else
  echo "$plugin_id is already enabled"
fi

echo "Installed $plugin_id to $dest"
