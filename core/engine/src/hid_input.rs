//! Pure HID++ input decisions: diversion, gestures, scroll, keyboard keys, G side buttons.
//! The platform posts the resulting effects. Nothing here opens a device.

use std::collections::{HashMap, HashSet};

use aeron_protocols::hidpp::{
    self, KeyControl, MxWheelMode, CID_BACK_BUTTON, CID_FORWARD_BUTTON, CID_GESTURE_THUMB_BUTTON,
    CID_HAPTIC_PANEL_BUTTON, CID_MIDDLE_BUTTON, CID_MODE_SHIFT_BUTTON,
};
use aeron_protocols::logitech_g::{self, TriggerSettings, SIDE_BUTTON_BACK, SIDE_BUTTON_FORWARD};
use aeron_protocols::logitech_keyboard::{BacklightConfig, BacklightEffect};
use aeron_protocols::models::{
    AccessoryButtonAction, MxMasterOptions, MxMasterState, MxThumbwheelAction,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GestureDirection {
    Up,
    Down,
    Left,
    Right,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GestureOutcome {
    Click,
    Gesture(GestureDirection),
    None,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct GestureTracker {
    held: Option<u16>,
    dx: i32,
    dy: i32,
}

impl GestureTracker {
    pub fn press(&mut self, cid: u16) {
        if self.held.is_some() {
            return;
        }
        self.held = Some(cid);
        self.dx = 0;
        self.dy = 0;
    }

    pub fn move_by(&mut self, dx: i32, dy: i32) {
        if self.held.is_none() {
            return;
        }
        self.dx += dx;
        self.dy += dy;
    }

    pub fn release(&mut self, cid: u16, threshold: i32) -> GestureOutcome {
        if self.held != Some(cid) {
            return GestureOutcome::None;
        }
        let (dx, dy) = (self.dx, self.dy);
        self.cancel();
        if dx.abs().max(dy.abs()) < threshold {
            return GestureOutcome::Click;
        }
        if dy.abs() >= dx.abs() {
            GestureOutcome::Gesture(if dy < 0 {
                GestureDirection::Up
            } else {
                GestureDirection::Down
            })
        } else {
            GestureOutcome::Gesture(if dx < 0 {
                GestureDirection::Left
            } else {
                GestureDirection::Right
            })
        }
    }

    pub fn cancel(&mut self) {
        self.held = None;
        self.dx = 0;
        self.dy = 0;
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum InputEffect {
    Scroll {
        pixels: bool,
        vertical: i32,
        horizontal: i32,
    },
    Key {
        code: u16,
        command: bool,
        shift: bool,
        control: bool,
        option: bool,
    },
    Host(&'static str),
    ToggleWheel,
}

#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct ScrollState {
    pending_line: f64,
    velocity_y: f64,
}

impl ScrollState {
    pub fn push_line(&mut self, ticks: f64) -> Option<i32> {
        self.pending_line += ticks;
        let lines = self.pending_line.trunc() as i32;
        if lines == 0 {
            return None;
        }
        self.pending_line -= f64::from(lines);
        Some(lines)
    }

    pub fn push_smooth(&mut self, ticks: f64) {
        self.velocity_y += ticks * 9.5;
    }

    pub fn step_smooth(&mut self) -> Option<i32> {
        if self.velocity_y.abs() < 0.45 {
            self.velocity_y = 0.0;
            return None;
        }
        let step = self.velocity_y.round() as i32;
        self.velocity_y *= 0.84;
        (step != 0).then_some(step)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ControlDiversion {
    pub cid: u16,
    pub diverted: bool,
    pub raw_xy: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct MxFeatures {
    pub reprog: Option<u8>,
    pub wheel: Option<u8>,
    pub thumb: Option<u8>,
    pub smart: Option<u8>,
    pub smart_enhanced: bool,
    pub dpi: Option<u8>,
    pub battery_unified: Option<u8>,
    pub battery_legacy: Option<u8>,
}

pub fn options_from_state(mx: &MxMasterState) -> MxMasterOptions {
    MxMasterOptions {
        standard_vertical_scroll: mx.standard_vertical_scroll,
        smooth_scrolling: mx.smooth_scrolling,
        scroll_speed_multiplier: mx.scroll_speed_multiplier,
        thumbwheel_action: mx.thumbwheel_action,
        invert_thumbwheel: mx.invert_thumbwheel,
        middle_button_action: mx.middle_button_action,
        back_button_action: mx.back_button_action,
        forward_button_action: mx.forward_button_action,
        gesture_button_action: mx.gesture_button_action,
        mode_shift_button_action: mx.mode_shift_button_action,
        haptic_panel_button_action: mx.haptic_panel_button_action,
        gestures_enabled: mx.gestures_enabled,
        gesture_up_action: mx.gesture_up_action,
        gesture_down_action: mx.gesture_down_action,
        gesture_left_action: mx.gesture_left_action,
        gesture_right_action: mx.gesture_right_action,
        saves_to_mouse: mx.saves_to_mouse,
    }
}

pub fn diverts_wheel(options: &MxMasterOptions) -> bool {
    options.standard_vertical_scroll
        || options.smooth_scrolling
        || options.scroll_speed_multiplier != 1.0
}

pub fn diverts_thumbwheel(options: &MxMasterOptions) -> bool {
    options.invert_thumbwheel || options.thumbwheel_action != MxThumbwheelAction::HorizontalScroll
}

pub fn button_diversions(options: &MxMasterOptions) -> Vec<ControlDiversion> {
    let gestures = options.gestures_enabled;
    let diverted = |action: AccessoryButtonAction| action != AccessoryButtonAction::SystemDefault;
    vec![
        ControlDiversion {
            cid: CID_GESTURE_THUMB_BUTTON,
            diverted: gestures || diverted(options.gesture_button_action),
            raw_xy: gestures,
        },
        ControlDiversion {
            cid: CID_MIDDLE_BUTTON,
            diverted: diverted(options.middle_button_action),
            raw_xy: false,
        },
        ControlDiversion {
            cid: CID_BACK_BUTTON,
            diverted: diverted(options.back_button_action),
            raw_xy: false,
        },
        ControlDiversion {
            cid: CID_FORWARD_BUTTON,
            diverted: diverted(options.forward_button_action),
            raw_xy: false,
        },
        ControlDiversion {
            cid: CID_MODE_SHIFT_BUTTON,
            diverted: diverted(options.mode_shift_button_action),
            raw_xy: false,
        },
        ControlDiversion {
            cid: CID_HAPTIC_PANEL_BUTTON,
            diverted: gestures || diverted(options.haptic_panel_button_action),
            raw_xy: gestures,
        },
    ]
}

pub fn gesture_threshold(dpi: u16) -> i32 {
    (36).max((f64::from(dpi) * 0.12) as i32)
}

#[derive(Debug, Clone)]
pub struct MxLive {
    pub device_index: u8,
    pub options: MxMasterOptions,
    pub dpi: u16,
    pub wheel_mode: MxWheelMode,
    pub smart_shift_enabled: bool,
    pub smart_shift_threshold: u8,
    pub battery_percent: Option<u8>,
    pub is_charging: bool,
    pub features: MxFeatures,
    pub dirty: bool,
    /// Saved DPI should be written back on connect.
    pub reapply_dpi: bool,
    /// Saved SmartShift should be written back on connect.
    pub reapply_smart_shift: bool,
    pressed: HashSet<u16>,
    gesture: GestureTracker,
    scroll: ScrollState,
    last_thumb_ms: u64,
}

impl MxLive {
    pub fn from_state(
        device_index: u8,
        mx: &MxMasterState,
        reapply_dpi: bool,
        reapply_smart_shift: bool,
    ) -> Self {
        Self {
            device_index,
            options: options_from_state(mx),
            dpi: mx.dpi,
            wheel_mode: mx.wheel_mode,
            smart_shift_enabled: mx.smart_shift_enabled,
            smart_shift_threshold: mx.smart_shift_threshold,
            battery_percent: mx.battery_percent,
            is_charging: mx.is_charging,
            features: MxFeatures::default(),
            dirty: true,
            reapply_dpi,
            reapply_smart_shift,
            pressed: HashSet::new(),
            gesture: GestureTracker::default(),
            scroll: ScrollState::default(),
            last_thumb_ms: 0,
        }
    }

    pub fn apply_options(&mut self, options: MxMasterOptions) {
        self.options = options;
        self.dirty = true;
    }

    pub fn handle_report(&mut self, report: &[u8], now_ms: u64, scroll_sign: f64) -> Vec<InputEffect> {
        let Some(norm) = hidpp::normalize_report(report) else {
            return Vec::new();
        };
        if norm.len() < 4 || norm[1] != self.device_index {
            return Vec::new();
        }
        let feature = norm[2];
        let mut effects = Vec::new();

        if self.features.wheel == Some(feature) {
            if let Some(notches) = hidpp::parse_wheel_movement_event(&norm, feature) {
                effects.extend(self.on_wheel(notches, scroll_sign));
            }
            return effects;
        }
        if self.features.thumb == Some(feature) {
            if let Some(rotation) = hidpp::parse_thumbwheel_event(&norm, feature) {
                effects.extend(self.on_thumbwheel(rotation, now_ms));
            }
            return effects;
        }
        if self.features.reprog == Some(feature) {
            if let Some((dx, dy)) = hidpp::parse_raw_xy_event(&norm, feature) {
                if self.options.gestures_enabled {
                    self.gesture.move_by(i32::from(dx), i32::from(dy));
                }
                return effects;
            }
            if let Some(cids) = hidpp::parse_diverted_buttons_event(&norm, feature) {
                effects.extend(self.on_buttons(&cids));
            }
        }
        effects
    }

    pub fn step_smooth(&mut self) -> Option<InputEffect> {
        self.scroll.step_smooth().map(|vertical| InputEffect::Scroll {
            pixels: true,
            vertical,
            horizontal: 0,
        })
    }

    pub fn toggle_wheel(&mut self) -> MxWheelMode {
        self.wheel_mode = match self.wheel_mode {
            MxWheelMode::Ratchet => MxWheelMode::FreeSpin,
            MxWheelMode::FreeSpin => MxWheelMode::Ratchet,
        };
        self.wheel_mode
    }

    fn on_wheel(&mut self, notches: i16, scroll_sign: f64) -> Vec<InputEffect> {
        if notches == 0 {
            return Vec::new();
        }
        let ticks = f64::from(notches) * scroll_sign * self.options.scroll_speed_multiplier;
        if self.options.smooth_scrolling {
            self.scroll.push_smooth(ticks);
            Vec::new()
        } else if let Some(lines) = self.scroll.push_line(ticks) {
            vec![InputEffect::Scroll {
                pixels: false,
                vertical: lines,
                horizontal: 0,
            }]
        } else {
            Vec::new()
        }
    }

    fn on_thumbwheel(&mut self, rotation: i16, now_ms: u64) -> Vec<InputEffect> {
        if rotation == 0 {
            return Vec::new();
        }
        let delta = if self.options.invert_thumbwheel {
            -i32::from(rotation)
        } else {
            i32::from(rotation)
        };
        let since = now_ms.saturating_sub(self.last_thumb_ms);
        let (effect, debounce_ms) = match self.options.thumbwheel_action {
            MxThumbwheelAction::HorizontalScroll => (
                InputEffect::Scroll {
                    pixels: true,
                    vertical: 0,
                    horizontal: delta * 2,
                },
                0,
            ),
            MxThumbwheelAction::DisplayBrightness => (
                InputEffect::Host(if delta > 0 {
                    "brightnessUp"
                } else {
                    "brightnessDown"
                }),
                0,
            ),
            MxThumbwheelAction::DisplayVolume => (
                InputEffect::Host(if delta > 0 { "volumeUp" } else { "volumeDown" }),
                0,
            ),
            MxThumbwheelAction::SwitchWorkspaces => (
                InputEffect::Host(if delta > 0 { "spaceRight" } else { "spaceLeft" }),
                280,
            ),
            MxThumbwheelAction::SwitchTabs => (
                InputEffect::Key {
                    code: if delta > 0 { 0x1E } else { 0x21 },
                    command: true,
                    shift: true,
                    control: false,
                    option: false,
                },
                160,
            ),
            MxThumbwheelAction::Zoom => (
                InputEffect::Key {
                    code: if delta > 0 { 0x18 } else { 0x1B },
                    command: true,
                    shift: false,
                    control: false,
                    option: false,
                },
                120,
            ),
        };
        if debounce_ms > 0 && since < debounce_ms {
            return Vec::new();
        }
        if debounce_ms > 0 {
            self.last_thumb_ms = now_ms;
        }
        vec![effect]
    }

    fn on_buttons(&mut self, cids: &[u16]) -> Vec<InputEffect> {
        let pressed: HashSet<u16> = cids.iter().copied().collect();
        let previous = self.pressed.clone();
        self.pressed = pressed.clone();
        let mut effects = Vec::new();
        for cid in pressed.difference(&previous) {
            effects.extend(self.on_edge(*cid, true));
        }
        for cid in previous.difference(&pressed) {
            effects.extend(self.on_edge(*cid, false));
        }
        effects
    }

    fn on_edge(&mut self, cid: u16, is_down: bool) -> Vec<InputEffect> {
        let click = match cid {
            CID_GESTURE_THUMB_BUTTON => Some(self.options.gesture_button_action),
            CID_HAPTIC_PANEL_BUTTON => Some(self.options.haptic_panel_button_action),
            CID_MIDDLE_BUTTON => {
                return if is_down {
                    self.action_effect(self.options.middle_button_action)
                } else {
                    Vec::new()
                };
            }
            CID_BACK_BUTTON => {
                return if is_down {
                    self.action_effect(self.options.back_button_action)
                } else {
                    Vec::new()
                };
            }
            CID_FORWARD_BUTTON => {
                return if is_down {
                    self.action_effect(self.options.forward_button_action)
                } else {
                    Vec::new()
                };
            }
            CID_MODE_SHIFT_BUTTON => {
                return if is_down {
                    self.action_effect(self.options.mode_shift_button_action)
                } else {
                    Vec::new()
                };
            }
            _ => return Vec::new(),
        };
        let Some(click_action) = click else {
            return Vec::new();
        };
        if is_down {
            self.gesture.press(cid);
            return Vec::new();
        }
        let outcome = self.gesture.release(cid, gesture_threshold(self.dpi));
        let action = match outcome {
            GestureOutcome::Click => click_action,
            GestureOutcome::Gesture(GestureDirection::Up) => self.options.gesture_up_action,
            GestureOutcome::Gesture(GestureDirection::Down) => self.options.gesture_down_action,
            GestureOutcome::Gesture(GestureDirection::Left) => self.options.gesture_left_action,
            GestureOutcome::Gesture(GestureDirection::Right) => self.options.gesture_right_action,
            GestureOutcome::None => return Vec::new(),
        };
        self.action_effect(action)
    }

    fn action_effect(&self, action: AccessoryButtonAction) -> Vec<InputEffect> {
        match action {
            AccessoryButtonAction::SystemDefault => Vec::new(),
            AccessoryButtonAction::ToggleWheelMode => vec![InputEffect::ToggleWheel],
            other => vec![InputEffect::Host(other.host_token())],
        }
    }
}

#[derive(Debug, Clone)]
pub struct KeyboardLive {
    pub device_index: u8,
    pub reprog: Option<u8>,
    pub keys: Vec<KeyControl>,
    pub actions: HashMap<u8, AccessoryButtonAction>,
    pub dirty: bool,
    pub battery_percent: Option<u8>,
    pub is_charging: bool,
    pub battery_unified: Option<u8>,
    pub battery_legacy: Option<u8>,
    pub backlight: Option<BacklightConfig>,
    pub backlight_effect: Option<BacklightEffect>,
    pub fn_standard: Option<bool>,
    pub current_host: Option<u8>,
    /// CIDs this app diverted. Keys outside this set are never handed back.
    pub diverted: HashSet<u16>,
    pressed: HashSet<u16>,
}

impl KeyboardLive {
    pub fn new(device_index: u8, actions: HashMap<u8, AccessoryButtonAction>) -> Self {
        Self {
            device_index,
            reprog: None,
            keys: Vec::new(),
            actions,
            dirty: true,
            battery_percent: None,
            is_charging: false,
            battery_unified: None,
            battery_legacy: None,
            backlight: None,
            backlight_effect: None,
            fn_standard: None,
            current_host: None,
            diverted: HashSet::new(),
            pressed: HashSet::new(),
        }
    }

    pub fn handle_report(&mut self, report: &[u8]) -> Vec<InputEffect> {
        let Some(norm) = hidpp::normalize_report(report) else {
            return Vec::new();
        };
        if norm.len() < 4 || norm[1] != self.device_index {
            return Vec::new();
        }
        let Some(index) = self.reprog else {
            return Vec::new();
        };
        let Some(cids) = hidpp::parse_diverted_buttons_event(&norm, index) else {
            return Vec::new();
        };
        let pressed: HashSet<u16> = cids.into_iter().collect();
        let previous = self.pressed.clone();
        self.pressed = pressed.clone();
        let mut effects = Vec::new();
        for cid in pressed.difference(&previous) {
            let Some(control) = self.keys.iter().find(|key| key.cid == *cid) else {
                continue;
            };
            let Some(action) = self.actions.get(&control.f_key_position).copied() else {
                continue;
            };
            if action != AccessoryButtonAction::SystemDefault {
                effects.push(InputEffect::Host(action.host_token()));
            }
        }
        effects
    }
}

#[derive(Debug, Clone)]
pub struct GMouseLive {
    pub device_index: u8,
    pub spy: Option<u8>,
    pub button_count: u8,
    pub back: AccessoryButtonAction,
    pub forward: AccessoryButtonAction,
    pub dirty: bool,
    pub spying: bool,
    pub dpi: u16,
    pub lift_off: u8,
    pub report_rate_hz: u16,
    pub triggers: TriggerSettings,
    pub reapply_dpi: bool,
    pub reapply_rate: bool,
    pub saves_profile: bool,
    pub profile_dirty: bool,
    pub battery_percent: Option<u8>,
    pub is_charging: bool,
    pub battery_unified: Option<u8>,
    pub battery_legacy: Option<u8>,
    last_mask: u16,
}

impl GMouseLive {
    pub fn new(device_index: u8, back: AccessoryButtonAction, forward: AccessoryButtonAction) -> Self {
        Self {
            device_index,
            spy: None,
            button_count: 0,
            back,
            forward,
            dirty: true,
            spying: false,
            dpi: 1600,
            lift_off: 1,
            report_rate_hz: 1000,
            triggers: TriggerSettings::default(),
            reapply_dpi: false,
            reapply_rate: false,
            saves_profile: false,
            profile_dirty: true,
            battery_percent: None,
            is_charging: false,
            battery_unified: None,
            battery_legacy: None,
            last_mask: 0,
        }
    }

    pub fn wants_spy(&self) -> bool {
        self.back != AccessoryButtonAction::SystemDefault
            || self.forward != AccessoryButtonAction::SystemDefault
    }

    pub fn handle_report(&mut self, report: &[u8]) -> Vec<InputEffect> {
        let Some(norm) = hidpp::normalize_report(report) else {
            return Vec::new();
        };
        if norm.len() < 4 || norm[1] != self.device_index {
            return Vec::new();
        }
        let Some(index) = self.spy else {
            return Vec::new();
        };
        let Some(mask) = logitech_g::parse_button_spy_event(&norm, index) else {
            return Vec::new();
        };
        let previous = self.last_mask;
        self.last_mask = mask;
        let mut effects = Vec::new();
        for (button, action) in [
            (SIDE_BUTTON_BACK, self.back),
            (SIDE_BUTTON_FORWARD, self.forward),
        ] {
            if action != AccessoryButtonAction::SystemDefault
                && logitech_g::button_pressed(button, mask)
                && !logitech_g::button_pressed(button, previous)
            {
                effects.push(InputEffect::Host(action.host_token()));
            }
        }
        effects
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn options() -> MxMasterOptions {
        options_from_state(&crate::hid_devices::default_accessories_snapshot().mx_master)
    }

    #[test]
    fn gesture_click_stays_a_click_below_the_threshold() {
        let mut tracker = GestureTracker::default();
        tracker.press(0x00C3);
        tracker.move_by(4, -3);
        assert_eq!(tracker.release(0x00C3, 36), GestureOutcome::Click);
    }

    #[test]
    fn gesture_uses_the_dominant_axis() {
        let mut tracker = GestureTracker::default();
        tracker.press(0x00C3);
        tracker.move_by(-10, -80);
        assert_eq!(
            tracker.release(0x00C3, 36),
            GestureOutcome::Gesture(GestureDirection::Up)
        );
    }

    #[test]
    fn line_scroll_carries_a_fractional_tick() {
        let mut scroll = ScrollState::default();
        assert_eq!(scroll.push_line(0.6), None);
        assert_eq!(scroll.push_line(0.6), Some(1));
    }

    #[test]
    fn smooth_scroll_decays() {
        let mut scroll = ScrollState::default();
        scroll.push_smooth(1.0);
        let first = scroll.step_smooth();
        assert!(first.is_some());
        let mut steps = 0;
        while scroll.step_smooth().is_some() {
            steps += 1;
            assert!(steps < 80);
        }
    }

    #[test]
    fn standard_scroll_diverts_the_wheel() {
        let mut options = options();
        options.standard_vertical_scroll = true;
        options.smooth_scrolling = false;
        options.scroll_speed_multiplier = 1.0;
        assert!(diverts_wheel(&options));
    }

    #[test]
    fn system_default_buttons_are_not_diverted() {
        let mut options = options();
        options.gestures_enabled = false;
        options.gesture_button_action = AccessoryButtonAction::SystemDefault;
        options.middle_button_action = AccessoryButtonAction::SystemDefault;
        options.back_button_action = AccessoryButtonAction::SystemDefault;
        options.forward_button_action = AccessoryButtonAction::SystemDefault;
        options.mode_shift_button_action = AccessoryButtonAction::SystemDefault;
        options.haptic_panel_button_action = AccessoryButtonAction::SystemDefault;
        let diverted: Vec<_> = button_diversions(&options)
            .into_iter()
            .filter(|control| control.diverted)
            .collect();
        assert!(diverted.is_empty());
    }
}
