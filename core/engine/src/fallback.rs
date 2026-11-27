//! Fallback / UI preview backend used when running the Tauri cross-platform workspace on macOS
//! (where native AeronTools SwiftUI is used for production).

use aeron_protocols::ddc;
use aeron_protocols::dock_topology::DockLayout;
use aeron_protocols::models::{
    ExternalDisplayInfo, GameModePolicy, GameModeState, InputSourceOption, ThermalPressure,
    ThermalSnapshot, WattageSnapshot,
};

use crate::PlatformBackend;

pub struct FallbackBackend {
    displays: Vec<ExternalDisplayInfo>,
    game_mode_policy: GameModePolicy,
}

impl Default for FallbackBackend {
    fn default() -> Self {
        Self::new()
    }
}

impl FallbackBackend {
    pub fn new() -> Self {
        Self {
            displays: vec![ExternalDisplayInfo {
                id: "preview-1".into(),
                settings_key: "preview-1".into(),
                name: "External Monitor (Preview)".into(),
                brightness: 0.75,
                volume: 0.5,
                is_muted: false,
                extra_dimming: 1.0,
                input_sources: vec![0x0F, 0x11, 0x12, 0x1B]
                    .into_iter()
                    .map(|code| InputSourceOption {
                        code,
                        name: ddc::input_source_name(code),
                    })
                    .collect(),
                current_input: Some(0x0F),
                has_hardware_control: true,
                is_builtin: false,
                is_enabled: true,
            }],
            game_mode_policy: GameModePolicy::Automatic,
        }
    }
}

impl PlatformBackend for FallbackBackend {
    fn platform_name(&self) -> &'static str {
        std::env::consts::OS
    }

    fn is_steamos(&self) -> bool {
        false
    }

    fn refresh_displays(&mut self) -> Vec<ExternalDisplayInfo> {
        self.displays.clone()
    }

    fn displays(&self) -> Vec<ExternalDisplayInfo> {
        self.displays.clone()
    }

    fn set_display_brightness(&mut self, display_id: &str, level: f32) -> Result<(), String> {
        if let Some(d) = self.displays.iter_mut().find(|d| d.id == display_id) {
            d.brightness = level.clamp(0.0, 1.0);
        }
        Ok(())
    }

    fn set_display_volume(&mut self, display_id: &str, level: f32) -> Result<(), String> {
        if let Some(d) = self.displays.iter_mut().find(|d| d.id == display_id) {
            d.volume = level.clamp(0.0, 1.0);
        }
        Ok(())
    }

    fn set_display_muted(&mut self, display_id: &str, muted: bool) -> Result<(), String> {
        if let Some(d) = self.displays.iter_mut().find(|d| d.id == display_id) {
            d.is_muted = muted;
        }
        Ok(())
    }

    fn set_display_input(&mut self, display_id: &str, input_code: u8) -> Result<(), String> {
        if let Some(d) = self.displays.iter_mut().find(|d| d.id == display_id) {
            d.current_input = Some(input_code);
        }
        Ok(())
    }

    fn set_caffeine_active(&mut self, _active: bool) -> Result<(), String> {
        Ok(())
    }

    fn read_thermals(&self) -> ThermalSnapshot {
        ThermalSnapshot {
            supported: true,
            pressure: ThermalPressure::Nominal,
            cpu_celsius: Some(52.0),
            gpu_celsius: Some(46.0),
            battery_celsius: Some(31.0),
            fans: Vec::new(),
        }
    }

    fn read_wattage(&self) -> WattageSnapshot {
        WattageSnapshot {
            supported: true,
            is_plugged_in: true,
            is_charging: false,
            battery_level: Some(100),
            system_load_watts: Some(14.2),
            input_watts: Some(14.2),
            adapter_watts: Some(65),
            battery_watts: Some(0.0),
            voltage: Some(12.4),
            amperage: Some(1.15),
            battery_health_percent: Some(98),
            cycle_count: Some(42),
        }
    }

    fn read_game_mode(&self) -> GameModeState {
        GameModeState {
            supported: true,
            is_active: self.game_mode_policy == GameModePolicy::ForcedOn,
            policy: self.game_mode_policy,
            backend_name: "Preview".into(),
        }
    }

    fn set_game_mode_policy(&mut self, policy: GameModePolicy) -> Result<GameModeState, String> {
        self.game_mode_policy = policy;
        Ok(self.read_game_mode())
    }

    fn read_dock_layouts(&self) -> (DockLayout, DockLayout) {
        (DockLayout::empty_razer(), DockLayout::empty_satechi())
    }
}
