#!/usr/bin/env bash
set -euo pipefail

# Installs the Gaming Mode backend: aeron-daemon, its user service, the Decky
# plugin, and (with --udev) persistent HID/DDC device permissions.
# Works from a release tarball (files next to this script) and from the git tree.
#
# Run it as your desktop user (deck). It asks for your password for the steps that
# need root (Decky's plugin folder, udev rules). Running it with sudo also works:
# the per-user steps are handed back to the user who ran sudo.

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

if [[ $EUID -eq 0 ]]; then
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    # `systemctl --user` needs the user's own session bus, and ~ must be the user's home.
    user_uid="$(id -u "$SUDO_USER")"
    user_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    exec sudo -u "$SUDO_USER" env \
      HOME="$user_home" \
      XDG_RUNTIME_DIR="/run/user/$user_uid" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$user_uid/bus" \
      PATH="$PATH" \
      bash "$SCRIPT_PATH" "$@"
  fi
  echo "error: run this as your desktop user (for example deck), not as root." >&2
  exit 1
fi

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

if [[ ! -f "$DAEMON_SRC" ]]; then
  echo "error: aeron-daemon not found at $DAEMON_SRC" >&2
  echo "From a git checkout, build it first: cargo build --release -p aeron-daemon" >&2
  exit 1
fi
if [[ ! -f "$DECKY_SRC/dist/index.js" || ! -f "$DECKY_SRC/main.py" || ! -f "$DECKY_SRC/plugin.json" ]]; then
  echo "error: Decky plugin not found in $DECKY_SRC" >&2
  echo "From a git checkout, build it first: npm run build (in platforms/steamos/decky)" >&2
  exit 1
fi

# Earlier installers run with sudo put the daemon in root's home, where nothing starts it.
if sudo test -e /root/.local/bin/aeron-daemon || sudo test -e /root/.config/systemd/user/aeron-daemon.service; then
  sudo rm -f /root/.local/bin/aeron-daemon /root/.config/systemd/user/aeron-daemon.service
  echo "Removed a copy of aeron-daemon that an earlier sudo install left in /root."
fi

# 1. Daemon and its user service.
mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user"
systemctl --user stop aeron-daemon.service 2>/dev/null || true
cp "$DAEMON_SRC" "$HOME/.local/bin/aeron-daemon"
chmod +x "$HOME/.local/bin/aeron-daemon"
cp "$UNIT_SRC" "$HOME/.config/systemd/user/aeron-daemon.service"
echo "Installed aeron-daemon to ~/.local/bin/aeron-daemon"

if systemctl --user daemon-reload 2>/dev/null; then
  systemctl --user enable aeron-daemon.service
  systemctl --user restart aeron-daemon.service
  echo "aeron-daemon.service is enabled and running."
else
  echo "warning: could not reach your systemd user session; aeron-daemon starts at your next login." >&2
  mkdir -p "$HOME/.config/systemd/user/default.target.wants"
  ln -sf "$HOME/.config/systemd/user/aeron-daemon.service" \
    "$HOME/.config/systemd/user/default.target.wants/aeron-daemon.service"
fi

# 2. Decky plugin. Decky Loader owns ~/homebrew/plugins as root and runs as a system service.
DECKY_DEST="$HOME/homebrew/plugins/aeron-tools"
if [[ -d "$HOME/homebrew/plugins" ]]; then
  sudo mkdir -p "$DECKY_DEST/dist"
  sudo cp "$DECKY_SRC/plugin.json" "$DECKY_SRC/main.py" "$DECKY_DEST/"
  sudo cp "$DECKY_SRC/dist/index.js" "$DECKY_DEST/dist/index.js"
  echo "Installed the Decky plugin to $DECKY_DEST"
  if sudo systemctl restart plugin_loader.service 2>/dev/null; then
    echo "Restarted Decky Loader."
  else
    echo "Restart Decky Loader (or the Deck) so Gaming Mode picks up the plugin."
  fi
else
  echo "warning: Decky Loader is not installed (~/homebrew/plugins is missing); skipped the Gaming Mode plugin." >&2
fi

# 3. Device permissions.
if [[ "${1:-}" == "--udev" ]]; then
  sudo cp "$UDEV_SRC" /etc/udev/rules.d/99-aeron-tools.rules
  sudo udevadm control --reload-rules
  sudo udevadm trigger
  echo "Installed udev rules to /etc/udev/rules.d/99-aeron-tools.rules. Replug receivers and docks if controls stay unavailable."
else
  echo "Run again with --udev to install HID and DDC/CI permissions."
fi
