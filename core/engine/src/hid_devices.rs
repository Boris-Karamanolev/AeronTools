//! Cross-platform HID device discovery and communication via `hidapi`.
//! Speaks Logitech HID++ 1.0/2.0 (Unifying, Logi Bolt, LIGHTSPEED, USB, BLE),
//! Keychron 4K (receiver, USB cable, BLE), and Razer Chroma protocols across macOS, Linux, and Windows.

use std::collections::{HashMap, HashSet};
use std::time::Duration;

use aeron_protocols::dock_topology::DockLayout;
use aeron_protocols::hidpp::{self, DeviceKind, MxWheelMode, PairedDevice, ReceiverFamily};
use aeron_protocols::keychron::{self, KeychronSettingsBlock};
use aeron_protocols::logitech_g::{self, TriggerSettings};
use aeron_protocols::logitech_keyboard::{
    self, BacklightConfig, BacklightEffect, RgbEffect, RgbLighting,
};
use aeron_protocols::models::{
    AccessoriesSnapshot, AccessoryButtonAction, AccessoryConnection, KeychronM3MiniState,
    LogitechGKeyboardState, LogitechGMouseState, MxKeyboardState, MxMasterOptions, MxMasterState,
    MxThumbwheelAction, RazerDockState, SatechiHubState, default_rgb_lighting,
};
use aeron_protocols::razer_chroma::{self, RazerLighting, ReplyStatus};
use hidapi::{BusType, HidApi, HidDevice};
use tracing::{debug, warn};

use crate::accessory_store;
use crate::hid_input::{GMouseLive, KeyboardLive, MxLive};
use crate::input_session::{DeviceRuntime, DeviceWrite, Interest, PathSession};

pub struct HidManager {
    api: Option<HidApi>,
    state: AccessoriesSnapshot,
    mx_master_path: Option<(String, u8)>,
    mx_keyboard_path: Option<(String, u8)>,
    logitech_g_mouse_path: Option<(String, u8)>,
    logitech_g_keyboard_path: Option<(String, u8)>,
    g_keyboard_effect_indices: HashMap<RgbEffect, u8>,
    keychron_path: Option<(String, bool)>,
    keychron_settings_block: Option<KeychronSettingsBlock>,
    razer_dock_path: Option<String>,
    sessions: Vec<PathSession>,
}

impl Default for HidManager {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Default)]
struct ScanSeen {
    mx_master: bool,
    mx_keyboard: bool,
    logitech_g_mouse: bool,
    logitech_g_keyboard: bool,
    keychron: bool,
    razer_dock_hid: bool,
}

impl HidManager {
    pub fn new() -> Self {
        let api = match HidApi::new() {
            Ok(a) => Some(a),
            Err(err) => {
                warn!("hidapi initialization failed: {err}");
                None
            }
        };
        let mut state = default_accessories_snapshot();
        accessory_store::apply(&mut state);
        Self {
            api,
            state,
            mx_master_path: None,
            mx_keyboard_path: None,
            logitech_g_mouse_path: None,
            logitech_g_keyboard_path: None,
            g_keyboard_effect_indices: HashMap::new(),
            keychron_path: None,
            keychron_settings_block: None,
            razer_dock_path: None,
            sessions: Vec::new(),
        }
    }

    pub fn snapshot(&self) -> AccessoriesSnapshot {
        let mut snap = self.state.clone();
        for session in &self.sessions {
            let Ok(live) = session.runtime.lock() else {
                continue;
            };
            if let Some(mx) = &live.mx {
                let options = &mx.options;
                snap.mx_master.dpi = mx.dpi;
                snap.mx_master.wheel_mode = mx.wheel_mode;
                snap.mx_master.smart_shift_enabled = mx.smart_shift_enabled;
                snap.mx_master.smart_shift_threshold = mx.smart_shift_threshold;
                snap.mx_master.battery_percent = mx.battery_percent;
                snap.mx_master.is_charging = mx.is_charging;
                snap.mx_master.standard_vertical_scroll = options.standard_vertical_scroll;
                snap.mx_master.smooth_scrolling = options.smooth_scrolling;
                snap.mx_master.scroll_speed_multiplier = options.scroll_speed_multiplier;
                snap.mx_master.thumbwheel_action = options.thumbwheel_action;
                snap.mx_master.invert_thumbwheel = options.invert_thumbwheel;
                snap.mx_master.middle_button_action = options.middle_button_action;
                snap.mx_master.back_button_action = options.back_button_action;
                snap.mx_master.forward_button_action = options.forward_button_action;
                snap.mx_master.gesture_button_action = options.gesture_button_action;
                snap.mx_master.mode_shift_button_action = options.mode_shift_button_action;
                snap.mx_master.haptic_panel_button_action = options.haptic_panel_button_action;
                snap.mx_master.gestures_enabled = options.gestures_enabled;
                snap.mx_master.gesture_up_action = options.gesture_up_action;
                snap.mx_master.gesture_down_action = options.gesture_down_action;
                snap.mx_master.gesture_left_action = options.gesture_left_action;
                snap.mx_master.gesture_right_action = options.gesture_right_action;
                snap.mx_master.saves_to_mouse = options.saves_to_mouse;
            }
            if let Some(keyboard) = &live.keyboard {
                snap.mx_keyboard.key_actions = keyboard.actions.clone();
            }
            if let Some(mouse) = &live.g_mouse {
                snap.logitech_g_mouse.back_button_action = mouse.back;
                snap.logitech_g_mouse.forward_button_action = mouse.forward;
            }
        }
        snap
    }

    pub fn shutdown(&mut self) {
        let sessions = std::mem::take(&mut self.sessions);
        for session in sessions {
            session.stop();
        }
    }

    pub fn set_dock_layouts(&mut self, razer: DockLayout, satechi: DockLayout) {
        self.state.razer_dock.ports = razer;
        self.state.razer_dock.connected =
            self.state.razer_dock.ports.is_present || self.razer_dock_path.is_some();
        if self.state.razer_dock.serial_number.is_none() {
            self.state.razer_dock.serial_number = self.state.razer_dock.ports.serial_number.clone();
        }
        self.state.satechi_hub.connected = satechi.is_present;
        self.state.satechi_hub.ports = satechi;
    }

