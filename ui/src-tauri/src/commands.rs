use aeron_platform::AeronCore;
use aeron_protocols::hidpp::MxWheelMode;
use aeron_protocols::logitech_g::TriggerSettings;
use aeron_protocols::logitech_keyboard::{BacklightEffect, RgbLighting};
use aeron_protocols::models::{AppPreferences, AppSnapshot, GameModePolicy};
use aeron_protocols::razer_chroma::RazerLighting;
use serde::Serialize;
use tauri::{AppHandle, Emitter, LogicalSize, Manager, Size, State};

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct SettingsNavPayload {
    tab: String,
    accessory: Option<String>,
}

#[tauri::command]
pub fn get_snapshot(core: State<'_, AeronCore>) -> AppSnapshot {
    core.snapshot()
}

/// Waits for the hardware watcher's scan (seconds on Windows), so it must not run on the main thread.
#[tauri::command]
pub async fn refresh_all(core: State<'_, AeronCore>) -> Result<AppSnapshot, String> {
    let core = core.inner().clone();
    tauri::async_runtime::spawn_blocking(move || core.refresh_all())
        .await
        .map_err(|err| err.to_string())
}

#[tauri::command]
pub fn set_display_brightness(
    core: State<'_, AeronCore>,
    display_id: String,
    level: f32,
) -> Result<AppSnapshot, String> {
    core.set_display_brightness(&display_id, level)
}

#[tauri::command]
pub fn set_display_volume(
    core: State<'_, AeronCore>,
    display_id: String,
    level: f32,
) -> Result<AppSnapshot, String> {
    core.set_display_volume(&display_id, level)
}

#[tauri::command]
pub fn set_display_muted(
    core: State<'_, AeronCore>,
    display_id: String,
    muted: bool,
) -> Result<AppSnapshot, String> {
    core.set_display_muted(&display_id, muted)
}

#[tauri::command]
pub fn set_display_input(
    core: State<'_, AeronCore>,
    display_id: String,
    input_code: u8,
) -> Result<AppSnapshot, String> {
    core.set_display_input(&display_id, input_code)
}

#[tauri::command]
pub fn set_caffeine(
    core: State<'_, AeronCore>,
    active: bool,
    duration_seconds: Option<u64>,
) -> Result<AppSnapshot, String> {
    core.set_caffeine(active, duration_seconds)
}

#[tauri::command]
pub fn toggle_caffeine(core: State<'_, AeronCore>) -> Result<AppSnapshot, String> {
    core.toggle_caffeine()
}

#[tauri::command]
pub fn set_game_mode_policy(
    core: State<'_, AeronCore>,
    policy: GameModePolicy,
) -> Result<AppSnapshot, String> {
    core.set_game_mode_policy(policy)
}

#[tauri::command]
pub fn toggle_game_mode_forced(core: State<'_, AeronCore>) -> Result<AppSnapshot, String> {
    core.toggle_game_mode_forced()
}

#[tauri::command]
pub fn update_preferences(core: State<'_, AeronCore>, prefs: AppPreferences) -> AppSnapshot {
    core.update_preferences(prefs)
}

#[tauri::command]
pub fn set_mx_master_dpi(core: State<'_, AeronCore>, dpi: u16) -> AppSnapshot {
    core.set_mx_master_dpi(dpi)
}

#[tauri::command]
pub fn set_mx_master_smart_shift(
    core: State<'_, AeronCore>,
    wheel_mode: MxWheelMode,
    smart_shift_enabled: bool,
    threshold: u8,
) -> AppSnapshot {
    core.set_mx_master_smart_shift(wheel_mode, smart_shift_enabled, threshold)
}

#[tauri::command]
pub fn set_logitech_g_dpi(core: State<'_, AeronCore>, dpi: u16) -> AppSnapshot {
    core.set_logitech_g_dpi(dpi)
}

#[tauri::command]
pub fn set_logitech_g_report_rate(core: State<'_, AeronCore>, hz: u16) -> AppSnapshot {
    core.set_logitech_g_report_rate(hz)
}

#[tauri::command]
pub fn set_logitech_g_triggers(
    core: State<'_, AeronCore>,
    triggers: TriggerSettings,
) -> AppSnapshot {
    core.set_logitech_g_triggers(triggers)
}

#[tauri::command]
pub fn set_mx_keyboard_backlight(
    core: State<'_, AeronCore>,
    enabled: bool,
    auto_brightness: bool,
    battery_saving: bool,
    level: u8,
    duration_seconds: u16,
    effect: BacklightEffect,
) -> AppSnapshot {
    core.set_mx_keyboard_backlight(
        enabled,
        auto_brightness,
        battery_saving,
        level,
        duration_seconds,
        effect,
    )
}

#[tauri::command]
pub fn set_mx_keyboard_fn_inversion(core: State<'_, AeronCore>, standard_fn: bool) -> AppSnapshot {
    core.set_mx_keyboard_fn_inversion(standard_fn)
}

#[tauri::command]
pub fn set_g_keyboard_lighting(
    core: State<'_, AeronCore>,
    brightness: u16,
    lighting: RgbLighting,
) -> AppSnapshot {
    core.set_g_keyboard_lighting(brightness, lighting)
}

#[tauri::command]
pub fn set_keychron_settings(
    core: State<'_, AeronCore>,
    active_stage: u8,
    dpi: u16,
    report_rate_hz: u16,
    lift_off_mm: u8,
    motion_sync: bool,
    angle_snapping: bool,
) -> AppSnapshot {
    core.set_keychron_settings(
        active_stage,
        dpi,
        report_rate_hz,
        lift_off_mm,
        motion_sync,
        angle_snapping,
    )
}

#[tauri::command]
pub fn set_razer_dock_lighting(
    core: State<'_, AeronCore>,
    brightness: Option<u8>,
    lighting: Option<RazerLighting>,
) -> AppSnapshot {
    core.set_razer_dock_lighting(brightness, lighting)
}

#[tauri::command]
pub fn open_settings(app: AppHandle, tab: Option<String>, accessory: Option<String>) {
    // Trigger an immediate background refresh of HID accessories & dock topology when opening Settings
    let refresh_core = app.state::<AeronCore>().inner().clone();
    std::thread::spawn(move || {
        refresh_core.refresh_accessories_and_docks();
    });
    // Close popover like StatusBarController.shared.closePopover()
    if let Some(main_win) = app.get_webview_window("main") {
        let _ = main_win.hide();
    }
    if let Some(settings_win) = app.get_webview_window("settings") {
        let _ = settings_win.show();
        let _ = settings_win.unminimize();
        let _ = settings_win.set_focus();
        let payload = SettingsNavPayload {
            tab: tab.unwrap_or_else(|| "general".to_string()),
            accessory,
        };
        let _ = settings_win.emit("navigate-settings", payload);
    }
}

#[tauri::command]
pub fn resize_popover(app: AppHandle, height: f64) {
    if let Some(win) = app.get_webview_window("main") {
        let clamped = height.clamp(180.0, 780.0).ceil();
        let _ = win.set_size(Size::Logical(LogicalSize::new(340.0, clamped)));
    }
}

#[tauri::command]
pub fn quit_app(app: AppHandle, core: State<'_, AeronCore>) {
    core.prepare_for_termination();
    app.exit(0);
}
