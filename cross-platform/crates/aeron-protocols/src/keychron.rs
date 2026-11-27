//! Keychron M3 Mini 4K vendor HID protocol (collection 0xFF0A / 0x01).
//! Ported directly from `AeronTools/KeychronMouseProtocol.swift`.

use serde::{Deserialize, Serialize};

pub const VENDOR_ID: u16 = 0x3434;
pub const USAGE_PAGE: u16 = 0xFF0A;
pub const USAGE: u16 = 0x01;
pub const RECEIVER_PRODUCT_ID: u16 = 0xD038;
pub const M3_MINI_PRODUCT_ID: u16 = 0xD041;
pub const M3_MINI_MODEL_ID: u16 = 0x0622;

pub const PACKET_LENGTH: usize = 64;
pub const DPI_MIN: u16 = 100;
pub const DPI_MAX: u16 = 26_000;
pub const DPI_STEP: u16 = 50;
pub const STAGE_COUNT: usize = 5;
pub const REPORT_RATES: &[u16] = &[125, 500, 1000, 2000, 4000];
pub const ROUTE_BIT: u8 = 0x40;
pub const LINKED_STATE: u8 = 0x0A;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Command {
    pub id: u8,
    pub length: u8,
    pub sub: u8,
}

impl Command {
    pub const VERSION: Self = Self { id: 0x00, length: 0x81, sub: 0x00 };
    pub const POWER: Self = Self { id: 0x01, length: 0x81, sub: 0x01 };
    pub const READ_SETTINGS: Self = Self { id: 0x04, length: 0x81, sub: 0x01 };
    pub const WRITE_SETTINGS: Self = Self { id: 0x04, length: 0xB5, sub: 0x02 };
    pub const SAVE: Self = Self { id: 0x0A, length: 0x81, sub: 0x01 };
    pub const READ_BUTTONS: Self = Self { id: 0x03, length: 0x81, sub: 0x01 };
    pub const WRITE_BUTTON: Self = Self { id: 0x03, length: 0x85, sub: 0x04 };
}

/// Builds a 64-byte Keychron 4K packet with trailing `0xA1 - sum` checksum.
pub fn packet(cmd: Command, routed: bool, payload: &[u8]) -> [u8; PACKET_LENGTH] {
    let mut pkt = [0u8; PACKET_LENGTH];
    pkt[0] = if routed { cmd.id | ROUTE_BIT } else { cmd.id };
    pkt[2] = cmd.length;
    pkt[3] = cmd.sub;
    let copy_len = payload.len().min(PACKET_LENGTH - 5);
    pkt[4..4 + copy_len].copy_from_slice(&payload[..copy_len]);
    let sum = pkt[..PACKET_LENGTH - 1]
        .iter()
        .fold(0u8, |acc, &b| acc.wrapping_add(b));
    pkt[PACKET_LENGTH - 1] = 0xA1u8.wrapping_sub(sum);
    pkt
}

pub fn is_reply(report: &[u8], request: &[u8]) -> bool {
    report.len() > 3 && request.len() > 3 && report[0] == request[0] && report[3] == request[3]
}

pub fn report_rate_hz(code: u8) -> Option<u16> {
    (code <= 5).then(|| 125u16 << code)
}

pub fn report_rate_code(hz: u16) -> Option<u8> {
    (0u8..=5).find(|&c| (125u16 << c) == hz)
}

pub fn clamp_dpi(dpi: u16) -> u16 {
    let rounded = ((dpi as f64 / DPI_STEP as f64).round() as u16) * DPI_STEP;
    rounded.clamp(DPI_MIN, DPI_MAX)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct PowerReply {
    pub percent: Option<u8>,
    pub is_charging: bool,
    pub active_stage: u8,
    pub max_report_rate_hz: Option<u16>,
}

impl PowerReply {
    pub fn parse(report: &[u8]) -> Option<Self> {
        if report.len() <= 8 || report[3] != Command::POWER.sub {
            return None;
        }
        Some(Self {
            percent: (report[6] <= 100).then_some(report[6]),
            is_charging: report[5] != 0,
            active_stage: report[8],
            max_report_rate_hz: report.get(10).copied().and_then(report_rate_hz),
        })
    }
}

/// Raw 52-byte settings block (bytes 4..=55 of the read/write report).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeychronSettingsBlock {
    /// Stored with original report indices [4..=55] mapped to [0..52].
    pub raw: [u8; 52],
}

impl KeychronSettingsBlock {
    const ANGLE_SNAPPING_BIT: u8 = 0x01;
    const MOTION_SYNC_BIT: u8 = 0x20;

    pub fn parse(report: &[u8]) -> Option<Self> {
        if report.len() < 56 || report[3] != Command::READ_SETTINGS.sub {
            return None;
        }
        let mut raw = [0u8; 52];
        raw.copy_from_slice(&report[4..56]);
        Some(Self { raw })
    }

    pub fn stage_count(&self) -> usize {
        (self.raw[6 - 4].count_ones() as usize).clamp(1, STAGE_COUNT)
    }

    pub fn active_stage(&self) -> u8 {
        self.raw[7 - 4].min((self.stage_count() - 1) as u8)
    }

    pub fn set_active_stage(&mut self, stage: u8) {
        self.raw[7 - 4] = stage.min((self.stage_count() - 1) as u8);
    }

    pub fn dpi(&self, stage: usize) -> u16 {
        let offset = (8 - 4) + stage * 4;
        u16::from_le_bytes([self.raw[offset], self.raw[offset + 1]])
    }

    pub fn set_dpi(&mut self, stage: usize, dpi: u16) {
        let clamped = clamp_dpi(dpi);
        let bytes = clamped.to_le_bytes();
        let offset = (8 - 4) + stage * 4;
        self.raw[offset..offset + 2].copy_from_slice(&bytes);
        self.raw[offset + 2..offset + 4].copy_from_slice(&bytes);
    }

    pub fn report_rate_hz(&self) -> Option<u16> {
        report_rate_hz(self.raw[5 - 4])
    }

    pub fn set_report_rate_hz(&mut self, hz: u16) {
        if let Some(code) = report_rate_code(hz) {
            self.raw[5 - 4] = code;
        }
    }

    pub fn lift_off_mm(&self) -> u8 {
        self.raw[43 - 4]
    }

    pub fn set_lift_off_mm(&mut self, mm: u8) {
        self.raw[43 - 4] = mm.clamp(1, 2);
    }

    pub fn motion_sync(&self) -> bool {
        (self.raw[0] & Self::MOTION_SYNC_BIT) != 0
    }

    pub fn set_motion_sync(&mut self, on: bool) {
        if on {
            self.raw[0] |= Self::MOTION_SYNC_BIT;
        } else {
            self.raw[0] &= !Self::MOTION_SYNC_BIT;
        }
    }

    pub fn angle_snapping(&self) -> bool {
        (self.raw[0] & Self::ANGLE_SNAPPING_BIT) != 0
    }

    pub fn set_angle_snapping(&mut self, on: bool) {
        if on {
            self.raw[0] |= Self::ANGLE_SNAPPING_BIT;
        } else {
            self.raw[0] &= !Self::ANGLE_SNAPPING_BIT;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keychron_packet_checksum_and_rate_codes() {
        let pkt = packet(Command::POWER, true, &[]);
        assert_eq!(pkt[0], 0x41);
        let sum = pkt.iter().fold(0u8, |acc, &b| acc.wrapping_add(b));
        assert_eq!(sum, 0xA1);
        assert_eq!(report_rate_hz(5), Some(4000));
        assert_eq!(report_rate_code(1000), Some(3));
    }
}