    /// Re-enumerates HID devices and queries telemetry for any connected supported accessories.
    /// Paired wireless devices whose receiver is present stay `connected = true` even while asleep,
    /// preserving their last-read battery and feature state until they wake again or are unplugged.
    pub fn refresh(&mut self) {
        let Some(api) = self.api.as_mut() else {
            return;
        };
        if let Err(err) = api.refresh_devices() {
            warn!("hidapi refresh_devices failed: {err}");
            return;
        }

        self.mx_master_path = None;
        self.mx_keyboard_path = None;
        self.logitech_g_mouse_path = None;
        self.logitech_g_keyboard_path = None;
        self.keychron_path = None;
        self.razer_dock_path = None;

        let infos: Vec<_> = api
            .device_list()
            .map(|d| {
                (
                    d.vendor_id(),
                    d.product_id(),
                    d.usage_page(),
                    d.usage(),
                    d.interface_number(),
                    d.bus_type(),
                    d.path().to_string_lossy().into_owned(),
                    d.product_string().unwrap_or_default().to_string(),
                )
            })
            .collect();

        let mut seen = ScanSeen::default();
        let mut seen_logitech_paths = HashSet::new();
        let mut seen_keychron_paths = HashSet::new();
        let mut seen_razer_paths = HashSet::new();
        let mut keychron_ble_present = false;

        for (vid, pid, usage_page, usage, iface, bus_type, path, product_name) in infos {
            match vid {
                hidpp::LOGITECH_VENDOR_ID => {
                    // On macOS/Windows, HID++ vendor collections report usage_page 0xFF00 or 0xFF43.
                    // On Linux hidraw, usage_page can be 0 unless parsed from report descriptors,
                    // so also allow usage_page == 0 (preferring interface 2 for receivers).
                    let is_hidpp_collection = usage_page == 0xFF00
                        || usage_page == 0xFF43
                        || (cfg!(target_os = "linux")
                            && usage_page == 0
                            && (iface == 2 || iface < 0));
                    if is_hidpp_collection && seen_logitech_paths.insert(path.clone()) {
                        self.probe_logitech_device(
                            pid,
                            bus_type,
                            &path,
                            &product_name,
                            &mut seen,
                        );
                    }
                }
                keychron::VENDOR_ID
                    if pid == keychron::RECEIVER_PRODUCT_ID
                        || pid == keychron::M3_MINI_PRODUCT_ID =>
                {
                    if pid == keychron::M3_MINI_PRODUCT_ID && matches!(bus_type, BusType::Bluetooth) {
                        keychron_ble_present = true;
                    }
                    let matches_usage = (usage_page == keychron::USAGE_PAGE
                        && usage == keychron::USAGE)
                        || (cfg!(target_os = "linux") && usage_page == 0);
                    if matches_usage && seen_keychron_paths.insert(path.clone()) {
                        let routed = pid == keychron::RECEIVER_PRODUCT_ID;
                        // Prefer USB cable over receiver if both are attached simultaneously.
                        if !seen.keychron || !routed {
                            self.probe_keychron(&path, routed, &mut seen);
                        }
                    }
                }
                razer_chroma::VENDOR_ID if pid == razer_chroma::DOCK_CHROMA_PRODUCT_ID => {
                    let matches_usage = (usage_page == razer_chroma::USAGE_PAGE
                        && usage == razer_chroma::USAGE)
                        || (cfg!(target_os = "linux") && usage_page == 0);
                    if matches_usage
                        && seen_razer_paths.insert(path.clone())
                        && self.razer_dock_path.is_none()
                    {
                        self.probe_razer_dock(&path, &mut seen);
                    }
                }
                _ => {}
            }
        }

        // Bluetooth fallback for Keychron M3 Mini (protocol isn't carried over BLE, but connection is visible).
        if !seen.keychron && keychron_ble_present {
            seen.keychron = true;
            self.state.keychron_m3_mini.connected = true;
            self.state.keychron_m3_mini.connection = Some(AccessoryConnection::BluetoothLe);
        }

        // Clear disconnected devices cleanly while keeping cached telemetry for still-connected sleeping devices.
        if !seen.mx_master {
            self.state.mx_master.connected = false;
            self.state.mx_master.connection = None;
            self.state.mx_master.battery_percent = None;
            self.state.mx_master.is_charging = false;
        }
        if !seen.mx_keyboard {
            self.state.mx_keyboard.connected = false;
            self.state.mx_keyboard.connection = None;
            self.state.mx_keyboard.battery_percent = None;
            self.state.mx_keyboard.is_charging = false;
        }
        if !seen.logitech_g_mouse {
            self.state.logitech_g_mouse.connected = false;
            self.state.logitech_g_mouse.connection = None;
            self.state.logitech_g_mouse.battery_percent = None;
            self.state.logitech_g_mouse.is_charging = false;
        }
        if !seen.logitech_g_keyboard {
            self.state.logitech_g_keyboard.connected = false;
            self.state.logitech_g_keyboard.connection = None;
            self.state.logitech_g_keyboard.battery_percent = None;
            self.state.logitech_g_keyboard.is_charging = false;
            self.g_keyboard_effect_indices.clear();
        }
        if !seen.keychron {
            self.state.keychron_m3_mini.connected = false;
            self.state.keychron_m3_mini.connection = None;
            self.state.keychron_m3_mini.battery_percent = None;
            self.state.keychron_m3_mini.is_charging = false;
            self.keychron_settings_block = None;
        }
        self.state.razer_dock.connected =
            seen.razer_dock_hid || self.state.razer_dock.ports.is_present;
        #[cfg(target_os = "macos")]
        self.sync_sessions();
    }

    fn session_interest(&self, path: &str) -> Option<Interest> {
        self.sessions
            .iter()
            .find(|session| session.path == path)
            .map(|session| session.interest)
    }

    fn enqueue(&self, path: &str, write: DeviceWrite) {
        let Some(session) = self.sessions.iter().find(|session| session.path == path) else {
            return;
        };
        if let Ok(mut live) = session.runtime.lock() {
            live.pending.push(write);
        }
    }

    #[cfg(target_os = "macos")]
    fn sync_sessions(&mut self) {
        let mut wanted: Vec<(String, Interest)> = Vec::new();
        let mut add = |path: &str, fill: &dyn Fn(&mut Interest)| {
            if let Some((_, interest)) = wanted.iter_mut().find(|(existing, _)| existing == path) {
                fill(interest);
            } else {
                let mut interest = Interest::default();
                fill(&mut interest);
                wanted.push((path.to_string(), interest));
            }
        };
        if let Some((path, index)) = self.mx_master_path.clone() {
            add(&path, &|interest| interest.mx = Some(index));
        }
        if let Some((path, index)) = self.mx_keyboard_path.clone() {
            add(&path, &|interest| interest.keyboard = Some(index));
        }
        if let Some((path, index)) = self.logitech_g_mouse_path.clone() {
            add(&path, &|interest| interest.g_mouse = Some(index));
        }

        let stale: Vec<usize> = self
            .sessions
            .iter()
            .enumerate()
            .filter(|(_, session)| {
                !wanted
                    .iter()
                    .any(|(path, interest)| path == &session.path && interest == &session.interest)
            })
            .map(|(index, _)| index)
            .collect();
        for index in stale.into_iter().rev() {
            self.sessions.remove(index).stop();
        }
        for (path, interest) in wanted {
            if self
                .sessions
                .iter()
                .any(|session| session.path == path && session.interest == interest)
            {
                continue;
            }
            self.start_session(path, interest);
        }
    }

    #[cfg(target_os = "macos")]
    fn start_session(&mut self, path: String, interest: Interest) {
        let Some(device) = self.open_path(&path) else {
            return;
        };
        let runtime = DeviceRuntime {
            mx: interest
                .mx
                .map(|index| MxLive::from_state(index, &self.state.mx_master)),
            keyboard: interest.keyboard.map(|index| {
                KeyboardLive::new(index, self.state.mx_keyboard.key_actions.clone())
            }),
            g_mouse: interest.g_mouse.map(|index| {
                GMouseLive::new(
                    index,
                    self.state.logitech_g_mouse.back_button_action,
                    self.state.logitech_g_mouse.forward_button_action,
                )
            }),
            pending: Vec::new(),
        };
        self.sessions
            .push(PathSession::spawn(path, interest, device, runtime));
    }

    fn open_path(&self, path: &str) -> Option<HidDevice> {
        let api = self.api.as_ref()?;
        let cpath = std::ffi::CString::new(path).ok()?;
        match api.open_path(&cpath) {
            Ok(dev) => Some(dev),
            Err(err) => {
                warn!("hidapi open_path({path}) failed: {err}");
                None
            }
        }
    }

    /// Sends a 7-byte HID++ 1.0 receiver register packet and waits for the matching reply.
    fn hidpp_short_request(&self, dev: &HidDevice, packet: &[u8; 7]) -> Option<Vec<u8>> {
        dev.write(packet).ok()?;
        let mut buf = [0u8; 64];
        for _ in 0..8 {
            let n = dev.read_timeout(&mut buf, 120).ok()?;
            if n == 0 {
                return None;
            }
            let Some(norm) = hidpp::normalize_report(&buf[..n]) else {
                continue;
            };
            if norm.len() < 5 || norm[1] != packet[1] {
                continue;
            }
            // HID++ 1.0 error (0x8F) or HID++ 2.0 error (0xFF)
            if (norm[2] == 0x8F || norm[2] == 0xFF)
                && norm[3] == packet[2]
                && norm[4] == packet[3]
            {
                return None;
            }
            let is_long_reg = packet[2] == hidpp::READ_LONG_REGISTER;
            if norm[2] == packet[2]
                && norm[3] == packet[3]
                && (!is_long_reg || norm[4] == packet[4])
            {
                return Some(norm);
            }
        }
        None
    }

    /// Sends a 20-byte HID++ 2.0 long packet and matches the reply strictly on index, feature, and function|swID.
    fn hidpp_request(&self, dev: &HidDevice, packet: &[u8; 20]) -> Option<Vec<u8>> {
        dev.write(packet).ok()?;
        let mut buf = [0u8; 64];
        for _ in 0..8 {
            let n = dev.read_timeout(&mut buf, 180).ok()?;
            if n == 0 {
                return None;
            }
            let Some(norm) = hidpp::normalize_report(&buf[..n]) else {
                continue;
            };
            if norm.len() < 5 || norm[1] != packet[1] {
                continue;
            }
            if (norm[2] == 0xFF || norm[2] == 0x8F)
                && norm[3] == packet[2]
                && norm[4] == packet[3]
            {
                return Some(norm);
            }
            if norm[2] == packet[2] && norm[3] == packet[3] {
                return Some(norm);
            }
        }
        None
    }

