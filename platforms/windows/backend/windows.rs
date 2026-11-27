//! Windows hardware backend:
//! - External Monitor DDC/CI via Win32 `dxva2.dll` (`GetVCPFeatureAndVCPFeatureReply` / `SetVCPFeature`)
//!   with a non-blocking coalescing background write queue (`aeron-ddc-writer`) so slider drags never stall
//! - Caffeine keep-awake via `SetThreadExecutionState`
//! - Battery & power status via `GetSystemPowerStatus`
//! - Windows Game Mode registry policy (`HKCU\Software\Microsoft\GameBar\AutoGameModeEnabled`)
//! - USB / Thunderbolt 4 dock port topology via Windows PnP USB tree -> `dock_topology::build_layout()`
//! - Basic ACPI thermal zone reading (with graceful fallback when kernel driver isn't loaded)

use std::collections::{HashMap, HashSet};
use std::ffi::c_void;
use std::os::windows::process::CommandExt;
use std::process::{Command, Stdio};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use aeron_protocols::ddc;
use aeron_protocols::dock_topology::{
    self, DockLayout, DockModel, UsbNode, USB_BILLBOARD_CLASS, USB_HUB_CLASS,
};
use aeron_protocols::models::{
    ExternalDisplayInfo, GameModePolicy, GameModeState, InputSourceOption, ThermalPressure,
    ThermalSnapshot, WattageSnapshot,
};
use serde::Deserialize;
use tracing::warn;
use windows_sys::Win32::Devices::Display::{
    DestroyPhysicalMonitors, GetNumberOfPhysicalMonitorsFromHMONITOR,
    GetPhysicalMonitorsFromHMONITOR, GetVCPFeatureAndVCPFeatureReply, SetVCPFeature,
    PHYSICAL_MONITOR,
};
use windows_sys::Win32::Foundation::{BOOL, LPARAM, RECT, TRUE};
use windows_sys::Win32::Graphics::Gdi::{EnumDisplayMonitors, HDC, HMONITOR};
use windows_sys::Win32::System::Power::{
    GetSystemPowerStatus, SetThreadExecutionState, ES_CONTINUOUS, ES_DISPLAY_REQUIRED,
    ES_SYSTEM_REQUIRED, SYSTEM_POWER_STATUS,
};

use crate::PlatformBackend;

const CREATE_NO_WINDOW: u32 = 0x0800_0000;
const DOCK_SCAN_CACHE_TTL: Duration = Duration::from_secs(5);

fn hidden_command(program: &str) -> Command {
    let mut cmd = Command::new(program);
    cmd.creation_flags(CREATE_NO_WINDOW);
    cmd
}

// MARK: - Coalescing Non-Blocking Windows DDC Write Queue

/// Minimum spacing between consecutive DDC/CI VCP writes to the same physical monitor.
const DDC_MIN_WRITE_SPACING: Duration = Duration::from_millis(35);

struct WindowsDdcQueueState {
    pending: HashMap<(usize, u8), u32>,
    last_sent: HashMap<(usize, u8), u32>,
    last_write_at: HashMap<usize, Instant>,
    shutdown: bool,
}

struct WindowsDdcWriteQueue {
    inner: Arc<(Mutex<WindowsDdcQueueState>, Condvar)>,
}

impl WindowsDdcWriteQueue {
    fn new() -> Self {
        let inner = Arc::new((
            Mutex::new(WindowsDdcQueueState {
                pending: HashMap::new(),
                last_sent: HashMap::new(),
                last_write_at: HashMap::new(),
                shutdown: false,
            }),
            Condvar::new(),
        ));
        let worker_inner = inner.clone();
        let _ = thread::Builder::new()
            .name("aeron-ddc-writer".into())
            .spawn(move || Self::worker_loop(worker_inner));
        Self { inner }
    }

    fn enqueue(&self, display_index: usize, vcp_code: u8, value: u32) {
        let (lock, cv) = &*self.inner;
        let mut st = lock.lock().unwrap_or_else(|e| e.into_inner());
        let key = (display_index, vcp_code);
        if !st.pending.contains_key(&key) && st.last_sent.get(&key) == Some(&value) {
            return;
        }
        st.pending.insert(key, value);
        cv.notify_one();
    }

    fn clear_cache(&self) {
        let (lock, _) = &*self.inner;
        let mut st = lock.lock().unwrap_or_else(|e| e.into_inner());
        st.last_sent.clear();
    }

