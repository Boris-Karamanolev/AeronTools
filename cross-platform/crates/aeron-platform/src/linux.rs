//! Linux & SteamOS hardware backend:
//! - External Monitor DDC/CI via native `/dev/i2c-*` ioctl + `ddcutil` fallback, plus built-in `/sys/class/backlight`
//! - Thermals & fans via `/sys/class/hwmon/*` (supports Steam Deck `jupiter`/`steamdeck_hwmon`, AMD `k10temp`/`amdgpu`, Intel `coretemp`)
//! - Accurate Power & Battery telemetry via `/sys/class/power_supply/*` + USB-C PD (`ucsi`) + `hwmon power1_average`
//! - Caffeine keep-awake via `systemd-inhibit` child process
//! - Game Mode via SteamOS `gamescope` / Feral `gamemoded`
//! - USB dock topology via `/sys/bus/usb/devices/*`

use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::Duration;

use aeron_protocols::ddc;
use aeron_protocols::dock_topology::{self, DockLayout, DockModel, ThunderboltNode, UsbNode};
use aeron_protocols::models::{
    ExternalDisplayInfo, FanReading, GameModePolicy, GameModeState, InputSourceOption,
    ThermalPressure, ThermalSnapshot, WattageSnapshot,
};
use tracing::{debug, warn};

use crate::PlatformBackend;

const I2C_SLAVE: libc::c_ulong = 0x0703;

struct LinuxDdcQueueState {
    pending: HashMap<(String, u8), u16>,
    last_sent: HashMap<(String, u8), u16>,
    shutdown: bool,
}

/// Non-blocking coalescing background DDC/I2C write queue for Linux & SteamOS.
/// Rapid slider drags collapse into only the newest value per `(bus, vcp)` so UI sliders
/// glide smoothly without queuing a lag backlog of `ddcutil` or I2C sleeps.
struct LinuxDdcWriteQueue {
    state: Arc<(Mutex<LinuxDdcQueueState>, Condvar)>,
}

impl LinuxDdcWriteQueue {
    fn new() -> Self {
        let state = Arc::new((
            Mutex::new(LinuxDdcQueueState {
                pending: HashMap::new(),
                last_sent: HashMap::new(),
                shutdown: false,
            }),
            Condvar::new(),
        ));
        let worker_state = Arc::clone(&state);
        let _ = thread::Builder::new()
            .name("aeron-ddc-writer".into())
            .spawn(move || {
                let (lock, cvar) = &*worker_state;
                loop {
                    let next_job = {
                        let mut guard = match lock.lock() {
                            Ok(g) => g,
                            Err(_) => break,
                        };
                        while guard.pending.is_empty() && !guard.shutdown {
                            guard = match cvar.wait(guard) {
                                Ok(g) => g,
                                Err(_) => return,
                            };
                        }
                        if guard.shutdown {
                            break;
                        }
                        let key = guard.pending.keys().next().unwrap().clone();
                        let val = guard.pending.remove(&key).unwrap();
                        guard.last_sent.insert(key.clone(), val);
                        (key, val)
                    };

                    let ((bus, vcp), val) = next_job;
                    if let Err(err) = linux_set_vcp(&bus, vcp, val) {
                        debug!("Linux DDC write failed (bus={bus}, vcp=0x{vcp:02X}): {err}");
                    }
                    // MCCS inter-command spacing so monitors don't drop rapid I2C writes.
                    thread::sleep(Duration::from_millis(30));
                }
            });
        Self { state }
    }

    fn enqueue(&self, bus: String, vcp: u8, value: u16) {
        let (lock, cvar) = &*self.state;
        if let Ok(mut guard) = lock.lock() {
            let key = (bus, vcp);
            if guard.pending.get(&key) == Some(&value) {
                return;
            }
            if !guard.pending.contains_key(&key) && guard.last_sent.get(&key) == Some(&value) {
                return;
            }
            guard.pending.insert(key, value);
            cvar.notify_one();
        }
    }

    fn clear_cache(&self) {
        let (lock, _) = &*self.state;
        if let Ok(mut guard) = lock.lock() {
            guard.last_sent.clear();
        }
    }
}

impl Drop for LinuxDdcWriteQueue {
    fn drop(&mut self) {
        let (lock, cvar) = &*self.state;
        if let Ok(mut guard) = lock.lock() {
            guard.shutdown = true;
            guard.pending.clear();
            cvar.notify_all();
        }
    }
}

pub struct LinuxBackend {
    is_steamos: bool,
    inhibit_child: Option<Child>,
    game_mode_policy: GameModePolicy,
    cached_displays: Vec<ExternalDisplayInfo>,
    ddc_bus_map: Vec<(String, String)>, // (display_id, i2c bus number)
    ddc_queue: LinuxDdcWriteQueue,
}

impl Default for LinuxBackend {
    fn default() -> Self {
        Self::new()
    }
}

impl LinuxBackend {
    pub fn new() -> Self {
        let is_steamos = detect_steamos();
        let mut backend = Self {
            is_steamos,
            inhibit_child: None,
            game_mode_policy: GameModePolicy::Automatic,
            cached_displays: Vec::new(),
            ddc_bus_map: Vec::new(),
            ddc_queue: LinuxDdcWriteQueue::new(),
        };
        backend.refresh_displays();
        backend
    }