    /// Reads the receiver's HID++ 1.0 pairing record for `slot`. Works even while the device sleeps!
    fn query_receiver_paired_device(
        &self,
        dev: &HidDevice,
        slot: u8,
        family: ReceiverFamily,
    ) -> Option<PairedDevice> {
        match family {
            ReceiverFamily::Unifying => {
                let slot_offset = slot.checked_sub(1)?;
                let info = self.hidpp_short_request(
                    dev,
                    &hidpp::receiver_register_read_packet(0x20u8.wrapping_add(slot_offset), 0x00),
                )?;
                let name = self.hidpp_short_request(
                    dev,
                    &hidpp::receiver_register_read_packet(0x40u8.wrapping_add(slot_offset), 0x00),
                )?;
                if info.len() <= 11 {
                    return None;
                }
                hidpp::parse_paired_device(info[4 + 7], &name, 5)
            }
            ReceiverFamily::Bolt => {
                let info = self.hidpp_short_request(
                    dev,
                    &hidpp::receiver_register_read_packet(0x50u8.wrapping_add(slot), 0x00),
                )?;
                let name = self.hidpp_short_request(
                    dev,
                    &hidpp::receiver_register_read_packet(0x60u8.wrapping_add(slot), 0x01),
                )?;
                if info.len() <= 5 {
                    return None;
                }
                hidpp::parse_paired_device(info[4 + 1], &name, 6)
            }
        }
    }

    fn resolve_feature(&self, dev: &HidDevice, device_idx: u8, feature_id: u16) -> Option<u8> {
        let req = hidpp::get_feature_index_packet(device_idx, feature_id);
        let reply = self.hidpp_request(dev, &req)?;
        hidpp::parse_feature_index_reply(&reply)
    }

    /// Queries the marketing name and `DeviceKind` of an awake HID++ 2.0 device via feature `0x0005`.
    fn query_hidpp_identity(
        &self,
        dev: &HidDevice,
        device_idx: u8,
        name_feature_idx: u8,
    ) -> (Option<String>, DeviceKind) {
        let name = (|| {
            let len_pkt =
                hidpp::make_long_packet(device_idx, name_feature_idx, 0, hidpp::SOFTWARE_ID, &[]);
            let len_rep = self.hidpp_request(dev, &len_pkt)?;
            if hidpp::is_error_response(&len_rep) || len_rep.len() < 5 {
                return None;
            }
            let total_len = (len_rep[4] as usize).min(64);
            if total_len == 0 {
                return None;
            }
            let mut bytes = Vec::with_capacity(total_len);
            while bytes.len() < total_len {
                let offset = bytes.len() as u8;
                let chunk_pkt = hidpp::make_long_packet(
                    device_idx,
                    name_feature_idx,
                    1,
                    hidpp::SOFTWARE_ID,
                    &[offset],
                );
                let chunk_rep = self.hidpp_request(dev, &chunk_pkt)?;
                if hidpp::is_error_response(&chunk_rep) || chunk_rep.len() < 5 {
                    break;
                }
                let remaining = total_len - bytes.len();
                let avail = (chunk_rep.len() - 4).min(remaining);
                bytes.extend_from_slice(&chunk_rep[4..4 + avail]);
            }
            let s = String::from_utf8_lossy(&bytes)
                .trim_matches('\0')
                .trim()
                .to_string();
            (!s.is_empty()).then_some(s)
        })();

        let kind_pkt =
            hidpp::make_long_packet(device_idx, name_feature_idx, 2, hidpp::SOFTWARE_ID, &[]);
        let kind = self
            .hidpp_request(dev, &kind_pkt)
            .filter(|rep| !hidpp::is_error_response(rep) && rep.len() >= 5)
            .map(|rep| DeviceKind::from_u8(rep[4]))
            .unwrap_or(DeviceKind::Unknown);

        (name, kind)
    }

