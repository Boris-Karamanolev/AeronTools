//! Local HTTP JSON API for AeronTools (used by SteamOS Decky Loader plugin, CLI scripts,
//! and optional browser dashboard). Always binds to loopback `127.0.0.1`.

use std::net::SocketAddr;

use aeron_platform::AeronCore;
use aeron_protocols::hidpp::MxWheelMode;
use aeron_protocols::logitech_g::TriggerSettings;
use aeron_protocols::logitech_keyboard::{BacklightEffect, RgbLighting};
use aeron_protocols::models::{AppPreferences, AppSnapshot, GameModePolicy};
use aeron_protocols::razer_chroma::RazerLighting;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::Deserialize;
use tower_http::cors::{AllowOrigin, Any, CorsLayer};
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
struct RazerDockPayload {
    brightness: Option<u8>,
    lighting: Option<RazerLighting>,
}

pub fn build_router(core: AeronCore) -> Router {
    // Loopback only, but a page on another site can still call 127.0.0.1 unless
    // the origin is restricted. Tauri uses IPC. Decky's Python backend has no Origin.
    let cors = CorsLayer::new()
        .allow_origin(AllowOrigin::predicate(|origin, _| {
            let Ok(origin) = origin.to_str() else {
                return false;
            };
            let rest = origin
                .strip_prefix("http://localhost")
                .or_else(|| origin.strip_prefix("http://127.0.0.1"));
            match rest {
                Some("") => true,
                Some(rest) if rest.starts_with(':') => {
                    rest[1..].chars().all(|c| c.is_ascii_digit())
                }
                _ => false,
            }
        }))
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
        .route("/api/caffeine", post(set_caffeine))
        .route("/api/game-mode", post(set_game_mode))
        .route("/api/preferences", post(update_preferences))
        .route("/api/accessories/mx-master/dpi", post(set_mx_master_dpi))
        .route(
            "/api/accessories/mx-master/smart-shift",
            post(set_mx_master_smart_shift),
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
            "/api/accessories/mx-keyboard/backlight",
            post(set_mx_keyboard_backlight),
        )
        .route(
            "/api/accessories/mx-keyboard/fn-inversion",
            post(set_mx_keyboard_fn_inversion),
        )
        .route(
            "/api/accessories/g-keyboard/lighting",
            post(set_g_keyboard_lighting),
        )
        .route("/api/accessories/keychron", post(set_keychron))
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

/// Device I/O blocks (HID reads with timeouts, DDC). Keep it off the async workers.
async fn blocking<T: Send + 'static>(work: impl FnOnce() -> T + Send + 'static) -> T {
    tokio::task::spawn_blocking(work)
        .await
        .expect("aeron-daemon blocking task panicked")
}

async fn get_state(State(core): State<AeronCore>) -> Json<AppSnapshot> {
    Json(core.snapshot())
}

async fn refresh_all(State(core): State<AeronCore>) -> Json<AppSnapshot> {
    // Waits for the hardware watcher's scan; don't hold a runtime worker meanwhile.
    let blocking = core.clone();
    match tokio::task::spawn_blocking(move || blocking.refresh_all()).await {
        Ok(snapshot) => Json(snapshot),
        Err(_) => Json(core.snapshot()),
    }
}

async fn set_brightness(
    State(core): State<AeronCore>,
    Path(id): Path<String>,
    Json(body): Json<LevelPayload>,
) -> Result<Json<AppSnapshot>, (StatusCode, String)> {
    blocking(move || core.set_display_brightness(&id, body.level))
        .await
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

async fn set_volume(
    State(core): State<AeronCore>,
    Path(id): Path<String>,
    Json(body): Json<LevelPayload>,
) -> Result<Json<AppSnapshot>, (StatusCode, String)> {
    blocking(move || core.set_display_volume(&id, body.level))
        .await
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

async fn set_mute(
    State(core): State<AeronCore>,
    Path(id): Path<String>,
    Json(body): Json<MutePayload>,
) -> Result<Json<AppSnapshot>, (StatusCode, String)> {
    blocking(move || core.set_display_muted(&id, body.muted))
        .await
        .map(Json)
        .map_err(|e| (StatusCode::BAD_REQUEST, e))
}

async fn set_input(
    State(core): State<AeronCore>,
    Path(id): Path<String>,
    Json(body): Json<InputPayload>,
) -> Result<Json<AppSnapshot>, (StatusCode, String)> {
    blocking(move || core.set_display_input(&id, body.code))
        .await
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
    Json(blocking(move || core.update_preferences(prefs)).await)
}

async fn set_mx_master_dpi(
    State(core): State<AeronCore>,
    Json(body): Json<DpiPayload>,
) -> Json<AppSnapshot> {
    Json(blocking(move || core.set_mx_master_dpi(body.dpi)).await)
}

async fn set_mx_master_smart_shift(
    State(core): State<AeronCore>,
    Json(body): Json<SmartShiftPayload>,
) -> Json<AppSnapshot> {
    Json(blocking(move || core.set_mx_master_smart_shift(body.wheel_mode, body.smart_shift_enabled, body.threshold)).await)
}

async fn set_logitech_g_dpi(
    State(core): State<AeronCore>,
    Json(body): Json<DpiPayload>,
) -> Json<AppSnapshot> {
    Json(blocking(move || core.set_logitech_g_dpi(body.dpi)).await)
}

async fn set_logitech_g_report_rate(
    State(core): State<AeronCore>,
    Json(body): Json<ReportRatePayload>,
) -> Json<AppSnapshot> {
    Json(blocking(move || core.set_logitech_g_report_rate(body.hz)).await)
}

async fn set_logitech_g_triggers(
    State(core): State<AeronCore>,
    Json(body): Json<TriggerSettings>,
) -> Json<AppSnapshot> {
    Json(blocking(move || core.set_logitech_g_triggers(body)).await)
}

async fn set_mx_keyboard_backlight(
    State(core): State<AeronCore>,
    Json(body): Json<MxKeyboardPayload>,
) -> Json<AppSnapshot> {
    Json(blocking(move || core.set_mx_keyboard_backlight(
        body.enabled,
        body.auto_brightness,
        body.battery_saving,
        body.level,
        body.duration_seconds,
        body.effect,
    )).await)
}

async fn set_mx_keyboard_fn_inversion(
    State(core): State<AeronCore>,
    Json(body): Json<FnInversionPayload>,
) -> Json<AppSnapshot> {
    Json(blocking(move || core.set_mx_keyboard_fn_inversion(body.standard_fn)).await)
}

async fn set_g_keyboard_lighting(
    State(core): State<AeronCore>,
    Json(body): Json<GKeyboardPayload>,
) -> Json<AppSnapshot> {
    Json(blocking(move || core.set_g_keyboard_lighting(body.brightness, body.lighting)).await)
}

async fn set_keychron(
    State(core): State<AeronCore>,
    Json(body): Json<KeychronPayload>,
) -> Json<AppSnapshot> {
    Json(blocking(move || core.set_keychron_settings(
        body.active_stage,
        body.dpi,
        body.report_rate_hz,
        body.lift_off_mm,
        body.motion_sync,
        body.angle_snapping,
    )).await)
}

async fn set_razer_dock(
    State(core): State<AeronCore>,
    Json(body): Json<RazerDockPayload>,
) -> Json<AppSnapshot> {
    Json(blocking(move || core.set_razer_dock_lighting(body.brightness, body.lighting)).await)
}
