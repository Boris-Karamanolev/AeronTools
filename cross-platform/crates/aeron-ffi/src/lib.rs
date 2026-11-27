//! UniFFI bridge exposing the full cross-platform `AeronCore` engine to Swift (macOS)
//! so changes to hardware protocols, peripherals, displays, telemetry, and preferences
//! flow automatically into both the native SwiftUI macOS app and the Tauri desktop app.

use std::collections::HashMap;
use std::fmt;
use std::sync::Arc;

use aeron_platform::AeronCore;
use aeron_protocols::dock_topology::{DockAttachedDevice, DockLayout, DockPort, DockPortKind};
use aeron_protocols::hidpp::MxWheelMode;
use aeron_protocols::logitech_g::TriggerSettings;
use aeron_protocols::logitech_keyboard::{BacklightEffect, RgbColor, RgbEffect, RgbLighting};
use aeron_protocols::models::{
    AccessoriesSnapshot, AccessoryButtonAction, AccessoryConnection, AppPreferences, AppSnapshot,
    BuiltinDisplayState, CaffeineState, ExternalDisplayInfo, FanReading, GameModePolicy,
    GameModeState, HotkeyBinding, InputSourceOption, KeychronM3MiniState, LogitechGKeyboardState,
    LogitechGMouseState, MonitorSettings, MxKeyboardState, MxMasterOptions, MxMasterState,
    MxThumbwheelAction, RazerDockState, SatechiHubState, ThermalPressure, ThermalSnapshot,
    WattageSnapshot,
};
use aeron_protocols::razer_chroma::{
    BreathingStyle, RazerLighting, RazerMode, RazerRgb, WaveDirection,
};

uniffi::setup_scaffolding!();

// MARK: - Error

#[derive(Debug, uniffi::Error)]
pub enum AeronEngineError {
    OperationFailed { message: String },
}

impl fmt::Display for AeronEngineError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::OperationFailed { message } => write!(f, "{message}"),
        }
    }
}

impl From<String> for AeronEngineError {
    fn from(message: String) -> Self {
        Self::OperationFailed { message }
    }
}

// MARK: - Enums

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CoreThermalPressure {
    Nominal,
    Fair,
    Serious,
    Critical,
}