    fn probe_logitech_device(
        &mut self,
        pid: u16,
        bus_type: BusType,
        path: &str,
        product_name: &str,
        seen: &mut ScanSeen,
    ) {
        if let Some(interest) = self.session_interest(path) {
            if let Some(index) = interest.mx {
                seen.mx_master = true;
                self.mx_master_path = Some((path.to_string(), index));
            }
            if let Some(index) = interest.keyboard {
                seen.mx_keyboard = true;
                self.mx_keyboard_path = Some((path.to_string(), index));
            }
            if let Some(index) = interest.g_mouse {
                seen.logitech_g_mouse = true;
                self.logitech_g_mouse_path = Some((path.to_string(), index));
            }
            return;
        }
        let Some(dev) = self.open_path(path) else {
            return;
        };

        let is_bolt = pid == hidpp::BOLT_RECEIVER_PRODUCT_ID;
        let is_unifying = pid == hidpp::UNIFYING_RECEIVER_PRODUCT_ID;
        let is_lightspeed = hidpp::LIGHTSPEED_RECEIVER_PRODUCT_IDS.contains(&pid);
        let is_receiver = is_bolt || is_unifying || is_lightspeed;

        let connection = if is_bolt {
            AccessoryConnection::LogiBolt
        } else if is_unifying {
            AccessoryConnection::Unifying
        } else if is_lightspeed {
            AccessoryConnection::Lightspeed
        } else if matches!(bus_type, BusType::Bluetooth) {
            AccessoryConnection::BluetoothLe
        } else {
            AccessoryConnection::UsbWired
        };

        let receiver_family = if is_bolt {
            Some(ReceiverFamily::Bolt)
        } else if is_unifying || is_lightspeed {
            Some(ReceiverFamily::Unifying)
        } else {
            None
        };

        // LIGHTSPEED receivers host a single device in slot 1; Bolt/Unifying host up to 6 slots.
        let indices: Vec<u8> = if is_lightspeed {
            vec![1]
        } else if is_bolt || is_unifying {
            vec![1, 2, 3, 4, 5, 6]
        } else {
            vec![0xFF]
        };

        for dev_idx in indices {
            let paired = receiver_family
                .and_then(|family| self.query_receiver_paired_device(&dev, dev_idx, family));

            // On Bolt/Unifying multi-slot receivers, skip empty slots immediately without slow HID++ 2.0 timeouts.
            if (is_bolt || is_unifying) && paired.is_none() {
                continue;
            }

            let name_fidx = self.resolve_feature(&dev, dev_idx, hidpp::FEATURE_DEVICE_NAME);

            // If neither pairing record nor live HID++ 2.0 responded, nothing is on this slot.
            if paired.is_none() && name_fidx.is_none() {
                continue;
            }

            let (live_name, live_kind) = match name_fidx {
                Some(fidx) => self.query_hidpp_identity(&dev, dev_idx, fidx),
                None => (None, DeviceKind::Unknown),
            };

            let resolved_name = live_name
                .filter(|n| !n.is_empty())
                .or_else(|| paired.as_ref().map(|p| p.name.clone()))
                .or_else(|| {
                    let trimmed = product_name.trim();
                    if !trimmed.is_empty() && !trimmed.eq_ignore_ascii_case("USB Receiver") {
                        Some(trimmed.to_string())
                    } else {
                        None
                    }
                });

            let is_awake = name_fidx.is_some();

            // Sleeping paired device on receiver: mark connected immediately with its pairing name & connection,
            // preserving any previously queried battery / settings until it wakes.
            if !is_awake {
                if let Some(ref p) = paired {
                    let lower = p.name.to_ascii_lowercase();
                    if is_lightspeed {
                        if p.kind.is_keyboard()
                            || lower.contains("g515")
                            || lower.contains("g915")
                            || lower.contains("tkl")
                            || lower.contains("keyboard")
                        {
                            seen.logitech_g_keyboard = true;
                            self.logitech_g_keyboard_path = Some((path.to_string(), dev_idx));
                            self.state.logitech_g_keyboard.connected = true;
                            self.state.logitech_g_keyboard.name = p.name.clone();
                            self.state.logitech_g_keyboard.connection = Some(connection);
                        } else if p.kind.is_pointing_device() {
                            seen.logitech_g_mouse = true;
                            self.logitech_g_mouse_path = Some((path.to_string(), dev_idx));
                            self.state.logitech_g_mouse.connected = true;
                            self.state.logitech_g_mouse.name = p.name.clone();
                            self.state.logitech_g_mouse.connection = Some(connection);
                        }
                    } else if p.kind.is_keyboard() {
                        seen.mx_keyboard = true;
                        self.mx_keyboard_path = Some((path.to_string(), dev_idx));
                        self.state.mx_keyboard.connected = true;
                        self.state.mx_keyboard.name = p.name.clone();
                        self.state.mx_keyboard.connection = Some(connection);
                    } else if p.kind.is_pointing_device() {
                        seen.mx_master = true;
                        self.mx_master_path = Some((path.to_string(), dev_idx));
                        self.state.mx_master.connected = true;
                        self.state.mx_master.name = p.name.clone();
                        self.state.mx_master.connection = Some(connection);
                    }
                }
                continue;
            }

            // Awake HID++ 2.0 device: read battery & device-specific capabilities.
            let battery = self
                .resolve_feature(&dev, dev_idx, hidpp::FEATURE_UNIFIED_BATTERY)
                .and_then(|fidx| {
                    let pkt = hidpp::get_unified_battery_status_packet(dev_idx, fidx);
                    let rep = self.hidpp_request(&dev, &pkt)?;
                    hidpp::parse_battery_reply(&rep, fidx, true)
                })
                .or_else(|| {
                    self.resolve_feature(&dev, dev_idx, hidpp::FEATURE_BATTERY_STATUS)
                        .and_then(|fidx| {
                            let pkt = hidpp::get_legacy_battery_status_packet(dev_idx, fidx);
                            let rep = self.hidpp_request(&dev, &pkt)?;
                            hidpp::parse_battery_reply(&rep, fidx, false)
                        })
                });

            let is_keyboard_kind = live_kind.is_keyboard()
                || paired.as_ref().is_some_and(|p| p.kind.is_keyboard());
            let is_pointing_kind = live_kind.is_pointing_device()
                || paired.as_ref().is_some_and(|p| p.kind.is_pointing_device());
            let lower_name = resolved_name
                .as_deref()
                .unwrap_or("")
                .to_ascii_lowercase();

            // 1. MX Master (SmartShift / SmartShift Enhanced)
            if let Some(smart_idx) = self
                .resolve_feature(&dev, dev_idx, hidpp::FEATURE_SMART_SHIFT_ENHANCED)
                .or_else(|| self.resolve_feature(&dev, dev_idx, hidpp::FEATURE_SMART_SHIFT))
            {
                let is_enhanced = self
                    .resolve_feature(&dev, dev_idx, hidpp::FEATURE_SMART_SHIFT_ENHANCED)
                    .is_some();
                seen.mx_master = true;
                self.mx_master_path = Some((path.to_string(), dev_idx));
                self.state.mx_master.connected = true;
                if let Some(name) = resolved_name {
                    self.state.mx_master.name = name;
                }
                self.state.mx_master.connection = Some(connection);
                if let Some(b) = battery {
                    self.state.mx_master.battery_percent = Some(b.percentage);
                    self.state.mx_master.is_charging = b.is_charging;
                }
                if let Some(dpi_idx) =
                    self.resolve_feature(&dev, dev_idx, hidpp::FEATURE_ADJUSTABLE_DPI)
                {
                    let pkt = hidpp::get_sensor_dpi_packet(dev_idx, dpi_idx, 0);
                    if let Some(rep) = self.hidpp_request(&dev, &pkt) {
                        if let Some(dpi) = hidpp::parse_sensor_dpi_reply(&rep, dpi_idx) {
                            self.state.mx_master.dpi = dpi;
                        }
                    }
                }
                let ss_pkt = hidpp::get_smart_shift_packet(dev_idx, smart_idx, is_enhanced);
                if let Some(rep) = self.hidpp_request(&dev, &ss_pkt) {
                    if let Some(ss) = hidpp::parse_smart_shift_reply(&rep, smart_idx) {
                        self.state.mx_master.wheel_mode = ss.wheel_mode;
                        self.state.mx_master.smart_shift_enabled = ss.smart_shift_enabled;
                        self.state.mx_master.smart_shift_threshold = ss.threshold;
                    }
                }
                continue;
            }

            // 2. Logitech G Mouse (Extended DPI 0x2202 or pointing device on LIGHTSPEED receiver)
            let ext_dpi_idx =
                self.resolve_feature(&dev, dev_idx, logitech_g::FEATURE_EXTENDED_DPI);
            if ext_dpi_idx.is_some() || (is_lightspeed && is_pointing_kind) {
                seen.logitech_g_mouse = true;
                self.logitech_g_mouse_path = Some((path.to_string(), dev_idx));
                self.state.logitech_g_mouse.connected = true;
                if let Some(name) = resolved_name {
                    self.state.logitech_g_mouse.name = name;
                }
                self.state.logitech_g_mouse.connection = Some(connection);
                if let Some(b) = battery {
                    self.state.logitech_g_mouse.battery_percent = Some(b.percentage);
                    self.state.logitech_g_mouse.is_charging = b.is_charging;
                }
                if let Some(dpi_idx) = ext_dpi_idx {
                    let pkt = hidpp::make_long_packet(
                        dev_idx,
                        dpi_idx,
                        5,
                        hidpp::SOFTWARE_ID,
                        &[0x00],
                    );
                    if let Some(rep) = self.hidpp_request(&dev, &pkt) {
                        if let Some(s) = logitech_g::parse_sensor_dpi(&rep) {
                            self.state.logitech_g_mouse.dpi = s.dpi;
                            self.state.logitech_g_mouse.lift_off_distance = s.lift_off_distance;
                        }
                    }
                }
                if let Some(rr_idx) =
                    self.resolve_feature(&dev, dev_idx, logitech_g::FEATURE_EXTENDED_REPORT_RATE)
                {
                    let list_pkt =
                        hidpp::make_long_packet(dev_idx, rr_idx, 1, hidpp::SOFTWARE_ID, &[]);
                    if let Some(rep) = self.hidpp_request(&dev, &list_pkt) {
                        let rates = logitech_g::parse_supported_report_rates(&rep);
                        if !rates.is_empty() {
                            self.state.logitech_g_mouse.supported_report_rates = rates;
                        }
                    }
                    let get_pkt =
                        hidpp::make_long_packet(dev_idx, rr_idx, 2, hidpp::SOFTWARE_ID, &[]);
                    if let Some(rep) = self.hidpp_request(&dev, &get_pkt) {
                        if let Some(hz) = logitech_g::parse_report_rate(&rep) {
                            self.state.logitech_g_mouse.report_rate_hz = hz;
                        }
                    }
                }
                if let Some(trig_idx) =
                    self.resolve_feature(&dev, dev_idx, logitech_g::FEATURE_ANALOG_TRIGGERS)
                {
                    let get_pkt =
                        hidpp::make_long_packet(dev_idx, trig_idx, 0, hidpp::SOFTWARE_ID, &[0x00]);
                    if let Some(rep) = self.hidpp_request(&dev, &get_pkt) {
                        if let Some(t) = logitech_g::parse_trigger_settings(&rep) {
                            self.state.logitech_g_mouse.triggers = Some(t);
                        }
                    }
                }
                continue;
            }

            // 3. Logitech G Keyboard (RGB Effects 0x8071, wired G515 0xC355, or keyboard on LIGHTSPEED)
            let rgb_idx =
                self.resolve_feature(&dev, dev_idx, logitech_keyboard::FEATURE_RGB_EFFECTS);
            if rgb_idx.is_some()
                || pid == hidpp::G515_WIRED_PRODUCT_ID
                || (is_lightspeed && (is_keyboard_kind || lower_name.contains("g515")))
            {
                seen.logitech_g_keyboard = true;
                self.logitech_g_keyboard_path = Some((path.to_string(), dev_idx));
                self.state.logitech_g_keyboard.connected = true;
                if let Some(name) = resolved_name {
                    self.state.logitech_g_keyboard.name = name;
                }
                self.state.logitech_g_keyboard.connection = Some(connection);
                if let Some(b) = battery {
                    self.state.logitech_g_keyboard.battery_percent = Some(b.percentage);
                    self.state.logitech_g_keyboard.is_charging = b.is_charging;
                }
                if let Some(br_idx) = self.resolve_feature(
                    &dev,
                    dev_idx,
                    logitech_keyboard::FEATURE_BRIGHTNESS_CONTROL,
                ) {
                    let info_pkt =
                        hidpp::make_long_packet(dev_idx, br_idx, 0, hidpp::SOFTWARE_ID, &[]);
                    if let Some(rep) = self.hidpp_request(&dev, &info_pkt) {
                        if let Some(max) = logitech_keyboard::parse_brightness_level(&rep) {
                            if max > 0 {
                                self.state.logitech_g_keyboard.max_brightness = max;
                            }
                        }
                    }
                    let pkt =
                        hidpp::make_long_packet(dev_idx, br_idx, 1, hidpp::SOFTWARE_ID, &[]);
                    if let Some(rep) = self.hidpp_request(&dev, &pkt) {
                        if let Some(level) = logitech_keyboard::parse_brightness_level(&rep) {
                            self.state.logitech_g_keyboard.brightness = level;
                        }
                    }
                }
                if let Some(r_idx) = rgb_idx {
                    let zone_pkt = hidpp::make_long_packet(
                        dev_idx,
                        r_idx,
                        0,
                        hidpp::SOFTWARE_ID,
                        &[0x00, 0xFF, 0x00],
                    );
                    if let Some(zone) = self.hidpp_request(&dev, &zone_pkt) {
                        if !hidpp::is_error_response(&zone) && zone.len() > 8 {
                            let count = zone[8].min(32);
                            let mut indices = HashMap::new();
                            let mut found = Vec::new();
                            for effect_slot in 0..count {
                                let epkt = hidpp::make_long_packet(
                                    dev_idx,
                                    r_idx,
                                    0,
                                    hidpp::SOFTWARE_ID,
                                    &[0x00, effect_slot, 0x00],
                                );
                                if let Some(rep) = self.hidpp_request(&dev, &epkt) {
                                    if let Some((idx, eff)) =
                                        logitech_keyboard::parse_rgb_zone_effect(&rep)
                                    {
                                        indices.insert(eff, idx);
                                        if !found.contains(&eff) {
                                            found.push(eff);
                                        }
                                    }
                                }
                            }
                            if !found.is_empty() {
                                self.g_keyboard_effect_indices = indices;
                                self.state.logitech_g_keyboard.supported_effects = found;
                            }
                        }
                    }
                }
                if let Some(gm_idx) =
                    self.resolve_feature(&dev, dev_idx, logitech_keyboard::FEATURE_GAME_MODE)
                {
                    let pkt =
                        hidpp::make_long_packet(dev_idx, gm_idx, 2, hidpp::SOFTWARE_ID, &[]);
                    if let Some(rep) = self.hidpp_request(&dev, &pkt) {
                        if let Some(on) = logitech_keyboard::parse_game_mode_state(&rep) {
                            self.state.logitech_g_keyboard.game_mode_on = on;
                        }
                    }
                }
                continue;
            }

            // 4. MX Keyboard (Backlight 0x1982, Fn Inversion 0x40A3, or keyboard on Bolt/Unifying/BLE)
            let bl_idx =
                self.resolve_feature(&dev, dev_idx, logitech_keyboard::FEATURE_BACKLIGHT);
            let fn_idx =
                self.resolve_feature(&dev, dev_idx, logitech_keyboard::FEATURE_FN_INVERSION);
            if bl_idx.is_some()
                || fn_idx.is_some()
                || is_keyboard_kind
                || lower_name.contains("mx mechanical")
                || lower_name.contains("mx mchncl")
                || lower_name.contains("mx keys")
            {
                seen.mx_keyboard = true;
                self.mx_keyboard_path = Some((path.to_string(), dev_idx));
                self.state.mx_keyboard.connected = true;
                if let Some(name) = resolved_name {
                    self.state.mx_keyboard.name = name;
                }
                self.state.mx_keyboard.connection = Some(connection);
                if let Some(b) = battery {
                    self.state.mx_keyboard.battery_percent = Some(b.percentage);
                    self.state.mx_keyboard.is_charging = b.is_charging;
                }
                if let Some(bl_idx) = bl_idx {
                    let pkt =
                        hidpp::make_long_packet(dev_idx, bl_idx, 0, hidpp::SOFTWARE_ID, &[]);
                    if let Some(rep) = self.hidpp_request(&dev, &pkt) {
                        if let Some(cfg) = logitech_keyboard::parse_backlight_config(&rep) {
                            self.state.mx_keyboard.backlight_enabled = cfg.is_enabled;
                            self.state.mx_keyboard.automatic_brightness =
                                cfg.is_automatic_brightness();
                            self.state.mx_keyboard.battery_saving = cfg.is_battery_saving();
                            self.state.mx_keyboard.backlight_level = cfg.level;
                            let effects = cfg.supported_effects();
                            if !effects.is_empty() {
                                self.state.mx_keyboard.supported_effects = effects;
                            }
                            self.state.mx_keyboard.duration_seconds = cfg.duration_seconds();
                        }
                    }
                    let eff_pkt =
                        hidpp::make_long_packet(dev_idx, bl_idx, 2, hidpp::SOFTWARE_ID, &[]);
                    if let Some(rep) = self.hidpp_request(&dev, &eff_pkt) {
                        if let Some(eff) = logitech_keyboard::parse_backlight_effect(&rep) {
                            self.state.mx_keyboard.backlight_effect = eff;
                        }
                    }
                }
                if let Some(host_idx) =
                    self.resolve_feature(&dev, dev_idx, logitech_keyboard::FEATURE_CHANGE_HOST)
                {
                    let hpkt =
                        hidpp::make_long_packet(dev_idx, host_idx, 0, hidpp::SOFTWARE_ID, &[]);
                    if let Some(rep) = self.hidpp_request(&dev, &hpkt) {
                        self.state.mx_keyboard.current_host =
                            logitech_keyboard::parse_current_host(&rep);
                    }
                }
                if let Some(fn_idx) = fn_idx {
                    let host = self.state.mx_keyboard.current_host.unwrap_or(0);
                    let fpkt =
                        hidpp::make_long_packet(dev_idx, fn_idx, 0, hidpp::SOFTWARE_ID, &[host]);
                    if let Some(rep) = self.hidpp_request(&dev, &fpkt) {
                        if let Some(inv) = logitech_keyboard::parse_fn_inversion(&rep, host) {
                            self.state.mx_keyboard.fn_inversion = Some(inv);
                        }
                    }
                }
                continue;
            }

            // 5. Fallback for pointing devices on Bolt/Unifying/BLE without SmartShift queried
            if is_pointing_kind && !is_receiver {
                seen.mx_master = true;
                self.mx_master_path = Some((path.to_string(), dev_idx));
                self.state.mx_master.connected = true;
                if let Some(name) = resolved_name {
                    self.state.mx_master.name = name;
                }
                self.state.mx_master.connection = Some(connection);
                if let Some(b) = battery {
                    self.state.mx_master.battery_percent = Some(b.percentage);
                    self.state.mx_master.is_charging = b.is_charging;
                }
            }
        }
    }

