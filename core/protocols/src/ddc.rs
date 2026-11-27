//! Pure DDC/CI (MCCS) packet encoding, decoding, VCP codes, and input source mapping.
//! Ported directly from `platforms/macos/app/DDCController.swift`.

use serde::{Deserialize, Serialize};

pub const CHIP_ADDRESS: u16 = 0x37;
pub const DATA_ADDRESS: u8 = 0x51;
/// Host address (0x6E) XOR sub-address (0x51) seeds every DDC/CI checksum.
const CHECKSUM_SEED: u8 = 0x6E ^ 0x51;

/// Standard MCCS VCP feature codes used by AeronTools.
pub mod vcp {
    pub const BRIGHTNESS: u8 = 0x10;
    pub const INPUT_SOURCE: u8 = 0x60;
    pub const AUDIO_SPEAKER_VOLUME: u8 = 0x62;
    pub const AUDIO_MUTE: u8 = 0x8D;
    pub const POWER_MODE: u8 = 0xD6;
}

/// EDID-derived monitor identity that survives reconnects and reboots.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct MonitorIdentity {
    pub vendor: u32,
    pub model: u32,
    pub serial: u32,
}

impl MonitorIdentity {
    pub fn key(&self) -> String {
        format!("{}-{}-{}", self.vendor, self.model, self.serial)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct VcpValue {
    pub current: u16,
    pub max: u16,
}

pub fn checksummed(bytes: &[u8]) -> Vec<u8> {
    let chk = bytes.iter().fold(CHECKSUM_SEED, |acc, &b| acc ^ b);
    let mut out = Vec::with_capacity(bytes.len() + 1);
    out.extend_from_slice(bytes);
    out.push(chk);
    out
}

pub fn set_vcp_packet(vcp: u8, value: u16) -> Vec<u8> {
    checksummed(&[0x84, 0x03, vcp, (value >> 8) as u8, (value & 0xFF) as u8])
}

pub fn get_vcp_packet(vcp: u8) -> Vec<u8> {
    checksummed(&[0x82, 0x01, vcp])
}

pub fn capabilities_packet(offset: u16) -> Vec<u8> {
    checksummed(&[0x83, 0xF3, (offset >> 8) as u8, (offset & 0xFF) as u8])
}

/// Parses a "Get VCP Feature" reply:
/// `6E 88 02 <result> <vcp> <type> <maxHi> <maxLo> <curHi> <curLo> <chk>`
pub fn parse_vcp_reply(reply: &[u8], vcp: u8) -> Option<VcpValue> {
    if reply.len() < 10 || reply[2] != 0x02 || reply[3] != 0x00 || reply[4] != vcp {
        return None;
    }
    let max = ((reply[6] as u16) << 8) | (reply[7] as u16);
    let current = ((reply[8] as u16) << 8) | (reply[9] as u16);
    Some(VcpValue { current, max })
}

/// Parses one capabilities fragment: `6E <0x80|len> E3 <offHi> <offLo> <data...>`.
/// Returns `None` for malformed/out-of-order fragments and `Some(vec![])` at end of string.
pub fn parse_capabilities_fragment(reply: &[u8], offset: u16) -> Option<Vec<u8>> {
    if reply.len() < 5 || reply[2] != 0xE3 {
        return None;
    }
    let reply_offset = ((reply[3] as u16) << 8) | (reply[4] as u16);
    if reply_offset != offset {
        return None;
    }
    let length = ((reply[1] & 0x7F) as isize) - 3;
    if length <= 0 {
        return Some(Vec::new());
    }
    let end = (5 + length as usize).min(reply.len());
    Some(reply[5..end].to_vec())
}

/// Extracts input source codes listed for VCP 0x60 in a capabilities string,
/// e.g. `"... 60(0F 11 12 ) ..."` -> `[0x0F, 0x11, 0x12]`.
pub fn input_sources_from_capabilities(caps: &str) -> Vec<u8> {
    let upper = caps.to_ascii_uppercase();
    let bytes = upper.as_bytes();
    let mut pos = 0;

    while let Some(rel) = upper[pos..].find("60(") {
        let start = pos + rel;
        pos = start + 3;

        // Skip longer codes that merely end in "60", e.g., "E260(".
        if start > 0 && bytes[start - 1].is_ascii_hexdigit() {
            continue;
        }
        let Some(close_rel) = upper[pos..].find(')') else {
            return Vec::new();
        };
        let inside = &upper[pos..pos + close_rel];
        return inside
            .split_whitespace()
            .filter_map(|tok| u8::from_str_radix(tok, 16).ok())
            .collect();
    }
    Vec::new()
}

/// Human-readable MCCS VCP 0x60 input source label.
pub fn input_source_name(code: u8) -> String {
    match code {
        0x01 => "VGA 1".into(),
        0x02 => "VGA 2".into(),
        0x03 => "DVI 1".into(),
        0x04 => "DVI 2".into(),
        0x0F => "DisplayPort 1".into(),
        0x10 => "DisplayPort 2".into(),
        0x11 => "HDMI 1".into(),
        0x12 => "HDMI 2".into(),
        0x13 => "HDMI 3".into(),
        0x14 => "HDMI 4".into(),
        0x19 | 0x1B => "USB-C".into(),
        other => format!("Input 0x{:02X}", other),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_vcp_reply_and_checksum() {
        let pkt = set_vcp_packet(vcp::BRIGHTNESS, 75);
        assert_eq!(pkt.len(), 6);
        assert_eq!(pkt[2], 0x10);
        assert_eq!(pkt[4], 75);

        let reply = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x4B, 0x00];
        let parsed = parse_vcp_reply(&reply, vcp::BRIGHTNESS).unwrap();
        assert_eq!(parsed, VcpValue { current: 75, max: 100 });
    }

    #[test]
    fn parses_input_sources_skipping_suffix_match() {
        let caps = "(prot(monitor)vcp(10 E260(01 02) 60(0F 11 12 1B) 62))";
        assert_eq!(input_sources_from_capabilities(caps), vec![0x0F, 0x11, 0x12, 0x1B]);
    }
}
