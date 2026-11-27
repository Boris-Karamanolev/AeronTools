//! Logitech G gaming mouse HID++ 2.0 features (Extended DPI, Extended Report Rate,
//! Analog Triggers, Mouse Button Spy, Onboard Profiles with CRC-16/CCITT).
//! Ported directly from `platforms/macos/app/LogitechGProtocol.swift`.

use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

pub const FEATURE_EXTENDED_DPI: u16 = 0x2202;
pub const FEATURE_EXTENDED_REPORT_RATE: u16 = 0x8061;
pub const FEATURE_ONBOARD_PROFILES: u16 = 0x8100;
pub const FEATURE_ANALOG_TRIGGERS: u16 = 0x1B0C;
pub const FEATURE_MOUSE_BUTTON_SPY: u16 = 0x8110;
pub const SIDE_BUTTON_BACK: usize = 4;
pub const SIDE_BUTTON_FORWARD: usize = 5;

pub fn parse_button_spy_event(report: &[u8], expected_feature_index: u8) -> Option<u16> {
    let norm = crate::hidpp::normalize_report(report)?;
    if norm.len() < 6 || norm[2] != expected_feature_index || norm[3] != 0x00 {
        return None;
    }
    Some(((norm[4] as u16) << 8) | (norm[5] as u16))
}

pub fn button_pressed(button: usize, mask: u16) -> bool {
    (1..=16).contains(&button) && mask & (1 << (button - 1)) != 0
}