    fn keychron_request(&self, dev: &HidDevice, pkt: &[u8; 64]) -> Option<Vec<u8>> {
        let mut with_id = [0u8; 65];
        with_id[0] = 0x00;
        with_id[1..].copy_from_slice(pkt);
        dev.write(&with_id).ok()?;
        let mut buf = [0u8; 65];
        for _ in 0..8 {
            let n = dev.read_timeout(&mut buf, 140).ok()?;
            if n == 0 {
                return None;
            }
            let slice = if n == 65 && buf[0] == 0 {
                &buf[1..65]
            } else {
                &buf[..n]
            };
            if keychron::is_reply(slice, pkt) {
                return Some(slice.to_vec());
            }
        }
        None
    }

    fn probe_keychron(&mut self, path: &str, routed: bool, seen: &mut ScanSeen) {
        let Some(dev) = self.open_path(path) else {
            return;
        };

        // On the 4K Link receiver, first ask the receiver itself whether a mouse is linked
        // (answers even while the mouse sleeps, matching KeychronM3MiniConnector.swift).
        if routed {
            let link_pkt = keychron::packet(keychron::Command::POWER, false, &[]);
            let Some(link_rep) = self.keychron_request(&dev, &link_pkt) else {
                return;
            };
            if link_rep.get(4).copied() != Some(keychron::LINKED_STATE) {
                return;
            }
            // If awake, verify it is actually an M3 Mini 4K (model ID 0x0622).
            let ver_pkt = keychron::packet(keychron::Command::VERSION, true, &[]);
            if let Some(ver_rep) = self.keychron_request(&dev, &ver_pkt) {
                if ver_rep.len() > 5 {
                    let model = u16::from_le_bytes([ver_rep[4], ver_rep[5]]);
                    if model != 0 && model != keychron::M3_MINI_MODEL_ID {
                        return;
                    }
                }
            }
        }

        seen.keychron = true;
        self.keychron_path = Some((path.to_string(), routed));
        self.state.keychron_m3_mini.connected = true;
        self.state.keychron_m3_mini.connection = Some(if routed {
            AccessoryConnection::Wireless4k
        } else {
            AccessoryConnection::UsbWired
        });

        let power_pkt = keychron::packet(keychron::Command::POWER, routed, &[]);
        let Some(power_rep) = self.keychron_request(&dev, &power_pkt) else {
            // Mouse is linked on the receiver, just asleep right now.
            return;
        };
        let Some(power) = keychron::PowerReply::parse(&power_rep) else {
            return;
        };

        self.state.keychron_m3_mini.battery_percent = power.percent;
        self.state.keychron_m3_mini.is_charging = power.is_charging;
        self.state.keychron_m3_mini.active_stage = power.active_stage;
        if let Some(max_hz) = power.max_report_rate_hz {
            self.state.keychron_m3_mini.max_report_rate_hz = max_hz;
        }

        let settings_pkt = keychron::packet(keychron::Command::READ_SETTINGS, routed, &[]);
        if let Some(rep) = self.keychron_request(&dev, &settings_pkt) {
            if let Some(block) = KeychronSettingsBlock::parse(&rep) {
                let count = block.stage_count();
                self.state.keychron_m3_mini.stage_dpis =
                    (0..count).map(|i| block.dpi(i)).collect();
                self.state.keychron_m3_mini.active_stage = block.active_stage();
                if let Some(hz) = block.report_rate_hz() {
                    self.state.keychron_m3_mini.report_rate_hz = hz;
                }
                self.state.keychron_m3_mini.lift_off_mm = block.lift_off_mm();
                self.state.keychron_m3_mini.motion_sync = block.motion_sync();
                self.state.keychron_m3_mini.angle_snapping = block.angle_snapping();
                self.keychron_settings_block = Some(block);
            }
        }
    }

