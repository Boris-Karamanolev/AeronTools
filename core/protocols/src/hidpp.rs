//! HID++ 1.0 / 2.0 protocol packet builders and parsers for Logitech devices
//! (BLE, Logi Bolt, Unifying, LIGHTSPEED, USB).
//! Ported directly from `platforms/macos/app/HIDPPProtocol.swift`,
//! `platforms/macos/app/HIDPPSession.swift`, and `platforms/macos/app/MXMasterModels.swift`.

use serde::{Deserialize, Serialize};

pub const LOGITECH_VENDOR_ID: u16 = 0x046D;
pub const BOLT_RECEIVER_PRODUCT_ID: u16 = 0xC548;
pub const UNIFYING_RECEIVER_PRODUCT_ID: u16 = 0xC52B;
pub const LIGHTSPEED_RECEIVER_PRODUCT_IDS: &[u16] =
    &[0xC539, 0xC53A, 0xC53F, 0xC541, 0xC545, 0xC547, 0xC54D];
pub const G515_WIRED_PRODUCT_ID: u16 = 0xC355;

pub const SHORT_REPORT_ID: u8 = 0x10;
pub const LONG_REPORT_ID: u8 = 0x11;
pub const SHORT_REPORT_LENGTH: usize = 7;
pub const LONG_REPORT_LENGTH: usize = 20;

/// HID++ 1.0 sub-ID for reading a long (16-byte) receiver register.
pub const READ_LONG_REGISTER: u8 = 0x83;

/// Software identifier nibble (1..=15) used by Aeron Tools to tag requests and match replies.
pub const SOFTWARE_ID: u8 = 0x0A;

// HID++ 2.0 Feature IDs
pub const FEATURE_ROOT: u16 = 0x0000;
pub const FEATURE_DEVICE_NAME: u16 = 0x0005;
pub const FEATURE_BATTERY_STATUS: u16 = 0x1000;
pub const FEATURE_UNIFIED_BATTERY: u16 = 0x1004;
pub const FEATURE_REPROG_CONTROLS_V4: u16 = 0x1B04;
pub const FEATURE_SMART_SHIFT: u16 = 0x2110;
pub const FEATURE_SMART_SHIFT_ENHANCED: u16 = 0x2111;
pub const FEATURE_HI_RES_WHEEL: u16 = 0x2121;
pub const FEATURE_THUMBWHEEL: u16 = 0x2150;
pub const FEATURE_ADJUSTABLE_DPI: u16 = 0x2201;

// Common MX Master Control IDs (CIDs) for feature 0x1B04
pub const CID_MIDDLE_BUTTON: u16 = 0x0052;
pub const CID_BACK_BUTTON: u16 = 0x0053;
pub const CID_FORWARD_BUTTON: u16 = 0x0056;
pub const CID_GESTURE_THUMB_BUTTON: u16 = 0x00C3;
pub const CID_MODE_SHIFT_BUTTON: u16 = 0x00C4;
/// MX Master 4 haptic sense panel under the thumb.
pub const CID_HAPTIC_PANEL_BUTTON: u16 = 0x01A0;

/// Receiver generations keep their pairing records in different HID++ 1.0 registers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReceiverFamily {
    /// Unifying and LIGHTSPEED: pairing info at `0x20 + slot - 1`, name at `0x40 + slot - 1`.
    Unifying,
    /// Logi Bolt: pairing info at `0x50 + slot`, name at `0x60 + slot` (page `0x01`).
    Bolt,
}

/// HID++ 1.0 device kind from a receiver pairing record.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PairedKind {
    Keyboard = 0x01,
    Mouse = 0x02,
    Numpad = 0x03,
    Presenter = 0x04,
    RemoteControl = 0x07,
    Trackball = 0x08,
    Touchpad = 0x09,
    Unknown = 0xFF,
}

impl PairedKind {
    pub fn from_nibble(byte: u8) -> Self {
        match byte & 0x0F {
            0x01 => Self::Keyboard,
            0x02 => Self::Mouse,
            0x03 => Self::Numpad,
            0x04 => Self::Presenter,
            0x07 => Self::RemoteControl,
            0x08 => Self::Trackball,
            0x09 => Self::Touchpad,
            _ => Self::Unknown,
        }
    }

    pub fn is_pointing_device(self) -> bool {
        matches!(self, Self::Mouse | Self::Trackball | Self::Touchpad)
    }

