//! Logitech MX & G keyboard HID++ 2.0 features: Backlight2 (0x1982), FnInversion (0x40A3),
//! ChangeHost (0x1814), RGB Effects (0x8071), Brightness Control (0x8040), Game Mode (0x4523).
//! Ported directly from `platforms/macos/app/LogitechKeyboardProtocol.swift`.

use serde::{Deserialize, Serialize};

pub const FEATURE_BACKLIGHT: u16 = 0x1982;
pub const FEATURE_FN_INVERSION: u16 = 0x40A3;
pub const FEATURE_CHANGE_HOST: u16 = 0x1814;
pub const FEATURE_RGB_EFFECTS: u16 = 0x8071;
pub const FEATURE_BRIGHTNESS_CONTROL: u16 = 0x8040;
pub const FEATURE_GAME_MODE: u16 = 0x4523;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BacklightEffect {
    StaticLight = 0,
    Breathing = 2,
    Contrast = 3,
    Reaction = 4,
    Random = 5,
    Waves = 6,
}

impl BacklightEffect {
    pub const ALL: &'static [BacklightEffect] = &[
        Self::StaticLight,
        Self::Contrast,
        Self::Breathing,
        Self::Waves,
        Self::Reaction,
        Self::Random,
    ];

    pub fn from_u8(val: u8) -> Option<Self> {
        match val {
            0 => Some(Self::StaticLight),
            2 => Some(Self::Breathing),
            3 => Some(Self::Contrast),
            4 => Some(Self::Reaction),
            5 => Some(Self::Random),
            6 => Some(Self::Waves),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BacklightConfig {
    pub is_enabled: bool,
    pub options: u8,
    pub supported: u8,
    pub effects: u16,
    pub level: u8,
    pub duration_away: u16,
    pub duration_typing: u16,
    pub duration_charging: u16,
}

impl BacklightConfig {
    const MODE_MASK: u8 = 0x18;
    const AUTOMATIC_MODE: u8 = 0x08;
    const MANUAL_MODE: u8 = 0x18;
    const BATTERY_SAVING_BIT: u8 = 0x04;

    pub fn is_automatic_brightness(&self) -> bool {
        (self.options & Self::MODE_MASK) != Self::MANUAL_MODE
    }

    pub fn set_automatic_brightness(&mut self, auto: bool) {
        self.options = (self.options & !Self::MODE_MASK)
            | if auto {
                Self::AUTOMATIC_MODE
            } else {
                Self::MANUAL_MODE
            };
    }

    pub fn is_battery_saving(&self) -> bool {
        (self.options & Self::BATTERY_SAVING_BIT) != 0
    }

    pub fn set_battery_saving(&mut self, enabled: bool) {
        if enabled {
            self.options |= Self::BATTERY_SAVING_BIT;
        } else {
            self.options &= !Self::BATTERY_SAVING_BIT;
        }
    }

    pub fn supported_effects(&self) -> Vec<BacklightEffect> {
        BacklightEffect::ALL
            .iter()
            .copied()
            .filter(|e| (self.effects & (1 << (*e as u16))) != 0)
            .collect()
    }

    pub fn duration_seconds(&self) -> u16 {
        self.duration_away.saturating_mul(5)
    }

    pub fn set_duration_seconds(&mut self, seconds: u16) {
        let units = (seconds / 5).max(1);
        self.duration_away = units;
        self.duration_typing = units;
        self.duration_charging = units;
    }
}

pub fn parse_backlight_config(reply: &[u8]) -> Option<BacklightConfig> {
    if reply.len() < 16 {
        return None;
    }
    let le = |i: usize| u16::from_le_bytes([reply[i], reply[i + 1]]);
    Some(BacklightConfig {
        is_enabled: reply[4] != 0,
        options: reply[5],
        supported: reply[6],
        effects: le(7),
        level: reply[9],
        duration_away: le(10),
        duration_typing: le(12),
        duration_charging: le(14),
    })
}

pub fn set_backlight_config_params(config: &BacklightConfig) -> Vec<u8> {
    let mut out = vec![
        u8::from(config.is_enabled),
        config.options,
        0xFF,
        config.level,
    ];
    out.extend_from_slice(&config.duration_away.to_le_bytes());
    out.extend_from_slice(&config.duration_typing.to_le_bytes());
    out.extend_from_slice(&config.duration_charging.to_le_bytes());
    out
}

pub fn parse_backlight_effect(reply: &[u8]) -> Option<BacklightEffect> {
    reply.get(7).copied().and_then(BacklightEffect::from_u8)
}

pub fn parse_fn_inversion(reply: &[u8], host: u8) -> Option<bool> {
    if reply.len() < 6 || reply[4] != host {
        return None;
    }
    Some(reply[5] != 0)
}

pub fn parse_current_host(reply: &[u8]) -> Option<u8> {
    reply.get(5).copied()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RgbEffect {
    Off = 0x0000,
    Fixed = 0x0001,
    Breathing = 0x000A,
    ColorCycle = 0x0015,
    ColorWave = 0x0016,
}

impl RgbEffect {
    pub fn from_u16(val: u16) -> Option<Self> {
        match val {
            0x0000 => Some(Self::Off),
            0x0001 => Some(Self::Fixed),
            0x000A => Some(Self::Breathing),
            0x0015 => Some(Self::ColorCycle),
            0x0016 => Some(Self::ColorWave),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct RgbColor {
    pub red: u8,
    pub green: u8,
    pub blue: u8,
}

impl RgbColor {
    pub const WHITE: Self = Self {
        red: 0xFF,
        green: 0xFF,
        blue: 0xFF,
    };
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RgbLighting {
    pub effect: RgbEffect,
    pub color: RgbColor,
    /// Speed 1 (slowest) ..= 10 (fastest).
    pub speed: u8,
}

impl RgbLighting {
    pub fn period_milliseconds(&self) -> u16 {
        let clamped = self.speed.clamp(1, 10) as u16;
        let base = 11_000 - clamped * 1_000;
        if matches!(self.effect, RgbEffect::ColorCycle | RgbEffect::ColorWave) {
            base * 2
        } else {
            base
        }
    }
}

pub fn parse_rgb_zone_effect(reply: &[u8]) -> Option<(u8, RgbEffect)> {
    if reply.len() < 8 {
        return None;
    }
    let id = ((reply[6] as u16) << 8) | (reply[7] as u16);
    RgbEffect::from_u16(id).map(|e| (reply[5], e))
}

pub fn set_rgb_effect_params(zone: u8, index: u8, lighting: &RgbLighting) -> Vec<u8> {
    let mut effect = [0u8; 10];
    let c = lighting.color;
    let period = lighting.period_milliseconds();
    match lighting.effect {
        RgbEffect::Off => {}
        RgbEffect::Fixed => {
            effect[0] = c.red;
            effect[1] = c.green;
            effect[2] = c.blue;
        }
        RgbEffect::Breathing => {
            effect[0] = c.red;
            effect[1] = c.green;
            effect[2] = c.blue;
            effect[3] = (period >> 8) as u8;
            effect[4] = (period & 0xFF) as u8;
            effect[6] = 100;
        }
        RgbEffect::ColorCycle | RgbEffect::ColorWave => {
            effect[1] = 0xFF;
            effect[6] = (period >> 8) as u8;
            effect[7] = (period & 0xFF) as u8;
            effect[8] = 100;
        }
    }
    let mut out = Vec::with_capacity(13);
    out.push(zone);
    out.push(index);
    out.extend_from_slice(&effect);
    out.push(0x01); // persist across power-off
    out
}

pub fn parse_brightness_level(report: &[u8]) -> Option<u16> {
    if report.len() < 6 {
        return None;
    }
    Some(((report[4] as u16) << 8) | (report[5] as u16))
}

pub fn set_brightness_params(level: u16) -> [u8; 2] {
    [(level >> 8) as u8, (level & 0xFF) as u8]
}

pub fn parse_game_mode_state(report: &[u8]) -> Option<bool> {
    report.get(4).map(|&b| b != 0)
}
