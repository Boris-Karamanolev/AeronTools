//! Posts the scroll and key effects the input loop decides on, and turns a button action into the
//! HID assignment a Keychron mouse stores and sends itself.

use std::ffi::c_void;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use aeron_protocols::models::AccessoryButtonAction;
use plist::Value;

use crate::hid_input::InputEffect;

const SESSION_TAP: u32 = 1;
const HID_TAP: u32 = 0;
const UNIT_PIXEL: u32 = 0;
const UNIT_LINE: u32 = 1;
const MASK_SHIFT: u64 = 0x0002_0000;
const MASK_CONTROL: u64 = 0x0004_0000;
const MASK_OPTION: u64 = 0x0008_0000;
const MASK_COMMAND: u64 = 0x0010_0000;
const MASK_NUMERIC_PAD: u64 = 0x0020_0000;
const MASK_SECONDARY_FN: u64 = 0x0080_0000;

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFRelease(cf: *const c_void);
}

#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    fn CGEventCreateScrollWheelEvent(
        source: *mut c_void,
        units: u32,
        wheel_count: u32,
        wheel1: i32,
        ...
    ) -> *mut c_void;
    fn CGEventCreateKeyboardEvent(source: *mut c_void, key: u16, down: bool) -> *mut c_void;
    fn CGEventSetFlags(event: *mut c_void, flags: u64);
    fn CGEventPost(tap: u32, event: *mut c_void);
}

pub fn scroll_sign(standard: bool) -> f64 {
    if standard {
        return 1.0;
    }
    if natural_scrolling_cached() { -1.0 } else { 1.0 }
}

pub fn hid_key_binding(action: AccessoryButtonAction) -> Option<(u8, u8)> {
    let (code, flags) = shortcut(action)?;
    hid_usage(code, flags)
}

pub fn action_for_keychron(entry: [u8; 4], back: bool) -> Option<AccessoryButtonAction> {
    [
        AccessoryButtonAction::NavigateBack,
        AccessoryButtonAction::NavigateForward,
        AccessoryButtonAction::MissionControl,
        AccessoryButtonAction::AppExpose,
        AccessoryButtonAction::ShowDesktop,
        AccessoryButtonAction::SpaceLeft,
        AccessoryButtonAction::SpaceRight,
        AccessoryButtonAction::Copy,
        AccessoryButtonAction::Paste,
        AccessoryButtonAction::SystemDefault,
    ]
    .into_iter()
    .find(|action| keychron_assignment(*action, back) == Some(entry))
}

fn natural_scrolling_cached() -> bool {
    struct Cache {
        at: Instant,
        natural: bool,
    }
    static CACHE: Mutex<Option<Cache>> = Mutex::new(None);
    if let Ok(mut guard) = CACHE.lock() {
        if let Some(cache) = guard.as_ref() {
            if cache.at.elapsed() < Duration::from_secs(5) {
                return cache.natural;
            }
        }
        let natural = natural_scrolling();
        *guard = Some(Cache {
            at: Instant::now(),
            natural,
        });
        return natural;
    }
    natural_scrolling()
}

pub fn perform(effect: &InputEffect) {
    match effect {
        InputEffect::Scroll {
            pixels,
            vertical,
            horizontal,
        } => post_scroll(*pixels, *vertical, *horizontal),
        InputEffect::Key {
            code,
            command,
            shift,
            control,
            option,
        } => post_key(*code, *command, *shift, *control, *option),
        InputEffect::Host(_) | InputEffect::ToggleWheel => {}
    }
}

/// Four-byte button entry the M3 Mini stores. `None` when this Mac cannot express the action as a key.
pub fn keychron_assignment(action: AccessoryButtonAction, back: bool) -> Option<[u8; 4]> {
    if action == AccessoryButtonAction::SystemDefault {
        return Some([0x01, 0x00, if back { 0xF3 } else { 0xF4 }, 0x00]);
    }
    let (code, flags) = shortcut(action)?;
    let (usage, modifiers) = hid_usage(code, flags)?;
    Some([0x00, modifiers, usage, 0x00])
}

