#!/usr/bin/env bash
set -euo pipefail

# Installs the Gaming Mode backend: aeron-daemon, its user service, the Decky
# plugin, and (with --udev) persistent HID/DDC device permissions.
# Works from a release tarball (files next to this script) and from the git tree.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$SCRIPT_DIR/aeron-daemon" ]]; then
  DAEMON_SRC="$SCRIPT_DIR/aeron-daemon"
  UNIT_SRC="$SCRIPT_DIR/aeron-daemon.service"
  UDEV_SRC="$SCRIPT_DIR/99-aeron-tools.rules"
  DECKY_SRC="$SCRIPT_DIR/decky"
else
  ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
  DAEMON_SRC="$ROOT_DIR/target/release/aeron-daemon"
  UNIT_SRC="$SCRIPT_DIR/aeron-daemon.service"
  UDEV_SRC="$SCRIPT_DIR/99-aeron-tools.rules"
  DECKY_SRC="$SCRIPT_DIR/../decky"
fi

mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user"

if [[ -f "$DAEMON_SRC" ]]; then
  cp "$DAEMON_SRC" "$HOME/.local/bin/aeron-daemon"
  chmod +x "$HOME/.local/bin/aeron-daemon"
  echo "Installed aeron-daemon to ~/.local/bin/aeron-daemon"
else
  echo "error: aeron-daemon not found at $DAEMON_SRC" >&2
  echo "From a git checkout, build it first: cargo build --release -p aeron-daemon" >&2
  exit 1
fi

cp "$UNIT_SRC" "$HOME/.config/systemd/user/aeron-daemon.service"
systemctl --user daemon-reload
systemctl --user enable --now aeron-daemon.service || true
echo "aeron-daemon.service is installed."

if [[ -f "$DECKY_SRC/dist/index.js" && -f "$DECKY_SRC/main.py" && -f "$DECKY_SRC/plugin.json" ]]; then
  DECKY_DEST="$HOME/homebrew/plugins/aeron-tools"
  mkdir -p "$DECKY_DEST/dist"
  cp "$DECKY_SRC/plugin.json" "$DECKY_SRC/main.py" "$DECKY_DEST/"
  cp "$DECKY_SRC/dist/index.js" "$DECKY_DEST/dist/index.js"
  echo "Installed Decky plugin to $DECKY_DEST"
  systemctl --user restart plugin_loader.service || echo "Restart Decky Loader so Gaming Mode picks up the plugin."
else
  echo "Decky plugin was not installed. Build it with: npm run build (in platforms/steamos/decky)" >&2
  exit 1
fi

if [[ "${1:-}" == "--udev" ]]; then
  echo "Installing persistent udev rules to /etc/udev/rules.d/99-aeron-tools.rules (requires sudo)..."
  sudo cp "$UDEV_SRC" /etc/udev/rules.d/99-aeron-tools.rules
  sudo udevadm control --reload-rules
  sudo udevadm trigger
  echo "udev rules installed."
else
  echo "Run again with --udev to install HID and DDC/CI permissions."
fi