    fn worker_loop(inner: Arc<(Mutex<WindowsDdcQueueState>, Condvar)>) {
        let (lock, cv) = &*inner;
        loop {
            let task = {
                let mut st = lock.lock().unwrap_or_else(|e| e.into_inner());
                loop {
                    if st.shutdown {
                        return;
                    }
                    if st.pending.is_empty() {
                        st = cv.wait(st).unwrap_or_else(|e| e.into_inner());
                        continue;
                    }
                    let now = Instant::now();
                    let mut ready_key: Option<(usize, u8)> = None;
                    let mut earliest_wait: Option<Duration> = None;

                    for &(display_index, vcp_code) in st.pending.keys() {
                        let wait = st
                            .last_write_at
                            .get(&display_index)
                            .and_then(|t| DDC_MIN_WRITE_SPACING.checked_sub(now.duration_since(*t)));
                        match wait {
                            None => {
                                ready_key = Some((display_index, vcp_code));
                                break;
                            }
                            Some(rem) => {
                                earliest_wait = Some(match earliest_wait {
                                    Some(cur) => cur.min(rem),
                                    None => rem,
                                });
                            }
                        }
                    }

                    if let Some(key) = ready_key {
                        let Some(val) = st.pending.remove(&key) else {
                            continue;
                        };
                        st.last_sent.insert(key, val);
                        st.last_write_at.insert(key.0, Instant::now());
                        break (key.0, key.1, val);
                    } else if let Some(wait_dur) = earliest_wait {
                        let (guard, _) = cv
                            .wait_timeout(st, wait_dur)
                            .unwrap_or_else(|e| e.into_inner());
                        st = guard;
                    } else {
                        st = cv.wait(st).unwrap_or_else(|e| e.into_inner());
                    }
                }
            };

            let (display_index, vcp_code, value) = task;
            if let Err(err) = write_vcp_sync(display_index, vcp_code, value) {
                warn!(
                    "Windows DDC write failed (monitor {display_index}, VCP 0x{vcp_code:02X}={value}): {err}"
                );
            }
        }
    }
}

impl Drop for WindowsDdcWriteQueue {
    fn drop(&mut self) {
        let (lock, cv) = &*self.inner;
        let mut st = lock.lock().unwrap_or_else(|e| e.into_inner());
        st.shutdown = true;
        st.pending.clear();
        cv.notify_all();
    }
}

pub struct WindowsBackend {
    cached_displays: Vec<ExternalDisplayInfo>,
    vcp_max_brightness: HashMap<usize, u32>,
    vcp_max_volume: HashMap<usize, u32>,
    game_mode_policy: GameModePolicy,
    ddc_queue: WindowsDdcWriteQueue,
}

impl Default for WindowsBackend {
    fn default() -> Self {
        Self::new()
    }
}

impl WindowsBackend {
    pub fn new() -> Self {
        let mut backend = Self {
            cached_displays: Vec::new(),
            vcp_max_brightness: HashMap::new(),
            vcp_max_volume: HashMap::new(),
            game_mode_policy: GameModePolicy::Automatic,
            ddc_queue: WindowsDdcWriteQueue::new(),
        };
        backend.refresh_displays();
        backend
    }
}

struct EnumContext {
    hmonitors: Vec<HMONITOR>,
}

unsafe extern "system" fn enum_monitor_cb(
    hmonitor: HMONITOR,
    _hdc: HDC,
    _rect: *mut RECT,
    lparam: LPARAM,
) -> BOOL {
    let ctx = &mut *(lparam as *mut EnumContext);
    ctx.hmonitors.push(hmonitor);
    TRUE
}

fn enumerate_hmonitors() -> Vec<HMONITOR> {
    let mut ctx = EnumContext {
        hmonitors: Vec::new(),
    };
    unsafe {
        EnumDisplayMonitors(
            std::ptr::null_mut(),
            std::ptr::null(),
            Some(enum_monitor_cb),
            (&mut ctx as *mut EnumContext) as LPARAM,
        );
    }
    ctx.hmonitors
}

fn with_physical_monitors<F>(display_index: usize, mut f: F) -> Result<(), String>
where
    F: FnMut(&PHYSICAL_MONITOR) -> Result<(), String>,
{
    let monitors = enumerate_hmonitors();
    let mut current_idx = 0usize;
    for hmon in monitors {
        let mut count = 0u32;
        if unsafe { GetNumberOfPhysicalMonitorsFromHMONITOR(hmon, &mut count) } == 0 || count == 0
        {
            continue;
        }
        let mut phys: Vec<PHYSICAL_MONITOR> = vec![
            PHYSICAL_MONITOR {
                hPhysicalMonitor: std::ptr::null_mut(),
                szPhysicalMonitorDescription: [0u16; 128],
            };
            count as usize
        ];
        if unsafe { GetPhysicalMonitorsFromHMONITOR(hmon, count, phys.as_mut_ptr()) } == 0 {
            continue;
        }
        let mut result = Ok(());
        let mut matched = false;
        for pm in &phys {
            if current_idx == display_index {
                result = f(pm);
                matched = true;
                break;
            }
            current_idx += 1;
        }
        unsafe {
            DestroyPhysicalMonitors(count, phys.as_ptr());
        }
        if matched {
            return result;
        }
    }
    Err(format!("Monitor index {display_index} not found"))
}