    fn read_ddc_displays(&mut self) -> Vec<ExternalDisplayInfo> {
        self.ddc_bus_map.clear();
        let mut displays = Vec::new();

        // Built-in laptop/handheld panels are managed via BuiltinDisplayState (not external display cards).
        let _ = read_builtin_backlight();

        // 2. External DDC/CI monitors via `ddcutil detect --terse` if installed
        let mut found_ddc = false;
        if let Ok(out) = Command::new("ddcutil")
            .args(["detect", "--terse"])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .output()
        {
            if out.status.success() {
                let text = String::from_utf8_lossy(&out.stdout);
                let mut current_bus: Option<String> = None;
                let mut current_name: Option<String> = None;
                let mut idx = 0usize;

                for line in text.lines() {
                    let trimmed = line.trim();
                    if trimmed.starts_with("Display ") {
                        if let Some(bus) = current_bus.take() {
                            let name = current_name
                                .take()
                                .unwrap_or_else(|| format!("External Display {}", idx + 1));
                            displays.push(self.build_ddc_display(idx, &bus, name));
                            idx += 1;
                            found_ddc = true;
                        }
                    } else if let Some(rest) = trimmed.strip_prefix("I2C bus:") {
                        if let Some(num) = rest.trim().rsplit('-').next() {
                            current_bus = Some(num.to_string());
                        }
                    } else if let Some(rest) = trimmed.strip_prefix("Monitor:") {
                        let parts: Vec<&str> = rest.trim().split(':').collect();
                        let model = parts.get(1).copied().unwrap_or("").trim();
                        let mfg = parts.first().copied().unwrap_or("").trim();
                        let label = if !model.is_empty() {
                            if !mfg.is_empty() {
                                format!("{mfg} {model}")
                            } else {
                                model.to_string()
                            }
                        } else {
                            rest.trim().to_string()
                        };
                        if !label.is_empty() {
                            current_name = Some(label);
                        }
                    }
                }

                if let Some(bus) = current_bus.take() {
                    let name = current_name
                        .take()
                        .unwrap_or_else(|| format!("External Display {}", idx + 1));
                    displays.push(self.build_ddc_display(idx, &bus, name));
                    found_ddc = true;
                }
            }
        }

        // 3. Native `/dev/i2c-*` DDC/CI discovery fallback when `ddcutil` is absent
        if !found_ddc {
            debug!("ddcutil unavailable or returned no monitors; probing /dev/i2c-* directly");
            for (idx, (bus, name)) in probe_native_i2c_displays().into_iter().enumerate() {
                displays.push(self.build_ddc_display(idx, &bus, name));
            }
        }

        displays
    }

    fn build_ddc_display(&mut self, index: usize, bus: &str, name: String) -> ExternalDisplayInfo {
        let id = format!("i2c-{bus}");
        self.ddc_bus_map.push((id.clone(), bus.to_string()));

        let brightness = linux_get_vcp(bus, ddc::vcp::BRIGHTNESS)
            .map(|(cur, max)| if max > 0 { cur as f32 / max as f32 } else { 0.75 })
            .unwrap_or(0.75);
        let volume = linux_get_vcp(bus, ddc::vcp::AUDIO_SPEAKER_VOLUME)
            .map(|(cur, max)| if max > 0 { cur as f32 / max as f32 } else { 0.5 })
            .unwrap_or(0.5);
        let current_input = linux_get_vcp(bus, ddc::vcp::INPUT_SOURCE).map(|(cur, _)| cur as u8);

        let default_inputs = vec![0x0F, 0x10, 0x11, 0x12, 0x1B]
            .into_iter()
            .map(|code| InputSourceOption {
                code,
                name: ddc::input_source_name(code),
            })
            .collect();

        ExternalDisplayInfo {
            id: id.clone(),
            settings_key: format!("linux-ddc-{index}-{name}"),
            name,
            brightness,
            volume,
            is_muted: false,
            extra_dimming: 1.0,
            input_sources: default_inputs,
            current_input,
            has_hardware_control: true,
            is_builtin: false,
            is_enabled: true,
        }
    }

    fn bus_for_display(&self, display_id: &str) -> Option<String> {
        self.ddc_bus_map
            .iter()
            .find(|(id, _)| id == display_id)
            .map(|(_, bus)| bus.clone())
    }
}

