//! One read loop per HID path. Command writes and the loop share that handle, so a scan cannot
//! steal a report the loop is waiting on.

use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use aeron_protocols::hidpp::{self, MxWheelMode, SOFTWARE_ID};
use aeron_protocols::logitech_g::{self, TriggerSettings, SIDE_BUTTON_BACK, SIDE_BUTTON_FORWARD};
use aeron_protocols::logitech_keyboard::{self, BacklightConfig, BacklightEffect};
use aeron_protocols::models::AccessoryButtonAction;
use hidapi::HidDevice;
use tracing::debug;

use crate::hid_input::{
    button_diversions, diverts_thumbwheel, diverts_wheel, GMouseLive, InputEffect, KeyboardLive,
    MxLive,
};
use crate::host_actions;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Interest {
    pub mx: Option<u8>,
    pub keyboard: Option<u8>,
    pub g_mouse: Option<u8>,
}

pub enum DeviceWrite {
    Reapply,
    MxDpi(u16),
    MxSmartShift {
        mode: MxWheelMode,
        enabled: bool,
        threshold: u8,
    },
    KeyboardBacklight {
        enabled: bool,
        auto_brightness: bool,
        battery_saving: bool,
        level: u8,
        duration_seconds: u16,
        effect: BacklightEffect,
    },
    KeyboardFn {
        standard: bool,
        host: u8,
    },
    GDpi { dpi: u16, lod: u8 },
    GReportRate(u16),
    GTriggers(TriggerSettings),
}

pub struct DeviceRuntime {
    pub mx: Option<MxLive>,
    pub keyboard: Option<KeyboardLive>,
    pub g_mouse: Option<GMouseLive>,
    pub pending: Vec<DeviceWrite>,
}

