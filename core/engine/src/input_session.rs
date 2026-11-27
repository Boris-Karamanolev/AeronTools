//! One read loop per HID path. Command writes and the loop share that handle, so a scan cannot
//! steal a report the loop is waiting on.

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use aeron_protocols::hidpp::{
    self, ControlInfo, MxWheelMode, SOFTWARE_ID, CID_BACK_BUTTON, CID_FORWARD_BUTTON,
    CID_GESTURE_THUMB_BUTTON, CID_HAPTIC_PANEL_BUTTON, CID_MIDDLE_BUTTON, CID_MODE_SHIFT_BUTTON,
};
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
        let _ = dev.write(&RECEIVER_NOTIFICATIONS);
        discover(&dev, &mut live);
        absorb_telemetry(&dev, &mut live);
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
                absorb_telemetry(&dev, &mut live);
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
        let mut relink = false;
        {
            let Ok(mut live) = runtime.lock() else {
                break;
            };
            if let Some((index, up)) = report.as_deref().and_then(hidpp::receiver_link_event) {
                // Only the device that linked: a keyboard waking on the same Bolt receiver must not
                // re-run the mouse's diversions and profile read.
                if let Some(mx) = live.mx.as_mut().filter(|mx| mx.device_index == index) {
                    mx.dirty |= up;
                    relink |= up;
                }
                if let Some(keyboard) = live.keyboard.as_mut().filter(|k| k.device_index == index) {
                    keyboard.dirty |= up;
                    relink |= up;
                }
                if let Some(mouse) = live.g_mouse.as_mut().filter(|m| m.device_index == index) {
                    // A power-cycled mouse has dropped spy reporting and its button map either way.
                    mouse.link_changed();
                    if up {
                        mouse.dirty = true;
                        mouse.profile_dirty = true;
                        relink = true;
                    }
                }
            }
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
        if relink {
            if let (Ok(dev), Ok(mut live)) = (device.lock(), runtime.lock()) {
                discover(&dev, &mut live);
                absorb_telemetry(&dev, &mut live);
                apply(&dev, &mut live);
            }
        }
        dispatch(&effects);
        if last_battery.elapsed() > Duration::from_secs(20) {
            last_battery = Instant::now();
            if let (Ok(dev), Ok(mut live)) = (device.lock(), runtime.lock()) {
                poll_battery(&dev, &mut live);
                absorb_telemetry(&dev, &mut live);
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

const RECEIVER_NOTIFICATIONS: [u8; 7] = [0x10, 0xFF, 0x80, 0x00, 0x00, 0x01, 0x00];

fn gained(before: Option<u8>, after: Option<u8>) -> bool {
    before.is_none() && after.is_some()
}

fn discover(dev: &HidDevice, live: &mut DeviceRuntime) {
    if let Some(mx) = live.mx.as_mut() {
        let index = mx.device_index;
        let before = mx.features;
        mx.features.reprog = resolve(dev, index, hidpp::FEATURE_REPROG_CONTROLS_V4);
        mx.features.wheel = resolve(dev, index, hidpp::FEATURE_HI_RES_WHEEL);
        mx.features.thumb = resolve(dev, index, hidpp::FEATURE_THUMBWHEEL);
        mx.features.dpi = resolve(dev, index, hidpp::FEATURE_ADJUSTABLE_DPI);
        mx.features.battery_unified = resolve(dev, index, hidpp::FEATURE_UNIFIED_BATTERY);
        mx.features.battery_legacy = resolve(dev, index, hidpp::FEATURE_BATTERY_STATUS);
        if let Some(enhanced) = resolve(dev, index, hidpp::FEATURE_SMART_SHIFT_ENHANCED) {
            mx.features.smart = Some(enhanced);
            mx.features.smart_enhanced = true;
        } else if mx.features.smart.is_none() || before.smart_enhanced {
            mx.features.smart = resolve(dev, index, hidpp::FEATURE_SMART_SHIFT);
            mx.features.smart_enhanced = false;
        }
        if gained(before.reprog, mx.features.reprog)
            || gained(before.wheel, mx.features.wheel)
            || gained(before.thumb, mx.features.thumb)
            || gained(before.dpi, mx.features.dpi)
            || gained(before.smart, mx.features.smart)
            || gained(before.battery_unified, mx.features.battery_unified)
            || gained(before.battery_legacy, mx.features.battery_legacy)
        {
            mx.dirty = true;
        }
    }
    if let Some(keyboard) = live.keyboard.as_mut() {
        let index = keyboard.device_index;
        let before_reprog = keyboard.reprog;
        let before_unified = keyboard.battery_unified;
        let before_legacy = keyboard.battery_legacy;
        keyboard.reprog = resolve(dev, index, hidpp::FEATURE_REPROG_CONTROLS_V4);
        keyboard.battery_unified = resolve(dev, index, hidpp::FEATURE_UNIFIED_BATTERY);
        keyboard.battery_legacy = resolve(dev, index, hidpp::FEATURE_BATTERY_STATUS);
        if let Some(feature) = keyboard.reprog {
            if keyboard.keys.is_empty() {
                keyboard.keys = read_key_controls(dev, index, feature);
            }
        }
        if gained(before_reprog, keyboard.reprog)
            || gained(before_unified, keyboard.battery_unified)
            || gained(before_legacy, keyboard.battery_legacy)
        {
            keyboard.dirty = true;
        }
    }
    if let Some(mouse) = live.g_mouse.as_mut() {
        let index = mouse.device_index;
        let before_spy = mouse.spy;
        let before_unified = mouse.battery_unified;
        let before_legacy = mouse.battery_legacy;
        mouse.spy = resolve(dev, index, logitech_g::FEATURE_MOUSE_BUTTON_SPY);
        mouse.battery_unified = resolve(dev, index, hidpp::FEATURE_UNIFIED_BATTERY);
        mouse.battery_legacy = resolve(dev, index, hidpp::FEATURE_BATTERY_STATUS);
        if let Some(feature) = mouse.spy {
            let packet = hidpp::make_long_packet(index, feature, 0, SOFTWARE_ID, &[]);
            if let Some(reply) = exchange(dev, &packet) {
                if reply.len() > 4 {
                    mouse.button_count = reply[4];
                }
            }
        }
        if gained(before_spy, mouse.spy)
            || gained(before_unified, mouse.battery_unified)
            || gained(before_legacy, mouse.battery_legacy)
        {
            mouse.dirty = true;
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
            let Some(keyboard) = live.keyboard.as_mut() else {
                return;
            };
            let Some(feature) = resolve(
                dev,
                keyboard.device_index,
                logitech_keyboard::FEATURE_BACKLIGHT,
            ) else {
                return;
            };
            if keyboard.backlight.is_none() {
                read_backlight(dev, keyboard, feature);
            }
            let mut config = keyboard.backlight.unwrap_or(BacklightConfig {
                is_enabled: enabled,
                options: 0,
                supported: 0xFF,
                effects: 0x007F,
                level,
                duration_away: (duration_seconds / 5).max(1),
                duration_typing: (duration_seconds / 5).max(1),
                duration_charging: (duration_seconds / 5).max(1),
            });
            config.is_enabled = enabled;
            config.level = level;
            config.set_automatic_brightness(auto_brightness);
            config.set_battery_saving(battery_saving);
            config.set_duration_seconds(duration_seconds);
            let params = logitech_keyboard::set_backlight_config_params(&config);
            let packet = hidpp::make_long_packet(keyboard.device_index, feature, 1, SOFTWARE_ID, &params);
            let _ = exchange(dev, &packet);
            let effect_packet =
                hidpp::make_long_packet(keyboard.device_index, feature, 3, SOFTWARE_ID, &[effect as u8]);
            let _ = exchange(dev, &effect_packet);
            keyboard.backlight = Some(config);
            keyboard.backlight_effect = Some(effect);
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
            let Some(mouse) = live.g_mouse.as_mut() else {
                return;
            };
            mouse.dpi = dpi;
            mouse.lift_off = lod;
            mouse.reapply_dpi = true;
            mouse.profile_dirty = true;
            set_host_mode(dev, mouse.device_index, true);
            let Some(feature) = resolve(dev, mouse.device_index, logitech_g::FEATURE_EXTENDED_DPI) else {
                return;
            };
            let params = logitech_g::set_sensor_dpi_params(dpi, lod);
            let packet = hidpp::make_long_packet(mouse.device_index, feature, 6, SOFTWARE_ID, &params);
            let _ = exchange(dev, &packet);
        }
        DeviceWrite::GReportRate(hz) => {
            let Some(mouse) = live.g_mouse.as_mut() else {
                return;
            };
            mouse.report_rate_hz = hz;
            mouse.reapply_rate = true;
            mouse.profile_dirty = true;
            set_host_mode(dev, mouse.device_index, true);
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
            let Some(mouse) = live.g_mouse.as_mut() else {
                return;
            };
            mouse.triggers = triggers;
            mouse.profile_dirty = true;
            set_host_mode(dev, mouse.device_index, true);
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
        save_mx_remaps(dev, mx);
    }
    if mx.reapply_dpi {
        if let Some(feature) = mx.features.dpi {
            let packet = hidpp::set_sensor_dpi_packet(index, feature, mx.dpi, 0);
            let _ = exchange(dev, &packet);
        }
    }
    if mx.reapply_smart_shift {
        if let Some(feature) = mx.features.smart {
            let packet = hidpp::set_smart_shift_packet(
                index,
                feature,
                mx.features.smart_enhanced,
                mx.wheel_mode,
                mx.smart_shift_enabled,
                mx.smart_shift_threshold,
            );
            let _ = exchange(dev, &packet);
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
    // `exchange` returns None for an error reply as well as a timeout; fall back on either, like the old app.
    if diverted && raw_xy && reply.is_none() {
        let fallback = hidpp::set_control_reporting_packet(device_index, feature, cid, true, false);
        let _ = exchange(dev, &fallback);
    }
}

fn apply_keyboard(dev: &HidDevice, keyboard: &mut KeyboardLive, release_all: bool) {
    let Some(feature) = keyboard.reprog else {
        return;
    };
    let wanted: Vec<(u16, bool)> = keyboard
        .keys
        .iter()
        .filter(|key| key.divertable)
        .map(|key| {
            let diverted = !release_all && keyboard.actions.contains_key(&key.f_key_position);
            (key.cid, diverted)
        })
        .collect();
    for (cid, diverted) in wanted {
        if !diverted && !keyboard.diverted.contains(&cid) {
            continue;
        }
        let packet = hidpp::set_control_reporting_packet(
            keyboard.device_index,
            feature,
            cid,
            diverted,
            false,
        );
        if exchange(dev, &packet).is_some() {
            if diverted {
                keyboard.diverted.insert(cid);
            } else {
                keyboard.diverted.remove(&cid);
            }
        }
    }
}

fn apply_g_mouse(dev: &HidDevice, mouse: &mut GMouseLive, release_all: bool) {
    if release_all {
        release_g_buttons(dev, mouse, true);
        set_host_mode(dev, mouse.device_index, false);
        return;
    }
    set_host_mode(dev, mouse.device_index, true);
    write_g_triggers(dev, mouse.device_index, mouse.triggers);
    if mouse.reapply_dpi {
        if let Some(feature) = resolve(dev, mouse.device_index, logitech_g::FEATURE_EXTENDED_DPI) {
            let params = logitech_g::set_sensor_dpi_params(mouse.dpi, mouse.lift_off);
            let packet = hidpp::make_long_packet(mouse.device_index, feature, 6, SOFTWARE_ID, &params);
            let _ = exchange(dev, &packet);
        }
    }
    if mouse.reapply_rate {
        if let Some(rate_index) = logitech_g::report_rate_index(mouse.report_rate_hz) {
            if let Some(feature) = resolve(dev, mouse.device_index, logitech_g::FEATURE_EXTENDED_REPORT_RATE) {
                let packet = hidpp::make_long_packet(mouse.device_index, feature, 3, SOFTWARE_ID, &[rate_index]);
                let _ = exchange(dev, &packet);
            }
        }
    }
    release_g_buttons(dev, mouse, false);
    if mouse.saves_profile && mouse.profile_dirty {
        if save_g_profile(dev, mouse) {
            mouse.profile_dirty = false;
        }
    }
}

fn release_g_buttons(dev: &HidDevice, mouse: &mut GMouseLive, hand_back: bool) {
    let Some(feature) = mouse.spy else {
        return;
    };
    let count = mouse.button_count.max(1) as usize;
    let mut silenced = HashSet::new();
    if !hand_back {
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
    if let Some(mx) = live.mx.as_mut() {
        read_battery(
            dev,
            mx.device_index,
            mx.features.battery_unified,
            mx.features.battery_legacy,
            &mut mx.battery_percent,
            &mut mx.is_charging,
        );
    }
    if let Some(keyboard) = live.keyboard.as_mut() {
        read_battery(
            dev,
            keyboard.device_index,
            keyboard.battery_unified,
            keyboard.battery_legacy,
            &mut keyboard.battery_percent,
            &mut keyboard.is_charging,
        );
    }
    if let Some(mouse) = live.g_mouse.as_mut() {
        read_battery(
            dev,
            mouse.device_index,
            mouse.battery_unified,
            mouse.battery_legacy,
            &mut mouse.battery_percent,
            &mut mouse.is_charging,
        );
    }
}

fn read_battery(
    dev: &HidDevice,
    index: u8,
    unified: Option<u8>,
    legacy: Option<u8>,
    percent: &mut Option<u8>,
    charging: &mut bool,
) {
    if let Some(feature) = unified {
        let packet = hidpp::get_unified_battery_status_packet(index, feature);
        if let Some(reply) = exchange(dev, &packet) {
            if let Some(reading) = hidpp::parse_battery_reply(&reply, feature, true) {
                *percent = Some(reading.percentage);
                *charging = reading.is_charging;
                return;
            }
        }
    }
    if let Some(feature) = legacy {
        let packet = hidpp::get_legacy_battery_status_packet(index, feature);
        if let Some(reply) = exchange(dev, &packet) {
            if let Some(reading) = hidpp::parse_battery_reply(&reply, feature, false) {
                *percent = Some(reading.percentage);
                *charging = reading.is_charging;
            }
        }
    }
}

fn absorb_telemetry(dev: &HidDevice, live: &mut DeviceRuntime) {
    poll_battery(dev, live);
    if let Some(mx) = live.mx.as_mut() {
        let index = mx.device_index;
        if !mx.reapply_dpi {
            if let Some(feature) = mx.features.dpi {
                let packet = hidpp::get_sensor_dpi_packet(index, feature, 0);
                if let Some(reply) = exchange(dev, &packet) {
                    if let Some(dpi) = hidpp::parse_sensor_dpi_reply(&reply, feature) {
                        mx.dpi = dpi;
                    }
                }
            }
        }
        if !mx.reapply_smart_shift {
            if let Some(feature) = mx.features.smart {
                let packet = hidpp::get_smart_shift_packet(index, feature, mx.features.smart_enhanced);
                if let Some(reply) = exchange(dev, &packet) {
                    if let Some(reading) = hidpp::parse_smart_shift_reply(&reply, feature) {
                        mx.wheel_mode = reading.wheel_mode;
                        mx.smart_shift_enabled = reading.smart_shift_enabled;
                        mx.smart_shift_threshold = reading.threshold;
                    }
                }
            }
        }
    }
    if let Some(keyboard) = live.keyboard.as_mut() {
        let index = keyboard.device_index;
        if let Some(feature) = resolve(dev, index, logitech_keyboard::FEATURE_BACKLIGHT) {
            read_backlight(dev, keyboard, feature);
        }
        if let Some(feature) = resolve(dev, index, logitech_keyboard::FEATURE_CHANGE_HOST) {
            let packet = hidpp::make_long_packet(index, feature, 0, SOFTWARE_ID, &[]);
            if let Some(reply) = exchange(dev, &packet) {
                keyboard.current_host = logitech_keyboard::parse_current_host(&reply);
            }
        }
        if let Some(feature) = resolve(dev, index, logitech_keyboard::FEATURE_FN_INVERSION) {
            let host = keyboard.current_host.unwrap_or(0);
            let packet = hidpp::make_long_packet(index, feature, 0, SOFTWARE_ID, &[host]);
            if let Some(reply) = exchange(dev, &packet) {
                keyboard.fn_standard = logitech_keyboard::parse_fn_inversion(&reply, host);
            }
        }
    }
    if let Some(mouse) = live.g_mouse.as_mut() {
        let index = mouse.device_index;
        if !mouse.reapply_dpi {
            if let Some(feature) = resolve(dev, index, logitech_g::FEATURE_EXTENDED_DPI) {
                let packet = hidpp::make_long_packet(index, feature, 5, SOFTWARE_ID, &[0x00]);
                if let Some(reply) = exchange(dev, &packet) {
                    if let Some(sensor) = logitech_g::parse_sensor_dpi(&reply) {
                        mouse.dpi = sensor.dpi;
                        mouse.lift_off = sensor.lift_off_distance;
                    }
                }
            }
        }
        if !mouse.reapply_rate {
            if let Some(feature) = resolve(dev, index, logitech_g::FEATURE_EXTENDED_REPORT_RATE) {
                let packet = hidpp::make_long_packet(index, feature, 2, SOFTWARE_ID, &[]);
                if let Some(reply) = exchange(dev, &packet) {
                    if let Some(hz) = logitech_g::parse_report_rate(&reply) {
                        mouse.report_rate_hz = hz;
                    }
                }
            }
        }
    }
}

fn read_backlight(dev: &HidDevice, keyboard: &mut KeyboardLive, feature: u8) {
    let packet = hidpp::make_long_packet(keyboard.device_index, feature, 0, SOFTWARE_ID, &[]);
    if let Some(reply) = exchange(dev, &packet) {
        keyboard.backlight = logitech_keyboard::parse_backlight_config(&reply);
    }
    let effect = hidpp::make_long_packet(keyboard.device_index, feature, 2, SOFTWARE_ID, &[]);
    if let Some(reply) = exchange(dev, &effect) {
        keyboard.backlight_effect = logitech_keyboard::parse_backlight_effect(&reply);
    }
}

fn set_host_mode(dev: &HidDevice, device_index: u8, host: bool) {
    let Some(feature) = resolve(dev, device_index, logitech_g::FEATURE_ONBOARD_PROFILES) else {
        return;
    };
    let mode = if host { 0x02 } else { 0x01 };
    let packet = hidpp::make_long_packet(device_index, feature, 1, SOFTWARE_ID, &[mode]);
    let _ = exchange(dev, &packet);
}

fn write_g_triggers(dev: &HidDevice, device_index: u8, triggers: TriggerSettings) {
    let Some(feature) = resolve(dev, device_index, logitech_g::FEATURE_ANALOG_TRIGGERS) else {
        return;
    };
    for key in [0u8, 1u8] {
        let params = logitech_g::set_trigger_params(key, triggers);
        let packet = hidpp::make_long_packet(device_index, feature, 1, SOFTWARE_ID, &params);
        let _ = exchange(dev, &packet);
    }
}

fn native_cid(action: AccessoryButtonAction) -> Option<u16> {
    match action {
        AccessoryButtonAction::NavigateBack => Some(CID_BACK_BUTTON),
        AccessoryButtonAction::NavigateForward => Some(CID_FORWARD_BUTTON),
        AccessoryButtonAction::ToggleWheelMode => Some(CID_MODE_SHIFT_BUTTON),
        AccessoryButtonAction::SystemDefault
        | AccessoryButtonAction::MissionControl
        | AccessoryButtonAction::AppExpose
        | AccessoryButtonAction::ShowDesktop
        | AccessoryButtonAction::Launchpad
        | AccessoryButtonAction::SpaceLeft
        | AccessoryButtonAction::SpaceRight
        | AccessoryButtonAction::PlayPause
        | AccessoryButtonAction::MutePointerDisplay
        | AccessoryButtonAction::ToggleBuiltinScreen
        | AccessoryButtonAction::ToggleCaffeine
        | AccessoryButtonAction::Copy
        | AccessoryButtonAction::Paste => None,
    }
}

fn save_mx_remaps(dev: &HidDevice, mx: &MxLive) {
    let Some(feature) = mx.features.reprog else {
        return;
    };
    let infos = read_control_infos(dev, mx.device_index, feature);
    if infos.is_empty() {
        return;
    }
    let buttons = [
        (CID_MIDDLE_BUTTON, mx.options.middle_button_action),
        (CID_BACK_BUTTON, mx.options.back_button_action),
        (CID_FORWARD_BUTTON, mx.options.forward_button_action),
        (CID_GESTURE_THUMB_BUTTON, mx.options.gesture_button_action),
        (CID_MODE_SHIFT_BUTTON, mx.options.mode_shift_button_action),
        (CID_HAPTIC_PANEL_BUTTON, mx.options.haptic_panel_button_action),
    ];
    for (cid, action) in buttons {
        let Some(info) = infos.get(&cid).copied() else {
            continue;
        };
        let mut target = cid;
        if mx.options.saves_to_mouse {
            if let Some(native) = native_cid(action) {
                if let Some(native_info) = infos.get(&native).copied() {
                    if info.can_remap_to(native_info) {
                        target = native;
                    }
                }
            }
        }
        let get = hidpp::make_long_packet(
            mx.device_index,
            feature,
            2,
            SOFTWARE_ID,
            &[(cid >> 8) as u8, (cid & 0xFF) as u8],
        );
        let Some(reply) = exchange(dev, &get) else {
            continue;
        };
        let Some(current) = hidpp::parse_control_remap(&reply, cid) else {
            continue;
        };
        if current != target {
            let packet = hidpp::set_control_remap_packet(mx.device_index, feature, cid, target);
            let _ = exchange(dev, &packet);
        }
    }
}

fn read_control_infos(dev: &HidDevice, index: u8, feature: u8) -> HashMap<u16, ControlInfo> {
    let mut infos = HashMap::new();
    let count_packet = hidpp::make_long_packet(index, feature, 0, SOFTWARE_ID, &[]);
    let Some(count_reply) = exchange(dev, &count_packet) else {
        return infos;
    };
    if count_reply.len() < 5 {
        return infos;
    }
    for slot in 0..count_reply[4] {
        let packet = hidpp::make_long_packet(index, feature, 1, SOFTWARE_ID, &[slot]);
        let Some(reply) = exchange(dev, &packet) else {
            continue;
        };
        if let Some(info) = hidpp::parse_control_info(&reply) {
            infos.insert(info.cid, info);
        }
    }
    infos
}

fn g_binding(action: AccessoryButtonAction, button: usize) -> [u8; 4] {
    #[cfg(target_os = "macos")]
    if action != AccessoryButtonAction::SystemDefault {
        if let Some((usage, modifiers)) = crate::input_perform::hid_key_binding(action) {
            return logitech_g::key_binding(usage, modifiers);
        }
    }
    logitech_g::mouse_button_binding(button)
}

fn save_g_profile(dev: &HidDevice, mouse: &GMouseLive) -> bool {
    let Some(feature) = resolve(dev, mouse.device_index, logitech_g::FEATURE_ONBOARD_PROFILES) else {
        return false;
    };
    let info_packet = hidpp::make_long_packet(mouse.device_index, feature, 0, SOFTWARE_ID, &[]);
    let Some(info_reply) = exchange(dev, &info_packet) else {
        return false;
    };
    let Some(info) = logitech_g::parse_onboard_profiles_info(&info_reply) else {
        return false;
    };
    if info.profile_format != logitech_g::SUPPORTED_PROFILE_FORMAT {
        return false;
    }
    let mut directory = Vec::new();
    for offset in [0usize, 16] {
        let params = logitech_g::read_memory_params(0, offset);
        let packet = hidpp::make_long_packet(mouse.device_index, feature, 5, SOFTWARE_ID, &params);
        let Some(reply) = exchange(dev, &packet) else {
            return false;
        };
        if reply.len() < 20 {
            return false;
        }
        directory.extend_from_slice(&reply[4..20]);
    }
    let Some(sector) = logitech_g::first_enabled_profile_sector(&directory) else {
        return false;
    };
    let Some(original) = read_profile_sector(dev, mouse.device_index, feature, sector, info.sector_size)
    else {
        return false;
    };
    let mut bindings = HashMap::new();
    bindings.insert(SIDE_BUTTON_BACK, g_binding(mouse.back, SIDE_BUTTON_BACK));
    bindings.insert(SIDE_BUTTON_FORWARD, g_binding(mouse.forward, SIDE_BUTTON_FORWARD));
    let patch = logitech_g::ProfilePatch {
        dpi: Some(mouse.dpi),
        report_rate_hz: Some(mouse.report_rate_hz),
        triggers: Some(mouse.triggers),
        button_bindings: bindings,
    };
    let Some(patched) = logitech_g::patched_profile_sector(&original, &patch) else {
        return false;
    };
    if patched == original {
        return true;
    }
    let verified = write_profile_sector(dev, mouse.device_index, feature, sector, &patched)
        && read_profile_sector(dev, mouse.device_index, feature, sector, info.sector_size)
            .is_some_and(|read_back| read_back == patched);
    if !verified {
        // A half-written sector fails its CRC and can't be patched again, so put the original back.
        let _ = write_profile_sector(dev, mouse.device_index, feature, sector, &original);
    }
    verified
}

fn read_profile_sector(
    dev: &HidDevice,
    index: u8,
    feature: u8,
    sector: u16,
    size: usize,
) -> Option<Vec<u8>> {
    let mut chunks = Vec::new();
    for offset in logitech_g::sector_read_offsets(size) {
        let params = logitech_g::read_memory_params(sector, offset);
        let packet = hidpp::make_long_packet(index, feature, 5, SOFTWARE_ID, &params);
        let reply = exchange(dev, &packet)?;
        if reply.len() < 20 {
            return None;
        }
        chunks.push(reply[4..20].to_vec());
    }
    logitech_g::assemble_sector(&chunks, size)
}

fn write_profile_sector(
    dev: &HidDevice,
    index: u8,
    feature: u8,
    sector: u16,
    data: &[u8],
) -> bool {
    let start = logitech_g::write_memory_start_params(sector, data.len());
    let packet = hidpp::make_long_packet(index, feature, 6, SOFTWARE_ID, &start);
    if exchange(dev, &packet).is_none() {
        return false;
    }
    for chunk in data.chunks(16) {
        if exchange(dev, &hidpp::make_long_packet(index, feature, 7, SOFTWARE_ID, chunk)).is_none() {
            return false;
        }
    }
    let end = hidpp::make_long_packet(index, feature, 8, SOFTWARE_ID, &[]);
    exchange(dev, &end).is_some()
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
            return None;
        }
        if norm[2] == packet[2] && norm[3] == packet[3] {
            return Some(norm);
        }
    }
    None
}