impl Drop for LinuxBackend {
    fn drop(&mut self) {
        if let Some(mut child) = self.inhibit_child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

impl PlatformBackend for LinuxBackend {
    fn platform_name(&self) -> &'static str {
        if self.is_steamos {
            "steamos"
        } else {
            "linux"
        }
    }

    fn is_steamos(&self) -> bool {
        self.is_steamos
    }

    fn refresh_displays(&mut self) -> Vec<ExternalDisplayInfo> {
        self.ddc_queue.clear_cache();
        self.cached_displays = self.read_ddc_displays();
        self.cached_displays.clone()
    }

    fn displays(&self) -> Vec<ExternalDisplayInfo> {
        self.cached_displays.clone()
    }

    fn set_display_brightness(&mut self, display_id: &str, level: f32) -> Result<(), String> {
        let clamped = level.clamp(0.0, 1.0);
        if display_id.starts_with("backlight:") {
            let name = display_id.trim_start_matches("backlight:");
            write_builtin_backlight(name, clamped)?;
        } else if let Some(bus) = self.bus_for_display(display_id) {
            let val = (clamped * 100.0).round() as u16;
            self.ddc_queue.enqueue(bus, ddc::vcp::BRIGHTNESS, val);
        }
        if let Some(d) = self.cached_displays.iter_mut().find(|d| d.id == display_id) {
            d.brightness = clamped;
        }
        Ok(())
    }

    fn set_display_volume(&mut self, display_id: &str, level: f32) -> Result<(), String> {
        let clamped = level.clamp(0.0, 1.0);
        if let Some(bus) = self.bus_for_display(display_id) {
            let val = (clamped * 100.0).round() as u16;
            self.ddc_queue
                .enqueue(bus, ddc::vcp::AUDIO_SPEAKER_VOLUME, val);
        }
        if let Some(d) = self.cached_displays.iter_mut().find(|d| d.id == display_id) {
            d.volume = clamped;
        }
        Ok(())
    }

    fn set_display_muted(&mut self, display_id: &str, muted: bool) -> Result<(), String> {
        if let Some(bus) = self.bus_for_display(display_id) {
            let val = if muted { 1 } else { 2 };
            self.ddc_queue.enqueue(bus, ddc::vcp::AUDIO_MUTE, val);
        }
        if let Some(d) = self.cached_displays.iter_mut().find(|d| d.id == display_id) {
            d.is_muted = muted;
        }
        Ok(())
    }

    fn set_display_input(&mut self, display_id: &str, input_code: u8) -> Result<(), String> {
        if let Some(bus) = self.bus_for_display(display_id) {
            self.ddc_queue
                .enqueue(bus, ddc::vcp::INPUT_SOURCE, input_code as u16);
        }
        if let Some(d) = self.cached_displays.iter_mut().find(|d| d.id == display_id) {
            d.current_input = Some(input_code);
        }
        Ok(())
    }

    fn set_caffeine_active(&mut self, active: bool) -> Result<(), String> {
        if active {
            if self.inhibit_child.is_none() {
                let child = Command::new("systemd-inhibit")
                    .args([
                        "--what=idle:sleep",
                        "--who=AeronTools",
                        "--why=Caffeine active",
                        "sleep",
                        "infinity",
                    ])
                    .stdin(Stdio::null())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .spawn()
                    .map_err(|e| format!("Failed to start systemd-inhibit: {e}"))?;
                self.inhibit_child = Some(child);
            }
        } else if let Some(mut child) = self.inhibit_child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        Ok(())
    }

    fn read_thermals(&self) -> ThermalSnapshot {
        read_hwmon_thermals()
    }

    fn read_wattage(&self) -> WattageSnapshot {
        read_power_supply_wattage()
    }

    fn read_game_mode(&self) -> GameModeState {
        let gamescope_running = std::env::var("XDG_CURRENT_DESKTOP")
            .map(|v| v.to_ascii_lowercase().contains("gamescope"))
            .unwrap_or(false);

        let gamemoded_active = Command::new("gamemoded")
            .arg("-s")
            .output()
            .ok()
            .map(|o| String::from_utf8_lossy(&o.stdout).contains("is active"))
            .unwrap_or(false);

        let is_active = match self.game_mode_policy {
            GameModePolicy::ForcedOn => true,
            GameModePolicy::ForcedOff => false,
            GameModePolicy::Automatic => gamescope_running || gamemoded_active,
        };

        GameModeState {
            supported: true,
            is_active,
            policy: self.game_mode_policy,
            backend_name: if gamescope_running {
                "SteamOS GameScope".into()
            } else {
                "Linux GameMode".into()
            },
        }
    }

    fn set_game_mode_policy(&mut self, policy: GameModePolicy) -> Result<GameModeState, String> {
        self.game_mode_policy = policy;
        Ok(self.read_game_mode())
    }

    fn read_dock_layouts(&self) -> (DockLayout, DockLayout) {
        scan_sysfs_usb_docks()
    }
}

fn detect_steamos() -> bool {
    fs::read_to_string("/etc/os-release")
        .map(|s| {
            let lower = s.to_ascii_lowercase();
            lower.contains("id=steamos") || lower.contains("steamos")
        })
        .unwrap_or(false)
}

fn read_builtin_backlight() -> Option<ExternalDisplayInfo> {
    let entries = fs::read_dir("/sys/class/backlight").ok()?;
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().to_string();
        let cur = read_u64(&path.join("brightness"))?;
        let max = read_u64(&path.join("max_brightness"))?;
        if max == 0 {
            continue;
        }
        return Some(ExternalDisplayInfo {
            id: format!("backlight:{name}"),
            settings_key: format!("linux-backlight-{name}"),
            name: "Built-in Display".into(),
            brightness: (cur as f32 / max as f32).clamp(0.0, 1.0),
            volume: 0.5,
            is_muted: false,
            extra_dimming: 1.0,
            input_sources: Vec::new(),
            current_input: None,
            has_hardware_control: true,
            is_builtin: true,
            is_enabled: true,
        });
    }
    None
}