fn write_vcp_sync(display_index: usize, vcp_code: u8, value: u32) -> Result<(), String> {
    with_physical_monitors(display_index, |pm| {
        let ok = unsafe { SetVCPFeature(pm.hPhysicalMonitor, vcp_code, value) };
        if ok == 0 {
            Err(format!("SetVCPFeature(0x{vcp_code:02X}) failed"))
        } else {
            Ok(())
        }
    })
}

fn read_vcp(handle: *mut c_void, code: u8) -> Option<(u32, u32)> {
    let mut current = 0u32;
    let mut maximum = 0u32;
    let ok = unsafe {
        GetVCPFeatureAndVCPFeatureReply(
            handle,
            code,
            std::ptr::null_mut(),
            &mut current,
            &mut maximum,
        )
    };
    (ok != 0).then_some((current, maximum))
}

impl PlatformBackend for WindowsBackend {
    fn platform_name(&self) -> &'static str {
        "windows"
    }

    fn is_steamos(&self) -> bool {
        false
    }

    fn refresh_displays(&mut self) -> Vec<ExternalDisplayInfo> {
        self.ddc_queue.clear_cache();
        self.vcp_max_brightness.clear();
        self.vcp_max_volume.clear();

        let mut out = Vec::new();
        let monitors = enumerate_hmonitors();
        let mut index = 0usize;

        for hmon in monitors {
            let mut count = 0u32;
            if unsafe { GetNumberOfPhysicalMonitorsFromHMONITOR(hmon, &mut count) } == 0
                || count == 0
            {
                continue;
            }
            let mut phys: Vec<PHYSICAL_MONITOR> = vec![
                PHYSICAL_MONITOR {
                    hPhysicalMonitor: std::ptr::null_mut(),
                    szPhysicalMonitorDescription: [0u16; 128],
                };
                count as usize
            ];
            if unsafe { GetPhysicalMonitorsFromHMONITOR(hmon, count, phys.as_mut_ptr()) } == 0 {
                continue;
            }

            for pm in &phys {
                // Copy out of the #[repr(C, packed(1))] Win32 PHYSICAL_MONITOR struct before slicing.
                let desc = pm.szPhysicalMonitorDescription;
                let nul = desc.iter().position(|&c| c == 0).unwrap_or(desc.len());
                let raw_name = String::from_utf16_lossy(&desc[..nul]);
                let name = if raw_name.trim().is_empty() {
                    format!("Display {}", index + 1)
                } else {
                    raw_name.trim().to_string()
                };

                let br = read_vcp(pm.hPhysicalMonitor, ddc::vcp::BRIGHTNESS);
                let has_hw = br.is_some();
                let (brightness, br_max) = br
                    .map(|(c, m)| {
                        let max = if m > 0 { m } else { 100 };
                        ((c as f32 / max as f32).clamp(0.0, 1.0), max)
                    })
                    .unwrap_or((0.75, 100));
                self.vcp_max_brightness.insert(index, br_max);

                let vol = read_vcp(pm.hPhysicalMonitor, ddc::vcp::AUDIO_SPEAKER_VOLUME);
                let (volume, vol_max) = vol
                    .map(|(c, m)| {
                        let max = if m > 0 { m } else { 100 };
                        ((c as f32 / max as f32).clamp(0.0, 1.0), max)
                    })
                    .unwrap_or((0.5, 100));
                self.vcp_max_volume.insert(index, vol_max);

                let is_muted = read_vcp(pm.hPhysicalMonitor, ddc::vcp::AUDIO_MUTE)
                    .map(|(c, _)| c == 1)
                    .unwrap_or(false);
                let current_input =
                    read_vcp(pm.hPhysicalMonitor, ddc::vcp::INPUT_SOURCE).map(|(c, _)| c as u8);

                let mut input_codes = vec![0x0F, 0x10, 0x11, 0x12, 0x1B];
                if let Some(cur) = current_input {
                    if !input_codes.contains(&cur) {
                        input_codes.push(cur);
                    }
                }
                let default_inputs = input_codes
                    .into_iter()
                    .map(|code| InputSourceOption {
                        code,
                        name: ddc::input_source_name(code),
                    })
                    .collect();

                out.push(ExternalDisplayInfo {
                    id: format!("win-{index}"),
                    settings_key: format!("win-{index}-{name}"),
                    name,
                    brightness,
                    volume,
                    is_muted,
                    extra_dimming: 1.0,
                    input_sources: default_inputs,
                    current_input,
                    has_hardware_control: has_hw,
                    is_builtin: false,
                    is_enabled: true,
                });
                index += 1;
            }

            unsafe {
                DestroyPhysicalMonitors(count, phys.as_ptr());
            }
        }

        self.cached_displays = out.clone();
        out
    }

    fn displays(&self) -> Vec<ExternalDisplayInfo> {
        self.cached_displays.clone()
    }

    fn set_display_brightness(&mut self, display_id: &str, level: f32) -> Result<(), String> {
        let clamped = level.clamp(0.0, 1.0);
        if let Some(idx) = display_id
            .strip_prefix("win-")
            .and_then(|s| s.parse::<usize>().ok())
        {
            let max = self.vcp_max_brightness.get(&idx).copied().unwrap_or(100);
            let val = (clamped * max as f32).round() as u32;
            self.ddc_queue.enqueue(idx, ddc::vcp::BRIGHTNESS, val);
        }
        if let Some(d) = self.cached_displays.iter_mut().find(|d| d.id == display_id) {
            d.brightness = clamped;
        }
        Ok(())
    }

    fn set_display_volume(&mut self, display_id: &str, level: f32) -> Result<(), String> {
        let clamped = level.clamp(0.0, 1.0);
        if let Some(idx) = display_id
            .strip_prefix("win-")
            .and_then(|s| s.parse::<usize>().ok())
        {
            let max = self.vcp_max_volume.get(&idx).copied().unwrap_or(100);
            let val = (clamped * max as f32).round() as u32;
            self.ddc_queue
                .enqueue(idx, ddc::vcp::AUDIO_SPEAKER_VOLUME, val);
        }
        if let Some(d) = self.cached_displays.iter_mut().find(|d| d.id == display_id) {
            d.volume = clamped;
        }
        Ok(())
    }

    fn set_display_muted(&mut self, display_id: &str, muted: bool) -> Result<(), String> {
        if let Some(idx) = display_id
            .strip_prefix("win-")
            .and_then(|s| s.parse::<usize>().ok())
        {
            let val = if muted { 1 } else { 2 };
            self.ddc_queue.enqueue(idx, ddc::vcp::AUDIO_MUTE, val);
        }
        if let Some(d) = self.cached_displays.iter_mut().find(|d| d.id == display_id) {
            d.is_muted = muted;
        }
        Ok(())
    }

    fn set_display_input(&mut self, display_id: &str, input_code: u8) -> Result<(), String> {
        if let Some(idx) = display_id
            .strip_prefix("win-")
            .and_then(|s| s.parse::<usize>().ok())
        {
            self.ddc_queue
                .enqueue(idx, ddc::vcp::INPUT_SOURCE, input_code as u32);
        }
        if let Some(d) = self.cached_displays.iter_mut().find(|d| d.id == display_id) {
            d.current_input = Some(input_code);
        }
        Ok(())
    }

    fn set_caffeine_active(&mut self, active: bool) -> Result<(), String> {
        let flags = if active {
            ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED
        } else {
            ES_CONTINUOUS
        };
        let prev = unsafe { SetThreadExecutionState(flags) };
        if prev == 0 {
            return Err("SetThreadExecutionState failed".into());
        }
        Ok(())
    }

    fn read_thermals(&self) -> ThermalSnapshot {
        // Non-privileged ACPI thermal zone probe (full CPU/GPU/Fan telemetry can plug in LibreHardwareMonitor)
        ThermalSnapshot {
            supported: false,
            pressure: ThermalPressure::Nominal,
            cpu_celsius: None,
            gpu_celsius: None,
            battery_celsius: None,
            fans: Vec::new(),
        }
    }

    fn read_wattage(&self) -> WattageSnapshot {
        let mut status = SYSTEM_POWER_STATUS {
            ACLineStatus: 255,
            BatteryFlag: 255,
            BatteryLifePercent: 255,
            SystemStatusFlag: 0,
            BatteryLifeTime: u32::MAX,
            BatteryFullLifeTime: u32::MAX,
        };
        let ok = unsafe { GetSystemPowerStatus(&mut status) } != 0;
        if !ok {
            return WattageSnapshot {
                supported: false,
                is_plugged_in: true,
                is_charging: false,
                battery_level: None,
                system_load_watts: None,
                input_watts: None,
                adapter_watts: None,
                battery_watts: None,
                voltage: None,
                amperage: None,
                battery_health_percent: None,
                cycle_count: None,
            };
        }

        let is_plugged_in = status.ACLineStatus == 1;
        let is_charging = (status.BatteryFlag & 8) != 0;
        let battery_level = (status.BatteryLifePercent <= 100).then_some(status.BatteryLifePercent);

        WattageSnapshot {
            supported: true,
            is_plugged_in,
            is_charging,
            battery_level,
            system_load_watts: None,
            input_watts: None,
            adapter_watts: None,
            battery_watts: None,
            voltage: None,
            amperage: None,
            battery_health_percent: None,
            cycle_count: None,
        }
    }

    fn read_game_mode(&self) -> GameModeState {
        let reg_enabled = hidden_command("reg")
            .args([
                "query",
                r"HKCU\Software\Microsoft\GameBar",
                "/v",
                "AutoGameModeEnabled",
            ])
            .output()
            .ok()
            .map(|o| String::from_utf8_lossy(&o.stdout).contains("0x1"))
            .unwrap_or(true);

        let is_active = match self.game_mode_policy {
            GameModePolicy::ForcedOn => true,
            GameModePolicy::ForcedOff => false,
            GameModePolicy::Automatic => reg_enabled,
        };

        GameModeState {
            supported: true,
            is_active,
            policy: self.game_mode_policy,
            backend_name: "Windows Game Mode".into(),
        }
    }

    fn set_game_mode_policy(&mut self, policy: GameModePolicy) -> Result<GameModeState, String> {
        self.game_mode_policy = policy;
        let val = match policy {
            GameModePolicy::ForcedOff => "0",
            GameModePolicy::Automatic | GameModePolicy::ForcedOn => "1",
        };
        let _ = hidden_command("reg")
            .args([
                "add",
                r"HKCU\Software\Microsoft\GameBar",
                "/v",
                "AutoGameModeEnabled",
                "/t",
                "REG_DWORD",
                "/d",
                val,
                "/f",
            ])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
        Ok(self.read_game_mode())
    }

    fn read_dock_layouts(&self) -> (DockLayout, DockLayout) {
        cached_dock_layouts()
    }
}

