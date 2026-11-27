# Aeron Tools

Shared hardware behavior lives in `core/`. Each OS keeps its own helpers and its own UI under `platforms/<name>/`. The desktop React UI is shared, so it stays in `ui/`.

- **Windows and Linux desktop** use `ui/` (React + Tauri) on top of `core/`.
- **SteamOS Gaming Mode** uses `platforms/steamos/decky` plus the headless daemon in `core/daemon`.
- **macOS menu-bar app** is `platforms/macos/app`. It starts `SharedCoreEngine`, which owns HID input and DDC writes. Schedules, extra dimming, media keys, the OSD, and wireless display stay in the Swift app.

## Layout

```text
core/
├── protocols/     # DDC/CI, HID++ 2.0, Logitech G/MX, Keychron, Razer Chroma, dock topology
├── engine/        # AeronCore: HID scan, preferences, display/caffeine/game-mode orchestration
├── daemon/        # Loopback HTTP API on 127.0.0.1:47620
└── ffi/           # UniFFI surface over AeronCore
ui/
├── src/           # Shared React UI (Windows, Linux, browser)
└── src-tauri/     # Shared Tauri shell
platforms/
├── macos/
│   ├── app/       # SwiftUI menu-bar app
│   ├── tests/
│   ├── backend/   # IOKit, SMC, CGDisplay, dock walk
│   ├── shell/     # macOS NSPanel for the Tauri popover
│   └── ffi/       # XCFramework build + AeronCoreKit
├── windows/
│   └── backend/   # dxva2, Win32 power, PnP dock walk
├── linux/
│   └── backend/   # sysfs, i2c/ddcutil
└── steamos/
    ├── decky/     # Gaming Mode Quick Access UI
    └── install/   # udev rules, user systemd unit, install script
```

## Included Features (Shared Engine)

- **External Monitor DDC/CI:** Brightness, speaker volume, mute, and VCP 0x60 input switching (`IOAVService` on Apple Silicon macOS; `dxva2` on Windows; `ddcutil` + `/sys/class/backlight` on Linux/SteamOS).
- **Peripherals (via `hidapi`):**
  - Logitech MX Master (battery, DPI, Ratchet/Free-Spin, SmartShift)
  - Logitech MX Keyboard (battery, Backlight2, effects, Fn inversion)
  - Logitech G Mouse (battery, Extended DPI, polling rate, analog triggers)
  - Logitech G515 Keyboard (battery, RGB effects, brightness, Game Mode)
  - Keychron M3 Mini 4K (battery, 5-stage DPI, 125–4000 Hz polling rate, lift-off, motion sync, angle snapping)
  - Razer Thunderbolt 4 Dock Chroma (underglow RGB lighting, brightness, firmware/serial, USB port topology)
  - Satechi Thunderbolt 4 Slim Hub Pro (USB port topology)
- **System Controls & Telemetry:** Thermals & fan RPMs (AppleSMC/HID on macOS, `/sys/class/hwmon` on Linux), Power & Battery wattage, Caffeine, Game Mode, and Global Shortcuts.
- **SteamOS Gaming Mode:** Headless `aeron-daemon` + Decky Loader Quick Access plugin.

## Building the Shared Rust Core for Xcode (macOS)

Whenever you change code in `core/protocols`, `core/engine`, or `core/ffi`, rebuild the UniFFI static library and Swift bindings before building in Xcode:

```bash
# Fast local build (host architecture)
./platforms/macos/ffi/build-xcframework.sh

# Universal build (Apple Silicon + Intel, used in CI/releases)
./platforms/macos/ffi/build-xcframework.sh --universal
```

## Local Development (Windows / Linux / Tauri)

Install **Rust** (`rustup`) and **Node.js 20+**:

```bash
# macOS / Linux
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

On **Linux (Ubuntu / Debian / SteamOS dev container)** also install Tauri & HID system libraries:

```bash
sudo apt-get install -y libwebkit2gtk-4.1-dev libappindicator3-dev librsvg2-dev patchelf libudev-dev pkg-config ddcutil
```

From the repo root:

```bash
# Run workspace unit tests (protocols, engine, daemon, FFI)
cargo test --workspace

# Build standalone headless daemon (for SteamOS Gaming Mode)
cargo build --release -p aeron-daemon
```

Shared desktop UI:

```bash
cd ui
npm install
npm run tauri dev
npm run tauri build
```

## Installing on SteamOS (Steam Deck)

Gaming Mode has no desktop window. It runs `aeron-daemon` and the Decky plugin. The AppImage is the Desktop Mode app.

Extract `Aeron-Tools-Linux.tar.gz` and, from Desktop Mode:

```bash
chmod +x install-steamos.sh
./install-steamos.sh --udev
```

That installs `~/.local/bin/aeron-daemon`, the user service, and `~/homebrew/plugins/aeron-tools`. `--udev` writes `/etc/udev/rules.d/99-aeron-tools.rules`, which persists across SteamOS updates and grants access to Logitech, Keychron, and Razer HID devices and `/dev/i2c-*`. After Decky restarts, open Aeron Tools from the Quick Access menu.

Desktop Mode, and other Linux desktops, run `Aeron-Tools.AppImage` from the same archive. On SteamOS, if FUSE cannot mount it:

```bash
APPIMAGE_EXTRACT_AND_RUN=1 ./Aeron-Tools.AppImage
```

From a git checkout the same installer is `platforms/steamos/install/install-steamos.sh`. Build the daemon with `cargo build --release -p aeron-daemon` and the plugin with `npm run build` in `platforms/steamos/decky` first.

## Automated Builds & GitHub Releases (macOS, Windows, Linux / SteamOS)

`.github/workflows/cross-platform.yml` builds three release files:
- **On every push to `main` (or manual Run workflow):** Uploads them under **Actions → Artifacts**.
- **On a version tag (`v*`), e.g. `git tag v0.1.0 && git push origin v0.1.0`:** Publishes a GitHub Release with those three files:
  - `Aeron-Tools-macOS-arm64.dmg` — native SwiftUI menu-bar app, Apple Silicon only
  - `Aeron-Tools-Linux.tar.gz` — Desktop Mode AppImage, plus `aeron-daemon`, the Decky plugin, and `install-steamos.sh` for Gaming Mode
  - `Aeron-Tools-Windows.exe` — portable executable, no installer