fn write_builtin_backlight(name: &str, level: f32) -> Result<(), String> {
    let base = Path::new("/sys/class/backlight").join(name);
    let max = read_u64(&base.join("max_brightness"))
        .ok_or_else(|| "Unable to read max_brightness".to_string())?;
    let val = ((level.clamp(0.01, 1.0) * max as f32).round() as u64).min(max);
    fs::write(base.join("brightness"), val.to_string())
        .map_err(|e| format!("Failed writing backlight brightness (check udev/video group): {e}"))
}

// MARK: - Native `/dev/i2c-*` DDC/CI + `ddcutil` fallback

fn probe_native_i2c_displays() -> Vec<(String, String)> {
    let mut found = Vec::new();
    let Ok(entries) = fs::read_dir("/sys/class/drm") else {
        return found;
    };
    for entry in entries.flatten() {
        let dir = entry.path();
        let status = fs::read_to_string(dir.join("status")).unwrap_or_default();
        if status.trim() != "connected" {
            continue;
        }
        let connector = entry.file_name().to_string_lossy().to_string();
        if connector.contains("eDP") || connector.contains("DSI") || connector.contains("LVDS") {
            continue;
        }
        let ddc_dir = dir.join("ddc");
        if let Ok(target) = fs::read_link(&ddc_dir) {
            if let Some(bus_name) = target.file_name().and_then(|s| s.to_str()) {
                if let Some(bus_num) = bus_name.strip_prefix("i2c-") {
                    if native_i2c_get_vcp(bus_num, ddc::vcp::BRIGHTNESS).is_some() {
                        let friendly = parse_edid_name(&dir.join("edid"))
                            .unwrap_or_else(|| format!("External Display ({connector})"));
                        found.push((bus_num.to_string(), friendly));
                    }
                }
            }
        }
    }
    found
}

fn parse_edid_name(path: &Path) -> Option<String> {
    let edid = fs::read(path).ok()?;
    if edid.len() < 128 {
        return None;
    }
    for block in 0..4 {
        let off = 54 + block * 18;
        if edid[off] == 0 && edid[off + 1] == 0 && edid[off + 2] == 0 && edid[off + 3] == 0xFC {
            let raw = &edid[off + 5..off + 18];
            let s = String::from_utf8_lossy(raw)
                .trim_matches(|c: char| c == '\n' || c == '\r' || c == '\0' || c.is_whitespace())
                .to_string();
            if !s.is_empty() {
                return Some(s);
            }
        }
    }
    None
}

fn native_i2c_get_vcp(bus: &str, vcp_code: u8) -> Option<(u16, u16)> {
    let mut file = OpenOptions::new()
        .read(true)
        .write(true)
        .open(format!("/dev/i2c-{bus}"))
        .ok()?;
    let rc = unsafe { libc::ioctl(file.as_raw_fd(), I2C_SLAVE, ddc::CHIP_ADDRESS as libc::c_int) };
    if rc < 0 {
        return None;
    }
    let payload = ddc::get_vcp_packet(vcp_code);
    let mut frame = Vec::with_capacity(payload.len() + 1);
    frame.push(ddc::DATA_ADDRESS);
    frame.extend_from_slice(&payload);
    file.write_all(&frame).ok()?;
    thread::sleep(Duration::from_millis(50));
    let mut reply = [0u8; 12];
    let n = file.read(&mut reply).ok()?;
    let parsed = ddc::parse_vcp_reply(&reply[..n], vcp_code)?;
    Some((parsed.current, parsed.max))
}

fn native_i2c_set_vcp(bus: &str, vcp_code: u8, value: u16) -> Result<(), String> {
    let mut file = OpenOptions::new()
        .read(true)
        .write(true)
        .open(format!("/dev/i2c-{bus}"))
        .map_err(|e| format!("Failed opening /dev/i2c-{bus}: {e}"))?;
    let rc = unsafe { libc::ioctl(file.as_raw_fd(), I2C_SLAVE, ddc::CHIP_ADDRESS as libc::c_int) };
    if rc < 0 {
        return Err(format!("ioctl I2C_SLAVE failed on /dev/i2c-{bus}"));
    }
    let payload = ddc::set_vcp_packet(vcp_code, value);
    let mut frame = Vec::with_capacity(payload.len() + 1);
    frame.push(ddc::DATA_ADDRESS);
    frame.extend_from_slice(&payload);
    file.write_all(&frame)
        .map_err(|e| format!("I2C DDC write failed on bus {bus}: {e}"))?;
    Ok(())
}

fn linux_get_vcp(bus: &str, vcp_code: u8) -> Option<(u16, u16)> {
    native_i2c_get_vcp(bus, vcp_code).or_else(|| ddcutil_get_vcp(bus, vcp_code))
}

fn linux_set_vcp(bus: &str, vcp_code: u8, value: u16) -> Result<(), String> {
    if native_i2c_set_vcp(bus, vcp_code, value).is_ok() {
        return Ok(());
    }
    ddcutil_set_vcp(bus, vcp_code, value)
}