    fn razer_request(&self, dev: &HidDevice, pkt: &[u8; 90]) -> Option<Vec<u8>> {
        let mut req = [0u8; 91];
        req[0] = 0x00;
        req[1..].copy_from_slice(pkt);
        dev.send_feature_report(&req).ok()?;
        for _ in 0..10 {
            std::thread::sleep(Duration::from_millis(12));
            let mut rep = [0u8; 91];
            rep[0] = 0x00;
            let n = dev.get_feature_report(&mut rep).ok()?;
            let body = if n >= 91 { &rep[1..91] } else { &rep[..n] };
            match razer_chroma::status_of(body, pkt) {
                Some(ReplyStatus::Success) => return Some(body.to_vec()),
                Some(ReplyStatus::Busy) | None => continue,
                _ => return None,
            }
        }
        None
    }

    fn probe_razer_dock(&mut self, path: &str, seen: &mut ScanSeen) {
        let Some(dev) = self.open_path(path) else {
            return;
        };
        seen.razer_dock_hid = true;
        self.razer_dock_path = Some(path.to_string());
        self.state.razer_dock.connected = true;

        if let Some(rep) = self.razer_request(
            &dev,
            &razer_chroma::packet(razer_chroma::Command::FIRMWARE, &[]),
        ) {
            self.state.razer_dock.firmware = razer_chroma::parse_firmware(&rep);
        }
        if let Some(rep) = self.razer_request(
            &dev,
            &razer_chroma::packet(razer_chroma::Command::SERIAL, &[]),
        ) {
            self.state.razer_dock.serial_number = razer_chroma::parse_serial(&rep);
        }
        if let Some(rep) = self.razer_request(&dev, &razer_chroma::get_brightness_packet()) {
            self.state.razer_dock.brightness = razer_chroma::parse_brightness(&rep);
        }
        if let Some(rep) = self.razer_request(&dev, &razer_chroma::get_effect_packet()) {
            let prev = self.state.razer_dock.lighting.clone().unwrap_or_default();
            self.state.razer_dock.lighting = razer_chroma::parse_lighting(&rep, &prev);
        }
    }

    // MARK: - Device Mutators

    pub fn set_mx_master_dpi(&mut self, dpi: u16) {
        let clamped = hidpp::clamp_mx_dpi(dpi, 200, 8000, 50);
        self.state.mx_master.dpi = clamped;
        if let Some((ref path, dev_idx)) = self.mx_master_path.clone() {
            if self.session_interest(path).is_some() {
                let path = path.clone();
                if let Some(session) = self.sessions.iter().find(|session| session.path == path) {
                    if let Ok(mut live) = session.runtime.lock() {
                        if let Some(mx) = live.mx.as_mut() {
                            mx.dpi = clamped;
                        }
                        live.pending.push(DeviceWrite::MxDpi(clamped));
                    }
                }
                accessory_store::save(&self.state);
                return;
            }
            if let Some(dev) = self.open_path(path) {
                if let Some(fidx) =
                    self.resolve_feature(&dev, dev_idx, hidpp::FEATURE_ADJUSTABLE_DPI)
                {
                    let pkt = hidpp::set_sensor_dpi_packet(dev_idx, fidx, clamped, 0);
                    let _ = self.hidpp_request(&dev, &pkt);
                }
            }
        }
    }

    pub fn set_mx_master_smart_shift(
        &mut self,
        wheel_mode: MxWheelMode,
        smart_shift_enabled: bool,
        threshold: u8,
    ) {
        let clamped = hidpp::clamp_smart_shift_threshold(threshold);
        self.state.mx_master.wheel_mode = wheel_mode;
        self.state.mx_master.smart_shift_enabled = smart_shift_enabled;
        self.state.mx_master.smart_shift_threshold = clamped;
        if let Some((ref path, dev_idx)) = self.mx_master_path.clone() {
            if self.session_interest(path).is_some() {
                let path = path.clone();
                if let Some(session) = self.sessions.iter().find(|session| session.path == path) {
                    if let Ok(mut live) = session.runtime.lock() {
                        if let Some(mx) = live.mx.as_mut() {
                            mx.wheel_mode = wheel_mode;
                            mx.smart_shift_enabled = smart_shift_enabled;
                            mx.smart_shift_threshold = clamped;
                        }
                        live.pending.push(DeviceWrite::MxSmartShift {
                            mode: wheel_mode,
                            enabled: smart_shift_enabled,
                            threshold: clamped,
                        });
                    }
                }
                accessory_store::save(&self.state);
                return;
            }
            if let Some(dev) = self.open_path(path) {
                let enhanced =
                    self.resolve_feature(&dev, dev_idx, hidpp::FEATURE_SMART_SHIFT_ENHANCED);
                let (fidx, is_enhanced) = match enhanced {
                    Some(idx) => (Some(idx), true),
                    None => (
                        self.resolve_feature(&dev, dev_idx, hidpp::FEATURE_SMART_SHIFT),
                        false,
                    ),
                };
                if let Some(fidx) = fidx {
                    let pkt = hidpp::set_smart_shift_packet(
                        dev_idx,
                        fidx,
                        is_enhanced,
                        wheel_mode,
                        smart_shift_enabled,
                        clamped,
                    );
                    let _ = self.hidpp_request(&dev, &pkt);
                }
            }
        }
    }

    pub fn set_mx_master_options(&mut self, opts: MxMasterOptions) {
        let mx = &mut self.state.mx_master;
        mx.standard_vertical_scroll = opts.standard_vertical_scroll;
        mx.smooth_scrolling = opts.smooth_scrolling;
        mx.scroll_speed_multiplier = opts.scroll_speed_multiplier.clamp(0.5, 3.0);
        mx.thumbwheel_action = opts.thumbwheel_action;
        mx.invert_thumbwheel = opts.invert_thumbwheel;
        mx.middle_button_action = opts.middle_button_action;
        mx.back_button_action = opts.back_button_action;
        mx.forward_button_action = opts.forward_button_action;
        mx.gesture_button_action = opts.gesture_button_action;
        mx.mode_shift_button_action = opts.mode_shift_button_action;
        mx.haptic_panel_button_action = opts.haptic_panel_button_action;
        mx.gestures_enabled = opts.gestures_enabled;
        mx.gesture_up_action = opts.gesture_up_action;
        mx.gesture_down_action = opts.gesture_down_action;
        mx.gesture_left_action = opts.gesture_left_action;
        mx.gesture_right_action = opts.gesture_right_action;
        mx.saves_to_mouse = opts.saves_to_mouse;
        if let Some((path, _)) = self.mx_master_path.clone() {
            if let Some(session) = self.sessions.iter().find(|session| session.path == path) {
                if let Ok(mut live) = session.runtime.lock() {
                    if let Some(mx) = live.mx.as_mut() {
                        mx.apply_options(opts);
                    }
                }
            }
        }
        accessory_store::save(&self.state);
    }

    pub fn set_logitech_g_dpi(&mut self, dpi: u16) {
        let clamped = dpi.clamp(
            self.state.logitech_g_mouse.min_dpi,
            self.state.logitech_g_mouse.max_dpi,
        );
        self.state.logitech_g_mouse.dpi = clamped;
        let lod = self.state.logitech_g_mouse.lift_off_distance;
        if let Some((ref path, dev_idx)) = self.logitech_g_mouse_path.clone() {
            if self.session_interest(path).is_some() {
                self.enqueue(path, DeviceWrite::GDpi { dpi: clamped, lod });
                accessory_store::save(&self.state);
                return;
            }
            if let Some(dev) = self.open_path(path) {
                if let Some(fidx) =
                    self.resolve_feature(&dev, dev_idx, logitech_g::FEATURE_EXTENDED_DPI)
                {
                    let params = logitech_g::set_sensor_dpi_params(clamped, lod);
                    let pkt = hidpp::make_long_packet(
                        dev_idx,
                        fidx,
                        6,
                        hidpp::SOFTWARE_ID,
                        &params,
                    );
                    let _ = self.hidpp_request(&dev, &pkt);
                }
            }
        }
    }

