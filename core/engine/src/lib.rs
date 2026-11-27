//! Unified cross-platform hardware controller (`AeronCore`) combining OS backends
//! (macOS, Linux/SteamOS, and Windows) with `hidapi` peripheral management and settings persistence.

pub mod hid_devices;
mod accessory_store;
mod hid_input;
pub mod host_actions;
mod input_session;

#[cfg(target_os = "macos")]
#[path = "../../../platforms/macos/backend/input_perform.rs"]
mod input_perform;

#[cfg(target_os = "macos")]
#[path = "../../../platforms/macos/backend/macos.rs"]
pub mod macos;
#[cfg(target_os = "macos")]
#[path = "../../../platforms/macos/backend/macos_dock.rs"]
pub mod macos_dock;
#[cfg(target_os = "linux")]
#[path = "../../../platforms/linux/backend/linux.rs"]
pub mod linux;
#[cfg(target_os = "windows")]
#[path = "../../../platforms/windows/backend/windows.rs"]
pub mod windows;
#[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
pub mod fallback;

use std::fs;
use std::path::PathBuf;
use std::sync::{mpsc, Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use aeron_protocols::dock_topology::DockLayout;
use aeron_protocols::hidpp::MxWheelMode;
use aeron_protocols::logitech_g::TriggerSettings;
use aeron_protocols::logitech_keyboard::{BacklightEffect, RgbLighting};
use aeron_protocols::models::{
    AccessoriesSnapshot, AccessoryButtonAction, AppPreferences, AppSnapshot, BuiltinDisplayState,
    CaffeineState, ExternalDisplayInfo, GameModePolicy, GameModeState, MxMasterOptions,
    ThermalSnapshot, WattageSnapshot,
};
use aeron_protocols::razer_chroma::RazerLighting;
use hid_devices::HidManager;
use tracing::warn;

const TELEMETRY_CACHE_TTL: Duration = Duration::from_millis(1500);

pub trait PlatformBackend: Send {
    fn platform_name(&self) -> &'static str;
    fn is_steamos(&self) -> bool;
    fn refresh_displays(&mut self) -> Vec<ExternalDisplayInfo>;
    fn displays(&self) -> Vec<ExternalDisplayInfo>;
    fn set_display_brightness(&mut self, display_id: &str, level: f32) -> Result<(), String>;
    fn set_display_volume(&mut self, display_id: &str, level: f32) -> Result<(), String>;
    fn set_display_muted(&mut self, display_id: &str, muted: bool) -> Result<(), String>;
    fn set_display_input(&mut self, display_id: &str, input_code: u8) -> Result<(), String>;
    fn set_caffeine_active(&mut self, active: bool) -> Result<(), String>;
    fn read_thermals(&self) -> ThermalSnapshot;
    fn read_wattage(&self) -> WattageSnapshot;
    fn read_game_mode(&self) -> GameModeState;
    fn set_game_mode_policy(&mut self, policy: GameModePolicy) -> Result<GameModeState, String>;
    fn read_dock_layouts(&self) -> (DockLayout, DockLayout);
    fn builtin_display_state(&self) -> BuiltinDisplayState {
        BuiltinDisplayState::default()
    }
    fn set_builtin_display_enabled(&mut self, _enabled: bool) -> Result<(), String> {
        Err("Built-in display control is not supported on this platform".to_string())
    }
    fn apply_auto_turn_off_preference(&mut self, _auto_turn_off_builtin: bool) {}
    fn poll_display_topology(&mut self, _auto_turn_off_builtin: bool) {}
}

/// OS dock walk. Must not run while `AeronCore.inner` is held.
fn scan_host_docks() -> (DockLayout, DockLayout) {
    #[cfg(target_os = "macos")]
    {
        macos_dock::scan_macos_usb_docks()
    }
    #[cfg(target_os = "linux")]
    {
        linux::scan_sysfs_usb_docks()
    }
    #[cfg(target_os = "windows")]
    {
        windows::cached_dock_layouts()
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
    {
        (DockLayout::empty_razer(), DockLayout::empty_satechi())
    }
}

fn create_platform_backend() -> Box<dyn PlatformBackend> {
    #[cfg(target_os = "macos")]
    {
        Box::new(macos::MacosBackend::new())
    }
    #[cfg(target_os = "linux")]
    {
        Box::new(linux::LinuxBackend::new())
    }
    #[cfg(target_os = "windows")]
    {
        Box::new(windows::WindowsBackend::new())
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
    {
        Box::new(fallback::FallbackBackend::new())
    }
}

struct InnerState {
    backend: Box<dyn PlatformBackend>,
    caffeine: CaffeineState,
    preferences: AppPreferences,
    cached_telemetry: Option<(Instant, WattageSnapshot, ThermalSnapshot)>,
    /// The menu-bar app keeps brightness schedules, extra dimming, and auto-off.
    /// The engine still performs the DDC write when asked, and does not toggle the panel itself.
    drive_display_policy: bool,
}

struct PrefsSaveState {
    pending: Option<AppPreferences>,
    last_change: Instant,
    shutdown: bool,
}

/// Thread-safe application core shared by both the Tauri desktop app and `aeron-daemon`.
///
/// `hid` and `hid_snapshot` live behind separate locks from `inner` so slow 300ms USB/HID
/// accessory scans NEVER stall display brightness/volume slider drags.
#[derive(Clone)]
pub struct AeronCore {
    inner: Arc<Mutex<InnerState>>,
    hid: Arc<Mutex<HidManager>>,
    hid_snapshot: Arc<Mutex<AccessoriesSnapshot>>,
    prefs_saver: Arc<(Mutex<PrefsSaveState>, Condvar)>,
}

impl Default for AeronCore {
    fn default() -> Self {
        Self::new()
    }
}

impl AeronCore {
    pub fn new() -> Self {
        Self::build(true)
    }

    /// Menu-bar process. HID input runs here. Display policy stays in Swift.
    pub fn for_menu_bar() -> Self {
        Self::build(false)
    }

    fn build(drive_display_policy: bool) -> Self {
        let mut backend = create_platform_backend();
        let mut hid_mgr = HidManager::new();
        let (razer_ports, satechi_ports) = backend.read_dock_layouts();
        hid_mgr.set_dock_layouts(razer_ports, satechi_ports);
        // HID enumeration is started on the watcher thread. Doing it here would
        // pin IOHIDManager to this thread and crash the next scan.
        let initial_hid_snapshot = hid_mgr.snapshot();

        let preferences = load_preferences();
        if drive_display_policy && preferences.auto_turn_off_builtin {
            backend.apply_auto_turn_off_preference(true);
        }

        let inner = Arc::new(Mutex::new(InnerState {
            backend,
            caffeine: CaffeineState {
                is_active: false,
                ends_at_ms: None,
                is_automatic: false,
            },
            preferences,
            cached_telemetry: None,
            drive_display_policy,
        }));
        let hid = Arc::new(Mutex::new(hid_mgr));
        let hid_snapshot = Arc::new(Mutex::new(initial_hid_snapshot));

        // Debounced background preferences writer so dragging monitor sliders does zero disk I/O.
        let prefs_saver = Arc::new((
            Mutex::new(PrefsSaveState {
                pending: None,
                last_change: Instant::now(),
                shutdown: false,
            }),
            Condvar::new(),
        ));
        let saver_ref = Arc::downgrade(&prefs_saver);
        let _ = thread::Builder::new()
            .name("aeron-prefs-saver".into())
            .spawn(move || {
                loop {
                    let Some(arc) = saver_ref.upgrade() else {
                        break;
                    };
                    let (lock, cvar) = &*arc;
                    let to_save = {
                        let mut guard = match lock.lock() {
                            Ok(g) => g,
                            Err(_) => break,
                        };
                        while guard.pending.is_none() && !guard.shutdown {
                            guard = match cvar.wait(guard) {
                                Ok(g) => g,
                                Err(_) => return,
                            };
                        }
                        if guard.shutdown {
                            guard.pending.take()
                        } else {
                            let elapsed = guard.last_change.elapsed();
                            let debounce = Duration::from_millis(350);
                            if elapsed < debounce {
                                let _ = cvar.wait_timeout(guard, debounce - elapsed);
                                continue;
                            }
                            guard.pending.take()
                        }
                    };
                    if let Some(prefs) = to_save {
                        save_preferences(&prefs);
                    }
                    if lock.lock().map(|g| g.shutdown).unwrap_or(true) {
                        break;
                    }
                }
            });

        // Background hardware watcher:
        // - Every 1s: display topology (auto built-in screen off/on on monitor attach/detach)
        // - Every 4s: USB/Thunderbolt dock port layout + HID accessories (outside `inner` lock!)
        let watcher_inner = Arc::downgrade(&inner);
        let watcher_hid = Arc::downgrade(&hid);
        let watcher_hid_snap = Arc::downgrade(&hid_snapshot);
        let (hid_ready_tx, hid_ready_rx) = mpsc::channel();
        let _ = thread::Builder::new()
            .name("aeron-hw-watcher".into())
            .spawn(move || {
                if let (Some(hid_arc), Some(snap_arc)) =
                    (watcher_hid.upgrade(), watcher_hid_snap.upgrade())
                {
                    if let Ok(mut h) = hid_arc.lock() {
                        h.refresh();
                        let latest = h.snapshot();
                        if let Ok(mut snap) = snap_arc.lock() {
                            *snap = latest;
                        }
                    }
                }
                let _ = hid_ready_tx.send(());

                let mut tick: u64 = 0;
                loop {
                    thread::sleep(Duration::from_secs(1));
                    tick = tick.wrapping_add(1);
                    let (Some(inner_arc), Some(hid_arc), Some(snap_arc)) = (
                        watcher_inner.upgrade(),
                        watcher_hid.upgrade(),
                        watcher_hid_snap.upgrade(),
                    ) else {
                        break;
                    };

                    let should_scan_docks = {
                        let Ok(mut guard) = inner_arc.lock() else {
                            continue;
                        };
                        if guard.drive_display_policy {
                            let auto_off = guard.preferences.auto_turn_off_builtin;
                            guard.backend.poll_display_topology(auto_off);
                        } else if tick % 4 == 0 {
                            let _ = guard.backend.refresh_displays();
                        }
                        tick % 4 == 0
                    };

                    // Dock walks and HID probes stay off `inner`. Windows shells out to
                    // PowerShell here; holding `inner` across that freezes brightness sliders.
                    if !should_scan_docks {
                        continue;
                    }
                    let (razer, satechi) = scan_host_docks();
                    let hid_guard = hid_arc.lock();
                    if let Ok(mut h) = hid_guard {
                        h.set_dock_layouts(razer, satechi);
                        h.refresh();
                        let latest = h.snapshot();
                        let snap_guard = snap_arc.lock();
                        if let Ok(mut s) = snap_guard {
                            *s = latest;
                        }
                    }
                }
            });
        let _ = hid_ready_rx.recv_timeout(Duration::from_secs(3));

        Self {
            inner,
            hid,
            hid_snapshot,
            prefs_saver,
        }
    }

    fn schedule_preferences_save(&self, prefs: AppPreferences) {
        let (lock, cvar) = &*self.prefs_saver;
        if let Ok(mut guard) = lock.lock() {
            guard.pending = Some(prefs);
            guard.last_change = Instant::now();
            cvar.notify_one();
        }
    }

    pub fn snapshot(&self) -> AppSnapshot {
        let mut guard = self.inner.lock().expect("AeronCore mutex poisoned");
        Self::check_caffeine_expiry(&mut guard);

        let displays = guard.backend.displays();
        let builtin_display = guard.backend.builtin_display_state();
        let game_mode = guard.backend.read_game_mode();

        let (wattage, thermals) = match &guard.cached_telemetry {
            Some((at, w, t)) if at.elapsed() < TELEMETRY_CACHE_TTL => (w.clone(), t.clone()),
            _ => {
                let w = guard.backend.read_wattage();
                let t = guard.backend.read_thermals();
                guard.cached_telemetry = Some((Instant::now(), w.clone(), t.clone()));
                (w, t)
            }
        };

        let platform = guard.backend.platform_name().to_string();
        let is_steamos = guard.backend.is_steamos();
        let caffeine = guard.caffeine.clone();
        let preferences = guard.preferences.clone();
        drop(guard);

        let accessories = self
            .hid_snapshot
            .lock()
            .expect("hid_snapshot mutex poisoned")
            .clone();

        AppSnapshot {
            platform,
            is_steamos,
            displays,
            builtin_display,
            accessories,
            wattage,
            thermals,
            caffeine,
            game_mode,
            preferences,
        }
    }

    /// Fast refresh of dock port topology and HID accessories without holding the display lock
    /// during slow USB/HID probing.
    pub fn refresh_accessories_and_docks(&self) {
        let (razer, satechi) = scan_host_docks();
        if let Ok(mut h) = self.hid.lock() {
            h.set_dock_layouts(razer, satechi);
            h.refresh();
            let latest = h.snapshot();
            if let Ok(mut s) = self.hid_snapshot.lock() {
                *s = latest;
            }
        }
    }

    pub fn refresh_all(&self) -> AppSnapshot {
        {
            let mut guard = self.inner.lock().expect("AeronCore mutex poisoned");
            guard.backend.refresh_displays();
            guard.cached_telemetry = None;
        }
        let layouts = scan_host_docks();
        {
            let mut h = self.hid.lock().expect("hid mutex poisoned");
            h.set_dock_layouts(layouts.0, layouts.1);
            h.refresh();
            let latest = h.snapshot();
            *self.hid_snapshot.lock().expect("hid_snapshot mutex poisoned") = latest;
        }
        self.snapshot()
    }

    pub fn set_display_brightness(
        &self,
        display_id: &str,
        level: f32,
    ) -> Result<AppSnapshot, String> {
        let prefs_to_save = {
            let mut guard = self.inner.lock().expect("AeronCore mutex poisoned");
            guard.backend.set_display_brightness(display_id, level)?;
            if let Some(d) = guard
                .backend
                .displays()
                .into_iter()
                .find(|d| d.id == display_id)
            {
                guard
                    .preferences
                    .monitor_settings
                    .entry(d.settings_key)
                    .or_default()
                    .brightness = Some(level.clamp(0.0, 1.0));
                Some(guard.preferences.clone())
            } else {
                None
            }
        };
        if let Some(prefs) = prefs_to_save {
            self.schedule_preferences_save(prefs);
        }
        Ok(self.snapshot())
    }

    pub fn step_all_brightness(&self, delta: f32) -> Result<AppSnapshot, String> {
        let updates: Vec<(String, f32)> = {
            let guard = self.inner.lock().expect("AeronCore mutex poisoned");
            guard
                .backend
                .displays()
                .into_iter()
                .map(|d| (d.id, (d.brightness + delta).clamp(0.0, 1.0)))
                .collect()
        };
        for (id, level) in updates {
            let _ = self.set_display_brightness(&id, level);
        }
        Ok(self.snapshot())
    }

    pub fn set_display_volume(
        &self,
        display_id: &str,
        level: f32,
    ) -> Result<AppSnapshot, String> {
        let prefs_to_save = {
            let mut guard = self.inner.lock().expect("AeronCore mutex poisoned");
            guard.backend.set_display_volume(display_id, level)?;
            if let Some(d) = guard
                .backend
                .displays()
                .into_iter()
                .find(|d| d.id == display_id)
            {
                guard
                    .preferences
                    .monitor_settings
                    .entry(d.settings_key)
                    .or_default()
                    .volume = Some(level.clamp(0.0, 1.0));
                Some(guard.preferences.clone())
            } else {
                None
            }
        };
        if let Some(prefs) = prefs_to_save {
            self.schedule_preferences_save(prefs);
        }
        Ok(self.snapshot())
    }

    pub fn set_display_muted(&self, display_id: &str, muted: bool) -> Result<AppSnapshot, String> {
        {
            let mut guard = self.inner.lock().expect("AeronCore mutex poisoned");
            guard.backend.set_display_muted(display_id, muted)?;
        }
        Ok(self.snapshot())
    }

    pub fn set_display_input(
        &self,
        display_id: &str,
        input_code: u8,
    ) -> Result<AppSnapshot, String> {
        {
            let mut guard = self.inner.lock().expect("AeronCore mutex poisoned");
            guard.backend.set_display_input(display_id, input_code)?;
        }
        Ok(self.snapshot())
    }

    pub fn set_caffeine(
        &self,
        active: bool,
        duration_seconds: Option<u64>,
    ) -> Result<AppSnapshot, String> {
        {
            let mut guard = self.inner.lock().expect("AeronCore mutex poisoned");
            guard.backend.set_caffeine_active(active)?;
            guard.caffeine.is_active = active;
            guard.caffeine.ends_at_ms = if active {
                duration_seconds.map(|secs| now_ms().saturating_add(secs * 1000))
            } else {
                None
            };
        }
        Ok(self.snapshot())
    }

    pub fn toggle_caffeine(&self) -> Result<AppSnapshot, String> {
        let next = {
            let guard = self.inner.lock().expect("AeronCore mutex poisoned");
            !guard.caffeine.is_active
        };
        self.set_caffeine(next, None)
    }

    pub fn set_game_mode_policy(&self, policy: GameModePolicy) -> Result<AppSnapshot, String> {
        {
            let mut guard = self.inner.lock().expect("AeronCore mutex poisoned");
            guard.backend.set_game_mode_policy(policy)?;
        }
        Ok(self.snapshot())
    }

    pub fn toggle_game_mode_forced(&self) -> Result<AppSnapshot, String> {
        let current = {
            let guard = self.inner.lock().expect("AeronCore mutex poisoned");
            guard.backend.read_game_mode().policy
        };
        let next = if current == GameModePolicy::ForcedOn {
            GameModePolicy::Automatic
        } else {
            GameModePolicy::ForcedOn
        };
        self.set_game_mode_policy(next)
    }

    pub fn update_preferences(&self, prefs: AppPreferences) -> AppSnapshot {
        {
            let mut guard = self.inner.lock().expect("AeronCore mutex poisoned");
            let prev_auto = guard.preferences.auto_turn_off_builtin;
            let next_auto = prefs.auto_turn_off_builtin;
            guard.preferences = prefs;
            save_preferences(&guard.preferences);
            if prev_auto != next_auto {
                guard.backend.apply_auto_turn_off_preference(next_auto);
            }
        }
        self.snapshot()
    }

    pub fn set_builtin_display_enabled(&self, enabled: bool) -> Result<AppSnapshot, String> {
        {
            let mut guard = self.inner.lock().expect("AeronCore mutex poisoned");
            guard.backend.set_builtin_display_enabled(enabled)?;
        }
        Ok(self.snapshot())
    }

    pub fn toggle_builtin_display(&self) -> Result<AppSnapshot, String> {
        let should_enable = {
            let guard = self.inner.lock().expect("AeronCore mutex poisoned");
            guard.backend.builtin_display_state().is_turned_off
        };
        self.set_builtin_display_enabled(should_enable)
    }

    pub fn prepare_for_termination(&self) {
        // Flush any pending debounced preferences to disk immediately
        let (lock, cvar) = &*self.prefs_saver;
        if let Ok(mut guard) = lock.lock() {
            if let Some(prefs) = guard.pending.take() {
                save_preferences(&prefs);
            }
            guard.shutdown = true;
            cvar.notify_all();
        }
        if let Ok(mut hid) = self.hid.lock() {
            hid.shutdown();
        }
        if let Ok(mut guard) = self.inner.lock() {
            if guard.drive_display_policy && guard.backend.builtin_display_state().is_turned_off {
                let _ = guard.backend.set_builtin_display_enabled(true);
            }
            if guard.caffeine.is_active {
                let _ = guard.backend.set_caffeine_active(false);
                guard.caffeine.is_active = false;
            }
        }
    }

    // MARK: - Accessory controls

    fn with_hid<F: FnOnce(&mut HidManager)>(&self, f: F) -> AppSnapshot {
        {
            let mut h = self.hid.lock().expect("hid mutex poisoned");
            f(&mut h);
            let latest = h.snapshot();
            *self.hid_snapshot.lock().expect("hid_snapshot mutex poisoned") = latest;
        }
        self.snapshot()
    }

    pub fn set_mx_master_dpi(&self, dpi: u16) -> AppSnapshot {
        self.with_hid(|h| h.set_mx_master_dpi(dpi))
    }

    pub fn set_mx_master_smart_shift(
        &self,
        wheel_mode: MxWheelMode,
        smart_shift_enabled: bool,
        threshold: u8,
    ) -> AppSnapshot {
        self.with_hid(|h| {
            h.set_mx_master_smart_shift(wheel_mode, smart_shift_enabled, threshold);
        })
    }

    pub fn set_mx_master_options(&self, opts: MxMasterOptions) -> AppSnapshot {
        self.with_hid(|h| h.set_mx_master_options(opts))
    }

    pub fn set_logitech_g_dpi(&self, dpi: u16) -> AppSnapshot {
        self.with_hid(|h| h.set_logitech_g_dpi(dpi))
    }

    pub fn set_logitech_g_report_rate(&self, hz: u16) -> AppSnapshot {
        self.with_hid(|h| h.set_logitech_g_report_rate(hz))
    }

    pub fn set_logitech_g_triggers(&self, triggers: TriggerSettings) -> AppSnapshot {
        self.with_hid(|h| h.set_logitech_g_triggers(triggers))
    }

    pub fn set_logitech_g_options(
        &self,
        back_button: AccessoryButtonAction,
        forward_button: AccessoryButtonAction,
        saves_to_onboard_profile: bool,
    ) -> AppSnapshot {
        self.with_hid(|h| {
            h.set_logitech_g_options(back_button, forward_button, saves_to_onboard_profile);
        })
    }

    pub fn set_mx_keyboard_backlight(
        &self,
        enabled: bool,
        auto_brightness: bool,
        battery_saving: bool,
        level: u8,
        duration_seconds: u16,
        effect: BacklightEffect,
    ) -> AppSnapshot {
        self.with_hid(|h| {
            h.set_mx_keyboard_backlight(
                enabled,
                auto_brightness,
                battery_saving,
                level,
                duration_seconds,
                effect,
            );
        })
    }

    pub fn set_mx_keyboard_fn_inversion(&self, standard_fn: bool) -> AppSnapshot {
        self.with_hid(|h| h.set_mx_keyboard_fn_inversion(standard_fn))
    }

    pub fn set_mx_keyboard_key_action(
        &self,
        position: u8,
        action: AccessoryButtonAction,
    ) -> AppSnapshot {
        self.with_hid(|h| h.set_mx_keyboard_key_action(position, action))
    }

    pub fn set_g_keyboard_lighting(&self, brightness: u16, lighting: RgbLighting) -> AppSnapshot {
        self.with_hid(|h| h.set_g_keyboard_lighting(brightness, lighting))
    }

    pub fn set_keychron_settings(
        &self,
        active_stage: u8,
        dpi: u16,
        report_rate_hz: u16,
        lift_off_mm: u8,
        motion_sync: bool,
        angle_snapping: bool,
    ) -> AppSnapshot {
        self.with_hid(|h| {
            h.set_keychron_settings(
                active_stage,
                dpi,
                report_rate_hz,
                lift_off_mm,
                motion_sync,
                angle_snapping,
            );
        })
    }

    pub fn set_keychron_side_buttons(
        &self,
        back_button: AccessoryButtonAction,
        forward_button: AccessoryButtonAction,
    ) -> AppSnapshot {
        self.with_hid(|h| h.set_keychron_side_buttons(back_button, forward_button))
    }

    pub fn set_razer_dock_lighting(
        &self,
        brightness: Option<u8>,
        lighting: Option<RazerLighting>,
    ) -> AppSnapshot {
        self.with_hid(|h| h.set_razer_dock_lighting(brightness, lighting))
    }

    fn check_caffeine_expiry(guard: &mut InnerState) {
        if guard.caffeine.is_active {
            if let Some(ends_at) = guard.caffeine.ends_at_ms {
                if now_ms() >= ends_at {
                    let _ = guard.backend.set_caffeine_active(false);
                    guard.caffeine.is_active = false;
                    guard.caffeine.ends_at_ms = None;
                }
            }
        }
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn preferences_path() -> Option<PathBuf> {
    dirs::config_dir().map(|d| d.join("AeronTools").join("preferences.json"))
}

fn load_preferences() -> AppPreferences {
    let Some(path) = preferences_path() else {
        return AppPreferences::default();
    };
    fs::read_to_string(&path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn save_preferences(prefs: &AppPreferences) {
    let Some(path) = preferences_path() else {
        return;
    };
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    match serde_json::to_string_pretty(prefs) {
        Ok(json) => {
            if let Err(err) = fs::write(&path, json) {
                warn!("Failed saving preferences to {}: {err}", path.display());
            }
        }
        Err(err) => warn!("Failed serializing preferences: {err}"),
    }
}