fn ddcutil_get_vcp(bus: &str, vcp_code: u8) -> Option<(u16, u16)> {
    let out = Command::new("ddcutil")
        .args([
            "--bus",
            bus,
            "--terse",
            "getvcp",
            &format!("0x{:02X}", vcp_code),
        ])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let line = String::from_utf8_lossy(&out.stdout);
    let parts: Vec<&str> = line.split_whitespace().collect();
    if parts.len() >= 5 && parts[2] == "C" {
        let cur = parts[3].parse::<u16>().ok()?;
        let max = parts[4].parse::<u16>().ok()?;
        return Some((cur, max));
    }
    if parts.len() >= 4 && parts[2] == "SNC" {
        let hex = parts[3].trim_start_matches('x').trim_start_matches("0x");
        let cur = u16::from_str_radix(hex, 16).ok()?;
        return Some((cur, 255));
    }
    None
}

fn ddcutil_set_vcp(bus: &str, vcp_code: u8, value: u16) -> Result<(), String> {
    let status = Command::new("ddcutil")
        .args([
            "--bus",
            bus,
            "--noverify",
            "setvcp",
            &format!("0x{:02X}", vcp_code),
            &value.to_string(),
        ])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map_err(|e| format!("ddcutil failed: {e}"))?;
    if !status.success() {
        warn!("ddcutil setvcp returned non-zero status on bus {bus}");
    }
    Ok(())
}

// MARK: - Thermals & Fans (`/sys/class/hwmon`)

fn read_hwmon_thermals() -> ThermalSnapshot {
    let mut cpu: Option<f64> = None;
    let mut gpu: Option<f64> = None;
    let mut battery: Option<f64> = None;
    let mut fans: Vec<FanReading> = Vec::new();

    if let Ok(entries) = fs::read_dir("/sys/class/hwmon") {
        for entry in entries.flatten() {
            let dir = entry.path();
            let name = fs::read_to_string(dir.join("name"))
                .unwrap_or_default()
                .trim()
                .to_ascii_lowercase();

            if let Ok(files) = fs::read_dir(&dir) {
                for f in files.flatten() {
                    let fname = f.file_name().to_string_lossy().to_string();
                    if fname.starts_with("temp") && fname.ends_with("_input") {
                        if let Some(milli_c) = read_i64(&f.path()) {
                            let c = milli_c as f64 / 1000.0;
                            if c <= 0.0 || c > 130.0 {
                                continue;
                            }
                            if name.contains("k10temp")
                                || name.contains("zenpower")
                                || name.contains("coretemp")
                                || name.contains("cpu")
                                || name.contains("acpitz")
                            {
                                cpu = Some(cpu.map_or(c, |prev| prev.max(c)));
                            } else if name.contains("amdgpu")
                                || name.contains("nouveau")
                                || name.contains("i915")
                                || name.contains("xe")
                            {
                                gpu = Some(gpu.map_or(c, |prev| prev.max(c)));
                            } else if name.contains("bat")
                                || name.contains("jupiter")
                                || name.contains("steamdeck")
                            {
                                let prefix = fname.trim_end_matches("_input");
                                let lbl = fs::read_to_string(dir.join(format!("{prefix}_label")))
                                    .unwrap_or_default()
                                    .to_ascii_lowercase();
                                if lbl.contains("bat") || name.contains("bat") {
                                    battery = Some(c);
                                } else if lbl.contains("apu") || lbl.contains("cpu") {
                                    cpu = Some(cpu.map_or(c, |prev| prev.max(c)));
                                }
                            }
                        }
                    } else if fname.starts_with("fan") && fname.ends_with("_input") {
                        if let Some(rpm) = read_u64(&f.path()) {
                            let prefix = fname.trim_end_matches("_input");
                            let max_rpm = read_u64(&dir.join(format!("{prefix}_max")))
                                .map(|v| v as u32)
                                .or_else(|| {
                                    if name.contains("jupiter") || name.contains("steamdeck") {
                                        Some(7300)
                                    } else {
                                        None
                                    }
                                });
                            let label = fs::read_to_string(dir.join(format!("{prefix}_label")))
                                .ok()
                                .map(|s| s.trim().to_string())
                                .filter(|s| !s.is_empty())
                                .unwrap_or_else(|| format!("Fan {}", fans.len() + 1));
                            fans.push(FanReading {
                                index: fans.len(),
                                name: label,
                                rpm: rpm as u32,
                                max_rpm,
                            });
                        }
                    }
                }
            }
        }
    }

    let peak = cpu.into_iter().chain(gpu).fold(0.0_f64, f64::max);
    let pressure = if peak >= 92.0 {
        ThermalPressure::Critical
    } else if peak >= 82.0 {
        ThermalPressure::Serious
    } else if peak >= 70.0 {
        ThermalPressure::Fair
    } else {
        ThermalPressure::Nominal
    };

    ThermalSnapshot {
        supported: cpu.is_some() || gpu.is_some() || !fans.is_empty(),
        pressure,
        cpu_celsius: cpu,
        gpu_celsius: gpu,
        battery_celsius: battery,
        fans,
    }
}

// MARK: - Power & Battery (`/sys/class/power_supply` + `hwmon power1_average`)