fn natural_scrolling() -> bool {
    let Some(home) = dirs::home_dir() else {
        return true;
    };
    let Ok(value) = Value::from_file(home.join("Library/Preferences/.GlobalPreferences.plist")) else {
        return true;
    };
    value
        .as_dictionary()
        .and_then(|dict| dict.get("com.apple.swipescrolldirection"))
        .and_then(Value::as_boolean)
        .unwrap_or(true)
}

fn post_scroll(pixels: bool, vertical: i32, horizontal: i32) {
    unsafe {
        let event = CGEventCreateScrollWheelEvent(
            std::ptr::null_mut(),
            if pixels { UNIT_PIXEL } else { UNIT_LINE },
            2,
            vertical,
            horizontal,
            0,
        );
        if event.is_null() {
            return;
        }
        CGEventPost(SESSION_TAP, event);
        CFRelease(event.cast());
    }
}

fn post_key(code: u16, command: bool, shift: bool, control: bool, option: bool) {
    let mut flags = 0u64;
    if command {
        flags |= MASK_COMMAND;
    }
    if shift {
        flags |= MASK_SHIFT;
    }
    if control {
        flags |= MASK_CONTROL;
    }
    if option {
        flags |= MASK_OPTION;
    }
    if matches!(code, 0x7B | 0x7C | 0x7D | 0x7E) {
        flags |= MASK_SECONDARY_FN | MASK_NUMERIC_PAD;
    }
    unsafe {
        let down = CGEventCreateKeyboardEvent(std::ptr::null_mut(), code, true);
        let up = CGEventCreateKeyboardEvent(std::ptr::null_mut(), code, false);
        if down.is_null() || up.is_null() {
            if !down.is_null() {
                CFRelease(down.cast());
            }
            if !up.is_null() {
                CFRelease(up.cast());
            }
            return;
        }
        CGEventSetFlags(down, flags);
        CGEventSetFlags(up, flags);
        CGEventPost(HID_TAP, down);
        CGEventPost(HID_TAP, up);
        CFRelease(down.cast());
        CFRelease(up.cast());
    }
}

fn shortcut(action: AccessoryButtonAction) -> Option<(u16, u64)> {
    match action {
        AccessoryButtonAction::MissionControl => {
            symbolic_hotkey(32, 0x7E, MASK_CONTROL)
        }
        AccessoryButtonAction::AppExpose => symbolic_hotkey(33, 0x7D, MASK_CONTROL),
        AccessoryButtonAction::ShowDesktop => symbolic_hotkey(36, 0x67, 0),
        AccessoryButtonAction::SpaceLeft => symbolic_hotkey(79, 0x7B, MASK_CONTROL),
        AccessoryButtonAction::SpaceRight => symbolic_hotkey(81, 0x7C, MASK_CONTROL),
        AccessoryButtonAction::NavigateBack => Some((0x21, MASK_COMMAND)),
        AccessoryButtonAction::NavigateForward => Some((0x1E, MASK_COMMAND)),
        AccessoryButtonAction::Copy => Some((0x08, MASK_COMMAND)),
        AccessoryButtonAction::Paste => Some((0x09, MASK_COMMAND)),
        AccessoryButtonAction::SystemDefault
        | AccessoryButtonAction::Launchpad
        | AccessoryButtonAction::PlayPause
        | AccessoryButtonAction::MutePointerDisplay
        | AccessoryButtonAction::ToggleBuiltinScreen
        | AccessoryButtonAction::ToggleCaffeine
        | AccessoryButtonAction::ToggleWheelMode => None,
    }
}

