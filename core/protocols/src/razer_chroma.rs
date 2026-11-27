//! Razer Thunderbolt 4 Dock Chroma 90-byte HID feature report protocol.
//! Ported directly from `platforms/macos/app/RazerChromaProtocol.swift`.

use serde::{Deserialize, Serialize};

pub const VENDOR_ID: u16 = 0x1532;
pub const DOCK_CHROMA_PRODUCT_ID: u16 = 0x0F21;
pub const DOCK_USB2_HUB_PRODUCT_ID: u16 = 0x0F2F;
pub const DOCK_USB3_HUB_PRODUCT_ID: u16 = 0x0F30;
pub const USAGE_PAGE: u16 = 0x0C;
pub const USAGE: u16 = 0x01;

pub const REPORT_LENGTH: usize = 90;
pub const TRANSACTION_ID: u8 = 0x1F;
pub const VAR_STORE: u8 = 0x01;
pub const ZONE: u8 = 0x00;
pub const WAVE_SPEED: u8 = 0x28;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ReplyStatus {
    Busy = 0x01,
    Success = 0x02,
    Failure = 0x03,
    Timeout = 0x04,
    NotSupported = 0x05,
}

impl ReplyStatus {
    pub fn from_u8(val: u8) -> Option<Self> {
        match val {
            0x01 => Some(Self::Busy),
            0x02 => Some(Self::Success),
            0x03 => Some(Self::Failure),
            0x04 => Some(Self::Timeout),
            0x05 => Some(Self::NotSupported),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Command {
    pub command_class: u8,
    pub id: u8,
    pub size: u8,
}

impl Command {
    pub const FIRMWARE: Self = Self { command_class: 0x00, id: 0x81, size: 0x02 };
    pub const SERIAL: Self = Self { command_class: 0x00, id: 0x82, size: 0x16 };
    pub const GET_EFFECT: Self = Self { command_class: 0x0F, id: 0x82, size: 0x0C };
    pub const GET_BRIGHTNESS: Self = Self { command_class: 0x0F, id: 0x84, size: 0x03 };
    pub const SET_BRIGHTNESS: Self = Self { command_class: 0x0F, id: 0x04, size: 0x03 };

    pub const fn set_effect(size: u8) -> Self {
        Self { command_class: 0x0F, id: 0x02, size }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct RazerRgb {
    pub red: u8,
    pub green: u8,
    pub blue: u8,
}

impl RazerRgb {
    pub const RAZER_GREEN: Self = Self { red: 0x44, green: 0xD6, blue: 0x2C };
    pub const BLUE: Self = Self { red: 0x00, green: 0x7A, blue: 0xFF };
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RazerMode {
    Off,
    StaticColor,
    Breathing,
    Spectrum,
    Wave,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BreathingStyle {
    Single,
    Dual,
    Random,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum WaveDirection {
    LeftToRight = 0x01,
    RightToLeft = 0x02,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RazerLighting {
    pub mode: Option<RazerMode>,
    pub primary: RazerRgb,
    pub secondary: RazerRgb,
    pub breathing: BreathingStyle,
    pub wave_direction: WaveDirection,
}

impl Default for RazerLighting {
    fn default() -> Self {
        Self {
            mode: Some(RazerMode::Spectrum),
            primary: RazerRgb::RAZER_GREEN,
            secondary: RazerRgb::BLUE,
            breathing: BreathingStyle::Single,
            wave_direction: WaveDirection::LeftToRight,
        }
    }
}

pub fn checksum(packet: &[u8]) -> u8 {
    packet[2..88].iter().fold(0u8, |acc, &b| acc ^ b)
}

pub fn packet(cmd: Command, arguments: &[u8]) -> [u8; REPORT_LENGTH] {
    let mut pkt = [0u8; REPORT_LENGTH];
    pkt[1] = TRANSACTION_ID;
    pkt[5] = cmd.size;
    pkt[6] = cmd.command_class;
    pkt[7] = cmd.id;
    let copy_len = arguments.len().min(80);
    pkt[8..8 + copy_len].copy_from_slice(&arguments[..copy_len]);
    pkt[88] = checksum(&pkt);
    pkt
}

pub fn status_of(reply: &[u8], request: &[u8]) -> Option<ReplyStatus> {
    if reply.len() < REPORT_LENGTH || reply[6] != request[6] || reply[7] != request[7] {
        return None;
    }
    ReplyStatus::from_u8(reply[0])
}

pub fn get_effect_packet() -> [u8; REPORT_LENGTH] {
    packet(Command::GET_EFFECT, &[VAR_STORE, ZONE])
}

pub fn get_brightness_packet() -> [u8; REPORT_LENGTH] {
    packet(Command::GET_BRIGHTNESS, &[VAR_STORE, ZONE])
}

pub fn set_brightness_packet(brightness: u8) -> [u8; REPORT_LENGTH] {
    packet(Command::SET_BRIGHTNESS, &[VAR_STORE, ZONE, brightness])
}

pub fn set_effect_packet(lighting: &RazerLighting) -> Option<[u8; REPORT_LENGTH]> {
    let mode = lighting.mode?;
    let p = lighting.primary;
    let s = lighting.secondary;
    let pkt = match mode {
        RazerMode::Off => packet(Command::set_effect(0x06), &[VAR_STORE, ZONE, 0x00]),
        RazerMode::StaticColor => packet(
            Command::set_effect(0x09),
            &[VAR_STORE, ZONE, 0x01, 0x00, 0x00, 0x01, p.red, p.green, p.blue],
        ),
        RazerMode::Breathing => match lighting.breathing {
            BreathingStyle::Single => packet(
                Command::set_effect(0x09),
                &[VAR_STORE, ZONE, 0x02, 0x01, 0x00, 0x01, p.red, p.green, p.blue],
            ),
            BreathingStyle::Dual => packet(
                Command::set_effect(0x0C),
                &[
                    VAR_STORE, ZONE, 0x02, 0x02, 0x00, 0x02, p.red, p.green, p.blue, s.red,
                    s.green, s.blue,
                ],
            ),
            BreathingStyle::Random => packet(
                Command::set_effect(0x06),
                &[VAR_STORE, ZONE, 0x02, 0x00, 0x00, 0x00],
            ),
        },
        RazerMode::Spectrum => packet(Command::set_effect(0x06), &[VAR_STORE, ZONE, 0x03]),
        RazerMode::Wave => packet(
            Command::set_effect(0x06),
            &[
                VAR_STORE,
                ZONE,
                0x04,
                lighting.wave_direction as u8,
                WAVE_SPEED,
            ],
        ),
    };
    Some(pkt)
}

pub fn parse_firmware(reply: &[u8]) -> Option<String> {
    if reply.len() < REPORT_LENGTH {
        return None;
    }
    Some(format!("{}.{}", reply[8], reply[9]))
}

pub fn parse_serial(reply: &[u8]) -> Option<String> {
    if reply.len() < REPORT_LENGTH {
        return None;
    }
    let slice = &reply[8..8 + Command::SERIAL.size as usize];
    let end = slice.iter().position(|&b| b == 0).unwrap_or(slice.len());
    let text = String::from_utf8_lossy(&slice[..end]).trim().to_string();
    (!text.is_empty()).then_some(text)
}

pub fn parse_brightness(reply: &[u8]) -> Option<u8> {
    (reply.len() >= REPORT_LENGTH).then(|| reply[10])
}

pub fn parse_lighting(reply: &[u8], previous: &RazerLighting) -> Option<RazerLighting> {
    if reply.len() < REPORT_LENGTH {
        return None;
    }
    let mut lighting = previous.clone();
    let param = reply[11];
    let color_count = (reply[13] as usize).min(2);
    let mut colors = Vec::with_capacity(color_count);
    for i in 0..color_count {
        colors.push(RazerRgb {
            red: reply[14 + i * 3],
            green: reply[15 + i * 3],
            blue: reply[16 + i * 3],
        });
    }
    match reply[10] {
        0x00 => lighting.mode = Some(RazerMode::Off),
        0x01 => {
            lighting.mode = Some(RazerMode::StaticColor);
            if let Some(c) = colors.first() {
                lighting.primary = *c;
            }
        }
        0x02 => {
            lighting.mode = Some(RazerMode::Breathing);
            lighting.breathing = match param {
                0x01 => BreathingStyle::Single,
                0x02 => BreathingStyle::Dual,
                _ => BreathingStyle::Random,
            };
            if let Some(c) = colors.first() {
                lighting.primary = *c;
            }
            if let Some(c) = colors.get(1) {
                lighting.secondary = *c;
            }
        }
        0x03 => lighting.mode = Some(RazerMode::Spectrum),
        0x04 => {
            lighting.mode = Some(RazerMode::Wave);
            lighting.wave_direction = if param == 0x02 {
                WaveDirection::RightToLeft
            } else {
                WaveDirection::LeftToRight
            };
        }
        _ => lighting.mode = None,
    }
    Some(lighting)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn razer_packet_checksum_and_effect() {
        let lighting = RazerLighting {
            mode: Some(RazerMode::StaticColor),
            primary: RazerRgb::RAZER_GREEN,
            ..Default::default()
        };
        let pkt = set_effect_packet(&lighting).unwrap();
        assert_eq!(pkt[1], TRANSACTION_ID);
        assert_eq!(pkt[88], checksum(&pkt));
        assert_eq!(pkt[14], 0x44);
    }
}
