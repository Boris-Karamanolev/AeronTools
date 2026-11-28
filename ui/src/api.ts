import { invoke } from "@tauri-apps/api/core";
import type {
  AppPreferences,
  AppSnapshot,
  BacklightEffect,
  GameModePolicy,
  MxWheelMode,
  RazerLighting,
  RgbLighting,
  TriggerSettings,
} from "./types";

const DAEMON_BASE = "http://127.0.0.1:47620";

export function isTauriRuntime(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

async function httpJson<T>(
  path: string,
  method: "GET" | "POST" = "GET",
  body?: unknown
): Promise<T> {
  const res = await fetch(`${DAEMON_BASE}${path}`, {
    method,
    headers: body !== undefined ? { "Content-Type": "application/json" } : undefined,
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) {
    throw new Error(`Daemon API error (${res.status}): ${await res.text()}`);
  }
  return (await res.json()) as T;
}

export const aeronApi = {
  getSnapshot(): Promise<AppSnapshot> {
    return isTauriRuntime() ? invoke("get_snapshot") : httpJson("/api/state");
  },

  refreshAll(): Promise<AppSnapshot> {
    return isTauriRuntime() ? invoke("refresh_all") : httpJson("/api/refresh", "POST");
  },

  setDisplayBrightness(displayId: string, level: number): Promise<AppSnapshot> {
    return isTauriRuntime()
      ? invoke("set_display_brightness", { displayId, level })
      : httpJson(`/api/displays/${encodeURIComponent(displayId)}/brightness`, "POST", { level });
  },

  setDisplayVolume(displayId: string, level: number): Promise<AppSnapshot> {
    return isTauriRuntime()
      ? invoke("set_display_volume", { displayId, level })
      : httpJson(`/api/displays/${encodeURIComponent(displayId)}/volume`, "POST", { level });
  },

  setDisplayMuted(displayId: string, muted: boolean): Promise<AppSnapshot> {
    return isTauriRuntime()
      ? invoke("set_display_muted", { displayId, muted })
      : httpJson(`/api/displays/${encodeURIComponent(displayId)}/mute`, "POST", { muted });
  },

  setDisplayInput(displayId: string, inputCode: number): Promise<AppSnapshot> {
    return isTauriRuntime()
      ? invoke("set_display_input", { displayId, inputCode })
      : httpJson(`/api/displays/${encodeURIComponent(displayId)}/input`, "POST", {
          code: inputCode,
        });
  },

  setCaffeine(active: boolean, durationSeconds: number | null): Promise<AppSnapshot> {
    return isTauriRuntime()
      ? invoke("set_caffeine", { active, durationSeconds })
      : httpJson("/api/caffeine", "POST", { active, durationSeconds });
  },

  toggleCaffeine(): Promise<AppSnapshot> {
    return isTauriRuntime()
      ? invoke("toggle_caffeine")
      : httpJson("/api/caffeine", "POST", { active: true, durationSeconds: null });
  },

  setGameModePolicy(policy: GameModePolicy): Promise<AppSnapshot> {
    return isTauriRuntime()
      ? invoke("set_game_mode_policy", { policy })
      : httpJson("/api/game-mode", "POST", { policy });
  },

  toggleGameModeForced(): Promise<AppSnapshot> {
    return isTauriRuntime()
      ? invoke("toggle_game_mode_forced")
      : httpJson("/api/game-mode", "POST", { policy: "forcedOn" });
  },

  updatePreferences(prefs: AppPreferences): Promise<AppSnapshot> {
    return isTauriRuntime()
      ? invoke("update_preferences", { prefs })
      : httpJson("/api/preferences", "POST", prefs);
  },

  setMxMasterDpi(dpi: number): Promise<AppSnapshot> {
    return isTauriRuntime()
      ? invoke("set_mx_master_dpi", { dpi })
      : httpJson("/api/accessories/mx-master/dpi", "POST", { dpi });
  },

  setMxMasterSmartShift(
    wheelMode: MxWheelMode,
    smartShiftEnabled: boolean,
    threshold: number
  ): Promise<AppSnapshot> {
    return isTauriRuntime()
      ? invoke("set_mx_master_smart_shift", { wheelMode, smartShiftEnabled, threshold })
      : httpJson("/api/accessories/mx-master/smart-shift", "POST", {
          wheelMode,
          smartShiftEnabled,
          threshold,
        });
  },

  setLogitechGDpi(dpi: number): Promise<AppSnapshot> {
    return isTauriRuntime()
      ? invoke("set_logitech_g_dpi", { dpi })
      : httpJson("/api/accessories/logitech-g/dpi", "POST", { dpi });
  },

  setLogitechGReportRate(hz: number): Promise<AppSnapshot> {
    return isTauriRuntime()
      ? invoke("set_logitech_g_report_rate", { hz })
      : httpJson("/api/accessories/logitech-g/report-rate", "POST", { hz });
  },

  setLogitechGTriggers(triggers: TriggerSettings): Promise<AppSnapshot> {
    return isTauriRuntime()
      ? invoke("set_logitech_g_triggers", { triggers })
      : httpJson("/api/accessories/logitech-g/triggers", "POST", triggers);
  },

  setMxKeyboardBacklight(params: {
    enabled: boolean;
    autoBrightness: boolean;
    batterySaving: boolean;
    level: number;
    durationSeconds: number;
    effect: BacklightEffect;
  }): Promise<AppSnapshot> {
    return isTauriRuntime()
      ? invoke("set_mx_keyboard_backlight", params)
      : httpJson("/api/accessories/mx-keyboard/backlight", "POST", params);
  },

  setMxKeyboardFnInversion(standardFn: boolean): Promise<AppSnapshot> {
    return isTauriRuntime()
      ? invoke("set_mx_keyboard_fn_inversion", { standardFn })
      : httpJson("/api/accessories/mx-keyboard/fn-inversion", "POST", { standardFn });
  },

  setGKeyboardLighting(brightness: number, lighting: RgbLighting): Promise<AppSnapshot> {
    return isTauriRuntime()
      ? invoke("set_g_keyboard_lighting", { brightness, lighting })
      : httpJson("/api/accessories/g-keyboard/lighting", "POST", { brightness, lighting });
  },

  setKeychronSettings(params: {
    activeStage: number;
    dpi: number;
    reportRateHz: number;
    liftOffMm: number;
    motionSync: boolean;
    angleSnapping: boolean;
  }): Promise<AppSnapshot> {
    return isTauriRuntime()
      ? invoke("set_keychron_settings", params)
      : httpJson("/api/accessories/keychron", "POST", params);
  },

  setRazerDockLighting(
    brightness: number | null,
    lighting: RazerLighting | null
  ): Promise<AppSnapshot> {
    return isTauriRuntime()
      ? invoke("set_razer_dock_lighting", { brightness, lighting })
      : httpJson("/api/accessories/razer-dock", "POST", { brightness, lighting });
  },

  openSettings(tab?: string, accessory?: string): Promise<void> {
    if (isTauriRuntime()) {
      return invoke("open_settings", { tab: tab ?? null, accessory: accessory ?? null });
    }
    return Promise.resolve();
  },

  resizePopover(height: number): Promise<void> {
    if (isTauriRuntime()) {
      return invoke("resize_popover", { height });
    }
    return Promise.resolve();
  },

  quitApp(): Promise<void> {
    return isTauriRuntime() ? invoke("quit_app") : Promise.resolve();
  },
};
