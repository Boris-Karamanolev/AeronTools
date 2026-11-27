//! Button maps and scroll options, stored next to `preferences.json`.
//! Connection and battery stay live; only the choices the user made are written.

use std::fs;
use std::path::PathBuf;

use aeron_protocols::hidpp::MxWheelMode;
use aeron_protocols::models::{AccessoriesSnapshot, AccessoryButtonAction, MxMasterOptions};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct AccessoryFile {
    mx: Option<MxMasterOptions>,
    mx_dpi: Option<u16>,
    mx_wheel_mode: Option<MxWheelMode>,
    mx_smart_shift_enabled: Option<bool>,
    mx_smart_shift_threshold: Option<u8>,
    keyboard_key_actions: Vec<(u8, AccessoryButtonAction)>,
    keyboard_fn_inversion: Option<bool>,
    g_back: Option<AccessoryButtonAction>,
    g_forward: Option<AccessoryButtonAction>,
    g_saves_profile: Option<bool>,
    keychron_back: Option<AccessoryButtonAction>,
    keychron_forward: Option<AccessoryButtonAction>,
}

fn path() -> Option<PathBuf> {
    dirs::config_dir().map(|dir| dir.join("AeronTools").join("accessories.json"))
}

pub fn apply(state: &mut AccessoriesSnapshot) {
    let Some(path) = path() else {
        return;
    };
    let Ok(text) = fs::read_to_string(path) else {
        return;
    };
    let Ok(saved) = serde_json::from_str::<AccessoryFile>(&text) else {
        return;
    };
    if let Some(mx) = saved.mx {
        let slot = &mut state.mx_master;
        slot.standard_vertical_scroll = mx.standard_vertical_scroll;
        slot.smooth_scrolling = mx.smooth_scrolling;
        slot.scroll_speed_multiplier = mx.scroll_speed_multiplier;
        slot.thumbwheel_action = mx.thumbwheel_action;
        slot.invert_thumbwheel = mx.invert_thumbwheel;
        slot.middle_button_action = mx.middle_button_action;
        slot.back_button_action = mx.back_button_action;
        slot.forward_button_action = mx.forward_button_action;
        slot.gesture_button_action = mx.gesture_button_action;
        slot.mode_shift_button_action = mx.mode_shift_button_action;
        slot.haptic_panel_button_action = mx.haptic_panel_button_action;
        slot.gestures_enabled = mx.gestures_enabled;
        slot.gesture_up_action = mx.gesture_up_action;
        slot.gesture_down_action = mx.gesture_down_action;
        slot.gesture_left_action = mx.gesture_left_action;
        slot.gesture_right_action = mx.gesture_right_action;
        slot.saves_to_mouse = mx.saves_to_mouse;
    }
    if let Some(dpi) = saved.mx_dpi {
        state.mx_master.dpi = dpi;
    }
    if let Some(mode) = saved.mx_wheel_mode {
        state.mx_master.wheel_mode = mode;
    }
    if let Some(enabled) = saved.mx_smart_shift_enabled {
        state.mx_master.smart_shift_enabled = enabled;
    }
    if let Some(threshold) = saved.mx_smart_shift_threshold {
        state.mx_master.smart_shift_threshold = threshold;
    }
    if !saved.keyboard_key_actions.is_empty() {
        state.mx_keyboard.key_actions = saved.keyboard_key_actions.into_iter().collect();
    }
    if let Some(standard) = saved.keyboard_fn_inversion {
        state.mx_keyboard.fn_inversion = Some(standard);
    }
    if let Some(back) = saved.g_back {
        state.logitech_g_mouse.back_button_action = back;
    }
    if let Some(forward) = saved.g_forward {
        state.logitech_g_mouse.forward_button_action = forward;
    }
    if let Some(saves) = saved.g_saves_profile {
        state.logitech_g_mouse.saves_to_onboard_profile = saves;
    }
    if let Some(back) = saved.keychron_back {
        state.keychron_m3_mini.back_button_action = back;
    }
    if let Some(forward) = saved.keychron_forward {
        state.keychron_m3_mini.forward_button_action = forward;
    }
}

pub fn save(state: &AccessoriesSnapshot) {
    let Some(path) = path() else {
        return;
    };
    let file = AccessoryFile {
        mx: Some(crate::hid_input::options_from_state(&state.mx_master)),
        mx_dpi: Some(state.mx_master.dpi),
        mx_wheel_mode: Some(state.mx_master.wheel_mode),
        mx_smart_shift_enabled: Some(state.mx_master.smart_shift_enabled),
        mx_smart_shift_threshold: Some(state.mx_master.smart_shift_threshold),
        keyboard_key_actions: state
            .mx_keyboard
            .key_actions
            .iter()
            .map(|(position, action)| (*position, *action))
            .collect(),
        keyboard_fn_inversion: state.mx_keyboard.fn_inversion,
        g_back: Some(state.logitech_g_mouse.back_button_action),
        g_forward: Some(state.logitech_g_mouse.forward_button_action),
        g_saves_profile: Some(state.logitech_g_mouse.saves_to_onboard_profile),
        keychron_back: Some(state.keychron_m3_mini.back_button_action),
        keychron_forward: Some(state.keychron_m3_mini.forward_button_action),
    };
    let Ok(text) = serde_json::to_string_pretty(&file) else {
        return;
    };
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let _ = fs::write(path, text);
}
