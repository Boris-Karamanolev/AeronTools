//! Shared cross-platform application state, telemetry, display, caffeine, game mode,
//! and hotkey models mirroring AeronTools (excluding macOS-only Wireless Display).

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

use crate::dock_topology::DockLayout;
use crate::hidpp::MxWheelMode;
use crate::logitech_g::TriggerSettings;
use crate::logitech_keyboard::{BacklightEffect, RgbColor, RgbEffect, RgbLighting};
use crate::razer_chroma::RazerLighting;

/// Persisted per-monitor settings keyed by EDID identity.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MonitorSettings {
    pub brightness: Option<f32>,
    pub volume: Option<f32>,
    #[serde(default)]
    pub is_muted: bool,
    /// Software extra dimming multiplier (1.0 = none, 0.2 = max dim).
    #[serde(default = "default_extra_dimming")]
    pub extra_dimming: f32,
    pub input_sources: Option<Vec<u8>>,
}

fn default_extra_dimming() -> f32 {
    1.0
}

fn default_true() -> bool {
    true
}

fn default_low_battery_threshold() -> u8 {
    15
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InputSourceOption {
    pub code: u8,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExternalDisplayInfo {
    pub id: String,
    pub settings_key: String,
    pub name: String,
    pub brightness: f32,
    pub volume: f32,
    pub is_muted: bool,
    pub extra_dimming: f32,
    pub input_sources: Vec<InputSourceOption>,
    pub current_input: Option<u8>,
    pub has_hardware_control: bool,
    pub is_builtin: bool,
    pub is_enabled: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BuiltinDisplayState {
    pub present: bool,
    pub is_turned_off: bool,
    pub can_turn_off: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ThermalPressure {
    Nominal,
    Fair,
    Serious,
    Critical,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FanReading {
    pub index: usize,
    pub name: String,
    pub rpm: u32,
    pub max_rpm: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThermalSnapshot {
    pub supported: bool,
    pub pressure: ThermalPressure,
    pub cpu_celsius: Option<f64>,
    pub gpu_celsius: Option<f64>,
    pub battery_celsius: Option<f64>,
    pub fans: Vec<FanReading>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WattageSnapshot {
    pub supported: bool,
    pub is_plugged_in: bool,
    pub is_charging: bool,
    pub battery_level: Option<u8>,
    pub system_load_watts: Option<f64>,
    pub input_watts: Option<f64>,
    pub adapter_watts: Option<u32>,
    pub battery_watts: Option<f64>,
    pub voltage: Option<f64>,
    pub amperage: Option<f64>,
    pub battery_health_percent: Option<u8>,
    pub cycle_count: Option<u32>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum GameModePolicy {
    Automatic,
    ForcedOn,
    ForcedOff,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GameModeState {
    pub supported: bool,
    pub is_active: bool,
    pub policy: GameModePolicy,
    pub backend_name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CaffeineState {
    pub is_active: bool,
    /// Unix timestamp in milliseconds when timed caffeine ends (`None` = indefinite).
    pub ends_at_ms: Option<u64>,
    pub is_automatic: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AccessoryConnection {
    BluetoothLe,
    LogiBolt,
    Unifying,
    Lightspeed,
    UsbWired,
    Thunderbolt,
    Wireless4k,
}

/// Action assignable to an accessory's buttons, keyboard F-keys, or MX Master gestures.
/// Matches `AccessoryButtonAction` in `AeronTools/AccessoryActions.swift`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AccessoryButtonAction {
    SystemDefault,
    MissionControl,
    AppExpose,
    ShowDesktop,
    Launchpad,
    SpaceLeft,
    SpaceRight,
    NavigateBack,
    NavigateForward,
    PlayPause,
    MutePointerDisplay,
    ToggleBuiltinScreen,
    ToggleCaffeine,
    ToggleWheelMode,
    Copy,
    Paste,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MxThumbwheelAction {
    HorizontalScroll,
    DisplayBrightness,
    DisplayVolume,
    SwitchWorkspaces,
    SwitchTabs,
    Zoom,
}

/// Editable MX Master behavioral settings (scrolling, thumbwheel, buttons, gestures, onboard memory).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MxMasterOptions {
    pub standard_vertical_scroll: bool,
    pub smooth_scrolling: bool,
    pub scroll_speed_multiplier: f64,
    pub thumbwheel_action: MxThumbwheelAction,
    pub invert_thumbwheel: bool,
    pub middle_button_action: AccessoryButtonAction,
    pub back_button_action: AccessoryButtonAction,
    pub forward_button_action: AccessoryButtonAction,
    pub gesture_button_action: AccessoryButtonAction,
    pub mode_shift_button_action: AccessoryButtonAction,
    pub haptic_panel_button_action: AccessoryButtonAction,
    pub gestures_enabled: bool,
    pub gesture_up_action: AccessoryButtonAction,
    pub gesture_down_action: AccessoryButtonAction,
    pub gesture_left_action: AccessoryButtonAction,
    pub gesture_right_action: AccessoryButtonAction,
    pub saves_to_mouse: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MxMasterState {
    pub connected: bool,
    pub name: String,
    pub connection: Option<AccessoryConnection>,
    pub battery_percent: Option<u8>,
    pub is_charging: bool,
    pub dpi: u16,
    pub min_dpi: u16,
    pub max_dpi: u16,
    pub dpi_step: u16,
    pub wheel_mode: MxWheelMode,
    pub smart_shift_enabled: bool,
    pub smart_shift_threshold: u8,
    pub standard_vertical_scroll: bool,
    pub smooth_scrolling: bool,
    pub scroll_speed_multiplier: f64,
    pub thumbwheel_action: MxThumbwheelAction,
    pub invert_thumbwheel: bool,
    pub middle_button_action: AccessoryButtonAction,
    pub back_button_action: AccessoryButtonAction,
    pub forward_button_action: AccessoryButtonAction,
    pub gesture_button_action: AccessoryButtonAction,
    pub mode_shift_button_action: AccessoryButtonAction,
    pub haptic_panel_button_action: AccessoryButtonAction,
    pub gestures_enabled: bool,
    pub gesture_up_action: AccessoryButtonAction,
    pub gesture_down_action: AccessoryButtonAction,
    pub gesture_left_action: AccessoryButtonAction,
    pub gesture_right_action: AccessoryButtonAction,
    pub saves_to_mouse: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MxKeyboardState {
    pub connected: bool,
    pub name: String,
    pub connection: Option<AccessoryConnection>,
    pub battery_percent: Option<u8>,
    pub is_charging: bool,
    pub backlight_enabled: bool,
    pub automatic_brightness: bool,
    pub battery_saving: bool,
    pub backlight_level: u8,
    pub backlight_effect: BacklightEffect,
    pub supported_effects: Vec<BacklightEffect>,
    pub duration_seconds: u16,
    pub fn_inversion: Option<bool>,
    pub current_host: Option<u8>,
    /// Remapped actions for F1..=F12 (keyed by 1-based F-key position).
    pub key_actions: HashMap<u8, AccessoryButtonAction>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LogitechGMouseState {
    pub connected: bool,
    pub name: String,
    pub connection: Option<AccessoryConnection>,
    pub battery_percent: Option<u8>,
    pub is_charging: bool,
    pub dpi: u16,
    pub min_dpi: u16,
    pub max_dpi: u16,
    pub report_rate_hz: u16,
    pub supported_report_rates: Vec<u16>,
    pub lift_off_distance: u8,
    pub triggers: Option<TriggerSettings>,
    pub back_button_action: AccessoryButtonAction,
    pub forward_button_action: AccessoryButtonAction,
    pub saves_to_onboard_profile: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LogitechGKeyboardState {
    pub connected: bool,
    pub name: String,
    pub connection: Option<AccessoryConnection>,
    pub battery_percent: Option<u8>,
    pub is_charging: bool,
    pub brightness: u16,
    pub max_brightness: u16,
    pub lighting: RgbLighting,
    pub supported_effects: Vec<RgbEffect>,
    pub game_mode_on: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeychronM3MiniState {
    pub connected: bool,
    pub name: String,
    pub connection: Option<AccessoryConnection>,
    pub battery_percent: Option<u8>,
    pub is_charging: bool,
    pub active_stage: u8,
    pub stage_dpis: Vec<u16>,
    pub report_rate_hz: u16,
    pub max_report_rate_hz: u16,
    pub lift_off_mm: u8,
    pub motion_sync: bool,
    pub angle_snapping: bool,
    pub back_button_action: AccessoryButtonAction,
    pub forward_button_action: AccessoryButtonAction,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RazerDockState {
    pub connected: bool,
    pub name: String,
    pub firmware: Option<String>,
    pub serial_number: Option<String>,
    pub brightness: Option<u8>,
    pub lighting: Option<RazerLighting>,
    pub ports: DockLayout,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SatechiHubState {
    pub connected: bool,
    pub name: String,
    pub ports: DockLayout,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AccessoriesSnapshot {
    pub mx_master: MxMasterState,
    pub mx_keyboard: MxKeyboardState,
    pub logitech_g_mouse: LogitechGMouseState,
    pub logitech_g_keyboard: LogitechGKeyboardState,
    pub keychron_m3_mini: KeychronM3MiniState,
    pub razer_dock: RazerDockState,
    pub satechi_hub: SatechiHubState,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HotkeyBinding {
    pub action: String,
    pub label: String,
    pub accelerator: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppPreferences {
    #[serde(default = "default_true")]
    pub show_accessories_card: bool,
    #[serde(default = "default_true")]
    pub show_wattage_meter: bool,
    #[serde(default = "default_true")]
    pub show_battery_health: bool,
    #[serde(default = "default_true")]
    pub show_thermals: bool,
    #[serde(default = "default_true")]
    pub auto_turn_off_builtin: bool,
    #[serde(default = "default_true")]
    pub show_input_switching: bool,
    #[serde(default)]
    pub extra_dimming_enabled: bool,
    #[serde(default = "default_true")]
    pub restore_monitor_settings: bool,
    #[serde(default = "default_true")]
    pub media_keys_control_pointer_display: bool,
    #[serde(default)]
    pub launch_at_login: bool,
    #[serde(default = "default_true")]
    pub low_battery_alert_enabled: bool,
    #[serde(default = "default_low_battery_threshold")]
    pub low_battery_threshold: u8,
    #[serde(default)]
    pub caffeine_with_external_display: bool,
    #[serde(default)]
    pub caffeine_on_power_adapter: bool,
    pub daemon_port: u16,
    pub hotkeys: Vec<HotkeyBinding>,
    pub monitor_settings: HashMap<String, MonitorSettings>,
}

impl Default for AppPreferences {
    fn default() -> Self {
        Self {
            show_accessories_card: true,
            show_wattage_meter: true,
            show_battery_health: true,
            show_thermals: true,
            auto_turn_off_builtin: true,
            show_input_switching: true,
            extra_dimming_enabled: false,
            restore_monitor_settings: true,
            media_keys_control_pointer_display: true,
            launch_at_login: false,
            low_battery_alert_enabled: true,
            low_battery_threshold: 15,
            caffeine_with_external_display: false,
            caffeine_on_power_adapter: false,
            daemon_port: 47620,
            hotkeys: vec![
                HotkeyBinding {
                    action: "brightnessUp".into(),
                    label: "Increase Monitor Brightness".into(),
                    accelerator: Some("Ctrl+Alt+F2".into()),
                },
                HotkeyBinding {
                    action: "brightnessDown".into(),
                    label: "Decrease Monitor Brightness".into(),
                    accelerator: Some("Ctrl+Alt+F1".into()),
                },
                HotkeyBinding {
                    action: "toggleCaffeine".into(),
                    label: "Toggle Caffeine".into(),
                    accelerator: Some("Ctrl+Alt+C".into()),
                },
                HotkeyBinding {
                    action: "toggleGameMode".into(),
                    label: "Toggle Game Mode".into(),
                    accelerator: Some("Ctrl+Alt+G".into()),
                },
                HotkeyBinding {
                    action: "toggleBuiltinScreen".into(),
                    label: "Toggle Built-in Screen".into(),
                    accelerator: Some("Ctrl+Alt+B".into()),
                },
            ],
            monitor_settings: HashMap::new(),
        }
    }
}

/// Complete state payload synced to the Tauri React UI and the SteamOS Decky Loader plugin.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppSnapshot {
    pub platform: String,
    pub is_steamos: bool,
    pub displays: Vec<ExternalDisplayInfo>,
    #[serde(default)]
    pub builtin_display: BuiltinDisplayState,
    pub accessories: AccessoriesSnapshot,
    pub wattage: WattageSnapshot,
    pub thermals: ThermalSnapshot,
    pub caffeine: CaffeineState,
    pub game_mode: GameModeState,
    pub preferences: AppPreferences,
}

/// Helper to create a default RGB white color when initializing keyboard state.
pub fn default_rgb_lighting() -> RgbLighting {
    RgbLighting {
        effect: RgbEffect::Fixed,
        color: RgbColor::WHITE,
        speed: 5,
    }
}
