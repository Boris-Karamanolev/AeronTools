//! Native macOS `NSPanel` (`NSWindowStyleMaskNonactivatingPanel`) conversion for the menu bar
//! popover so it floats cleanly above regular windows AND native Fullscreen Spaces (green zoom
//! button) without activating the app or forcing macOS to switch Spaces.

use objc2::ffi::object_setClass;
use objc2::runtime::{AnyClass, AnyObject};
use objc2::{define_class, ClassType, MainThreadOnly};
use objc2_app_kit::{
    NSPanel, NSPopUpMenuWindowLevel, NSResponder, NSWindow, NSWindowCollectionBehavior,
    NSWindowStyleMask,
};
use objc2_foundation::NSObject;
use tauri::WebviewWindow;

define_class!(
    #[unsafe(super(NSPanel, NSWindow, NSResponder, NSObject))]
    #[thread_kind = MainThreadOnly]
    #[name = "AeronPopoverPanel"]
    struct AeronPopoverPanel;

    impl AeronPopoverPanel {
        #[unsafe(method(canBecomeKeyWindow))]
        fn can_become_key_window(&self) -> bool {
            true
        }

        #[unsafe(method(canBecomeMainWindow))]
        fn can_become_main_window(&self) -> bool {
            false
        }
    }
);

/// Converts Tauri's `"main"` `TaoWindow` (`NSWindow`) into an `AeronPopoverPanel` (`NSPanel`)
/// with `NSWindowStyleMaskNonactivatingPanel` before it is shown.
///
/// Memory safety: `NSPanel` has the exact same instance size as `NSWindow` (0 extra ivars), while
/// `TaoWindow` appends 2 trivial `Cell<bool>` flags (no `Drop`). We assert `new_cls.instance_size()
/// <= old_cls.instance_size()` and invoke `object_setClass` directly so `AeronPopoverPanel` never
/// reads past the allocated object and leaves `TaoWindow`'s trailing flags untouched.
pub fn init_popover_panel(win: &WebviewWindow) {
    if let Ok(ns_win_ptr) = win.ns_window() {
        unsafe {
            let obj = ns_win_ptr as *mut AnyObject;
            let old_cls = (*obj).class();
            let new_cls: &AnyClass = AeronPopoverPanel::class();
            if new_cls.instance_size() <= old_cls.instance_size() {
                object_setClass(obj, new_cls as *const AnyClass);
            }
        }
    }
    configure_popover_panel(win);
}

/// Applies non-activating panel, FullScreenAuxiliary, CanJoinAllSpaces, and popup window level.
pub fn configure_popover_panel(win: &WebviewWindow) {
    if let Ok(ns_win_ptr) = win.ns_window() {
        unsafe {
            let panel = &*(ns_win_ptr as *const NSPanel);
            let mask = panel.styleMask() | NSWindowStyleMask::NonactivatingPanel;
            panel.setStyleMask(mask);
            panel.setFloatingPanel(true);
            panel.setWorksWhenModal(true);
            panel.setBecomesKeyOnlyIfNeeded(false);
            panel.setHidesOnDeactivate(false);
            // CanJoinAllSpaces + FullScreenAuxiliary + NonactivatingPanel lets WindowServer
            // display the popover directly over native macOS Fullscreen Spaces.
            panel.setCollectionBehavior(
                NSWindowCollectionBehavior::CanJoinAllSpaces
                    | NSWindowCollectionBehavior::FullScreenAuxiliary
                    | NSWindowCollectionBehavior::Stationary
                    | NSWindowCollectionBehavior::IgnoresCycle,
            );
            // Match native NSPopover / menu bar popup Z-order above fullscreen apps & menu bar.
            panel.setLevel(NSPopUpMenuWindowLevel);
        }
    }
}

/// Displays the non-activating panel directly on top of the active Space (including native
/// Fullscreen Spaces) WITHOUT calling `NSApp.activateIgnoringOtherApps(true)`.
pub fn show_popover_panel(win: &WebviewWindow) {
    configure_popover_panel(win);
    if let Ok(ns_win_ptr) = win.ns_window() {
        unsafe {
            let panel = &*(ns_win_ptr as *const NSPanel);
            panel.orderFrontRegardless();
            panel.makeKeyWindow();
        }
    }
}

/// Hides the panel cleanly without disturbing the active fullscreen application.
pub fn hide_popover_panel(win: &WebviewWindow) {
    if let Ok(ns_win_ptr) = win.ns_window() {
        unsafe {
            let panel = &*(ns_win_ptr as *const NSPanel);
            panel.orderOut(None);
        }
    }
}