    pub fn is_keyboard(self) -> bool {
        self == Self::Keyboard
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairedDevice {
    pub name: String,
    pub kind: PairedKind,
}

/// HID++ 2.0 `DeviceName.getDeviceType` (feature `0x0005`, function `0x02`) values.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeviceKind {
    Keyboard = 0,
    RemoteControl = 1,
    Numpad = 2,
    Mouse = 3,
    Touchpad = 4,
    Trackball = 5,
    Presenter = 6,
    Receiver = 7,
    Unknown = 0xFF,
}

impl DeviceKind {
    pub fn from_u8(val: u8) -> Self {
        match val {
            0 => Self::Keyboard,
            1 => Self::RemoteControl,
            2 => Self::Numpad,
            3 => Self::Mouse,
            4 => Self::Touchpad,
            5 => Self::Trackball,
            6 => Self::Presenter,
            7 => Self::Receiver,
            _ => Self::Unknown,
        }
    }

    pub fn is_pointing_device(self) -> bool {
        matches!(self, Self::Mouse | Self::Trackball | Self::Touchpad)
    }

    pub fn is_keyboard(self) -> bool {
        self == Self::Keyboard
    }
}

/// Builds a 7-byte HID++ 1.0 receiver long-register read (`0x83`, register `0xB5`).
pub fn receiver_register_read_packet(sub: u8, page: u8) -> [u8; SHORT_REPORT_LENGTH] {
    [SHORT_REPORT_ID, 0xFF, READ_LONG_REGISTER, 0xB5, sub, page, 0x00]
}

/// Parses a receiver pairing record from the info reply's kind byte and the name reply.
/// - Unifying/LIGHTSPEED: `kind_byte = info[4 + 7]`, `length_at = 5`
/// - Bolt: `kind_byte = info[4 + 1]`, `length_at = 6`
pub fn parse_paired_device(
    kind_byte: u8,
    name_reply: &[u8],
    length_at: usize,
) -> Option<PairedDevice> {
    if name_reply.len() <= length_at + 1 {
        return None;
    }
    let length = (name_reply[length_at] as usize).min(name_reply.len() - length_at - 1);
    if length == 0 {
        return None;
    }
    let raw = &name_reply[(length_at + 1)..(length_at + 1 + length)];
    let trimmed = raw
        .iter()
        .copied()
        .take_while(|&b| b != 0)
        .collect::<Vec<u8>>();
    let name = String::from_utf8_lossy(&trimmed).trim().to_string();
    if name.is_empty() {
        return None;
    }
    Some(PairedDevice {
        name,
        kind: PairedKind::from_nibble(kind_byte),
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MxWheelMode {
    Ratchet,
    FreeSpin,
}

impl MxWheelMode {
    pub fn hidpp_value(self) -> u8 {
        match self {
            Self::FreeSpin => 0x01,
            Self::Ratchet => 0x02,
        }
    }

    pub fn from_hidpp(val: u8) -> Option<Self> {
        match val {
            0x01 => Some(Self::FreeSpin),
            0x02 => Some(Self::Ratchet),
            _ => None,
        }
    }
}

pub fn clamp_mx_dpi(raw: u16, min_dpi: u16, max_dpi: u16, step: u16) -> u16 {
    let clamped = raw.clamp(min_dpi, max_dpi);
    if step == 0 {
        return clamped;
    }
    let offset = clamped - min_dpi;
    let rounded = ((offset as f64 / step as f64).round() as u16) * step;
    (min_dpi + rounded).clamp(min_dpi, max_dpi)
}

pub fn clamp_smart_shift_threshold(raw: u8) -> u8 {
    raw.clamp(1, 50)
}

/// Builds a 20-byte HID++ 2.0 long request packet.
pub fn make_long_packet(
    device_index: u8,
    feature_index: u8,
    function_id: u8,
    sw_id: u8,
    params: &[u8],
) -> [u8; LONG_REPORT_LENGTH] {
    let mut packet = [0u8; LONG_REPORT_LENGTH];
    packet[0] = LONG_REPORT_ID;
    packet[1] = device_index;
    packet[2] = feature_index;
    packet[3] = ((function_id & 0x0F) << 4) | (sw_id & 0x0F);
    let copy_len = params.len().min(LONG_REPORT_LENGTH - 4);
    packet[4..4 + copy_len].copy_from_slice(&params[..copy_len]);
    packet
}

/// Builds an `IRoot.getFeature(feature_id)` request (`0x0000`, function `0x00`).
pub fn get_feature_index_packet(device_index: u8, feature_id: u16) -> [u8; LONG_REPORT_LENGTH] {
    make_long_packet(
        device_index,
        0x00,
        0x00,
        SOFTWARE_ID,
        &[(feature_id >> 8) as u8, (feature_id & 0xFF) as u8],
    )
}

pub fn get_unified_battery_status_packet(
    device_index: u8,
    feature_index: u8,
) -> [u8; LONG_REPORT_LENGTH] {
    make_long_packet(device_index, feature_index, 0x01, SOFTWARE_ID, &[])
}

pub fn get_legacy_battery_status_packet(
    device_index: u8,
    feature_index: u8,
) -> [u8; LONG_REPORT_LENGTH] {
    make_long_packet(device_index, feature_index, 0x00, SOFTWARE_ID, &[])
}

pub fn get_sensor_dpi_packet(
    device_index: u8,
    feature_index: u8,
    sensor_index: u8,
) -> [u8; LONG_REPORT_LENGTH] {
    make_long_packet(device_index, feature_index, 0x02, SOFTWARE_ID, &[sensor_index])
}

pub fn set_sensor_dpi_packet(
    device_index: u8,
    feature_index: u8,
    dpi: u16,
    sensor_index: u8,
) -> [u8; LONG_REPORT_LENGTH] {
    let clamped = clamp_mx_dpi(dpi, 200, 8000, 50);
    make_long_packet(
        device_index,
        feature_index,
        0x03,
        SOFTWARE_ID,
        &[sensor_index, (clamped >> 8) as u8, (clamped & 0xFF) as u8],
    )
}

pub fn get_smart_shift_packet(
    device_index: u8,
    feature_index: u8,
    is_enhanced: bool,
) -> [u8; LONG_REPORT_LENGTH] {
    make_long_packet(
        device_index,
        feature_index,
        if is_enhanced { 0x01 } else { 0x00 },
        SOFTWARE_ID,
        &[],
    )
}

pub fn set_smart_shift_packet(
    device_index: u8,
    feature_index: u8,
    is_enhanced: bool,
    wheel_mode: MxWheelMode,
    smart_shift_enabled: bool,
    threshold: u8,
) -> [u8; LONG_REPORT_LENGTH] {
    let clamped_threshold = clamp_smart_shift_threshold(threshold);
    let auto_disengage = if wheel_mode == MxWheelMode::Ratchet {
        if smart_shift_enabled {
            clamped_threshold
        } else {
            0xFF
        }
    } else {
        0x00
    };
    make_long_packet(
        device_index,
        feature_index,
        if is_enhanced { 0x02 } else { 0x01 },
        SOFTWARE_ID,
        &[wheel_mode.hidpp_value(), auto_disengage, 0x00],
    )
}

pub fn set_control_reporting_packet(
    device_index: u8,
    feature_index: u8,
    control_id: u16,
    diverted: bool,
    raw_xy: bool,
) -> [u8; LONG_REPORT_LENGTH] {
    let mut flags: u8 = 0x02 | 0x20;
    if diverted {
        flags |= 0x01;
    }
    if diverted && raw_xy {
        flags |= 0x10;
    }
    make_long_packet(
        device_index,
        feature_index,
        0x03,
        SOFTWARE_ID,
        &[(control_id >> 8) as u8, (control_id & 0xFF) as u8, flags],
    )
}

pub fn set_control_remap_packet(
    device_index: u8,
    feature_index: u8,
    control_id: u16,
    target: u16,
) -> [u8; LONG_REPORT_LENGTH] {
    make_long_packet(
        device_index,
        feature_index,
        0x03,
        SOFTWARE_ID,
        &[
            (control_id >> 8) as u8,
            (control_id & 0xFF) as u8,
            0x00,
            (target >> 8) as u8,
            (target & 0xFF) as u8,
        ],
    )
}

pub fn set_wheel_mode_packet(
    device_index: u8,
    feature_index: u8,
    diverted: bool,
) -> [u8; LONG_REPORT_LENGTH] {
    make_long_packet(
        device_index,
        feature_index,
        0x02,
        SOFTWARE_ID,
        &[u8::from(diverted)],
    )
}

pub fn set_thumbwheel_reporting_packet(
    device_index: u8,
    feature_index: u8,
    diverted: bool,
) -> [u8; LONG_REPORT_LENGTH] {
    make_long_packet(
        device_index,
        feature_index,
        0x02,
        SOFTWARE_ID,
        &[u8::from(diverted), 0x00],
    )
}

/// Normalizes an incoming HID report (adds leading report ID if omitted on BLE).
pub fn normalize_report(bytes: &[u8]) -> Option<Vec<u8>> {
    if bytes.is_empty() {
        return None;
    }
    if bytes[0] == SHORT_REPORT_ID || bytes[0] == LONG_REPORT_ID {
        return (bytes.len() >= 7).then(|| bytes.to_vec());
    }
    if bytes.len() == 19 {
        let mut out = Vec::with_capacity(20);
        out.push(LONG_REPORT_ID);
        out.extend_from_slice(bytes);
        return Some(out);
    }
    if bytes.len() == 6 {
        let mut out = Vec::with_capacity(7);
        out.push(SHORT_REPORT_ID);
        out.extend_from_slice(bytes);
        return Some(out);
    }
    None
}

pub fn is_error_response(report: &[u8]) -> bool {
    match normalize_report(report) {
        Some(norm) => norm[2] == 0xFF || norm[2] == 0x8F,
        None => true,
    }
}

pub fn parse_feature_index_reply(report: &[u8]) -> Option<u8> {
    let norm = normalize_report(report)?;
    if is_error_response(&norm) || norm[2] != 0x00 || (norm[3] >> 4) != 0x00 || norm.len() < 5 {
        return None;
    }
    let idx = norm[4];
    (idx != 0).then_some(idx)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct BatteryReading {
    pub percentage: u8,
    pub is_charging: bool,
}

pub fn parse_battery_reply(
    report: &[u8],
    expected_feature_index: u8,
    _is_unified_battery: bool,
) -> Option<BatteryReading> {
    let norm = normalize_report(report)?;
    if is_error_response(&norm) || norm[2] != expected_feature_index || norm.len() < 7 {
        return None;
    }
    let percentage = norm[4];
    if !(1..=100).contains(&percentage) {
        return None;
    }
    let status = norm[6];
    let is_charging = (1..=4).contains(&status);
    Some(BatteryReading {
        percentage,
        is_charging,
    })
}

pub fn parse_sensor_dpi_reply(report: &[u8], expected_feature_index: u8) -> Option<u16> {
    let norm = normalize_report(report)?;
    if is_error_response(&norm) || norm[2] != expected_feature_index || norm.len() < 7 {
        return None;
    }
    let dpi = ((norm[5] as u16) << 8) | (norm[6] as u16);
    (100..=16_000).contains(&dpi).then_some(dpi)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct SmartShiftReading {
    pub wheel_mode: MxWheelMode,
    pub smart_shift_enabled: bool,
    pub threshold: u8,
}

pub fn parse_smart_shift_reply(
    report: &[u8],
    expected_feature_index: u8,
) -> Option<SmartShiftReading> {
    let norm = normalize_report(report)?;
    if is_error_response(&norm) || norm[2] != expected_feature_index || norm.len() < 6 {
        return None;
    }
    let wheel_mode = MxWheelMode::from_hidpp(norm[4])?;
    let auto_disengage = norm[5];
    let enabled = (1..=254).contains(&auto_disengage);
    let threshold = if enabled {
        clamp_smart_shift_threshold(auto_disengage)
    } else {
        25
    };
    Some(SmartShiftReading {
        wheel_mode,
        smart_shift_enabled: enabled,
        threshold,
    })
}

pub fn parse_diverted_buttons_event(
    report: &[u8],
    expected_feature_index: u8,
) -> Option<Vec<u16>> {
    let norm = normalize_report(report)?;
    if is_error_response(&norm)
        || norm[2] != expected_feature_index
        || (norm[3] >> 4) != 0x00
        || norm.len() < 12
    {
        return None;
    }
    let mut cids = Vec::with_capacity(4);
    for slot in 0..4 {
        let cid = ((norm[4 + slot * 2] as u16) << 8) | (norm[5 + slot * 2] as u16);
        if cid != 0 {
            cids.push(cid);
        }
    }
    Some(cids)
}

fn is_event(norm: &[u8], feature_index: u8, function: u8) -> bool {
    norm[2] == feature_index && norm[3] == (function << 4)
}

fn read_i16(hi: u8, lo: u8) -> i16 {
    i16::from_be_bytes([hi, lo])
}

pub fn parse_wheel_movement_event(report: &[u8], expected_feature_index: u8) -> Option<i16> {
    let norm = normalize_report(report)?;
    if norm.len() < 7 || !is_event(&norm, expected_feature_index, 0) {
        return None;
    }
    Some(read_i16(norm[5], norm[6]))
}

pub fn parse_thumbwheel_event(report: &[u8], expected_feature_index: u8) -> Option<i16> {
    let norm = normalize_report(report)?;
    if norm.len() < 6 || !is_event(&norm, expected_feature_index, 0) {
        return None;
    }
    Some(read_i16(norm[4], norm[5]))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KeyControl {
    pub cid: u16,
    pub task: u16,
    pub f_key_position: u8,
    pub divertable: bool,
}

/// Reprogrammable Controls V4 function 1: control info.
/// `[cid hi, cid lo, task hi, task lo, flags, F-key position, …]`.
pub fn parse_key_control(reply: &[u8]) -> Option<KeyControl> {
    let norm = normalize_report(reply)?;
    if norm.len() < 10 {
        return None;
    }
    let cid = ((norm[4] as u16) << 8) | (norm[5] as u16);
    if cid == 0 {
        return None;
    }
    Some(KeyControl {
        cid,
        task: ((norm[6] as u16) << 8) | (norm[7] as u16),
        f_key_position: norm[9],
        divertable: norm[8] & 0x20 != 0,
    })
}

pub fn parse_raw_xy_event(report: &[u8], expected_feature_index: u8) -> Option<(i16, i16)> {
    let norm = normalize_report(report)?;
    if norm.len() < 8 || !is_event(&norm, expected_feature_index, 0x01) {
        return None;
    }
    Some((read_i16(norm[4], norm[5]), read_i16(norm[6], norm[7])))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_and_parses_hidpp_packets() {
        let pkt = set_sensor_dpi_packet(0x01, 0x0A, 1620, 0);
        assert_eq!(pkt[0], LONG_REPORT_ID);
        assert_eq!(pkt[1], 0x01);
        assert_eq!(pkt[2], 0x0A);
        assert_eq!(pkt[3], 0x3A);
        // 1620 rounds to 1600 (0x0640)
        assert_eq!(&pkt[4..7], &[0x00, 0x06, 0x40]);

        let batt_reply = [
            0x11, 0x01, 0x05, 0x1A, 82, 0x04, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        ];
        let batt = parse_battery_reply(&batt_reply, 0x05, true).unwrap();
        assert_eq!(
            batt,
            BatteryReading {
                percentage: 82,
                is_charging: true
            }
        );
    }

    #[test]
    fn parses_lightspeed_and_bolt_pairing_records() {
        // Real captured replies from LIGHTSPEED receiver 0x046D:0xC547 with G515 LS TKL
        let info = [
            0x11, 0xFF, 0x83, 0xB5, 0x20, 0x07, 0x08, 0x40, 0xB4, 0x11, 0x00, 0x01, 0xB1, 0x00,
            0x00, 0x00, 0x00, 0x2C, 0x00, 0x00,
        ];
        let name = [
            0x11, 0xFF, 0x83, 0xB5, 0x40, 0x0B, 0x47, 0x35, 0x31, 0x35, 0x20, 0x4C, 0x53, 0x20,
            0x54, 0x4B, 0x4C, 0x00, 0x00, 0x00,
        ];
        let paired = parse_paired_device(info[4 + 7], &name, 5).unwrap();
        assert_eq!(paired.name, "G515 LS TKL");
        assert_eq!(paired.kind, PairedKind::Keyboard);

        // Bolt pairing record format: kind at info[5], name length at name[6]
        let bolt_name = [
            0x11, 0xFF, 0x83, 0xB5, 0x61, 0x01, 0x09, b'M', b'X', b' ', b'M', b'a', b's', b't',
            b'e', b'r', 0, 0, 0, 0,
        ];
        let bolt = parse_paired_device(0x02, &bolt_name, 6).unwrap();
        assert_eq!(bolt.name, "MX Master");
        assert_eq!(bolt.kind, PairedKind::Mouse);
    }
}
