//! Callback into the macOS app for actions that need AppKit (Mission Control, media, caffeine).
//! The pointer is installed with `aeron_set_host_action_handler` before the engine starts.

use std::ffi::{c_char, CString};
use std::sync::Mutex;

pub type HostFn = Option<extern "C" fn(*const c_char)>;

static HOST_ACTION: Mutex<HostFn> = Mutex::new(None);

pub fn set_handler(handler: HostFn) {
    if let Ok(mut slot) = HOST_ACTION.lock() {
        *slot = handler;
    }
}

pub fn emit(token: &str) {
    let handler = HOST_ACTION.lock().ok().and_then(|guard| *guard);
    let Some(handler) = handler else {
        return;
    };
    let Ok(text) = CString::new(token) else {
        return;
    };
    handler(text.as_ptr());
}
