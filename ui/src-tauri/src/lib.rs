mod commands;
#[cfg(target_os = "macos")]
#[path = "../../../platforms/macos/shell/macos_panel.rs"]
mod macos_panel;

use aeron_platform::AeronCore;
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::image::Image;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{Manager, PhysicalPosition, Position, Rect, WindowEvent};
use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, ShortcutState};
use tracing::{info, warn};
use tracing_subscriber::EnvFilter;

const POPOVER_WIDTH: f64 = 340.0;

/// Tracks when the popover last hid on focus loss so clicking the tray icon while
/// the popover is already open toggles it shut instead of immediately reopening it.
static LAST_POPOVER_BLUR: Mutex<Option<Instant>> = Mutex::new(None);

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env().add_directive("info".parse().unwrap()))
        .try_init();

    let core = AeronCore::new();
    let api_core = core.clone();
    let shortcut_core = core.clone();
    let daemon_port = core.snapshot().preferences.daemon_port;

    tauri::Builder::default()
        .manage(core)
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(move |_app, shortcut, event| {
                    if event.state() != ShortcutState::Pressed {
                        return;
                    }
                    info!("Global shortcut pressed: {shortcut}");
                    match shortcut.key {
                        Code::KeyC => {
                            let _ = shortcut_core.toggle_caffeine();
                        }
                        Code::KeyG => {
                            let _ = shortcut_core.toggle_game_mode_forced();
                        }
                        Code::F2 => {
                            let _ = shortcut_core.step_all_brightness(0.1);
                        }
                        Code::F1 => {
                            let _ = shortcut_core.step_all_brightness(-0.1);
                        }
                        _ => {}
                    }
                })
                .build(),
        )
        .setup(move |app| {
            // Run as a macOS menu bar accessory app (LSUIElement / Accessory activation policy)
            // so the popover can float directly over other windows and native Fullscreen Spaces
            // without forcing a Space switch back to the desktop.
            #[cfg(target_os = "macos")]
            {
                app.set_activation_policy(tauri::ActivationPolicy::Accessory);
            }

            // Expose the local loopback HTTP API so SteamOS Decky Loader or CLI tools can talk
            // directly to this running instance (silently skipped if aeron-daemon already owns the port).
            tauri::async_runtime::spawn(async move {
                if let Err(err) = aeron_daemon::serve(api_core, daemon_port).await {
                    warn!("Local API port {daemon_port} unavailable (daemon may already be running): {err}");
                }
            });

            // Register default global shortcuts (best-effort; Wayland may restrict global grabs)
            for accel in [
                "Ctrl+Alt+F1",
                "Ctrl+Alt+F2",
                "Ctrl+Alt+C",
                "Ctrl+Alt+G",
            ] {
                if let Err(err) = app.global_shortcut().register(accel) {
                    warn!("Could not register global shortcut {accel}: {err}");
                }
            }

            // Build native system tray icon and menu
            let show_item = MenuItem::with_id(app, "show", "Show Aeron Tools", true, None::<&str>)?;
            let settings_item = MenuItem::with_id(app, "settings", "Settings…", true, None::<&str>)?;
            let caffeine_item =
                MenuItem::with_id(app, "caffeine", "Toggle Caffeine", true, None::<&str>)?;
            let gamemode_item =
                MenuItem::with_id(app, "gamemode", "Toggle Game Mode", true, None::<&str>)?;
            let refresh_item =
                MenuItem::with_id(app, "refresh", "Refresh Devices", true, None::<&str>)?;
            let quit_item = MenuItem::with_id(app, "quit", "Quit Aeron Tools", true, None::<&str>)?;

            let menu = Menu::with_items(
                app,
                &[
                    &show_item,
                    &settings_item,
                    &caffeine_item,
                    &gamemode_item,
                    &refresh_item,
                    &quit_item,
                ],
            )?;

            let mut tray_builder = TrayIconBuilder::new()
                .menu(&menu)
                .show_menu_on_left_click(false)
                .tooltip("Aeron Tools")
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "show" => toggle_main_window(app, true, None),
                    "settings" => commands::open_settings(app.clone(), Some("general".into()), None),
                    "caffeine" => {
                        let _ = app.state::<AeronCore>().toggle_caffeine();
                    }
                    "gamemode" => {
                        let _ = app.state::<AeronCore>().toggle_game_mode_forced();
                    }
                    "refresh" => {
                        // Blocks until the watcher's scan finishes; keep it off the event loop.
                        let core = app.state::<AeronCore>().inner().clone();
                        std::thread::spawn(move || {
                            let _ = core.refresh_all();
                        });
                    }
                    "quit" => {
                        app.state::<AeronCore>().prepare_for_termination();
                        app.exit(0);
                    }
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        rect,
                        ..
                    } = event
                    {
                        toggle_main_window(tray.app_handle(), false, Some(rect));
                    }
                });

            // Use the dedicated crisp monochrome template glyph in the macOS menu bar
            // (matching AeronToolsIcon.menuBarImage in StatusBarController.swift)
            if let Ok(tray_icon) = Image::from_bytes(include_bytes!("../icons/tray-icon.png")) {
                tray_builder = tray_builder.icon(tray_icon);
                #[cfg(target_os = "macos")]
                {
                    tray_builder = tray_builder.icon_as_template(true);
                }
            } else if let Some(icon) = app.default_window_icon() {
                tray_builder = tray_builder.icon(icon.clone());
            }
            tray_builder.build(app)?;

            // Convert `"main"` into a true non-activating NSPanel (macOS) BEFORE its first display
            // so WindowServer registers it as a FullScreenAuxiliary panel that overlays fullscreen apps.
            if let Some(win) = app.get_webview_window("main") {
                init_popover_window(&win);
                if let Ok(Some(monitor)) = win.current_monitor() {
                    let scale = monitor.scale_factor();
                    let mon_pos = monitor.position();
                    let mon_size = monitor.size();
                    let win_w = (POPOVER_WIDTH * scale) as i32;
                    let margin = (16.0 * scale) as i32;
                    let top_offset = (38.0 * scale) as i32;
                    let x = (mon_pos.x + mon_size.width as i32 - win_w - margin).max(mon_pos.x);
                    let y = mon_pos.y + top_offset;
                    let _ = win.set_position(Position::Physical(PhysicalPosition::new(x, y)));
                }
                show_popover_window(&win);
            }

            Ok(())
        })
        .on_window_event(|window, event| match event {
            WindowEvent::CloseRequested { api, .. } => {
                // Keep windows alive in tray / instant reopen
                let _ = window.hide();
                api.prevent_close();
            }
            WindowEvent::Focused(false) => {
                // Transient NSPopover feel: hide main popover when clicking outside
                if window.label() == "main" {
                    if let Ok(mut guard) = LAST_POPOVER_BLUR.lock() {
                        *guard = Some(Instant::now());
                    }
                    let _ = window.hide();
                }
            }
            _ => {}
        })
        .invoke_handler(tauri::generate_handler![
            commands::get_snapshot,
            commands::refresh_all,
            commands::set_display_brightness,
            commands::set_display_volume,
            commands::set_display_muted,
            commands::set_display_input,
            commands::set_caffeine,
            commands::toggle_caffeine,
            commands::set_game_mode_policy,
            commands::toggle_game_mode_forced,
            commands::update_preferences,
            commands::set_mx_master_dpi,
            commands::set_mx_master_smart_shift,
            commands::set_logitech_g_dpi,
            commands::set_logitech_g_report_rate,
            commands::set_logitech_g_triggers,
            commands::set_mx_keyboard_backlight,
            commands::set_mx_keyboard_fn_inversion,
            commands::set_g_keyboard_lighting,
            commands::set_keychron_settings,
            commands::set_razer_dock_lighting,
            commands::open_settings,
            commands::resize_popover,
            commands::quit_app,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Aeron Tools Tauri application");
}

fn init_popover_window(win: &tauri::WebviewWindow) {
    let _ = win.set_always_on_top(true);
    let _ = win.set_visible_on_all_workspaces(true);
    #[cfg(target_os = "macos")]
    {
        macos_panel::init_popover_panel(win);
    }
}

fn show_popover_window(win: &tauri::WebviewWindow) {
    #[cfg(target_os = "macos")]
    {
        // Show via NSPanel::orderFrontRegardless + makeKeyWindow WITHOUT activating NSApp,
        // which keeps macOS inside the current Fullscreen Space and renders directly on top.
        macos_panel::show_popover_panel(win);
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = win.set_always_on_top(true);
        let _ = win.set_visible_on_all_workspaces(true);
        let _ = win.show();
        let _ = win.unminimize();
        let _ = win.set_focus();
    }
}

fn hide_popover_window(win: &tauri::WebviewWindow) {
    #[cfg(target_os = "macos")]
    {
        macos_panel::hide_popover_panel(win);
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = win.hide();
    }
}

fn toggle_main_window(app: &tauri::AppHandle, force_show: bool, tray_rect: Option<Rect>) {
    let Some(win) = app.get_webview_window("main") else {
        return;
    };
    let visible = win.is_visible().unwrap_or(false);
    if visible && !force_show {
        hide_popover_window(&win);
        return;
    }

    // If the popover just auto-hid because the user clicked the tray icon to dismiss it,
    // don't immediately re-open it on the matching MouseUp event.
    if !force_show {
        if let Ok(mut guard) = LAST_POPOVER_BLUR.lock() {
            if let Some(at) = *guard {
                if at.elapsed() < Duration::from_millis(250) {
                    *guard = None;
                    return;
                }
            }
        }
    }

    // Trigger an immediate background refresh of HID accessories & dock ports on popover open
    // (mirrors Swift's `popoverWillShow`).
    let core = app.state::<AeronCore>().inner().clone();
    std::thread::spawn(move || {
        core.refresh_accessories_and_docks();
    });

    if let Some(rect) = tray_rect {
        position_popover_near_tray(&win, rect);
    }

    show_popover_window(&win);
}

fn position_popover_near_tray(win: &tauri::WebviewWindow, rect: Rect) {
    let fallback_scale = win.scale_factor().unwrap_or(1.0);
    let raw_pos = rect.position.to_physical::<i32>(fallback_scale);
    let raw_size = rect.size.to_physical::<i32>(fallback_scale);
    let click_cx = raw_pos.x + raw_size.width / 2;
    let click_cy = raw_pos.y + raw_size.height / 2;

    // Pick the monitor containing the clicked tray icon (important on multi-display & fullscreen setups)
    let target_monitor = win
        .available_monitors()
        .ok()
        .and_then(|monitors| {
            monitors.into_iter().find(|m| {
                let pos = m.position();
                let size = m.size();
                click_cx >= pos.x
                    && click_cx < pos.x + size.width as i32
                    && click_cy >= pos.y
                    && click_cy < pos.y + size.height as i32
            })
        })
        .or_else(|| win.current_monitor().ok().flatten());

    let scale = target_monitor
        .as_ref()
        .map(|m| m.scale_factor())
        .unwrap_or(fallback_scale);
    let tray_pos = rect.position.to_physical::<i32>(scale);
    let tray_size = rect.size.to_physical::<i32>(scale);

    let win_size = win.outer_size().unwrap_or_else(|_| {
        tauri::PhysicalSize::new((POPOVER_WIDTH * scale) as u32, (540.0 * scale) as u32)
    });

    let win_w = win_size.width as i32;
    let win_h = win_size.height as i32;
    let gap = (8.0 * scale) as i32;

    let mut x = tray_pos.x + (tray_size.width / 2) - (win_w / 2);
    let mut y = tray_pos.y + tray_size.height + gap;

    if let Some(monitor) = target_monitor {
        let mon_pos = monitor.position();
        let mon_size = monitor.size();
        let max_x = mon_pos.x + mon_size.width as i32 - win_w - (10.0 * scale) as i32;
        let min_x = mon_pos.x + (10.0 * scale) as i32;
        x = x.clamp(min_x, max_x.max(min_x));

        // If tray is at the bottom of the screen (Windows taskbar / KDE panel), place popover above tray
        if y + win_h > mon_pos.y + mon_size.height as i32 {
            y = (tray_pos.y - win_h - gap).max(mon_pos.y + (10.0 * scale) as i32);
        }
    }

    let _ = win.set_position(Position::Physical(PhysicalPosition::new(x, y)));
}