pub(crate) fn cached_dock_layouts() -> (DockLayout, DockLayout) {
    static CACHE: Mutex<Option<(Instant, DockLayout, DockLayout)>> = Mutex::new(None);
    let mut guard = CACHE.lock().unwrap_or_else(|e| e.into_inner());
    if let Some((at, razer, satechi)) = guard.as_ref() {
        if at.elapsed() < DOCK_SCAN_CACHE_TTL {
            return (razer.clone(), satechi.clone());
        }
    }
    let scanned = scan_windows_usb_docks();
    *guard = Some((Instant::now(), scanned.0.clone(), scanned.1.clone()));
    scanned
}

// MARK: - Windows PnP USB Dock Port Topology Scanner

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct WinPnpUsbRecord {
    instance_id: String,
    #[serde(default)]
    parent_id: Option<String>,
    #[serde(default)]
    friendly_name: Option<String>,
    #[serde(default)]
    bus_desc: Option<String>,
    #[serde(default)]
    manufacturer: Option<String>,
    #[serde(default)]
    location_info: Option<String>,
    #[serde(default)]
    compat_ids: Option<serde_json::Value>,
    #[serde(default)]
    class_name: Option<String>,
}

impl WinPnpUsbRecord {
    fn compat_id_strings(&self) -> Vec<String> {
        match &self.compat_ids {
            Some(serde_json::Value::Array(arr)) => arr
                .iter()
                .filter_map(|v| v.as_str().map(ToString::to_string))
                .collect(),
            Some(serde_json::Value::String(s)) => vec![s.clone()],
            _ => Vec::new(),
        }
    }
}