    pub fn set_logitech_g_report_rate(&mut self, hz: u16) {
        let Some(idx) = logitech_g::report_rate_index(hz) else {
            return;
        };
        self.state.logitech_g_mouse.report_rate_hz = hz;
        if let Some((ref path, dev_idx)) = self.logitech_g_mouse_path.clone() {
            if self.session_interest(path).is_some() {
                self.enqueue(path, DeviceWrite::GReportRate(hz));
                return;
            }
            if let Some(dev) = self.open_path(path) {
                if let Some(fidx) =
                    self.resolve_feature(&dev, dev_idx, logitech_g::FEATURE_EXTENDED_REPORT_RATE)
                {
                    let pkt = hidpp::make_long_packet(
                        dev_idx,
                        fidx,
                        3,
                        hidpp::SOFTWARE_ID,
                        &[idx],
                    );
                    let _ = self.hidpp_request(&dev, &pkt);
                }
            }
        }
    }

    pub fn set_logitech_g_triggers(&mut self, triggers: TriggerSettings) {
        self.state.logitech_g_mouse.triggers = Some(triggers);
        if let Some((ref path, dev_idx)) = self.logitech_g_mouse_path.clone() {
            if self.session_interest(path).is_some() {
                self.enqueue(path, DeviceWrite::GTriggers(triggers));
                return;
            }
            if let Some(dev) = self.open_path(path) {
                if let Some(fidx) =
                    self.resolve_feature(&dev, dev_idx, logitech_g::FEATURE_ANALOG_TRIGGERS)
                {
                    for key in [0u8, 1u8] {
                        let params = logitech_g::set_trigger_params(key, triggers);
                        let pkt = hidpp::make_long_packet(
                            dev_idx,
                            fidx,
                            1,
                            hidpp::SOFTWARE_ID,
                            &params,
                        );
                        let _ = self.hidpp_request(&dev, &pkt);
                    }
                }
            }
        }
    }

    pub fn set_logitech_g_options(
        &mut self,
        back_button: AccessoryButtonAction,
        forward_button: AccessoryButtonAction,
        saves_to_onboard_profile: bool,
    ) {
        self.state.logitech_g_mouse.back_button_action = back_button;
        self.state.logitech_g_mouse.forward_button_action = forward_button;
        self.state.logitech_g_mouse.saves_to_onboard_profile = saves_to_onboard_profile;
        if let Some((path, _)) = self.logitech_g_mouse_path.clone() {
            if let Some(session) = self.sessions.iter().find(|session| session.path == path) {
                if let Ok(mut live) = session.runtime.lock() {
                    if let Some(mouse) = live.g_mouse.as_mut() {
                        mouse.back = back_button;
                        mouse.forward = forward_button;
                        mouse.dirty = true;
                    }
                }
            }
        }
        accessory_store::save(&self.state);
    }

    pub fn set_mx_keyboard_backlight(
        &mut self,
        enabled: bool,
        auto_brightness: bool,
        battery_saving: bool,
        level: u8,
        duration_seconds: u16,
        effect: BacklightEffect,
    ) {
        self.state.mx_keyboard.backlight_enabled = enabled;
        self.state.mx_keyboard.automatic_brightness = auto_brightness;
        self.state.mx_keyboard.battery_saving = battery_saving;
        self.state.mx_keyboard.backlight_level = level.clamp(1, 7);
        self.state.mx_keyboard.duration_seconds = duration_seconds.clamp(5, 600);
        self.state.mx_keyboard.backlight_effect = effect;
        if let Some((ref path, dev_idx)) = self.mx_keyboard_path.clone() {
            if self.session_interest(path).is_some() {
                self.enqueue(
                    path,
                    DeviceWrite::KeyboardBacklight {
                        enabled,
                        auto_brightness,
                        battery_saving,
                        level: self.state.mx_keyboard.backlight_level,
                        duration_seconds: self.state.mx_keyboard.duration_seconds,
                        effect,
                    },
                );
                return;
            }
            if let Some(dev) = self.open_path(path) {
                if let Some(fidx) =
                    self.resolve_feature(&dev, dev_idx, logitech_keyboard::FEATURE_BACKLIGHT)
                {
                    let mut cfg = BacklightConfig {
                        is_enabled: enabled,
                        options: 0,
                        supported: 0xFF,
                        effects: 0x007F,
                        level: self.state.mx_keyboard.backlight_level,
                        duration_away: (self.state.mx_keyboard.duration_seconds / 5).max(1),
                        duration_typing: (self.state.mx_keyboard.duration_seconds / 5).max(1),
                        duration_charging: (self.state.mx_keyboard.duration_seconds / 5).max(1),
                    };
                    cfg.set_automatic_brightness(auto_brightness);
                    cfg.set_battery_saving(battery_saving);
                    let params = logitech_keyboard::set_backlight_config_params(&cfg);
                    let pkt = hidpp::make_long_packet(
                        dev_idx,
                        fidx,
                        1,
                        hidpp::SOFTWARE_ID,
                        &params,
                    );
                    let _ = self.hidpp_request(&dev, &pkt);
                    let eff_pkt = hidpp::make_long_packet(
                        dev_idx,
                        fidx,
                        3,
                        hidpp::SOFTWARE_ID,
                        &[effect as u8],
                    );
                    let _ = self.hidpp_request(&dev, &eff_pkt);
                }
            }
        }
    }

    pub fn set_mx_keyboard_fn_inversion(&mut self, standard_fn: bool) {
        self.state.mx_keyboard.fn_inversion = Some(standard_fn);
        if let Some((ref path, dev_idx)) = self.mx_keyboard_path.clone() {
            if self.session_interest(path).is_some() {
                let host = self.state.mx_keyboard.current_host.unwrap_or(0);
                self.enqueue(path, DeviceWrite::KeyboardFn { standard: standard_fn, host });
                accessory_store::save(&self.state);
                return;
            }
            if let Some(dev) = self.open_path(path) {
                if let Some(fidx) =
                    self.resolve_feature(&dev, dev_idx, logitech_keyboard::FEATURE_FN_INVERSION)
                {
                    let host = self.state.mx_keyboard.current_host.unwrap_or(0);
                    let pkt = hidpp::make_long_packet(
                        dev_idx,
                        fidx,
                        1,
                        hidpp::SOFTWARE_ID,
                        &[host, u8::from(standard_fn)],
                    );
                    let _ = self.hidpp_request(&dev, &pkt);
                }
            }
        }
    }

    pub fn set_mx_keyboard_key_action(&mut self, position: u8, action: AccessoryButtonAction) {
        if action == AccessoryButtonAction::SystemDefault {
            self.state.mx_keyboard.key_actions.remove(&position);
        } else {
            self.state.mx_keyboard.key_actions.insert(position, action);
        }
        if let Some((path, _)) = self.mx_keyboard_path.clone() {
            if let Some(session) = self.sessions.iter().find(|session| session.path == path) {
                if let Ok(mut live) = session.runtime.lock() {
                    if let Some(keyboard) = live.keyboard.as_mut() {
                        if action == AccessoryButtonAction::SystemDefault {
                            keyboard.actions.remove(&position);
                        } else {
                            keyboard.actions.insert(position, action);
                        }
                        keyboard.dirty = true;
                    }
                }
            }
        }
        accessory_store::save(&self.state);
    }

    pub fn set_g_keyboard_lighting(&mut self, brightness: u16, lighting: RgbLighting) {
        self.state.logitech_g_keyboard.brightness = brightness;
        self.state.logitech_g_keyboard.lighting = lighting;
        if let Some((ref path, dev_idx)) = self.logitech_g_keyboard_path.clone() {
            if let Some(dev) = self.open_path(path) {
                if let Some(br_idx) = self.resolve_feature(
                    &dev,
                    dev_idx,
                    logitech_keyboard::FEATURE_BRIGHTNESS_CONTROL,
                ) {
                    let params = logitech_keyboard::set_brightness_params(brightness);
                    let pkt = hidpp::make_long_packet(
                        dev_idx,
                        br_idx,
                        2,
                        hidpp::SOFTWARE_ID,
                        &params,
                    );
                    let _ = self.hidpp_request(&dev, &pkt);
                }
                if let Some(rgb_idx) =
                    self.resolve_feature(&dev, dev_idx, logitech_keyboard::FEATURE_RGB_EFFECTS)
                {
                    // Take host lighting control (same as G HUB & LogitechG515Connector.swift)
                    let host_ctrl = hidpp::make_long_packet(
                        dev_idx,
                        rgb_idx,
                        5,
                        hidpp::SOFTWARE_ID,
                        &[0x01, 0x03, 0x05],
                    );
                    let _ = self.hidpp_request(&dev, &host_ctrl);

                    let effect_index = self
                        .g_keyboard_effect_indices
                        .get(&lighting.effect)
                        .copied()
                        .unwrap_or(0);
                    let params =
                        logitech_keyboard::set_rgb_effect_params(0, effect_index, &lighting);
                    let pkt = hidpp::make_long_packet(
                        dev_idx,
                        rgb_idx,
                        1,
                        hidpp::SOFTWARE_ID,
                        &params,
                    );
                    let _ = self.hidpp_request(&dev, &pkt);
                }
            }
        }
    }