pub struct PathSession {
    pub path: String,
    pub interest: Interest,
    #[allow(dead_code)]
    pub device: Arc<Mutex<HidDevice>>,
    pub runtime: Arc<Mutex<DeviceRuntime>>,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl PathSession {
    pub fn spawn(path: String, interest: Interest, device: HidDevice, runtime: DeviceRuntime) -> Self {
        let device = Arc::new(Mutex::new(device));
        let runtime = Arc::new(Mutex::new(runtime));
        let stop = Arc::new(AtomicBool::new(false));
        let thread_device = Arc::clone(&device);
        let thread_runtime = Arc::clone(&runtime);
        let thread_stop = Arc::clone(&stop);
        let thread_path = path.clone();
        let thread = thread::Builder::new()
            .name(format!("aeron-hid-{}", interest_label(&interest)))
            .spawn(move || reader(thread_path, thread_device, thread_runtime, thread_stop))
            .ok();
        Self {
            path,
            interest,
            device,
            runtime,
            stop,
            thread,
        }
    }

    pub fn stop(mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

fn interest_label(interest: &Interest) -> String {
    let mut parts = Vec::new();
    if interest.mx.is_some() {
        parts.push("mx");
    }
    if interest.keyboard.is_some() {
        parts.push("keys");
    }
    if interest.g_mouse.is_some() {
        parts.push("g");
    }
    if parts.is_empty() {
        "hid".into()
    } else {
        parts.join("-")
    }
}

fn reader(
    path: String,
    device: Arc<Mutex<HidDevice>>,
    runtime: Arc<Mutex<DeviceRuntime>>,
    stop: Arc<AtomicBool>,
) {
    debug!("HID input loop started for {path}");
    {
        let Ok(dev) = device.lock() else {
            return;
        };
        let Ok(mut live) = runtime.lock() else {
            return;
        };
        discover(&dev, &mut live);
        apply(&dev, &mut live);
    }
    let mut last_battery = Instant::now();
    let mut last_discover = Instant::now();
    while !stop.load(Ordering::Relaxed) {
        let needs_discover = runtime.lock().ok().is_some_and(|live| {
            live.mx.as_ref().is_some_and(|mx| mx.features.reprog.is_none() && mx.features.wheel.is_none())
                || live.keyboard.as_ref().is_some_and(|keyboard| keyboard.reprog.is_none() && !keyboard.actions.is_empty())
                || live.g_mouse.as_ref().is_some_and(|mouse| mouse.spy.is_none() && mouse.wants_spy())
        });
        if needs_discover && last_discover.elapsed() > Duration::from_secs(5) {
            last_discover = Instant::now();
            if let (Ok(dev), Ok(mut live)) = (device.lock(), runtime.lock()) {
                discover(&dev, &mut live);
                apply(&dev, &mut live);
            }
        }
        let report = {
            let Ok(dev) = device.lock() else {
                break;
            };
            let mut buf = [0u8; 64];
            match dev.read_timeout(&mut buf, 8) {
                Ok(0) | Err(_) => None,
                Ok(n) => Some(buf[..n].to_vec()),
            }
        };
        if stop.load(Ordering::Relaxed) {
            break;
        }
        let now_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_millis() as u64)
            .unwrap_or(0);
        let mut effects = Vec::new();
        let mut toggle_wheel = false;
        let mut writes = Vec::new();
        {
            let Ok(mut live) = runtime.lock() else {
                break;
            };
            let sign = scroll_sign(
                live.mx
                    .as_ref()
                    .is_some_and(|mx| mx.options.standard_vertical_scroll),
            );
            if let Some(report) = report.as_deref() {
                if let Some(mx) = live.mx.as_mut() {
                    for effect in mx.handle_report(report, now_ms, sign) {
                        if matches!(effect, InputEffect::ToggleWheel) {
                            toggle_wheel = true;
                        } else {
                            effects.push(effect);
                        }
                    }
                }
                if let Some(keyboard) = live.keyboard.as_mut() {
                    effects.extend(keyboard.handle_report(report));
                }
                if let Some(mouse) = live.g_mouse.as_mut() {
                    effects.extend(mouse.handle_report(report));
                }
            }
            if let Some(mx) = live.mx.as_mut() {
                if let Some(effect) = mx.step_smooth() {
                    effects.push(effect);
                }
            }
            if live.mx.as_ref().is_some_and(|mx| mx.dirty)
                || live.keyboard.as_ref().is_some_and(|keyboard| keyboard.dirty)
                || live.g_mouse.as_ref().is_some_and(|mouse| mouse.dirty)
            {
                writes.push(DeviceWrite::Reapply);
            }
            writes.append(&mut live.pending);
            if toggle_wheel {
                if let Some(mx) = live.mx.as_mut() {
                    let mode = mx.toggle_wheel();
                    writes.push(DeviceWrite::MxSmartShift {
                        mode,
                        enabled: mx.smart_shift_enabled,
                        threshold: mx.smart_shift_threshold,
                    });
                }
            }
        }
        if !writes.is_empty() {
            let Ok(dev) = device.lock() else {
                break;
            };
            let Ok(mut live) = runtime.lock() else {
                break;
            };
            for write in writes {
                perform_write(&dev, &mut live, write);
            }
        }
        dispatch(&effects);
        if last_battery.elapsed() > Duration::from_secs(20) {
            last_battery = Instant::now();
            if let (Ok(dev), Ok(mut live)) = (device.lock(), runtime.lock()) {
                poll_battery(&dev, &mut live);
            }
        }
    }
    if let (Ok(dev), Ok(mut live)) = (device.lock(), runtime.lock()) {
        release(&dev, &mut live);
    }
    debug!("HID input loop stopped for {path}");
}

fn scroll_sign(standard: bool) -> f64 {
    #[cfg(target_os = "macos")]
    {
        crate::input_perform::scroll_sign(standard)
    }
    #[cfg(not(target_os = "macos"))]
    {
        if standard { 1.0 } else { -1.0 }
    }
}

fn dispatch(effects: &[InputEffect]) {
    for effect in effects {
        match effect {
            InputEffect::Host(token) => host_actions::emit(token),
            InputEffect::ToggleWheel => {}
            other => {
                #[cfg(target_os = "macos")]
                crate::input_perform::perform(other);
                #[cfg(not(target_os = "macos"))]
                let _ = other;
            }
        }
    }
}

fn discover(dev: &HidDevice, live: &mut DeviceRuntime) {
    if let Some(mx) = live.mx.as_mut() {
        let index = mx.device_index;
        mx.features.reprog = resolve(dev, index, hidpp::FEATURE_REPROG_CONTROLS_V4);
        mx.features.wheel = resolve(dev, index, hidpp::FEATURE_HI_RES_WHEEL);
        mx.features.thumb = resolve(dev, index, hidpp::FEATURE_THUMBWHEEL);
        mx.features.dpi = resolve(dev, index, hidpp::FEATURE_ADJUSTABLE_DPI);
        mx.features.battery_unified = resolve(dev, index, hidpp::FEATURE_UNIFIED_BATTERY);
        mx.features.battery_legacy = resolve(dev, index, hidpp::FEATURE_BATTERY_STATUS);
        if let Some(enhanced) = resolve(dev, index, hidpp::FEATURE_SMART_SHIFT_ENHANCED) {
            mx.features.smart = Some(enhanced);
            mx.features.smart_enhanced = true;
        } else {
            mx.features.smart = resolve(dev, index, hidpp::FEATURE_SMART_SHIFT);
            mx.features.smart_enhanced = false;
        }
    }
    if let Some(keyboard) = live.keyboard.as_mut() {
        let index = keyboard.device_index;
        keyboard.reprog = resolve(dev, index, hidpp::FEATURE_REPROG_CONTROLS_V4);
        if let Some(feature) = keyboard.reprog {
            keyboard.keys = read_key_controls(dev, index, feature);
        }
    }
    if let Some(mouse) = live.g_mouse.as_mut() {
        let index = mouse.device_index;
        mouse.spy = resolve(dev, index, logitech_g::FEATURE_MOUSE_BUTTON_SPY);
        if let Some(feature) = mouse.spy {
            let packet = hidpp::make_long_packet(index, feature, 0, SOFTWARE_ID, &[]);
            if let Some(reply) = exchange(dev, &packet) {
                if reply.len() > 4 {
                    mouse.button_count = reply[4];
                }
            }
        }
    }
}

fn read_key_controls(dev: &HidDevice, device_index: u8, feature: u8) -> Vec<hidpp::KeyControl> {
    let count_packet = hidpp::make_long_packet(device_index, feature, 0, SOFTWARE_ID, &[]);
    let Some(count_reply) = exchange(dev, &count_packet) else {
        return Vec::new();
    };
    if count_reply.len() < 5 || hidpp::is_error_response(&count_reply) {
        return Vec::new();
    }
    let mut keys = Vec::new();
    for control_index in 0..count_reply[4] {
        let packet = hidpp::make_long_packet(device_index, feature, 1, SOFTWARE_ID, &[control_index]);
        let Some(reply) = exchange(dev, &packet) else {
            continue;
        };
        if let Some(control) = hidpp::parse_key_control(&reply) {
            if (1..=12).contains(&control.f_key_position) {
                keys.push(control);
            }
        }
    }
    keys
}

fn perform_write(dev: &HidDevice, live: &mut DeviceRuntime, write: DeviceWrite) {
    match write {
        DeviceWrite::Reapply => apply(dev, live),
        DeviceWrite::MxDpi(dpi) => {
            let Some(mx) = live.mx.as_ref() else {
                return;
            };
            let Some(feature) = mx.features.dpi else {
                return;
            };
            let packet = hidpp::set_sensor_dpi_packet(mx.device_index, feature, dpi, 0);
            let _ = exchange(dev, &packet);
        }
        DeviceWrite::MxSmartShift {
            mode,
            enabled,
            threshold,
        } => {
            let Some(mx) = live.mx.as_ref() else {
                return;
            };
            let Some(feature) = mx.features.smart else {
                return;
            };
            let packet = hidpp::set_smart_shift_packet(
                mx.device_index,
                feature,
                mx.features.smart_enhanced,
                mode,
                enabled,
                threshold,
            );
            let _ = exchange(dev, &packet);
        }
        DeviceWrite::KeyboardBacklight {
            enabled,
            auto_brightness,
            battery_saving,
            level,
            duration_seconds,
            effect,
        } => {
            let Some(keyboard) = live.keyboard.as_ref() else {
                return;
            };
            let Some(feature) = resolve(
                dev,
                keyboard.device_index,
                logitech_keyboard::FEATURE_BACKLIGHT,
            ) else {
                return;
            };
            let mut config = BacklightConfig {
                is_enabled: enabled,
                options: 0,
                supported: 0xFF,
                effects: 0x007F,
                level,
                duration_away: (duration_seconds / 5).max(1),
                duration_typing: (duration_seconds / 5).max(1),
                duration_charging: (duration_seconds / 5).max(1),
            };
            config.set_automatic_brightness(auto_brightness);
            config.set_battery_saving(battery_saving);
            let params = logitech_keyboard::set_backlight_config_params(&config);
            let packet = hidpp::make_long_packet(keyboard.device_index, feature, 1, SOFTWARE_ID, &params);
            let _ = exchange(dev, &packet);
            let effect_packet =
                hidpp::make_long_packet(keyboard.device_index, feature, 3, SOFTWARE_ID, &[effect as u8]);
            let _ = exchange(dev, &effect_packet);
        }
        DeviceWrite::KeyboardFn { standard, host } => {
            let Some(keyboard) = live.keyboard.as_ref() else {
                return;
            };
            let Some(feature) = resolve(
                dev,
                keyboard.device_index,
                logitech_keyboard::FEATURE_FN_INVERSION,
            ) else {
                return;
            };
            let packet = hidpp::make_long_packet(
                keyboard.device_index,
                feature,
                1,
                SOFTWARE_ID,
                &[host, u8::from(standard)],
            );
            let _ = exchange(dev, &packet);
        }
        DeviceWrite::GDpi { dpi, lod } => {
            let Some(mouse) = live.g_mouse.as_ref() else {
                return;
            };
            let Some(feature) = resolve(dev, mouse.device_index, logitech_g::FEATURE_EXTENDED_DPI) else {
                return;
            };
            let params = logitech_g::set_sensor_dpi_params(dpi, lod);
            let packet = hidpp::make_long_packet(mouse.device_index, feature, 6, SOFTWARE_ID, &params);
            let _ = exchange(dev, &packet);
        }
        DeviceWrite::GReportRate(hz) => {
            let Some(mouse) = live.g_mouse.as_ref() else {
                return;
            };
            let Some(index) = logitech_g::report_rate_index(hz) else {
                return;
            };
            let Some(feature) = resolve(
                dev,
                mouse.device_index,
                logitech_g::FEATURE_EXTENDED_REPORT_RATE,
            ) else {
                return;
            };
            let packet = hidpp::make_long_packet(mouse.device_index, feature, 3, SOFTWARE_ID, &[index]);
            let _ = exchange(dev, &packet);
        }
        DeviceWrite::GTriggers(triggers) => {
            let Some(mouse) = live.g_mouse.as_ref() else {
                return;
            };
            let Some(feature) = resolve(dev, mouse.device_index, logitech_g::FEATURE_ANALOG_TRIGGERS)
            else {
                return;
            };
            for key in [0u8, 1u8] {
                let params = logitech_g::set_trigger_params(key, triggers);
                let packet =
                    hidpp::make_long_packet(mouse.device_index, feature, 1, SOFTWARE_ID, &params);
                let _ = exchange(dev, &packet);
            }
        }
    }
}

fn apply(dev: &HidDevice, live: &mut DeviceRuntime) {
    if let Some(mx) = live.mx.as_mut() {
        if mx.dirty {
            apply_mx(dev, mx);
            mx.dirty = false;
        }
    }
    if let Some(keyboard) = live.keyboard.as_mut() {
        if keyboard.dirty {
            apply_keyboard(dev, keyboard, false);
            keyboard.dirty = false;
        }
    }
    if let Some(mouse) = live.g_mouse.as_mut() {
        if mouse.dirty {
            apply_g_mouse(dev, mouse, false);
            mouse.dirty = false;
        }
    }
}

fn release(dev: &HidDevice, live: &mut DeviceRuntime) {
    if let Some(mx) = live.mx.as_mut() {
        release_mx(dev, mx);
    }
    if let Some(keyboard) = live.keyboard.as_mut() {
        apply_keyboard(dev, keyboard, true);
    }
    if let Some(mouse) = live.g_mouse.as_mut() {
        apply_g_mouse(dev, mouse, true);
    }
}

fn apply_mx(dev: &HidDevice, mx: &MxLive) {
    let index = mx.device_index;
    if let Some(feature) = mx.features.wheel {
        let packet = hidpp::set_wheel_mode_packet(index, feature, diverts_wheel(&mx.options));
        let _ = exchange(dev, &packet);
    }
    if let Some(feature) = mx.features.thumb {
        let packet = hidpp::set_thumbwheel_reporting_packet(
            index,
            feature,
            diverts_thumbwheel(&mx.options),
        );
        let _ = exchange(dev, &packet);
    }
    if let Some(feature) = mx.features.reprog {
        for control in button_diversions(&mx.options) {
            send_control(dev, index, feature, control.cid, control.diverted, control.raw_xy);
        }
    }
}

fn release_mx(dev: &HidDevice, mx: &MxLive) {
    let index = mx.device_index;
    if let Some(feature) = mx.features.wheel {
        let _ = exchange(dev, &hidpp::set_wheel_mode_packet(index, feature, false));
    }
    if let Some(feature) = mx.features.thumb {
        let _ = exchange(dev, &hidpp::set_thumbwheel_reporting_packet(index, feature, false));
    }
    if let Some(feature) = mx.features.reprog {
        for control in button_diversions(&mx.options) {
            send_control(dev, index, feature, control.cid, false, false);
        }
    }
}

fn send_control(dev: &HidDevice, device_index: u8, feature: u8, cid: u16, diverted: bool, raw_xy: bool) {
    let packet = hidpp::set_control_reporting_packet(device_index, feature, cid, diverted, raw_xy);
    let reply = exchange(dev, &packet);
    if diverted && raw_xy && reply.as_deref().is_some_and(hidpp::is_error_response) {
        let fallback = hidpp::set_control_reporting_packet(device_index, feature, cid, true, false);
        let _ = exchange(dev, &fallback);
    }
}

fn apply_keyboard(dev: &HidDevice, keyboard: &KeyboardLive, release_all: bool) {
    let Some(feature) = keyboard.reprog else {
        return;
    };
    for key in &keyboard.keys {
        if !key.divertable {
            continue;
        }
        let diverted = !release_all && keyboard.actions.contains_key(&key.f_key_position);
        let packet = hidpp::set_control_reporting_packet(
            keyboard.device_index,
            feature,
            key.cid,
            diverted,
            false,
        );
        let _ = exchange(dev, &packet);
    }
}

fn apply_g_mouse(dev: &HidDevice, mouse: &mut GMouseLive, release_all: bool) {
    let Some(feature) = mouse.spy else {
        return;
    };
    let count = mouse.button_count.max(1) as usize;
    let mut silenced = HashSet::new();
    if !release_all {
        if mouse.back != AccessoryButtonAction::SystemDefault {
            silenced.insert(SIDE_BUTTON_BACK);
        }
        if mouse.forward != AccessoryButtonAction::SystemDefault {
            silenced.insert(SIDE_BUTTON_FORWARD);
        }
    }
    if silenced.is_empty() {
        if mouse.spying {
            let map = logitech_g::button_map(count, &silenced);
            let packet = hidpp::make_long_packet(mouse.device_index, feature, 4, SOFTWARE_ID, &map);
            let _ = exchange(dev, &packet);
            let stop = hidpp::make_long_packet(mouse.device_index, feature, 2, SOFTWARE_ID, &[]);
            let _ = exchange(dev, &stop);
            mouse.spying = false;
        }
        return;
    }
    if !mouse.spying {
        let start = hidpp::make_long_packet(mouse.device_index, feature, 1, SOFTWARE_ID, &[]);
        mouse.spying = exchange(dev, &start).is_some_and(|reply| !hidpp::is_error_response(&reply));
    }
    if mouse.spying {
        let map = logitech_g::button_map(count, &silenced);
        let packet = hidpp::make_long_packet(mouse.device_index, feature, 4, SOFTWARE_ID, &map);
        let _ = exchange(dev, &packet);
    }
}

fn poll_battery(dev: &HidDevice, live: &mut DeviceRuntime) {
    let Some(mx) = live.mx.as_mut() else {
        return;
    };
    let index = mx.device_index;
    if let Some(feature) = mx.features.battery_unified {
        let packet = hidpp::get_unified_battery_status_packet(index, feature);
        if let Some(reply) = exchange(dev, &packet) {
            if let Some(reading) = hidpp::parse_battery_reply(&reply, feature, true) {
                mx.battery_percent = Some(reading.percentage);
                mx.is_charging = reading.is_charging;
                return;
            }
        }
    }
    if let Some(feature) = mx.features.battery_legacy {
        let packet = hidpp::get_legacy_battery_status_packet(index, feature);
        if let Some(reply) = exchange(dev, &packet) {
            if let Some(reading) = hidpp::parse_battery_reply(&reply, feature, false) {
                mx.battery_percent = Some(reading.percentage);
                mx.is_charging = reading.is_charging;
            }
        }
    }
}

fn resolve(dev: &HidDevice, device_index: u8, feature_id: u16) -> Option<u8> {
    let packet = hidpp::get_feature_index_packet(device_index, feature_id);
    let reply = exchange(dev, &packet)?;
    hidpp::parse_feature_index_reply(&reply)
}

fn exchange(dev: &HidDevice, packet: &[u8; 20]) -> Option<Vec<u8>> {
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
        if (norm[2] == 0xFF || norm[2] == 0x8F) && norm[3] == packet[2] && norm[4] == packet[3] {
            return Some(norm);
        }
        if norm[2] == packet[2] && norm[3] == packet[3] {
            return Some(norm);
        }
    }
    None
}