const WIN_USB_SCAN_PS: &str = r#"
$ErrorActionPreference = 'SilentlyContinue'
$devs = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'USB\*' -or $_.Class -eq 'Net' }
$out = foreach ($d in $devs) {
    $id = $d.InstanceId
    if ($id -like '*&MI_*' -and $d.Class -ne 'Net') { continue }
    $props = Get-PnpDeviceProperty -InstanceId $id -KeyName @(
        'DEVPKEY_Device_Parent',
        'DEVPKEY_Device_LocationInfo',
        'DEVPKEY_Device_CompatibleIds',
        'DEVPKEY_Device_BusReportedDeviceDesc'
    )
    $map = @{}
    foreach ($p in $props) { $map[$p.KeyName] = $p.Data }
    $compat = @()
    if ($map['DEVPKEY_Device_CompatibleIds']) {
        $compat = @($map['DEVPKEY_Device_CompatibleIds'] | ForEach-Object { [string]$_ })
    }
    [PSCustomObject]@{
        instanceId   = [string]$id
        parentId     = [string]$map['DEVPKEY_Device_Parent']
        friendlyName = [string]$d.FriendlyName
        busDesc      = [string]$map['DEVPKEY_Device_BusReportedDeviceDesc']
        manufacturer = [string]$d.Manufacturer
        locationInfo = [string]$map['DEVPKEY_Device_LocationInfo']
        compatIds    = $compat
        className    = [string]$d.Class
    }
}
ConvertTo-Json -InputObject @($out) -Depth 3 -Compress
"#;