fn symbolic_hotkey(id: u32, fallback_code: u16, fallback_flags: u64) -> Option<(u16, u64)> {
    let Some(home) = dirs::home_dir() else {
        return Some((fallback_code, fallback_flags));
    };
    let Ok(value) =
        Value::from_file(home.join("Library/Preferences/com.apple.symbolichotkeys.plist"))
    else {
        return Some((fallback_code, fallback_flags));
    };
    let Some(entry) = value
        .as_dictionary()
        .and_then(|dict| dict.get("AppleSymbolicHotKeys"))
        .and_then(Value::as_dictionary)
        .and_then(|keys| keys.get(&id.to_string()))
        .and_then(Value::as_dictionary)
    else {
        return Some((fallback_code, fallback_flags));
    };
    if entry.get("enabled").and_then(Value::as_boolean) == Some(false) {
        return None;
    }
    let Some(parameters) = entry
        .get("value")
        .and_then(Value::as_dictionary)
        .and_then(|value| value.get("parameters"))
        .and_then(Value::as_array)
    else {
        return Some((fallback_code, fallback_flags));
    };
    let code = parameters.get(1).and_then(Value::as_signed_integer).unwrap_or(0);
    let flags = parameters.get(2).and_then(Value::as_signed_integer).unwrap_or(0);
    if code == 0 || code == 0xFFFF {
        return Some((fallback_code, fallback_flags));
    }
    Some((code as u16, flags as u64))
}

fn hid_usage(code: u16, flags: u64) -> Option<(u8, u8)> {
    let usage = HID_USAGE.iter().find(|(key, _)| *key == code)?.1;
    let mut modifiers = 0u8;
    if flags & MASK_CONTROL != 0 {
        modifiers |= 0x01;
    }
    if flags & MASK_SHIFT != 0 {
        modifiers |= 0x02;
    }
    if flags & MASK_OPTION != 0 {
        modifiers |= 0x04;
    }
    if flags & MASK_COMMAND != 0 {
        modifiers |= 0x08;
    }
    Some((usage, modifiers))
}

/// macOS virtual key codes and the HID keyboard usages for the same key positions.
const HID_USAGE: &[(u16, u8)] = &[
    (0x00, 0x04), (0x0B, 0x05), (0x08, 0x06), (0x02, 0x07), (0x0E, 0x08), (0x03, 0x09),
    (0x05, 0x0A), (0x04, 0x0B), (0x22, 0x0C), (0x26, 0x0D), (0x28, 0x0E), (0x25, 0x0F),
    (0x2E, 0x10), (0x2D, 0x11), (0x1F, 0x12), (0x23, 0x13), (0x0C, 0x14), (0x0F, 0x15),
    (0x01, 0x16), (0x11, 0x17), (0x20, 0x18), (0x09, 0x19), (0x0D, 0x1A), (0x07, 0x1B),
    (0x10, 0x1C), (0x06, 0x1D), (0x12, 0x1E), (0x13, 0x1F), (0x14, 0x20), (0x15, 0x21),
    (0x17, 0x22), (0x16, 0x23), (0x1A, 0x24), (0x1C, 0x25), (0x19, 0x26), (0x1D, 0x27),
    (0x24, 0x28), (0x35, 0x29), (0x33, 0x2A), (0x30, 0x2B), (0x31, 0x2C), (0x1B, 0x2D),
    (0x18, 0x2E), (0x21, 0x2F), (0x1E, 0x30), (0x2A, 0x31), (0x29, 0x33), (0x27, 0x34),
    (0x32, 0x35), (0x2B, 0x36), (0x2F, 0x37), (0x2C, 0x38), (0x7A, 0x3A), (0x78, 0x3B),
    (0x63, 0x3C), (0x76, 0x3D), (0x60, 0x3E), (0x61, 0x3F), (0x62, 0x40), (0x64, 0x41),
    (0x65, 0x42), (0x6D, 0x43), (0x67, 0x44), (0x6F, 0x45), (0x73, 0x4A), (0x74, 0x4B),
    (0x75, 0x4C), (0x77, 0x4D), (0x79, 0x4E), (0x7C, 0x4F), (0x7B, 0x50), (0x7D, 0x51),
    (0x7E, 0x52),
];