fn read_hwmon_package_watts() -> Option<f64> {
    let mut sum = 0.0;
    let mut found = false;
    let Ok(entries) = fs::read_dir("/sys/class/hwmon") else {
        return None;
    };
    for entry in entries.flatten() {
        let dir = entry.path();
        let name = fs::read_to_string(dir.join("name"))
            .unwrap_or_default()
            .trim()
            .to_ascii_lowercase();
        if name.contains("amdgpu")
            || name.contains("zenpower")
            || name.contains("k10temp")
            || name.contains("jupiter")
            || name.contains("steamdeck")
        {
            if let Some(uw) = read_u64(&dir.join("power1_average"))
                .or_else(|| read_u64(&dir.join("power1_input")))
            {
                let w = uw as f64 / 1_000_000.0;
                if w > 0.1 && w < 400.0 {
                    sum += w;
                    found = true;
                }
            }
        }
    }
    found.then_some(sum)
}

fn read_power_supply_wattage() -> WattageSnapshot {
    let mut is_plugged_in = false;
    let mut is_charging = false;
    let mut battery_level: Option<u8> = None;
    let mut battery_watts: Option<f64> = None;
    let mut voltage: Option<f64> = None;
    let mut amperage: Option<f64> = None;
    let mut battery_health_percent: Option<u8> = None;
    let mut cycle_count: Option<u32> = None;
    let mut adapter_watts: Option<u32> = None;
    let mut ac_input_watts: Option<f64> = None;
    let mut supported = false;

    if let Ok(entries) = fs::read_dir("/sys/class/power_supply") {
        for entry in entries.flatten() {
            let dir = entry.path();
            let ptype = fs::read_to_string(dir.join("type"))
                .unwrap_or_default()
                .trim()
                .to_ascii_lowercase();

            if ptype == "mains" || ptype == "usb" {
                if read_u64(&dir.join("online")).unwrap_or(0) == 1 {
                    is_plugged_in = true;
                    supported = true;

                    if let (Some(uv), Some(ua)) = (
                        read_u64(&dir.join("voltage_max")),
                        read_u64(&dir.join("current_max")),
                    ) {
                        let w = ((uv as f64 / 1e6) * (ua as f64 / 1e6)).round() as u32;
                        if w > 0 {
                            adapter_watts = Some(adapter_watts.map_or(w, |prev| prev.max(w)));
                        }
                    }

                    let live_in = read_u64(&dir.join("power_now"))
                        .map(|uw| uw as f64 / 1e6)
                        .or_else(|| {
                            match (
                                read_u64(&dir.join("voltage_now")),
                                read_i64(&dir.join("current_now")),
                            ) {
                                (Some(uv), Some(ua)) if uv > 0 && ua.abs() > 0 => {
                                    Some((uv as f64 / 1e6) * (ua.abs() as f64 / 1e6))
                                }
                                _ => None,
                            }
                        });
                    if let Some(w) = live_in.filter(|&w| w > 0.2 && w < 300.0) {
                        ac_input_watts = Some(ac_input_watts.map_or(w, |prev| prev.max(w)));
                    }
                }
            } else if ptype == "battery" {
                supported = true;
                battery_level = read_u64(&dir.join("capacity")).map(|c| c.min(100) as u8);
                let status = fs::read_to_string(dir.join("status"))
                    .unwrap_or_default()
                    .trim()
                    .to_ascii_lowercase();
                is_charging = status == "charging";
                if status == "charging" || status == "full" || status == "not charging" {
                    is_plugged_in = true;
                }
                voltage = read_u64(&dir.join("voltage_now")).map(|uv| uv as f64 / 1e6);
                amperage = read_i64(&dir.join("current_now")).map(|ua| ua.abs() as f64 / 1e6);
                let power_w = read_u64(&dir.join("power_now"))
                    .map(|uw| uw as f64 / 1e6)
                    .or_else(|| match (voltage, amperage) {
                        (Some(v), Some(a)) => Some(v * a),
                        _ => None,
                    });
                battery_watts = power_w.map(|w| {
                    if status == "charging" {
                        w
                    } else if status == "discharging" {
                        -w
                    } else {
                        0.0
                    }
                });
                cycle_count = read_u64(&dir.join("cycle_count")).map(|c| c as u32);

                let full = read_u64(&dir.join("energy_full"))
                    .or_else(|| read_u64(&dir.join("charge_full")));
                let design = read_u64(&dir.join("energy_full_design"))
                    .or_else(|| read_u64(&dir.join("charge_full_design")));
                if let (Some(f), Some(d)) = (full, design) {
                    if d > 0 {
                        battery_health_percent =
                            Some(((f as f64 / d as f64) * 100.0).round().clamp(0.0, 100.0) as u8);
                    }
                }
            }
        }
    }

    let hwmon_watts = read_hwmon_package_watts();
    if hwmon_watts.is_some() {
        supported = true;
    }

    let system_load_watts = if is_plugged_in {
        if let Some(in_w) = ac_input_watts {
            let batt_w = battery_watts.unwrap_or(0.0);
            Some((in_w - batt_w).max(0.5))
        } else {
            hwmon_watts
        }
    } else {
        battery_watts
            .map(|w| w.abs())
            .filter(|&w| w > 0.05)
            .or(hwmon_watts)
    };

    let input_watts = if is_plugged_in {
        ac_input_watts.or_else(|| {
            system_load_watts.map(|sys| sys + battery_watts.unwrap_or(0.0).max(0.0))
        })
    } else {
        None
    };

    WattageSnapshot {
        supported,
        is_plugged_in,
        is_charging,
        battery_level,
        system_load_watts,
        input_watts,
        adapter_watts,
        battery_watts,
        voltage,
        amperage,
        battery_health_percent,
        cycle_count,
    }
}