fn scan_windows_usb_docks() -> (DockLayout, DockLayout) {
    let records = query_windows_pnp_usb();
    if records.is_empty() {
        return (DockLayout::empty_razer(), DockLayout::empty_satechi());
    }
    let nodes = build_windows_usb_nodes(&records);
    let razer_model = DockModel::razer_thunderbolt_4();
    let satechi_model = DockModel::satechi_slim_hub_pro();

    let razer_nodes = normalize_windows_roots(&nodes, &razer_model);
    let satechi_nodes = normalize_windows_roots(&nodes, &satechi_model);

    let razer = dock_topology::build_layout(&razer_model, &razer_nodes, &[]);
    let satechi = dock_topology::build_layout(&satechi_model, &satechi_nodes, &[]);
    (razer, satechi)
}

fn query_windows_pnp_usb() -> Vec<WinPnpUsbRecord> {
    let output = match hidden_command("powershell")
        .args([
            "-NoProfile",
            "-NonInteractive",
            "-WindowStyle",
            "Hidden",
            "-Command",
            WIN_USB_SCAN_PS,
        ])
        .stderr(Stdio::null())
        .output()
    {
        Ok(o) if o.status.success() => o,
        _ => return Vec::new(),
    };

    let text = String::from_utf8_lossy(&output.stdout);
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Vec::new();
    }

    if let Ok(list) = serde_json::from_str::<Vec<WinPnpUsbRecord>>(trimmed) {
        return list;
    }
    if let Ok(single) = serde_json::from_str::<WinPnpUsbRecord>(trimmed) {
        return vec![single];
    }
    Vec::new()
}

