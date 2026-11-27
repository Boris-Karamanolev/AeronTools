# Aeron Tools — Shared Rust Core & Cross-Platform (macOS, Windows, Linux / SteamOS)

Shared Rust hardware engine (`aeron-protocols` + `aeron-platform`) powering:
- **macOS (Native SwiftUI)** in `../AeronTools/` via the **UniFFI** bridge (`crates/aeron-ffi` → `AeronCoreFFI.xcframework` / `AeronCoreKit`) + Mac-only Wireless Display & native macOS UI.
- **Windows & Linux / SteamOS** via the **Tauri v2** desktop app (`src-tauri/` + `src/`).
- **SteamOS Gaming Mode** via the headless `aeron-daemon` + Decky Loader plugin (`decky-plugin/`).

## Architecture

```text
cross-platform/
├── crates/
│   ├── aeron-protocols/   # Pure Rust ports of DDC/CI, HID++ 2.0, Logitech G/MX, Keychron 4K, Razer Chroma, Dock Topology
│   ├── aeron-platform/    # OS backends (macOS IOKit/SMC/CGDisplay, Linux/SteamOS sysfs/ddcutil, Windows dxva2/Win32 + hidapi)
│   ├── aeron-daemon/      # Headless service exposing local HTTP JSON API on 127.0.0.1:47620
│   └── aeron-ffi/         # UniFFI bridge exposing full AeronCore to Swift (macOS)
├── scripts/
│   └── build-macos-xcframework.sh  # Builds libaeron_ffi.a, Swift bindings, and AeronCoreFFI.xcframework
├── swift/
│   └── AeronCoreKit/      # Local Swift Package manifest wrapping AeronCoreFFI.xcframework
├── src-tauri/             # Tauri v2 desktop tray app + global shortcuts + embedded local API
├── src/                   # React + TypeScript + Tailwind UI (shared with browser/daemon API)
├── steamos/               # Persistent udev rules, systemd --user unit, and SteamOS install script
└── decky-plugin/          # SteamOS Gaming Mode Decky Loader Quick Access plugin
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

Whenever you change code in `crates/aeron-protocols`, `crates/aeron-platform`, or `crates/aeron-ffi`, rebuild the UniFFI static library & Swift bindings before building in Xcode:

```bash
# Fast local build (host architecture)
./cross-platform/scripts/build-macos-xcframework.sh

# Universal build (Apple Silicon + Intel, used in CI/releases)
./cross-platform/scripts/build-macos-xcframework.sh --universal
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

Then inside `cross-platform/`:

```bash
# Run workspace unit tests (protocols, platform, daemon, FFI)
cargo test --workspace

# Install frontend dependencies and start Tauri dev mode
npm install
npm run tauri dev

# Build release desktop bundle (.AppImage/.deb on Linux, .exe/.msi on Windows)
npm run tauri build

# Build standalone headless daemon (for SteamOS Gaming Mode)
cargo build --release -p aeron-daemon
```

## Installing on SteamOS (Steam Deck)

1. Run the Desktop Mode AppImage (`Aeron Tools_*.AppImage`), or extract `Aeron-Tools-SteamOS-Daemon-Decky.tar.gz` and run:
   ```bash
   chmod +x steamos/install-steamos.sh
   ./steamos/install-steamos.sh --udev
   ```
   `/etc/udev/rules.d/99-aeron-tools.rules` persists across SteamOS updates and grants non-root access to Logitech, Keychron, Razer HID devices and `/dev/i2c-*` DDC monitors.
2. For **SteamOS Gaming Mode**, copy `decky-plugin/` into `~/homebrew/plugins/aeron-tools/` (with Decky Loader installed) while `aeron-daemon.service` runs in the background.

## Automated Builds & GitHub Releases (macOS, Windows, Linux / SteamOS)

`../.github/workflows/cross-platform.yml` builds all three platforms automatically:
- **On every push to `main` (or manual Run workflow):** Uploads downloadable build artifacts under **Actions → Artifacts**:
  - `aeron-tools-macos` (`Aeron-Tools-macOS.dmg`, `Aeron-Tools-macOS.zip` — native SwiftUI app linked with universal Rust `aeron-ffi`)
  - `aeron-tools-windows` (`.exe`, `.msi`, `Aeron-Tools-Windows-Daemon.zip`)
  - `aeron-tools-linux-steamos` (`.AppImage`, `.deb`, `Aeron-Tools-SteamOS-Daemon-Decky.tar.gz`)
- **On pushing a version tag (`v*`), e.g. `git tag v0.1.0 && git push origin v0.1.0`:** Automatically creates a public **GitHub Release** with all installers attached.