impl From<ThermalPressure> for CoreThermalPressure {
    fn from(v: ThermalPressure) -> Self {
        match v {
            ThermalPressure::Nominal => Self::Nominal,
            ThermalPressure::Fair => Self::Fair,
            ThermalPressure::Serious => Self::Serious,
            ThermalPressure::Critical => Self::Critical,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CoreGameModePolicy {
    Automatic,
    ForcedOn,
    ForcedOff,
}

impl From<GameModePolicy> for CoreGameModePolicy {
    fn from(v: GameModePolicy) -> Self {
        match v {
            GameModePolicy::Automatic => Self::Automatic,
            GameModePolicy::ForcedOn => Self::ForcedOn,
            GameModePolicy::ForcedOff => Self::ForcedOff,
        }
    }
}

impl From<CoreGameModePolicy> for GameModePolicy {
    fn from(v: CoreGameModePolicy) -> Self {
        match v {
            CoreGameModePolicy::Automatic => Self::Automatic,
            CoreGameModePolicy::ForcedOn => Self::ForcedOn,
            CoreGameModePolicy::ForcedOff => Self::ForcedOff,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CoreAccessoryConnection {
    BluetoothLe,
    LogiBolt,
    Unifying,
    Lightspeed,
    UsbWired,
    Thunderbolt,
    Wireless4k,
}

impl From<AccessoryConnection> for CoreAccessoryConnection {
    fn from(v: AccessoryConnection) -> Self {
        match v {
            AccessoryConnection::BluetoothLe => Self::BluetoothLe,
            AccessoryConnection::LogiBolt => Self::LogiBolt,
            AccessoryConnection::Unifying => Self::Unifying,
            AccessoryConnection::Lightspeed => Self::Lightspeed,
            AccessoryConnection::UsbWired => Self::UsbWired,
            AccessoryConnection::Thunderbolt => Self::Thunderbolt,
            AccessoryConnection::Wireless4k => Self::Wireless4k,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CoreButtonAction {
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

impl From<AccessoryButtonAction> for CoreButtonAction {
    fn from(v: AccessoryButtonAction) -> Self {
        match v {
            AccessoryButtonAction::SystemDefault => Self::SystemDefault,
            AccessoryButtonAction::MissionControl => Self::MissionControl,
            AccessoryButtonAction::AppExpose => Self::AppExpose,
            AccessoryButtonAction::ShowDesktop => Self::ShowDesktop,
            AccessoryButtonAction::Launchpad => Self::Launchpad,
            AccessoryButtonAction::SpaceLeft => Self::SpaceLeft,
            AccessoryButtonAction::SpaceRight => Self::SpaceRight,
            AccessoryButtonAction::NavigateBack => Self::NavigateBack,
            AccessoryButtonAction::NavigateForward => Self::NavigateForward,
            AccessoryButtonAction::PlayPause => Self::PlayPause,
            AccessoryButtonAction::MutePointerDisplay => Self::MutePointerDisplay,
            AccessoryButtonAction::ToggleBuiltinScreen => Self::ToggleBuiltinScreen,
            AccessoryButtonAction::ToggleCaffeine => Self::ToggleCaffeine,
            AccessoryButtonAction::ToggleWheelMode => Self::ToggleWheelMode,
            AccessoryButtonAction::Copy => Self::Copy,
            AccessoryButtonAction::Paste => Self::Paste,
        }
    }
}

impl From<CoreButtonAction> for AccessoryButtonAction {
    fn from(v: CoreButtonAction) -> Self {
        match v {
            CoreButtonAction::SystemDefault => Self::SystemDefault,
            CoreButtonAction::MissionControl => Self::MissionControl,
            CoreButtonAction::AppExpose => Self::AppExpose,
            CoreButtonAction::ShowDesktop => Self::ShowDesktop,
            CoreButtonAction::Launchpad => Self::Launchpad,
            CoreButtonAction::SpaceLeft => Self::SpaceLeft,
            CoreButtonAction::SpaceRight => Self::SpaceRight,
            CoreButtonAction::NavigateBack => Self::NavigateBack,
            CoreButtonAction::NavigateForward => Self::NavigateForward,
            CoreButtonAction::PlayPause => Self::PlayPause,
            CoreButtonAction::MutePointerDisplay => Self::MutePointerDisplay,
            CoreButtonAction::ToggleBuiltinScreen => Self::ToggleBuiltinScreen,
            CoreButtonAction::ToggleCaffeine => Self::ToggleCaffeine,
            CoreButtonAction::ToggleWheelMode => Self::ToggleWheelMode,
            CoreButtonAction::Copy => Self::Copy,
            CoreButtonAction::Paste => Self::Paste,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CoreThumbwheelAction {
    HorizontalScroll,
    DisplayBrightness,
    DisplayVolume,
    SwitchWorkspaces,
    SwitchTabs,
    Zoom,
}

impl From<MxThumbwheelAction> for CoreThumbwheelAction {
    fn from(v: MxThumbwheelAction) -> Self {
        match v {
            MxThumbwheelAction::HorizontalScroll => Self::HorizontalScroll,
            MxThumbwheelAction::DisplayBrightness => Self::DisplayBrightness,
            MxThumbwheelAction::DisplayVolume => Self::DisplayVolume,
            MxThumbwheelAction::SwitchWorkspaces => Self::SwitchWorkspaces,
            MxThumbwheelAction::SwitchTabs => Self::SwitchTabs,
            MxThumbwheelAction::Zoom => Self::Zoom,
        }
    }
}

impl From<CoreThumbwheelAction> for MxThumbwheelAction {
    fn from(v: CoreThumbwheelAction) -> Self {
        match v {
            CoreThumbwheelAction::HorizontalScroll => Self::HorizontalScroll,
            CoreThumbwheelAction::DisplayBrightness => Self::DisplayBrightness,
            CoreThumbwheelAction::DisplayVolume => Self::DisplayVolume,
            CoreThumbwheelAction::SwitchWorkspaces => Self::SwitchWorkspaces,
            CoreThumbwheelAction::SwitchTabs => Self::SwitchTabs,
            CoreThumbwheelAction::Zoom => Self::Zoom,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CoreWheelMode {
    Ratchet,
    FreeSpin,
}

impl From<MxWheelMode> for CoreWheelMode {
    fn from(v: MxWheelMode) -> Self {
        match v {
            MxWheelMode::Ratchet => Self::Ratchet,
            MxWheelMode::FreeSpin => Self::FreeSpin,
        }
    }
}

impl From<CoreWheelMode> for MxWheelMode {
    fn from(v: CoreWheelMode) -> Self {
        match v {
            CoreWheelMode::Ratchet => Self::Ratchet,
            CoreWheelMode::FreeSpin => Self::FreeSpin,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CoreBacklightEffect {
    StaticLight,
    Breathing,
    Contrast,
    Reaction,
    Random,
    Waves,
}

impl From<BacklightEffect> for CoreBacklightEffect {
    fn from(v: BacklightEffect) -> Self {
        match v {
            BacklightEffect::StaticLight => Self::StaticLight,
            BacklightEffect::Breathing => Self::Breathing,
            BacklightEffect::Contrast => Self::Contrast,
            BacklightEffect::Reaction => Self::Reaction,
            BacklightEffect::Random => Self::Random,
            BacklightEffect::Waves => Self::Waves,
        }
    }
}

impl From<CoreBacklightEffect> for BacklightEffect {
    fn from(v: CoreBacklightEffect) -> Self {
        match v {
            CoreBacklightEffect::StaticLight => Self::StaticLight,
            CoreBacklightEffect::Breathing => Self::Breathing,
            CoreBacklightEffect::Contrast => Self::Contrast,
            CoreBacklightEffect::Reaction => Self::Reaction,
            CoreBacklightEffect::Random => Self::Random,
            CoreBacklightEffect::Waves => Self::Waves,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CoreRgbEffect {
    Off,
    Fixed,
    Breathing,
    ColorCycle,
    ColorWave,
}

impl From<RgbEffect> for CoreRgbEffect {
    fn from(v: RgbEffect) -> Self {
        match v {
            RgbEffect::Off => Self::Off,
            RgbEffect::Fixed => Self::Fixed,
            RgbEffect::Breathing => Self::Breathing,
            RgbEffect::ColorCycle => Self::ColorCycle,
            RgbEffect::ColorWave => Self::ColorWave,
        }
    }
}

impl From<CoreRgbEffect> for RgbEffect {
    fn from(v: CoreRgbEffect) -> Self {
        match v {
            CoreRgbEffect::Off => Self::Off,
            CoreRgbEffect::Fixed => Self::Fixed,
            CoreRgbEffect::Breathing => Self::Breathing,
            CoreRgbEffect::ColorCycle => Self::ColorCycle,
            CoreRgbEffect::ColorWave => Self::ColorWave,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CoreRazerMode {
    Off,
    StaticColor,
    Breathing,
    Spectrum,
    Wave,
}

impl From<RazerMode> for CoreRazerMode {
    fn from(v: RazerMode) -> Self {
        match v {
            RazerMode::Off => Self::Off,
            RazerMode::StaticColor => Self::StaticColor,
            RazerMode::Breathing => Self::Breathing,
            RazerMode::Spectrum => Self::Spectrum,
            RazerMode::Wave => Self::Wave,
        }
    }
}

impl From<CoreRazerMode> for RazerMode {
    fn from(v: CoreRazerMode) -> Self {
        match v {
            CoreRazerMode::Off => Self::Off,
            CoreRazerMode::StaticColor => Self::StaticColor,
            CoreRazerMode::Breathing => Self::Breathing,
            CoreRazerMode::Spectrum => Self::Spectrum,
            CoreRazerMode::Wave => Self::Wave,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CoreBreathingStyle {
    Single,
    Dual,
    Random,
}

impl From<BreathingStyle> for CoreBreathingStyle {
    fn from(v: BreathingStyle) -> Self {
        match v {
            BreathingStyle::Single => Self::Single,
            BreathingStyle::Dual => Self::Dual,
            BreathingStyle::Random => Self::Random,
        }
    }
}

impl From<CoreBreathingStyle> for BreathingStyle {
    fn from(v: CoreBreathingStyle) -> Self {
        match v {
            CoreBreathingStyle::Single => Self::Single,
            CoreBreathingStyle::Dual => Self::Dual,
            CoreBreathingStyle::Random => Self::Random,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CoreWaveDirection {
    LeftToRight,
    RightToLeft,
}

impl From<WaveDirection> for CoreWaveDirection {
    fn from(v: WaveDirection) -> Self {
        match v {
            WaveDirection::LeftToRight => Self::LeftToRight,
            WaveDirection::RightToLeft => Self::RightToLeft,
        }
    }
}

impl From<CoreWaveDirection> for WaveDirection {
    fn from(v: CoreWaveDirection) -> Self {
        match v {
            CoreWaveDirection::LeftToRight => Self::LeftToRight,
            CoreWaveDirection::RightToLeft => Self::RightToLeft,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CoreDockPortKind {
    Thunderbolt,
    UsbA,
}

impl From<DockPortKind> for CoreDockPortKind {
    fn from(v: DockPortKind) -> Self {
        match v {
            DockPortKind::Thunderbolt => Self::Thunderbolt,
            DockPortKind::UsbA => Self::UsbA,
        }
    }
}

// MARK: - Records

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreRgbColor {
    pub red: u8,
    pub green: u8,
    pub blue: u8,
}

impl From<RgbColor> for CoreRgbColor {
    fn from(v: RgbColor) -> Self {
        Self {
            red: v.red,
            green: v.green,
            blue: v.blue,
        }
    }
}

impl From<CoreRgbColor> for RgbColor {
    fn from(v: CoreRgbColor) -> Self {
        Self {
            red: v.red,
            green: v.green,
            blue: v.blue,
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreRgbLighting {
    pub effect: CoreRgbEffect,
    pub color: CoreRgbColor,
    pub speed: u8,
}

impl From<RgbLighting> for CoreRgbLighting {
    fn from(v: RgbLighting) -> Self {
        Self {
            effect: v.effect.into(),
            color: v.color.into(),
            speed: v.speed,
        }
    }
}

impl From<CoreRgbLighting> for RgbLighting {
    fn from(v: CoreRgbLighting) -> Self {
        Self {
            effect: v.effect.into(),
            color: v.color.into(),
            speed: v.speed,
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreRazerRgb {
    pub red: u8,
    pub green: u8,
    pub blue: u8,
}

impl From<RazerRgb> for CoreRazerRgb {
    fn from(v: RazerRgb) -> Self {
        Self {
            red: v.red,
            green: v.green,
            blue: v.blue,
        }
    }
}

impl From<CoreRazerRgb> for RazerRgb {
    fn from(v: CoreRazerRgb) -> Self {
        Self {
            red: v.red,
            green: v.green,
            blue: v.blue,
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreRazerLighting {
    pub mode: Option<CoreRazerMode>,
    pub primary: CoreRazerRgb,
    pub secondary: CoreRazerRgb,
    pub breathing: CoreBreathingStyle,
    pub wave_direction: CoreWaveDirection,
}

impl From<RazerLighting> for CoreRazerLighting {
    fn from(v: RazerLighting) -> Self {
        Self {
            mode: v.mode.map(Into::into),
            primary: v.primary.into(),
            secondary: v.secondary.into(),
            breathing: v.breathing.into(),
            wave_direction: v.wave_direction.into(),
        }
    }
}

impl From<CoreRazerLighting> for RazerLighting {
    fn from(v: CoreRazerLighting) -> Self {
        Self {
            mode: v.mode.map(Into::into),
            primary: v.primary.into(),
            secondary: v.secondary.into(),
            breathing: v.breathing.into(),
            wave_direction: v.wave_direction.into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreTriggerSettings {
    pub actuation: u8,
    pub rapid_trigger: u8,
    pub haptics: u8,
}

impl From<TriggerSettings> for CoreTriggerSettings {
    fn from(v: TriggerSettings) -> Self {
        Self {
            actuation: v.actuation,
            rapid_trigger: v.rapid_trigger,
            haptics: v.haptics,
        }
    }
}

impl From<CoreTriggerSettings> for TriggerSettings {
    fn from(v: CoreTriggerSettings) -> Self {
        Self {
            actuation: v.actuation,
            rapid_trigger: v.rapid_trigger,
            haptics: v.haptics,
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreMonitorSettings {
    pub brightness: Option<f32>,
    pub volume: Option<f32>,
    pub is_muted: bool,
    pub extra_dimming: f32,
    pub input_sources: Option<Vec<u8>>,
}

impl From<MonitorSettings> for CoreMonitorSettings {
    fn from(v: MonitorSettings) -> Self {
        Self {
            brightness: v.brightness,
            volume: v.volume,
            is_muted: v.is_muted,
            extra_dimming: v.extra_dimming,
            input_sources: v.input_sources,
        }
    }
}

impl From<CoreMonitorSettings> for MonitorSettings {
    fn from(v: CoreMonitorSettings) -> Self {
        Self {
            brightness: v.brightness,
            volume: v.volume,
            is_muted: v.is_muted,
            extra_dimming: v.extra_dimming,
            input_sources: v.input_sources,
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreInputSourceOption {
    pub code: u8,
    pub name: String,
}

impl From<InputSourceOption> for CoreInputSourceOption {
    fn from(v: InputSourceOption) -> Self {
        Self {
            code: v.code,
            name: v.name,
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreExternalDisplayInfo {
    pub id: String,
    pub settings_key: String,
    pub name: String,
    pub brightness: f32,
    pub volume: f32,
    pub is_muted: bool,
    pub extra_dimming: f32,
    pub input_sources: Vec<CoreInputSourceOption>,
    pub current_input: Option<u8>,
    pub has_hardware_control: bool,
    pub is_builtin: bool,
    pub is_enabled: bool,
}

impl From<ExternalDisplayInfo> for CoreExternalDisplayInfo {
    fn from(v: ExternalDisplayInfo) -> Self {
        Self {
            id: v.id,
            settings_key: v.settings_key,
            name: v.name,
            brightness: v.brightness,
            volume: v.volume,
            is_muted: v.is_muted,
            extra_dimming: v.extra_dimming,
            input_sources: v.input_sources.into_iter().map(Into::into).collect(),
            current_input: v.current_input,
            has_hardware_control: v.has_hardware_control,
            is_builtin: v.is_builtin,
            is_enabled: v.is_enabled,
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreBuiltinDisplayState {
    pub present: bool,
    pub is_turned_off: bool,
    pub can_turn_off: bool,
}

impl From<BuiltinDisplayState> for CoreBuiltinDisplayState {
    fn from(v: BuiltinDisplayState) -> Self {
        Self {
            present: v.present,
            is_turned_off: v.is_turned_off,
            can_turn_off: v.can_turn_off,
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreFanReading {
    pub index: u32,
    pub name: String,
    pub rpm: u32,
    pub max_rpm: Option<u32>,
}

impl From<FanReading> for CoreFanReading {
    fn from(v: FanReading) -> Self {
        Self {
            index: v.index as u32,
            name: v.name,
            rpm: v.rpm,
            max_rpm: v.max_rpm,
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreThermalSnapshot {
    pub supported: bool,
    pub pressure: CoreThermalPressure,
    pub cpu_celsius: Option<f64>,
    pub gpu_celsius: Option<f64>,
    pub battery_celsius: Option<f64>,
    pub fans: Vec<CoreFanReading>,
}

impl From<ThermalSnapshot> for CoreThermalSnapshot {
    fn from(v: ThermalSnapshot) -> Self {
        Self {
            supported: v.supported,
            pressure: v.pressure.into(),
            cpu_celsius: v.cpu_celsius,
            gpu_celsius: v.gpu_celsius,
            battery_celsius: v.battery_celsius,
            fans: v.fans.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreWattageSnapshot {
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

impl From<WattageSnapshot> for CoreWattageSnapshot {
    fn from(v: WattageSnapshot) -> Self {
        Self {
            supported: v.supported,
            is_plugged_in: v.is_plugged_in,
            is_charging: v.is_charging,
            battery_level: v.battery_level,
            system_load_watts: v.system_load_watts,
            input_watts: v.input_watts,
            adapter_watts: v.adapter_watts,
            battery_watts: v.battery_watts,
            voltage: v.voltage,
            amperage: v.amperage,
            battery_health_percent: v.battery_health_percent,
            cycle_count: v.cycle_count,
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreGameModeState {
    pub supported: bool,
    pub is_active: bool,
    pub policy: CoreGameModePolicy,
    pub backend_name: String,
}

impl From<GameModeState> for CoreGameModeState {
    fn from(v: GameModeState) -> Self {
        Self {
            supported: v.supported,
            is_active: v.is_active,
            policy: v.policy.into(),
            backend_name: v.backend_name,
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreCaffeineState {
    pub is_active: bool,
    pub ends_at_ms: Option<u64>,
    pub is_automatic: bool,
}

impl From<CaffeineState> for CoreCaffeineState {
    fn from(v: CaffeineState) -> Self {
        Self {
            is_active: v.is_active,
            ends_at_ms: v.ends_at_ms,
            is_automatic: v.is_automatic,
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreDockAttachedDevice {
    pub id: String,
    pub name: String,
    pub detail: String,
    pub icon: String,
}

impl From<DockAttachedDevice> for CoreDockAttachedDevice {
    fn from(v: DockAttachedDevice) -> Self {
        Self {
            id: v.id,
            name: v.name,
            detail: v.detail,
            icon: v.icon,
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreDockPort {
    pub id: String,
    pub kind: CoreDockPortKind,
    pub number: u8,
    pub title: String,
    pub devices: Vec<CoreDockAttachedDevice>,
}

impl From<DockPort> for CoreDockPort {
    fn from(v: DockPort) -> Self {
        Self {
            id: v.id,
            kind: v.kind.into(),
            number: v.number,
            title: v.title,
            devices: v.devices.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreDockLayout {
    pub is_present: bool,
    pub thunderbolt: Vec<CoreDockPort>,
    pub usb_a: Vec<CoreDockPort>,
    pub ethernet_interface: Option<String>,
    pub serial_number: Option<String>,
}

impl From<DockLayout> for CoreDockLayout {
    fn from(v: DockLayout) -> Self {
        Self {
            is_present: v.is_present,
            thunderbolt: v.thunderbolt.into_iter().map(Into::into).collect(),
            usb_a: v.usb_a.into_iter().map(Into::into).collect(),
            ethernet_interface: v.ethernet_interface,
            serial_number: v.serial_number,
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreMxMasterOptions {
    pub standard_vertical_scroll: bool,
    pub smooth_scrolling: bool,
    pub scroll_speed_multiplier: f64,
    pub thumbwheel_action: CoreThumbwheelAction,
    pub invert_thumbwheel: bool,
    pub middle_button_action: CoreButtonAction,
    pub back_button_action: CoreButtonAction,
    pub forward_button_action: CoreButtonAction,
    pub gesture_button_action: CoreButtonAction,
    pub mode_shift_button_action: CoreButtonAction,
    pub haptic_panel_button_action: CoreButtonAction,
    pub gestures_enabled: bool,
    pub gesture_up_action: CoreButtonAction,
    pub gesture_down_action: CoreButtonAction,
    pub gesture_left_action: CoreButtonAction,
    pub gesture_right_action: CoreButtonAction,
    pub saves_to_mouse: bool,
}

impl From<CoreMxMasterOptions> for MxMasterOptions {
    fn from(v: CoreMxMasterOptions) -> Self {
        Self {
            standard_vertical_scroll: v.standard_vertical_scroll,
            smooth_scrolling: v.smooth_scrolling,
            scroll_speed_multiplier: v.scroll_speed_multiplier,
            thumbwheel_action: v.thumbwheel_action.into(),
            invert_thumbwheel: v.invert_thumbwheel,
            middle_button_action: v.middle_button_action.into(),
            back_button_action: v.back_button_action.into(),
            forward_button_action: v.forward_button_action.into(),
            gesture_button_action: v.gesture_button_action.into(),
            mode_shift_button_action: v.mode_shift_button_action.into(),
            haptic_panel_button_action: v.haptic_panel_button_action.into(),
            gestures_enabled: v.gestures_enabled,
            gesture_up_action: v.gesture_up_action.into(),
            gesture_down_action: v.gesture_down_action.into(),
            gesture_left_action: v.gesture_left_action.into(),
            gesture_right_action: v.gesture_right_action.into(),
            saves_to_mouse: v.saves_to_mouse,
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreMxMasterState {
    pub connected: bool,
    pub name: String,
    pub connection: Option<CoreAccessoryConnection>,
    pub battery_percent: Option<u8>,
    pub is_charging: bool,
    pub dpi: u16,
    pub min_dpi: u16,
    pub max_dpi: u16,
    pub dpi_step: u16,
    pub wheel_mode: CoreWheelMode,
    pub smart_shift_enabled: bool,
    pub smart_shift_threshold: u8,
    pub standard_vertical_scroll: bool,
    pub smooth_scrolling: bool,
    pub scroll_speed_multiplier: f64,
    pub thumbwheel_action: CoreThumbwheelAction,
    pub invert_thumbwheel: bool,
    pub middle_button_action: CoreButtonAction,
    pub back_button_action: CoreButtonAction,
    pub forward_button_action: CoreButtonAction,
    pub gesture_button_action: CoreButtonAction,
    pub mode_shift_button_action: CoreButtonAction,
    pub haptic_panel_button_action: CoreButtonAction,
    pub gestures_enabled: bool,
    pub gesture_up_action: CoreButtonAction,
    pub gesture_down_action: CoreButtonAction,
    pub gesture_left_action: CoreButtonAction,
    pub gesture_right_action: CoreButtonAction,
    pub saves_to_mouse: bool,
}

impl From<MxMasterState> for CoreMxMasterState {
    fn from(v: MxMasterState) -> Self {
        Self {
            connected: v.connected,
            name: v.name,
            connection: v.connection.map(Into::into),
            battery_percent: v.battery_percent,
            is_charging: v.is_charging,
            dpi: v.dpi,
            min_dpi: v.min_dpi,
            max_dpi: v.max_dpi,
            dpi_step: v.dpi_step,
            wheel_mode: v.wheel_mode.into(),
            smart_shift_enabled: v.smart_shift_enabled,
            smart_shift_threshold: v.smart_shift_threshold,
            standard_vertical_scroll: v.standard_vertical_scroll,
            smooth_scrolling: v.smooth_scrolling,
            scroll_speed_multiplier: v.scroll_speed_multiplier,
            thumbwheel_action: v.thumbwheel_action.into(),
            invert_thumbwheel: v.invert_thumbwheel,
            middle_button_action: v.middle_button_action.into(),
            back_button_action: v.back_button_action.into(),
            forward_button_action: v.forward_button_action.into(),
            gesture_button_action: v.gesture_button_action.into(),
            mode_shift_button_action: v.mode_shift_button_action.into(),
            haptic_panel_button_action: v.haptic_panel_button_action.into(),
            gestures_enabled: v.gestures_enabled,
            gesture_up_action: v.gesture_up_action.into(),
            gesture_down_action: v.gesture_down_action.into(),
            gesture_left_action: v.gesture_left_action.into(),
            gesture_right_action: v.gesture_right_action.into(),
            saves_to_mouse: v.saves_to_mouse,
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreMxKeyboardState {
    pub connected: bool,
    pub name: String,
    pub connection: Option<CoreAccessoryConnection>,
    pub battery_percent: Option<u8>,
    pub is_charging: bool,
    pub backlight_enabled: bool,
    pub automatic_brightness: bool,
    pub battery_saving: bool,
    pub backlight_level: u8,
    pub backlight_effect: CoreBacklightEffect,
    pub supported_effects: Vec<CoreBacklightEffect>,
    pub duration_seconds: u16,
    pub fn_inversion: Option<bool>,
    pub current_host: Option<u8>,
    pub key_actions: HashMap<u8, CoreButtonAction>,
}

impl From<MxKeyboardState> for CoreMxKeyboardState {
    fn from(v: MxKeyboardState) -> Self {
        Self {
            connected: v.connected,
            name: v.name,
            connection: v.connection.map(Into::into),
            battery_percent: v.battery_percent,
            is_charging: v.is_charging,
            backlight_enabled: v.backlight_enabled,
            automatic_brightness: v.automatic_brightness,
            battery_saving: v.battery_saving,
            backlight_level: v.backlight_level,
            backlight_effect: v.backlight_effect.into(),
            supported_effects: v.supported_effects.into_iter().map(Into::into).collect(),
            duration_seconds: v.duration_seconds,
            fn_inversion: v.fn_inversion,
            current_host: v.current_host,
            key_actions: v.key_actions.into_iter().map(|(k, a)| (k, a.into())).collect(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreLogitechGMouseState {
    pub connected: bool,
    pub name: String,
    pub connection: Option<CoreAccessoryConnection>,
    pub battery_percent: Option<u8>,
    pub is_charging: bool,
    pub dpi: u16,
    pub min_dpi: u16,
    pub max_dpi: u16,
    pub report_rate_hz: u16,
    pub supported_report_rates: Vec<u16>,
    pub lift_off_distance: u8,
    pub triggers: Option<CoreTriggerSettings>,
    pub back_button_action: CoreButtonAction,
    pub forward_button_action: CoreButtonAction,
    pub saves_to_onboard_profile: bool,
}

impl From<LogitechGMouseState> for CoreLogitechGMouseState {
    fn from(v: LogitechGMouseState) -> Self {
        Self {
            connected: v.connected,
            name: v.name,
            connection: v.connection.map(Into::into),
            battery_percent: v.battery_percent,
            is_charging: v.is_charging,
            dpi: v.dpi,
            min_dpi: v.min_dpi,
            max_dpi: v.max_dpi,
            report_rate_hz: v.report_rate_hz,
            supported_report_rates: v.supported_report_rates,
            lift_off_distance: v.lift_off_distance,
            triggers: v.triggers.map(Into::into),
            back_button_action: v.back_button_action.into(),
            forward_button_action: v.forward_button_action.into(),
            saves_to_onboard_profile: v.saves_to_onboard_profile,
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreLogitechGKeyboardState {
    pub connected: bool,
    pub name: String,
    pub connection: Option<CoreAccessoryConnection>,
    pub battery_percent: Option<u8>,
    pub is_charging: bool,
    pub brightness: u16,
    pub max_brightness: u16,
    pub lighting: CoreRgbLighting,
    pub supported_effects: Vec<CoreRgbEffect>,
    pub game_mode_on: bool,
}

impl From<LogitechGKeyboardState> for CoreLogitechGKeyboardState {
    fn from(v: LogitechGKeyboardState) -> Self {
        Self {
            connected: v.connected,
            name: v.name,
            connection: v.connection.map(Into::into),
            battery_percent: v.battery_percent,
            is_charging: v.is_charging,
            brightness: v.brightness,
            max_brightness: v.max_brightness,
            lighting: v.lighting.into(),
            supported_effects: v.supported_effects.into_iter().map(Into::into).collect(),
            game_mode_on: v.game_mode_on,
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreKeychronM3MiniState {
    pub connected: bool,
    pub name: String,
    pub connection: Option<CoreAccessoryConnection>,
    pub battery_percent: Option<u8>,
    pub is_charging: bool,
    pub active_stage: u8,
    pub stage_dpis: Vec<u16>,
    pub report_rate_hz: u16,
    pub max_report_rate_hz: u16,
    pub lift_off_mm: u8,
    pub motion_sync: bool,
    pub angle_snapping: bool,
    pub back_button_action: CoreButtonAction,
    pub forward_button_action: CoreButtonAction,
}

impl From<KeychronM3MiniState> for CoreKeychronM3MiniState {
    fn from(v: KeychronM3MiniState) -> Self {
        Self {
            connected: v.connected,
            name: v.name,
            connection: v.connection.map(Into::into),
            battery_percent: v.battery_percent,
            is_charging: v.is_charging,
            active_stage: v.active_stage,
            stage_dpis: v.stage_dpis,
            report_rate_hz: v.report_rate_hz,
            max_report_rate_hz: v.max_report_rate_hz,
            lift_off_mm: v.lift_off_mm,
            motion_sync: v.motion_sync,
            angle_snapping: v.angle_snapping,
            back_button_action: v.back_button_action.into(),
            forward_button_action: v.forward_button_action.into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreRazerDockState {
    pub connected: bool,
    pub name: String,
    pub firmware: Option<String>,
    pub serial_number: Option<String>,
    pub brightness: Option<u8>,
    pub lighting: Option<CoreRazerLighting>,
    pub ports: CoreDockLayout,
}

impl From<RazerDockState> for CoreRazerDockState {
    fn from(v: RazerDockState) -> Self {
        Self {
            connected: v.connected,
            name: v.name,
            firmware: v.firmware,
            serial_number: v.serial_number,
            brightness: v.brightness,
            lighting: v.lighting.map(Into::into),
            ports: v.ports.into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreSatechiHubState {
    pub connected: bool,
    pub name: String,
    pub ports: CoreDockLayout,
}

impl From<SatechiHubState> for CoreSatechiHubState {
    fn from(v: SatechiHubState) -> Self {
        Self {
            connected: v.connected,
            name: v.name,
            ports: v.ports.into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreAccessoriesSnapshot {
    pub mx_master: CoreMxMasterState,
    pub mx_keyboard: CoreMxKeyboardState,
    pub logitech_g_mouse: CoreLogitechGMouseState,
    pub logitech_g_keyboard: CoreLogitechGKeyboardState,
    pub keychron_m3_mini: CoreKeychronM3MiniState,
    pub razer_dock: CoreRazerDockState,
    pub satechi_hub: CoreSatechiHubState,
}

impl From<AccessoriesSnapshot> for CoreAccessoriesSnapshot {
    fn from(v: AccessoriesSnapshot) -> Self {
        Self {
            mx_master: v.mx_master.into(),
            mx_keyboard: v.mx_keyboard.into(),
            logitech_g_mouse: v.logitech_g_mouse.into(),
            logitech_g_keyboard: v.logitech_g_keyboard.into(),
            keychron_m3_mini: v.keychron_m3_mini.into(),
            razer_dock: v.razer_dock.into(),
            satechi_hub: v.satechi_hub.into(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreHotkeyBinding {
    pub action: String,
    pub label: String,
    pub accelerator: Option<String>,
}

impl From<HotkeyBinding> for CoreHotkeyBinding {
    fn from(v: HotkeyBinding) -> Self {
        Self {
            action: v.action,
            label: v.label,
            accelerator: v.accelerator,
        }
    }
}

impl From<CoreHotkeyBinding> for HotkeyBinding {
    fn from(v: CoreHotkeyBinding) -> Self {
        Self {
            action: v.action,
            label: v.label,
            accelerator: v.accelerator,
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreAppPreferences {
    pub show_accessories_card: bool,
    pub show_wattage_meter: bool,
    pub show_battery_health: bool,
    pub show_thermals: bool,
    pub auto_turn_off_builtin: bool,
    pub show_input_switching: bool,
    pub extra_dimming_enabled: bool,
    pub restore_monitor_settings: bool,
    pub media_keys_control_pointer_display: bool,
    pub launch_at_login: bool,
    pub low_battery_alert_enabled: bool,
    pub low_battery_threshold: u8,
    pub caffeine_with_external_display: bool,
    pub caffeine_on_power_adapter: bool,
    pub daemon_port: u16,
    pub hotkeys: Vec<CoreHotkeyBinding>,
    pub monitor_settings: HashMap<String, CoreMonitorSettings>,
}

impl From<AppPreferences> for CoreAppPreferences {
    fn from(v: AppPreferences) -> Self {
        Self {
            show_accessories_card: v.show_accessories_card,
            show_wattage_meter: v.show_wattage_meter,
            show_battery_health: v.show_battery_health,
            show_thermals: v.show_thermals,
            auto_turn_off_builtin: v.auto_turn_off_builtin,
            show_input_switching: v.show_input_switching,
            extra_dimming_enabled: v.extra_dimming_enabled,
            restore_monitor_settings: v.restore_monitor_settings,
            media_keys_control_pointer_display: v.media_keys_control_pointer_display,
            launch_at_login: v.launch_at_login,
            low_battery_alert_enabled: v.low_battery_alert_enabled,
            low_battery_threshold: v.low_battery_threshold,
            caffeine_with_external_display: v.caffeine_with_external_display,
            caffeine_on_power_adapter: v.caffeine_on_power_adapter,
            daemon_port: v.daemon_port,
            hotkeys: v.hotkeys.into_iter().map(Into::into).collect(),
            monitor_settings: v
                .monitor_settings
                .into_iter()
                .map(|(k, s)| (k, s.into()))
                .collect(),
        }
    }
}

impl From<CoreAppPreferences> for AppPreferences {
    fn from(v: CoreAppPreferences) -> Self {
        Self {
            show_accessories_card: v.show_accessories_card,
            show_wattage_meter: v.show_wattage_meter,
            show_battery_health: v.show_battery_health,
            show_thermals: v.show_thermals,
            auto_turn_off_builtin: v.auto_turn_off_builtin,
            show_input_switching: v.show_input_switching,
            extra_dimming_enabled: v.extra_dimming_enabled,
            restore_monitor_settings: v.restore_monitor_settings,
            media_keys_control_pointer_display: v.media_keys_control_pointer_display,
            launch_at_login: v.launch_at_login,
            low_battery_alert_enabled: v.low_battery_alert_enabled,
            low_battery_threshold: v.low_battery_threshold,
            caffeine_with_external_display: v.caffeine_with_external_display,
            caffeine_on_power_adapter: v.caffeine_on_power_adapter,
            daemon_port: v.daemon_port,
            hotkeys: v.hotkeys.into_iter().map(Into::into).collect(),
            monitor_settings: v
                .monitor_settings
                .into_iter()
                .map(|(k, s)| (k, s.into()))
                .collect(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreAppSnapshot {
    pub platform: String,
    pub is_steamos: bool,
    pub displays: Vec<CoreExternalDisplayInfo>,
    pub builtin_display: CoreBuiltinDisplayState,
    pub accessories: CoreAccessoriesSnapshot,
    pub wattage: CoreWattageSnapshot,
    pub thermals: CoreThermalSnapshot,
    pub caffeine: CoreCaffeineState,
    pub game_mode: CoreGameModeState,
    pub preferences: CoreAppPreferences,
}

impl From<AppSnapshot> for CoreAppSnapshot {
    fn from(v: AppSnapshot) -> Self {
        Self {
            platform: v.platform,
            is_steamos: v.is_steamos,
            displays: v.displays.into_iter().map(Into::into).collect(),
            builtin_display: v.builtin_display.into(),
            accessories: v.accessories.into(),
            wattage: v.wattage.into(),
            thermals: v.thermals.into(),
            caffeine: v.caffeine.into(),
            game_mode: v.game_mode.into(),
            preferences: v.preferences.into(),
        }
    }
}

// MARK: - Free helpers (no hardware side-effects; ideal for version checks & tests)

#[uniffi::export]
pub fn aeron_engine_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

#[uniffi::export]
pub fn aeron_default_preferences() -> CoreAppPreferences {
    AppPreferences::default().into()
}

// MARK: - Shared Full Engine Object

/// Thread-safe UniFFI wrapper around `aeron_platform::AeronCore`.
#[derive(uniffi::Object)]
pub struct AeronEngine {
    core: AeronCore,
}

#[uniffi::export]
impl AeronEngine {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            core: AeronCore::new(),
        })
    }

    pub fn snapshot(&self) -> CoreAppSnapshot {
        self.core.snapshot().into()
    }

    pub fn snapshot_json(&self) -> Result<String, AeronEngineError> {
        serde_json::to_string(&self.core.snapshot())
            .map_err(|err| AeronEngineError::OperationFailed {
                message: err.to_string(),
            })
    }

    pub fn refresh_all(&self) -> CoreAppSnapshot {
        self.core.refresh_all().into()
    }

    pub fn refresh_accessories_and_docks(&self) {
        self.core.refresh_accessories_and_docks();
    }

    pub fn set_display_brightness(
        &self,
        display_id: String,
        level: f32,
    ) -> Result<CoreAppSnapshot, AeronEngineError> {
        self.core
            .set_display_brightness(&display_id, level)
            .map(Into::into)
            .map_err(Into::into)
    }

    pub fn step_all_brightness(&self, delta: f32) -> Result<CoreAppSnapshot, AeronEngineError> {
        self.core
            .step_all_brightness(delta)
            .map(Into::into)
            .map_err(Into::into)
    }

    pub fn set_display_volume(
        &self,
        display_id: String,
        level: f32,
    ) -> Result<CoreAppSnapshot, AeronEngineError> {
        self.core
            .set_display_volume(&display_id, level)
            .map(Into::into)
            .map_err(Into::into)
    }

    pub fn set_display_muted(
        &self,
        display_id: String,
        muted: bool,
    ) -> Result<CoreAppSnapshot, AeronEngineError> {
        self.core
            .set_display_muted(&display_id, muted)
            .map(Into::into)
            .map_err(Into::into)
    }

    pub fn set_display_input(
        &self,
        display_id: String,
        input_code: u8,
    ) -> Result<CoreAppSnapshot, AeronEngineError> {
        self.core
            .set_display_input(&display_id, input_code)
            .map(Into::into)
            .map_err(Into::into)
    }

    pub fn set_builtin_display_enabled(
        &self,
        enabled: bool,
    ) -> Result<CoreAppSnapshot, AeronEngineError> {
        self.core
            .set_builtin_display_enabled(enabled)
            .map(Into::into)
            .map_err(Into::into)
    }

    pub fn toggle_builtin_display(&self) -> Result<CoreAppSnapshot, AeronEngineError> {
        self.core
            .toggle_builtin_display()
            .map(Into::into)
            .map_err(Into::into)
    }

    pub fn set_caffeine(
        &self,
        active: bool,
        duration_seconds: Option<u64>,
    ) -> Result<CoreAppSnapshot, AeronEngineError> {
        self.core
            .set_caffeine(active, duration_seconds)
            .map(Into::into)
            .map_err(Into::into)
    }

    pub fn toggle_caffeine(&self) -> Result<CoreAppSnapshot, AeronEngineError> {
        self.core
            .toggle_caffeine()
            .map(Into::into)
            .map_err(Into::into)
    }

    pub fn set_game_mode_policy(
        &self,
        policy: CoreGameModePolicy,
    ) -> Result<CoreAppSnapshot, AeronEngineError> {
        self.core
            .set_game_mode_policy(policy.into())
            .map(Into::into)
            .map_err(Into::into)
    }

    pub fn toggle_game_mode_forced(&self) -> Result<CoreAppSnapshot, AeronEngineError> {
        self.core
            .toggle_game_mode_forced()
            .map(Into::into)
            .map_err(Into::into)
    }

    pub fn update_preferences(&self, prefs: CoreAppPreferences) -> CoreAppSnapshot {
        self.core.update_preferences(prefs.into()).into()
    }

    pub fn prepare_for_termination(&self) {
        self.core.prepare_for_termination();
    }

    // MARK: - Accessories

    pub fn set_mx_master_dpi(&self, dpi: u16) -> CoreAppSnapshot {
        self.core.set_mx_master_dpi(dpi).into()
    }

    pub fn set_mx_master_smart_shift(
        &self,
        wheel_mode: CoreWheelMode,
        smart_shift_enabled: bool,
        threshold: u8,
    ) -> CoreAppSnapshot {
        self.core
            .set_mx_master_smart_shift(wheel_mode.into(), smart_shift_enabled, threshold)
            .into()
    }

    pub fn set_mx_master_options(&self, opts: CoreMxMasterOptions) -> CoreAppSnapshot {
        self.core.set_mx_master_options(opts.into()).into()
    }

    pub fn set_logitech_g_dpi(&self, dpi: u16) -> CoreAppSnapshot {
        self.core.set_logitech_g_dpi(dpi).into()
    }

    pub fn set_logitech_g_report_rate(&self, hz: u16) -> CoreAppSnapshot {
        self.core.set_logitech_g_report_rate(hz).into()
    }

    pub fn set_logitech_g_triggers(&self, triggers: CoreTriggerSettings) -> CoreAppSnapshot {
        self.core.set_logitech_g_triggers(triggers.into()).into()
    }

    pub fn set_logitech_g_options(
        &self,
        back_button: CoreButtonAction,
        forward_button: CoreButtonAction,
        saves_to_onboard_profile: bool,
    ) -> CoreAppSnapshot {
        self.core
            .set_logitech_g_options(
                back_button.into(),
                forward_button.into(),
                saves_to_onboard_profile,
            )
            .into()
    }

    pub fn set_mx_keyboard_backlight(
        &self,
        enabled: bool,
        auto_brightness: bool,
        battery_saving: bool,
        level: u8,
        duration_seconds: u16,
        effect: CoreBacklightEffect,
    ) -> CoreAppSnapshot {
        self.core
            .set_mx_keyboard_backlight(
                enabled,
                auto_brightness,
                battery_saving,
                level,
                duration_seconds,
                effect.into(),
            )
            .into()
    }

    pub fn set_mx_keyboard_fn_inversion(&self, standard_fn: bool) -> CoreAppSnapshot {
        self.core
            .set_mx_keyboard_fn_inversion(standard_fn)
            .into()
    }

    pub fn set_mx_keyboard_key_action(
        &self,
        position: u8,
        action: CoreButtonAction,
    ) -> CoreAppSnapshot {
        self.core
            .set_mx_keyboard_key_action(position, action.into())
            .into()
    }

    pub fn set_g_keyboard_lighting(
        &self,
        brightness: u16,
        lighting: CoreRgbLighting,
    ) -> CoreAppSnapshot {
        self.core
            .set_g_keyboard_lighting(brightness, lighting.into())
            .into()
    }

    pub fn set_keychron_settings(
        &self,
        active_stage: u8,
        dpi: u16,
        report_rate_hz: u16,
        lift_off_mm: u8,
        motion_sync: bool,
        angle_snapping: bool,
    ) -> CoreAppSnapshot {
        self.core
            .set_keychron_settings(
                active_stage,
                dpi,
                report_rate_hz,
                lift_off_mm,
                motion_sync,
                angle_snapping,
            )
            .into()
    }

    pub fn set_keychron_side_buttons(
        &self,
        back_button: CoreButtonAction,
        forward_button: CoreButtonAction,
    ) -> CoreAppSnapshot {
        self.core
            .set_keychron_side_buttons(back_button.into(), forward_button.into())
            .into()
    }

    pub fn set_razer_dock_lighting(
        &self,
        brightness: Option<u8>,
        lighting: Option<CoreRazerLighting>,
    ) -> CoreAppSnapshot {
        self.core
            .set_razer_dock_lighting(brightness, lighting.map(Into::into))
            .into()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preferences_round_trip_preserves_fields() {
        let original = AppPreferences::default();
        let ffi: CoreAppPreferences = original.clone().into();
        let back: AppPreferences = ffi.into();
        assert_eq!(original, back);
    }

    #[test]
    fn engine_version_matches_workspace() {
        assert!(!aeron_engine_version().is_empty());
    }

    #[test]
    fn lighting_and_trigger_round_trips() {
        let lighting = RazerLighting::default();
        let back: RazerLighting = CoreRazerLighting::from(lighting.clone()).into();
        assert_eq!(lighting, back);

        let trigger = TriggerSettings {
            actuation: 4,
            rapid_trigger: 2,
            haptics: 5,
        };
        let back_trigger: TriggerSettings = CoreTriggerSettings::from(trigger).into();
        assert_eq!(trigger, back_trigger);
    }
}