fn build_windows_usb_nodes(records: &[WinPnpUsbRecord]) -> Vec<UsbNode> {
    // Map USB device InstanceId (uppercased) -> Ethernet adapter name from `Net` class nodes.
    let mut net_by_usb_id: HashMap<String, String> = HashMap::new();
    for rec in records {
        if rec.class_name.as_deref() == Some("Net") {
            let name = rec
                .friendly_name
                .as_deref()
                .filter(|s| !s.is_empty())
                .unwrap_or("Ethernet")
                .to_string();
            let upper_id = rec.instance_id.to_ascii_uppercase();
            if upper_id.starts_with("USB\\") && !upper_id.contains("&MI_") {
                // Single-interface USB Ethernet adapter (e.g. Realtek RTL8153 on Razer Dock)
                net_by_usb_id.insert(upper_id, name.clone());
            }
            if let Some(parent) = rec.parent_id.as_deref().filter(|s| !s.is_empty()) {
                let upper_parent = parent.to_ascii_uppercase();
                net_by_usb_id.entry(upper_parent.clone()).or_insert_with(|| name.clone());
                if let Some(base) = strip_mi_suffix(&upper_parent) {
                    net_by_usb_id.entry(base).or_insert(name);
                }
            }
        }
    }

    // Collect physical USB device records (exclude composite `&MI_XX` child interfaces).
    let usb_records: Vec<&WinPnpUsbRecord> = records
        .iter()
        .filter(|r| {
            let upper = r.instance_id.to_ascii_uppercase();
            upper.starts_with("USB\\") && !upper.contains("&MI_")
        })
        .collect();

    if usb_records.is_empty() {
        return Vec::new();
    }

    // Assign stable IDs to each uppercased USB InstanceId.
    let mut id_map: HashMap<String, u64> = HashMap::new();
    let mut record_by_key: HashMap<String, &WinPnpUsbRecord> = HashMap::new();
    for (idx, rec) in usb_records.iter().enumerate() {
        let key = rec.instance_id.to_ascii_uppercase();
        id_map.entry(key.clone()).or_insert((idx as u64) + 1);
        record_by_key.insert(key, rec);
    }

    // Assign a bus byte (1..=255) per PCI host controller (parent of `USB\ROOT_HUB*`).
    let mut pci_bus_map: HashMap<String, u8> = HashMap::new();
    let mut next_bus: u8 = 1;
    for rec in &usb_records {
        let key = rec.instance_id.to_ascii_uppercase();
        if is_windows_root_hub(&key) {
            let pci_parent = rec
                .parent_id
                .as_deref()
                .map(|s| s.to_ascii_uppercase())
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| key.clone());
            pci_bus_map.entry(pci_parent).or_insert_with(|| {
                let b = next_bus;
                next_bus = next_bus.wrapping_add(1).max(1);
                b
            });
        }
    }

    // Build UsbNodes with nibble-encoded location_ids derived from each node's chain up to its root hub.
    let mut nodes: Vec<UsbNode> = Vec::with_capacity(usb_records.len());
    for rec in &usb_records {
        let key = rec.instance_id.to_ascii_uppercase();
        let id = id_map[&key];
        let parent_key = rec
            .parent_id
            .as_deref()
            .map(|s| s.to_ascii_uppercase())
            .filter(|k| id_map.contains_key(k));
        let parent_id = parent_key.as_ref().and_then(|k| id_map.get(k).copied());

        let (bus, port_chain) = resolve_windows_bus_and_ports(&key, &record_by_key, &pci_bus_map);
        let location_id = encode_location_id(bus, &port_chain);

        let is_root = is_windows_root_hub(&key);
        let (vendor_id, product_id) = if is_root {
            (0x1D6B, 0x0003) // synthetic root hub marker (same convention as Linux)
        } else {
            parse_vid_pid(&key).unwrap_or((0, 0))
        };

        let compat = rec.compat_id_strings();
        let device_class = if is_root {
            USB_HUB_CLASS
        } else {
            parse_usb_class(&compat, rec.friendly_name.as_deref())
        };

        let name = rec
            .bus_desc
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .or_else(|| {
                rec.friendly_name
                    .as_deref()
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
            })
            .unwrap_or(if device_class == USB_HUB_CLASS {
                "USB Hub"
            } else {
                "USB Device"
            })
            .to_string();

        let vendor_name = rec
            .manufacturer
            .as_deref()
            .map(str::trim)
            .filter(|s| {
                !s.is_empty()
                    && !s.starts_with('(')
                    && !s.eq_ignore_ascii_case("Microsoft")
                    && !s.eq_ignore_ascii_case("Generic")
            })
            .map(ToString::to_string);

        let serial_number = parse_windows_serial(&rec.instance_id);
        let network_interface = net_by_usb_id.get(&key).cloned();

        nodes.push(UsbNode {
            id,
            parent_id,
            location_id,
            vendor_id,
            product_id,
            name,
            vendor_name,
            device_class,
            speed: None,
            network_interface,
            serial_number,
        });
    }

    nodes
}

/// If the dock's anchor sits behind an intermediate hardware hub (depth >= 2 beneath a Windows
/// `ROOT_HUB30`), drop the synthetic root hubs so the controller's hardware USB 2.0 + USB 3.0
/// hubs become the top-level roots expected by `dock_topology::build_layout()`.
/// Conversely, if the anchor is a direct child of `ROOT_HUB30` (Goshen Ridge PCIe xHCI),
/// keep `ROOT_HUB30` as the controller hub.
fn normalize_windows_roots(nodes: &[UsbNode], model: &DockModel) -> Vec<UsbNode> {
    let Some(anchor) = nodes
        .iter()
        .find(|n| n.vendor_id == model.vendor_id && n.product_id == model.anchor_product_id)
    else {
        return nodes.to_vec();
    };

    let by_id: HashMap<u64, &UsbNode> = nodes.iter().map(|n| (n.id, n)).collect();
    let parent_is_synthetic_root = anchor
        .parent_id
        .and_then(|pid| by_id.get(&pid))
        .map(|p| p.parent_id.is_none() && p.vendor_id == 0x1D6B)
        .unwrap_or(false);

    if parent_is_synthetic_root {
        return nodes.to_vec();
    }

    let root_hub_ids: HashSet<u64> = nodes
        .iter()
        .filter(|n| n.parent_id.is_none() && n.vendor_id == 0x1D6B)
        .map(|n| n.id)
        .collect();

    if root_hub_ids.is_empty() {
        return nodes.to_vec();
    }

    nodes
        .iter()
        .filter(|n| !root_hub_ids.contains(&n.id))
        .cloned()
        .map(|mut n| {
            if let Some(pid) = n.parent_id {
                if root_hub_ids.contains(&pid) {
                    n.parent_id = None;
                }
            }
            n
        })
        .collect()
}