pub const REPORT_RATES_HZ: &[u16] = &[125, 250, 500, 1000, 2000, 4000, 8000];
pub const TRIGGER_UNITS_PER_LEVEL: u8 = 4;
pub const SUPPORTED_PROFILE_FORMAT: u8 = 0x08;
pub const PROFILE_BUTTON_TABLE_OFFSET: usize = 48;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DpiSegment {
    pub lower: u16,
    pub upper: u16,
    pub step: u16,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DpiRange {
    pub segments: Vec<DpiSegment>,
}

impl DpiRange {
    pub fn minimum(&self) -> u16 {
        self.segments.first().map(|s| s.lower).unwrap_or(0)
    }

    pub fn maximum(&self) -> u16 {
        self.segments.last().map(|s| s.upper).unwrap_or(0)
    }

    pub fn nearest_supported(&self, dpi: u16) -> u16 {
        let clamped = dpi.clamp(self.minimum(), self.maximum());
        let Some(seg) = self.segments.iter().find(|s| clamped <= s.upper) else {
            return clamped;
        };
        let offset = ((clamped - seg.lower) + seg.step / 2) / seg.step * seg.step;
        (seg.lower + offset).min(seg.upper)
    }
}

pub fn parse_dpi_ranges(pages: &[Vec<u8>]) -> Option<DpiRange> {
    let mut data = Vec::new();
    for page in pages {
        if page.len() >= 20 {
            data.extend_from_slice(&page[7..20]);
        }
    }
    let mut words = Vec::new();
    let mut idx = 0;
    while idx + 1 < data.len() {
        let word = ((data[idx] as u16) << 8) | (data[idx + 1] as u16);
        if word == 0 {
            break;
        }
        words.push(word);
        idx += 2;
    }

    let mut segments = Vec::new();
    let mut previous: Option<u16> = None;
    let mut pending_step: Option<u16> = None;
    for word in words {
        if word >= 0xE000 {
            pending_step = Some(word & 0x1FFF);
        } else {
            if let (Some(lower), Some(step)) = (previous, pending_step) {
                if step > 0 && word > lower {
                    segments.push(DpiSegment {
                        lower,
                        upper: word,
                        step,
                    });
                }
            }
            previous = Some(word);
            pending_step = None;
        }
    }
    (!segments.is_empty()).then_some(DpiRange { segments })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct SensorDpi {
    pub dpi: u16,
    pub lift_off_distance: u8,
}

pub fn parse_sensor_dpi(reply: &[u8]) -> Option<SensorDpi> {
    if reply.len() < 14 {
        return None;
    }
    let dpi = ((reply[5] as u16) << 8) | (reply[6] as u16);
    (dpi > 0).then_some(SensorDpi {
        dpi,
        lift_off_distance: reply[13],
    })
}

pub fn set_sensor_dpi_params(dpi: u16, lift_off_distance: u8) -> [u8; 6] {
    let hi = (dpi >> 8) as u8;
    let lo = (dpi & 0xFF) as u8;
    [0x00, hi, lo, hi, lo, lift_off_distance]
}

pub fn parse_supported_report_rates(reply: &[u8]) -> Vec<u16> {
    if reply.len() < 6 {
        return Vec::new();
    }
    let flags = ((reply[4] as u16) << 8) | (reply[5] as u16);
    REPORT_RATES_HZ
        .iter()
        .enumerate()
        .filter(|(i, _)| flags & (1 << i) != 0)
        .map(|(_, &hz)| hz)
        .collect()
}

pub fn parse_report_rate(reply: &[u8]) -> Option<u16> {
    let idx = *reply.get(4)? as usize;
    REPORT_RATES_HZ.get(idx).copied()
}

pub fn report_rate_index(hz: u16) -> Option<u8> {
    REPORT_RATES_HZ
        .iter()
        .position(|&r| r == hz)
        .map(|i| i as u8)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TriggerSettings {
    pub actuation: u8,
    pub rapid_trigger: u8,
    pub haptics: u8,
}

impl Default for TriggerSettings {
    fn default() -> Self {
        Self {
            actuation: 5,
            rapid_trigger: 0,
            haptics: 3,
        }
    }
}

pub fn set_trigger_params(key: u8, settings: TriggerSettings) -> [u8; 4] {
    let rapid = if settings.rapid_trigger > 0 {
        (settings.rapid_trigger.saturating_mul(TRIGGER_UNITS_PER_LEVEL)) | 0x01
    } else {
        2 * TRIGGER_UNITS_PER_LEVEL
    };
    [
        key,
        settings.actuation.saturating_mul(TRIGGER_UNITS_PER_LEVEL),
        rapid,
        settings.haptics.saturating_mul(TRIGGER_UNITS_PER_LEVEL),
    ]
}

/// `getInfo` (function 0). Limits are raw units at `[6]`, `[7]` and `[8]`.
pub fn parse_trigger_limits(reply: &[u8]) -> Option<TriggerSettings> {
    if reply.len() < 9 || reply[6] == 0 {
        return None;
    }
    Some(TriggerSettings {
        actuation: (reply[6] / TRIGGER_UNITS_PER_LEVEL).max(1),
        rapid_trigger: reply[7] / TRIGGER_UNITS_PER_LEVEL,
        haptics: reply[8] / TRIGGER_UNITS_PER_LEVEL,
    })
}

pub fn parse_trigger_settings(reply: &[u8]) -> Option<TriggerSettings> {
    if reply.len() < 8 {
        return None;
    }
    let actuation = (reply[5] / TRIGGER_UNITS_PER_LEVEL).max(1);
    let rapid_byte = reply[6];
    let rapid_trigger = if rapid_byte & 0x01 != 0 {
        (rapid_byte & !0x01) / TRIGGER_UNITS_PER_LEVEL
    } else {
        0
    };
    let haptics = reply[7] / TRIGGER_UNITS_PER_LEVEL;
    Some(TriggerSettings {
        actuation,
        rapid_trigger,
        haptics,
    })
}

pub fn button_map(button_count: usize, silenced: &HashSet<usize>) -> Vec<u8> {
    (1..=button_count.max(1))
        .map(|b| if silenced.contains(&b) { 0 } else { b as u8 })
        .collect()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OnboardProfilesInfo {
    pub profile_format: u8,
    pub sector_size: usize,
}

/// `getOnboardProfilesInfo` (function 0): `[5]` profile format, `[11…12]` sector size.
pub fn parse_onboard_profiles_info(reply: &[u8]) -> Option<OnboardProfilesInfo> {
    if reply.len() < 13 {
        return None;
    }
    let sector_size = ((reply[11] as usize) << 8) | (reply[12] as usize);
    (sector_size > 16).then_some(OnboardProfilesInfo {
        profile_format: reply[5],
        sector_size,
    })
}

/// First enabled profile sector in the sector-0 directory.
/// Entries are `[sector hi, sector lo, enabled, 0xFF]`, ended by `0xFFFF`.
pub fn first_enabled_profile_sector(directory: &[u8]) -> Option<u16> {
    let mut offset = 0;
    while offset + 3 < directory.len() {
        let sector = u16::from_be_bytes([directory[offset], directory[offset + 1]]);
        if sector == 0xFFFF {
            return None;
        }
        if directory[offset + 2] != 0 {
            return Some(sector);
        }
        offset += 4;
    }
    None
}

pub fn read_memory_params(sector: u16, offset: usize) -> [u8; 4] {
    [
        (sector >> 8) as u8,
        (sector & 0xFF) as u8,
        (offset >> 8) as u8,
        (offset & 0xFF) as u8,
    ]
}

pub fn sector_read_offsets(sector_size: usize) -> Vec<usize> {
    let mut offsets: Vec<usize> = (0..sector_size.saturating_sub(16)).step_by(16).collect();
    offsets.push(sector_size - 16);
    offsets
}

pub fn assemble_sector(chunks: &[Vec<u8>], sector_size: usize) -> Option<Vec<u8>> {
    let offsets = sector_read_offsets(sector_size);
    if chunks.len() != offsets.len() || chunks.iter().any(|chunk| chunk.len() < 16) {
        return None;
    }
    let mut sector = vec![0u8; sector_size];
    for (offset, chunk) in offsets.into_iter().zip(chunks) {
        sector[offset..offset + 16].copy_from_slice(&chunk[..16]);
    }
    Some(sector)
}

pub fn write_memory_start_params(sector: u16, length: usize) -> [u8; 6] {
    [
        (sector >> 8) as u8,
        (sector & 0xFF) as u8,
        0x00,
        0x00,
        (length >> 8) as u8,
        (length & 0xFF) as u8,
    ]
}

pub fn mouse_button_binding(button: usize) -> [u8; 4] {
    let mask = 1u16 << (button.saturating_sub(1) as u16);
    [0x80, 0x01, (mask >> 8) as u8, (mask & 0xFF) as u8]
}

pub fn key_binding(usage: u8, modifiers: u8) -> [u8; 4] {
    [0x80, 0x02, modifiers, usage]
}

/// CRC-16/CCITT (poly 0x1021, init 0xFFFF).
pub fn profile_crc(bytes: &[u8]) -> u16 {
    let mut crc: u16 = 0xFFFF;
    for &byte in bytes {
        crc ^= (byte as u16) << 8;
        for _ in 0..8 {
            crc = if crc & 0x8000 != 0 {
                (crc << 1) ^ 0x1021
            } else {
                crc << 1
            };
        }
    }
    crc
}

pub fn has_valid_crc(sector: &[u8]) -> bool {
    if sector.len() <= 2 {
        return false;
    }
    let stored = ((sector[sector.len() - 2] as u16) << 8) | (sector[sector.len() - 1] as u16);
    profile_crc(&sector[..sector.len() - 2]) == stored
}

#[derive(Debug, Clone, Default)]
pub struct ProfilePatch {
    pub dpi: Option<u16>,
    pub report_rate_hz: Option<u16>,
    pub triggers: Option<TriggerSettings>,
    pub button_bindings: HashMap<usize, [u8; 4]>,
}

pub fn patched_profile_sector(sector: &[u8], patch: &ProfilePatch) -> Option<Vec<u8>> {
    if sector.len() < 64 || !has_valid_crc(sector) {
        return None;
    }
    let mut patched = sector.to_vec();
    if let Some(hz) = patch.report_rate_hz {
        if let Some(idx) = report_rate_index(hz) {
            patched[0] = idx;
            patched[1] = idx;
        }
    }
    if let Some(dpi) = patch.dpi {
        let level = patched[2] as usize;
        if level >= 5 {
            return None;
        }
        let offset = 4 + level * 5;
        let lo = (dpi & 0xFF) as u8;
        let hi = (dpi >> 8) as u8;
        patched[offset] = lo;
        patched[offset + 1] = hi;
        patched[offset + 2] = lo;
        patched[offset + 3] = hi;
    }
    for (&button, binding) in &patch.button_bindings {
        if button < 1 {
            continue;
        }
        let offset = PROFILE_BUTTON_TABLE_OFFSET + (button - 1) * 4;
        if offset + 4 <= patched.len() - 2 && patched[offset] == 0x80 {
            patched[offset..offset + 4].copy_from_slice(binding);
        }
    }
    if let Some(triggers) = patch.triggers {
        for (key, base) in [(0u8, 38usize), (1u8, 41usize)] {
            let params = set_trigger_params(key, triggers);
            patched[base] = params[1];
            patched[base + 1] = params[2];
            patched[base + 2] = params[3];
        }
    }
    let crc = profile_crc(&patched[..patched.len() - 2]);
    let len = patched.len();
    patched[len - 2] = (crc >> 8) as u8;
    patched[len - 1] = (crc & 0xFF) as u8;
    Some(patched)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crc_and_profile_patching_preserve_integrity() {
        let mut sector = vec![0u8; 64];
        sector[2] = 0; // DPI level 0
        sector[48] = 0x80;
        let crc = profile_crc(&sector[..62]);
        sector[62] = (crc >> 8) as u8;
        sector[63] = (crc & 0xFF) as u8;
        assert!(has_valid_crc(&sector));

        let patch = ProfilePatch {
            dpi: Some(1600),
            report_rate_hz: Some(2000),
            triggers: Some(TriggerSettings::default()),
            button_bindings: HashMap::new(),
        };
        let out = patched_profile_sector(&sector, &patch).unwrap();
        assert!(has_valid_crc(&out));
        assert_eq!(out[0], 4); // 2000 Hz index
        assert_eq!(u16::from_le_bytes([out[4], out[5]]), 1600);
    }

    #[test]
    fn trigger_settings_round_trip() {
        let settings = TriggerSettings {
            actuation: 6,
            rapid_trigger: 3,
            haptics: 4,
        };
        let params = set_trigger_params(0, settings);
        let mut reply = [0u8; 20];
        reply[4..8].copy_from_slice(&params);
        assert_eq!(parse_trigger_settings(&reply), Some(settings));
    }
}
