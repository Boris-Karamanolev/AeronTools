//! Local HTTP JSON API for AeronTools (used by SteamOS Decky Loader plugin, CLI scripts,
//! and optional browser dashboard). Always binds to loopback `127.0.0.1`.

use std::net::SocketAddr;

use aeron_platform::AeronCore;
use aeron_protocols::hidpp::MxWheelMode;
use aeron_protocols::logitech_g::TriggerSettings;
use aeron_protocols::logitech_keyboard::{BacklightEffect, RgbLighting};
use aeron_protocols::models::{
    AccessoryButtonAction, AppPreferences, AppSnapshot, GameModePolicy, MxMasterOptions,
};
use aeron_protocols::razer_chroma::RazerLighting;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::Deserialize;
use tower_http::cors::{Any, CorsLayer};
use tracing::info;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LevelPayload {
    level: f32,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MutePayload {
    muted: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct InputPayload {
    code: u8,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BuiltinEnabledPayload {
    enabled: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CaffeinePayload {
    active: bool,
    duration_seconds: Option<u64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GameModePayload {
    policy: GameModePolicy,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DpiPayload {
    dpi: u16,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SmartShiftPayload {
    wheel_mode: MxWheelMode,
    smart_shift_enabled: bool,
    threshold: u8,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReportRatePayload {
    hz: u16,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LogitechGOptionsPayload {
    back_button: AccessoryButtonAction,
    forward_button: AccessoryButtonAction,
    saves_to_onboard_profile: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MxKeyboardPayload {
    enabled: bool,
    auto_brightness: bool,
    #[serde(default)]
    battery_saving: bool,
    level: u8,
    #[serde(default = "default_duration")]
    duration_seconds: u16,
    effect: BacklightEffect,
}

fn default_duration() -> u16 {
    60
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FnInversionPayload {
    standard_fn: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct KeyActionPayload {
    position: u8,
    action: AccessoryButtonAction,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GKeyboardPayload {
    brightness: u16,
    lighting: RgbLighting,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct KeychronPayload {
    active_stage: u8,
    dpi: u16,
    report_rate_hz: u16,
    lift_off_mm: u8,
    motion_sync: bool,
    angle_snapping: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct KeychronButtonsPayload {
    back_button: AccessoryButtonAction,
    forward_button: AccessoryButtonAction,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RazerDockPayload {
    brightness: Option<u8>,
    lighting: Option<RazerLighting>,
}

pub fn build_router(core: AeronCore) -> Router {
    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any);

    Router::new()
        .route("/api/health", get(|| async { "ok" }))
        .route("/api/state", get(get_state))
        .route("/api/refresh", post(refresh_all))
        .route("/api/displays/:id/brightness", post(set_brightness))
        .route("/api/displays/:id/volume", post(set_volume))
        .route("/api/displays/:id/mute", post(set_mute))
        .route("/api/displays/:id/input", post(set_input))
        .route("/api/displays/builtin", post(set_builtin_enabled))
        .route("/api/displays/builtin/toggle", post(toggle_builtin))
        .route("/api/caffeine", post(set_caffeine))
        .route("/api/game-mode", post(set_game_mode))
        .route("/api/preferences", post(update_preferences))
        .route("/api/accessories/mx-master/dpi", post(set_mx_master_dpi))
        .route(
            "/api/accessories/mx-master/smart-shift",
            post(set_mx_master_smart_shift),
        )
        .route(
            "/api/accessories/mx-master/options",
            post(set_mx_master_options),
        )
        .route("/api/accessories/logitech-g/dpi", post(set_logitech_g_dpi))
        .route(
            "/api/accessories/logitech-g/report-rate",
            post(set_logitech_g_report_rate),
        )
        .route(
            "/api/accessories/logitech-g/triggers",
            post(set_logitech_g_triggers),
        )
        .route(
            "/api/accessories/logitech-g/options",
            post(set_logitech_g_options),
        )
        .route(
            "/api/accessories/mx-keyboard/backlight",
            post(set_mx_keyboard_backlight),
        )
        .route(
            "/api/accessories/mx-keyboard/fn-inversion",
            post(set_mx_keyboard_fn_inversion),
        )
        .route(
            "/api/accessories/mx-keyboard/key-action",
            post(set_mx_keyboard_key_action),
        )
        .route(
            "/api/accessories/g-keyboard/lighting",
            post(set_g_keyboard_lighting),
        )
        .route("/api/accessories/keychron", post(set_keychron))
        .route(
            "/api/accessories/keychron/buttons",
            post(set_keychron_buttons),
        )
        .route("/api/accessories/razer-dock", post(set_razer_dock))
        .layer(cors)
        .with_state(core)
}

pub async fn serve(core: AeronCore, port: u16) -> Result<(), std::io::Error> {
    let addr = SocketAddr::from(([127, 0, 0, 1], port));
    let listener = tokio::net::TcpListener::bind(addr).await?;
    info!("AeronTools local API listening on http://{addr}");
    axum::serve(listener, build_router(core)).await
}

async fn get_state(State(core): State<AeronCore>) -> Json<AppSnapshot> {
    Json(core.snapshot())
}

async fn refresh_all(State(core): State<AeronCore>) -> Json<AppSnapshot> {
    Json(core.refresh_all())
}

async fn set_brightness(
    State(core): State<AeronCore>,
    Path(id): Path<String>,
    Json(body): Json<LevelPayload>,
) -> Result<Json<AppSnapshot>, (StatusCode, String)> {
    core.set_display_brightness(&id, body.level)
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

async fn set_volume(
    State(core): State<AeronCore>,
    Path(id): Path<String>,
    Json(body): Json<LevelPayload>,
) -> Result<Json<AppSnapshot>, (StatusCode, String)> {
    core.set_display_volume(&id, body.level)
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

async fn set_mute(
    State(core): State<AeronCore>,
    Path(id): Path<String>,
    Json(body): Json<MutePayload>,
) -> Result<Json<AppSnapshot>, (StatusCode, String)> {
    core.set_display_muted(&id, body.muted)
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

async fn set_input(
    State(core): State<AeronCore>,
    Path(id): Path<String>,
    Json(body): Json<InputPayload>,
) -> Result<Json<AppSnapshot>, (StatusCode, String)> {
    core.set_display_input(&id, body.code)
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

async fn set_builtin_enabled(
    State(core): State<AeronCore>,
    Json(body): Json<BuiltinEnabledPayload>,
) -> Result<Json<AppSnapshot>, (StatusCode, String)> {
    core.set_builtin_display_enabled(body.enabled)
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

async fn toggle_builtin(
    State(core): State<AeronCore>,
) -> Result<Json<AppSnapshot>, (StatusCode, String)> {
    core.toggle_builtin_display()
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

async fn set_caffeine(
    State(core): State<AeronCore>,
    Json(body): Json<CaffeinePayload>,
) -> Result<Json<AppSnapshot>, (StatusCode, String)> {
    core.set_caffeine(body.active, body.duration_seconds)
        .map(Json)
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))
}

async fn set_game_mode(
    State(core): State<AeronCore>,
    Json(body): Json<GameModePayload>,
) -> Result<Json<AppSnapshot>, (StatusCode, String)> {
    core.set_game_mode_policy(body.policy)
        .map(Json)
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e))
}

async fn update_preferences(
    State(core): State<AeronCore>,
    Json(prefs): Json<AppPreferences>,
) -> Json<AppSnapshot> {
    Json(core.update_preferences(prefs))
}

async fn set_mx_master_dpi(
    State(core): State<AeronCore>,
    Json(body): Json<DpiPayload>,
) -> Json<AppSnapshot> {
    Json(core.set_mx_master_dpi(body.dpi))
}

async fn set_mx_master_smart_shift(
    State(core): State<AeronCore>,
    Json(body): Json<SmartShiftPayload>,
) -> Json<AppSnapshot> {
    Json(core.set_mx_master_smart_shift(
        body.wheel_mode,
        body.smart_shift_enabled,
        body.threshold,
    ))
}

async fn set_mx_master_options(
    State(core): State<AeronCore>,
    Json(body): Json<MxMasterOptions>,
) -> Json<AppSnapshot> {
    Json(core.set_mx_master_options(body))
}

async fn set_logitech_g_dpi(
    State(core): State<AeronCore>,
    Json(body): Json<DpiPayload>,
) -> Json<AppSnapshot> {
    Json(core.set_logitech_g_dpi(body.dpi))
}

async fn set_logitech_g_report_rate(
    State(core): State<AeronCore>,
    Json(body): Json<ReportRatePayload>,
) -> Json<AppSnapshot> {
    Json(core.set_logitech_g_report_rate(body.hz))
}

async fn set_logitech_g_triggers(
    State(core): State<AeronCore>,
    Json(body): Json<TriggerSettings>,
) -> Json<AppSnapshot> {
    Json(core.set_logitech_g_triggers(body))
}

async fn set_logitech_g_options(
    State(core): State<AeronCore>,
    Json(body): Json<LogitechGOptionsPayload>,
) -> Json<AppSnapshot> {
    Json(core.set_logitech_g_options(
        body.back_button,
        body.forward_button,
        body.saves_to_onboard_profile,
    ))
}

async fn set_mx_keyboard_backlight(
    State(core): State<AeronCore>,
    Json(body): Json<MxKeyboardPayload>,
) -> Json<AppSnapshot> {
    Json(core.set_mx_keyboard_backlight(
        body.enabled,
        body.auto_brightness,
        body.battery_saving,
        body.level,
        body.duration_seconds,
        body.effect,
    ))
}

async fn set_mx_keyboard_fn_inversion(
    State(core): State<AeronCore>,
    Json(body): Json<FnInversionPayload>,
) -> Json<AppSnapshot> {
    Json(core.set_mx_keyboard_fn_inversion(body.standard_fn))
}

async fn set_mx_keyboard_key_action(
    State(core): State<AeronCore>,
    Json(body): Json<KeyActionPayload>,
) -> Json<AppSnapshot> {
    Json(core.set_mx_keyboard_key_action(body.position, body.action))
}

async fn set_g_keyboard_lighting(
    State(core): State<AeronCore>,
    Json(body): Json<GKeyboardPayload>,
) -> Json<AppSnapshot> {
    Json(core.set_g_keyboard_lighting(body.brightness, body.lighting))
}

async fn set_keychron(
    State(core): State<AeronCore>,
    Json(body): Json<KeychronPayload>,
) -> Json<AppSnapshot> {
    Json(core.set_keychron_settings(
        body.active_stage,
        body.dpi,
        body.report_rate_hz,
        body.lift_off_mm,
        body.motion_sync,
        body.angle_snapping,
    ))
}

async fn set_keychron_buttons(
    State(core): State<AeronCore>,
    Json(body): Json<KeychronButtonsPayload>,
) -> Json<AppSnapshot> {
    Json(core.set_keychron_side_buttons(body.back_button, body.forward_button))
}

async fn set_razer_dock(
    State(core): State<AeronCore>,
    Json(body): Json<RazerDockPayload>,
) -> Json<AppSnapshot> {
    Json(core.set_razer_dock_lighting(body.brightness, body.lighting))
}