fn scan_sysfs_usb_docks() -> (DockLayout, DockLayout) {
    let usb_nodes = scan_sysfs_usb_nodes();
    let tb_nodes = scan_sysfs_thunderbolt_nodes();

    let razer = dock_topology::build_layout(
        &DockModel::razer_thunderbolt_4(),
        &usb_nodes,
        &tb_nodes,
    );
    let satechi = dock_topology::build_layout(
        &DockModel::satechi_slim_hub_pro(),
        &usb_nodes,
        &tb_nodes,
    );
    (razer, satechi)
}

fn scan_sysfs_usb_nodes() -> Vec<UsbNode> {
    const LINUX_ROOT_HUB_VID: u16 = 0x1D6B;

    let Ok(entries) = fs::read_dir("/sys/bus/usb/devices") else {
        return Vec::new();
    };

    struct RawSysfsUsb {
        sys_name: String,
        parent_name: Option<String>,
        controller_key: String,
        port_chain: Vec<u8>,
        vid: u16,
        pid: u16,
        name: String,
        vendor_name: Option<String>,
        device_class: u8,
        speed: Option<u8>,
        network_interface: Option<String>,
        serial_number: Option<String>,
    }

    let mut raw: Vec<RawSysfsUsb> = Vec::new();
    let mut controller_groups: HashMap<String, u8> = HashMap::new();
    let mut next_group: u8 = 1;

    for entry in entries.flatten() {
        let dir: PathBuf = entry.path();
        let sys_name = entry.file_name().to_string_lossy().to_string();
        // Skip USB interface sub-directories like `3-1.4:1.0`
        if sys_name.contains(':') {
            continue;
        }
        let Some(vid) = read_hex_u16(&dir.join("idVendor")) else {
            continue;
        };
        let Some(pid) = read_hex_u16(&dir.join("idProduct")) else {
            continue;
        };

        let canonical = fs::canonicalize(&dir).unwrap_or_else(|_| dir.clone());
        let (parent_name, port_chain) = parse_sysfs_usb_path(&sys_name);
        // Group sibling USB 2.0 (`usbN`) and USB 3.0 (`usbM`) buses that share the same PCI xHCI controller
        let controller_key = find_pci_controller_key(&canonical)
            .unwrap_or_else(|| sys_name.split('-').next().unwrap_or(&sys_name).to_string());
        if !controller_groups.contains_key(&controller_key) {
            controller_groups.insert(controller_key.clone(), next_group);
            next_group = next_group.saturating_add(1).max(1);
        }

        let name = read_trimmed(&dir.join("product"))
            .unwrap_or_else(|| format!("USB Device {:04X}:{:04X}", vid, pid));
        let vendor_name = read_trimmed(&dir.join("manufacturer"));
        let device_class = read_hex_u16(&dir.join("bDeviceClass")).unwrap_or(0) as u8;
        let speed = read_trimmed(&dir.join("speed")).and_then(|sp| parse_linux_usb_speed(&sp));
        let serial_number = read_trimmed(&dir.join("serial"));
        let network_interface = find_sysfs_net_interface(&dir, &sys_name);

        raw.push(RawSysfsUsb {
            sys_name,
            parent_name,
            controller_key,
            port_chain,
            vid,
            pid,
            name,
            vendor_name,
            device_class,
            speed,
            network_interface,
            serial_number,
        });
    }

    // Check if any known dock anchor sits beneath a real hardware hub rather than directly on Linux's
    // synthetic `0x1D6B` root hub. If so, drop synthetic `0x1D6B` root hubs so the dock controller's
    // USB 2.0 & USB 3.0 hubs become top-level (`parent_id: None`) roots matching macOS IOKit.
    let by_name_vid: HashMap<&str, u16> = raw.iter().map(|r| (r.sys_name.as_str(), r.vid)).collect();
    let drop_linux_root_hubs = raw.iter().any(|r| {
        let is_anchor = dock_topology::is_satechi_slim_hub_anchor(r.vid, r.pid)
            || dock_topology::is_razer_dock_usb_hub(r.vid, r.pid);
        if !is_anchor {
            return false;
        }
        r.parent_name
            .as_deref()
            .and_then(|pn| by_name_vid.get(pn).copied())
            .is_some_and(|pvid| pvid != LINUX_ROOT_HUB_VID)
    });

    let mut id_map: HashMap<String, u64> = HashMap::new();
    for (idx, item) in raw.iter().enumerate() {
        id_map.insert(item.sys_name.clone(), (idx as u64) + 1);
    }

    let mut out = Vec::with_capacity(raw.len());
    for item in &raw {
        if drop_linux_root_hubs && item.vid == LINUX_ROOT_HUB_VID {
            continue;
        }
        let id = id_map[&item.sys_name];
        let parent_id = item.parent_name.as_deref().and_then(|pn| {
            if drop_linux_root_hubs && by_name_vid.get(pn).copied() == Some(LINUX_ROOT_HUB_VID) {
                None
            } else {
                id_map.get(pn).copied()
            }
        });
        let bus_group = *controller_groups.get(&item.controller_key).unwrap_or(&1) as u32;
        let location_id = encode_location_id(bus_group, &item.port_chain);

        out.push(UsbNode {
            id,
            parent_id,
            location_id,
            vendor_id: item.vid,
            product_id: item.pid,
            name: item.name.clone(),
            vendor_name: item.vendor_name.clone(),
            device_class: item.device_class,
            speed: item.speed,
            network_interface: item.network_interface.clone(),
            serial_number: item.serial_number.clone(),
        });
    }
    out
}