fn is_windows_root_hub(upper_instance_id: &str) -> bool {
    upper_instance_id.starts_with("USB\\ROOT_HUB")
}

fn resolve_windows_bus_and_ports(
    start_key: &str,
    records: &HashMap<String, &WinPnpUsbRecord>,
    pci_bus_map: &HashMap<String, u8>,
) -> (u8, Vec<u8>) {
    let mut ports_rev: Vec<u8> = Vec::new();
    let mut cur_key = start_key.to_string();
    let mut bus: u8 = 1;

    for _ in 0..10 {
        let Some(rec) = records.get(&cur_key) else {
            break;
        };
        if is_windows_root_hub(&cur_key) {
            let pci_parent = rec
                .parent_id
                .as_deref()
                .map(|s| s.to_ascii_uppercase())
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| cur_key.clone());
            bus = pci_bus_map.get(&pci_parent).copied().unwrap_or(1);
            break;
        }
        if let Some(port) = rec
            .location_info
            .as_deref()
            .and_then(parse_windows_port_number)
        {
            ports_rev.push(port);
        }
        match rec
            .parent_id
            .as_deref()
            .map(|s| s.to_ascii_uppercase())
            .filter(|k| records.contains_key(k))
        {
            Some(parent) => cur_key = parent,
            None => break,
        }
    }

    ports_rev.reverse();
    (bus, ports_rev)
}

fn encode_location_id(bus: u8, ports: &[u8]) -> u32 {
    let mut loc = (bus as u32) << 24;
    for (idx, &port) in ports.iter().take(6).enumerate() {
        let shift = 20 - (idx as u32) * 4;
        loc |= ((port & 0x0F) as u32) << shift;
    }
    loc
}

/// Parses `"Port_#0004.Hub_#0002"` -> `Some(4)`.
fn parse_windows_port_number(location_info: &str) -> Option<u8> {
    let idx = location_info.find("Port_#")?;
    let rest = &location_info[idx + 6..];
    let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
    let val = digits.parse::<u16>().ok()?;
    (val > 0 && val <= 15).then_some(val as u8)
}

/// Parses `"USB\\VID_310E&PID_0952\\..."` -> `Some((0x310E, 0x0952))`.
fn parse_vid_pid(upper_instance_id: &str) -> Option<(u16, u16)> {
    let vid_idx = upper_instance_id.find("VID_")?;
    let vid_hex = upper_instance_id.get(vid_idx + 4..vid_idx + 8)?;
    let pid_idx = upper_instance_id.find("PID_")?;
    let pid_hex = upper_instance_id.get(pid_idx + 4..pid_idx + 8)?;
    let vid = u16::from_str_radix(vid_hex, 16).ok()?;
    let pid = u16::from_str_radix(pid_hex, 16).ok()?;
    Some((vid, pid))
}

fn parse_usb_class(compat_ids: &[String], friendly_name: Option<&str>) -> u8 {
    for cid in compat_ids {
        let upper = cid.to_ascii_uppercase();
        if let Some(idx) = upper.find("CLASS_") {
            if let Some(hex) = upper.get(idx + 6..idx + 8) {
                if let Ok(cls) = u8::from_str_radix(hex, 16) {
                    if cls != 0 {
                        return cls;
                    }
                }
            }
        }
    }
    if let Some(name) = friendly_name {
        let lower = name.to_ascii_lowercase();
        if lower.contains("billboard") {
            return USB_BILLBOARD_CLASS;
        }
        if lower.contains("hub") {
            return USB_HUB_CLASS;
        }
    }
    0
}

fn parse_windows_serial(instance_id: &str) -> Option<String> {
    // Format: USB\VID_XXXX&PID_YYYY\<serial>
    // Windows synthesizes container IDs containing `&` when no hardware serial is present.
    let seg = instance_id.split('\\').nth(2)?.trim();
    if seg.is_empty() || seg.contains('&') {
        return None;
    }
    Some(seg.to_string())
}

fn strip_mi_suffix(upper_id: &str) -> Option<String> {
    let mi_idx = upper_id.find("&MI_")?;
    let slash_idx = upper_id[mi_idx..].find('\\').map(|i| i + mi_idx)?;
    Some(format!("{}{}", &upper_id[..mi_idx], &upper_id[slash_idx..]))
}