    pub fn set_keychron_settings(
        &mut self,
        active_stage: u8,
        dpi: u16,
        report_rate_hz: u16,
        lift_off_mm: u8,
        motion_sync: bool,
        angle_snapping: bool,
    ) {
        let clamped_dpi = keychron::clamp_dpi(dpi);
        self.state.keychron_m3_mini.active_stage = active_stage;
        if let Some(slot) = self
            .state
            .keychron_m3_mini
            .stage_dpis
            .get_mut(active_stage as usize)
        {
            *slot = clamped_dpi;
        }
        self.state.keychron_m3_mini.report_rate_hz = report_rate_hz;
        self.state.keychron_m3_mini.lift_off_mm = lift_off_mm.clamp(1, 2);
        self.state.keychron_m3_mini.motion_sync = motion_sync;
        self.state.keychron_m3_mini.angle_snapping = angle_snapping;

        if let (Some((path, routed)), Some(mut block)) = (
            self.keychron_path.clone(),
            self.keychron_settings_block.clone(),
        ) {
            block.set_active_stage(active_stage);
            block.set_dpi(active_stage as usize, clamped_dpi);
            block.set_report_rate_hz(report_rate_hz);
            block.set_lift_off_mm(lift_off_mm);
            block.set_motion_sync(motion_sync);
            block.set_angle_snapping(angle_snapping);
            self.keychron_settings_block = Some(block.clone());

            if let Some(dev) = self.open_path(&path) {
                let write_pkt =
                    keychron::packet(keychron::Command::WRITE_SETTINGS, routed, &block.raw);
                let _ = self.keychron_request(&dev, &write_pkt);
                let save_pkt = keychron::packet(keychron::Command::SAVE, routed, &[]);
                let _ = self.keychron_request(&dev, &save_pkt);
            }
        }
    }

    pub fn set_keychron_side_buttons(
        &mut self,
        back_button: AccessoryButtonAction,
        forward_button: AccessoryButtonAction,
    ) {
        self.state.keychron_m3_mini.back_button_action = back_button;
        self.state.keychron_m3_mini.forward_button_action = forward_button;
        #[cfg(target_os = "macos")]
        if let Some((path, routed)) = self.keychron_path.clone() {
            if let Some(dev) = self.open_path(&path) {
                for (back, action) in [(true, back_button), (false, forward_button)] {
                    let Some(assignment) = crate::input_perform::keychron_assignment(action, back) else {
                        continue;
                    };
                    let slot: u8 = if back { 3 } else { 4 };
                    let mut payload = vec![slot];
                    payload.extend_from_slice(&assignment);
                    let packet = keychron::packet(keychron::Command::WRITE_BUTTON, routed, &payload);
                    let _ = self.keychron_request(&dev, &packet);
                }
                let save = keychron::packet(keychron::Command::SAVE, routed, &[]);
                let _ = self.keychron_request(&dev, &save);
            }
        }
        accessory_store::save(&self.state);
    }

    pub fn set_razer_dock_lighting(
        &mut self,
        brightness: Option<u8>,
        lighting: Option<RazerLighting>,
    ) {
        if let Some(b) = brightness {
            self.state.razer_dock.brightness = Some(b);
        }
        if let Some(ref l) = lighting {
            self.state.razer_dock.lighting = Some(l.clone());
        }
        if let Some(ref path) = self.razer_dock_path.clone() {
            if let Some(dev) = self.open_path(path) {
                if let Some(b) = brightness {
                    let pkt = razer_chroma::set_brightness_packet(b);
                    let _ = self.razer_request(&dev, &pkt);
                }
                if let Some(ref l) = lighting {
                    if let Some(pkt) = razer_chroma::set_effect_packet(l) {
                        let _ = self.razer_request(&dev, &pkt);
                    }
                }
            }
        } else {
            debug!("Razer dock lighting updated in state (hardware not attached)");
        }
    }
}

impl Drop for HidManager {
    fn drop(&mut self) {
        self.shutdown();
    }
}

pub fn default_accessories_snapshot() -> AccessoriesSnapshot {
    AccessoriesSnapshot {
        mx_master: MxMasterState {
            connected: false,
            name: "MX Master".into(),
            connection: None,
            battery_percent: None,
            is_charging: false,
            dpi: 1600,
            min_dpi: 200,
            max_dpi: 8000,
            dpi_step: 50,
            wheel_mode: MxWheelMode::Ratchet,
            smart_shift_enabled: true,
            smart_shift_threshold: 25,
            standard_vertical_scroll: true,
            smooth_scrolling: true,
            scroll_speed_multiplier: 1.25,
            thumbwheel_action: MxThumbwheelAction::HorizontalScroll,
            invert_thumbwheel: false,
            middle_button_action: AccessoryButtonAction::SystemDefault,
            back_button_action: AccessoryButtonAction::NavigateBack,
            forward_button_action: AccessoryButtonAction::NavigateForward,
            gesture_button_action: AccessoryButtonAction::MissionControl,
            mode_shift_button_action: AccessoryButtonAction::SystemDefault,
            haptic_panel_button_action: AccessoryButtonAction::SystemDefault,
            gestures_enabled: true,
            gesture_up_action: AccessoryButtonAction::MissionControl,
            gesture_down_action: AccessoryButtonAction::AppExpose,
            gesture_left_action: AccessoryButtonAction::SpaceLeft,
            gesture_right_action: AccessoryButtonAction::SpaceRight,
            saves_to_mouse: true,
        },
        mx_keyboard: MxKeyboardState {
            connected: false,
            name: "MX Keyboard".into(),
            connection: None,
            battery_percent: None,
            is_charging: false,
            backlight_enabled: true,
            automatic_brightness: true,
            battery_saving: false,
            backlight_level: 3,
            backlight_effect: BacklightEffect::StaticLight,
            supported_effects: BacklightEffect::ALL.to_vec(),
            duration_seconds: 60,
            fn_inversion: Some(false),
            current_host: None,
            key_actions: HashMap::new(),
        },
        logitech_g_mouse: LogitechGMouseState {
            connected: false,
            name: "G2 Superstrike".into(),
            connection: None,
            battery_percent: None,
            is_charging: false,
            dpi: 1600,
            min_dpi: 100,
            max_dpi: 44_000,
            report_rate_hz: 1000,
            supported_report_rates: vec![125, 250, 500, 1000, 2000, 4000, 8000],
            lift_off_distance: 1,
            triggers: Some(TriggerSettings {
                actuation: 5,
                rapid_trigger: 0,
                haptics: 2,
            }),
            back_button_action: AccessoryButtonAction::SystemDefault,
            forward_button_action: AccessoryButtonAction::SystemDefault,
            saves_to_onboard_profile: true,
        },
        logitech_g_keyboard: LogitechGKeyboardState {
            connected: false,
            name: "Logitech G515 TKL".into(),
            connection: None,
            battery_percent: None,
            is_charging: false,
            brightness: 100,
            max_brightness: 100,
            lighting: default_rgb_lighting(),
            supported_effects: vec![
                RgbEffect::Off,
                RgbEffect::Fixed,
                RgbEffect::Breathing,
                RgbEffect::ColorCycle,
                RgbEffect::ColorWave,
            ],
            game_mode_on: false,
        },
        keychron_m3_mini: KeychronM3MiniState {
            connected: false,
            name: "Keychron M3 Mini 4K".into(),
            connection: None,
            battery_percent: None,
            is_charging: false,
            active_stage: 2,
            stage_dpis: vec![400, 800, 1600, 3200, 6400],
            report_rate_hz: 1000,
            max_report_rate_hz: 4000,
            lift_off_mm: 1,
            motion_sync: true,
            angle_snapping: false,
            back_button_action: AccessoryButtonAction::NavigateBack,
            forward_button_action: AccessoryButtonAction::NavigateForward,
        },
        razer_dock: RazerDockState {
            connected: false,
            name: "Razer Thunderbolt 4 Dock Chroma".into(),
            firmware: None,
            serial_number: None,
            brightness: Some(255),
            lighting: Some(RazerLighting::default()),
            ports: DockLayout::empty_razer(),
        },
        satechi_hub: SatechiHubState {
            connected: false,
            name: "Satechi Thunderbolt 4 Slim Hub Pro".into(),
            ports: DockLayout::empty_satechi(),
        },
    }
}