fn scan_sysfs_thunderbolt_nodes() -> Vec<ThunderboltNode> {
    let Ok(entries) = fs::read_dir("/sys/bus/thunderbolt/devices") else {
        return Vec::new();
    };
    let mut raw: Vec<(String, PathBuf, Option<u16>, Option<u16>, Option<String>, Option<String>)> =
        Vec::new();

    for entry in entries.flatten() {
        let dir = entry.path();
        let name = entry.file_name().to_string_lossy().to_string();
        // Skip domain/interface/retimer entries (e.g. `domain0`, `0-0:1.1`, `0-0:3.1`)
        if name.starts_with("domain") || name.contains(':') {
            continue;
        }
        let canonical = fs::canonicalize(&dir).unwrap_or(dir.clone());
        let vendor_id = read_hex_u16(&dir.join("vendor"));
        let model_id = read_hex_u16(&dir.join("device"));
        let vendor_name = read_trimmed(&dir.join("vendor_name"));
        let model_name = read_trimmed(&dir.join("device_name"));
        raw.push((name, canonical, vendor_id, model_id, vendor_name, model_name));
    }

    let path_to_id: HashMap<PathBuf, u64> = raw
        .iter()
        .enumerate()
        .map(|(i, (_, path, _, _, _, _))| (path.clone(), (i as u64) + 1))
        .collect();

    raw.into_iter()
        .enumerate()
        .map(|(i, (_, path, vendor_id, model_id, vendor_name, model_name))| {
            let parent_switch_id = path
                .parent()
                .and_then(|parent| path_to_id.get(parent).copied());
            ThunderboltNode {
                id: (i as u64) + 1,
                parent_switch_id,
                vendor_id,
                model_id,
                vendor_name,
                model_name,
            }
        })
        .collect()
}

fn parse_sysfs_usb_path(sys_name: &str) -> (Option<String>, Vec<u8>) {
    if sys_name.starts_with("usb") {
        return (None, Vec::new());
    }
    let Some((bus, rest)) = sys_name.split_once('-') else {
        return (None, Vec::new());
    };
    let parts: Vec<&str> = rest.split('.').collect();
    let chain: Vec<u8> = parts
        .iter()
        .filter_map(|p| p.parse::<u8>().ok())
        .collect();
    let parent = if parts.len() <= 1 {
        Some(format!("usb{bus}"))
    } else {
        Some(format!("{bus}-{}", parts[..parts.len() - 1].join(".")))
    };
    (parent, chain)
}

fn encode_location_id(bus_group: u32, port_chain: &[u8]) -> u32 {
    let mut loc = (bus_group & 0xFF) << 24;
    for (i, &port) in port_chain.iter().take(6).enumerate() {
        let shift = 20 - (i as u32 * 4);
        loc |= ((port as u32) & 0x0F) << shift;
    }
    loc
}

fn find_pci_controller_key(canonical: &Path) -> Option<String> {
    let mut cur = canonical;
    while let Some(parent) = cur.parent() {
        if let Some(name) = cur.file_name().and_then(|s| s.to_str()) {
            if name.starts_with("usb") && name[3..].chars().all(|c| c.is_ascii_digit()) {
                return Some(parent.to_string_lossy().to_string());
            }
        }
        cur = parent;
    }
    None
}

fn parse_linux_usb_speed(speed: &str) -> Option<u8> {
    match speed.trim() {
        "1.5" => Some(0),
        "12" => Some(1),
        "480" => Some(2),
        "5000" => Some(3),
        "10000" => Some(4),
        "20000" => Some(5),
        _ => None,
    }
}

fn find_sysfs_net_interface(dev_dir: &Path, sys_name: &str) -> Option<String> {
    let prefix = format!("{sys_name}:");
    let entries = fs::read_dir(dev_dir).ok()?;
    for entry in entries.flatten() {
        let fname = entry.file_name().to_string_lossy().to_string();
        if !fname.starts_with(&prefix) {
            continue;
        }
        let net_dir = entry.path().join("net");
        if let Ok(net_entries) = fs::read_dir(&net_dir) {
            for ne in net_entries.flatten() {
                let iface = ne.file_name().to_string_lossy().to_string();
                if !iface.is_empty() {
                    return Some(iface);
                }
            }
        }
    }
    None
}

fn read_trimmed(path: &Path) -> Option<String> {
    fs::read_to_string(path)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

fn read_u64(path: &Path) -> Option<u64> {
    fs::read_to_string(path).ok()?.trim().parse::<u64>().ok()
}

fn read_i64(path: &Path) -> Option<i64> {
    fs::read_to_string(path).ok()?.trim().parse::<i64>().ok()
}

fn read_hex_u16(path: &Path) -> Option<u16> {
    let raw = fs::read_to_string(path).ok()?;
    u16::from_str_radix(raw.trim(), 16).ok()
}
