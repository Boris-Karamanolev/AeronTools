#!/usr/bin/env bash
set -euo pipefail

# Installs AeronTools headless daemon + persistent udev rules on SteamOS (immutable-safe).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user"

if [[ -f "$ROOT_DIR/target/release/aeron-daemon" ]]; then
  cp "$ROOT_DIR/target/release/aeron-daemon" "$HOME/.local/bin/aeron-daemon"
  chmod +x "$HOME/.local/bin/aeron-daemon"
  echo "Installed aeron-daemon to ~/.local/bin/aeron-daemon"
else
  echo "Warning: $ROOT_DIR/target/release/aeron-daemon not found. Build first with:"
  echo "  cargo build --release -p aeron-daemon"
fi

cp "$SCRIPT_DIR/aeron-daemon.service" "$HOME/.config/systemd/user/aeron-daemon.service"
systemctl --user daemon-reload
systemctl --user enable --now aeron-daemon.service || true

if [[ "${1:-}" == "--udev" ]]; then
  echo "Installing persistent udev rules to /etc/udev/rules.d/99-aeron-tools.rules (requires sudo)..."
  sudo cp "$SCRIPT_DIR/99-aeron-tools.rules" /etc/udev/rules.d/99-aeron-tools.rules
  sudo udevadm control --reload-rules
  sudo udevadm trigger
  echo "udev rules installed."
else
  echo "Tip: Run with --udev to install /etc/udev/rules.d/99-aeron-tools.rules for HID & DDC/CI permissions."
fi
