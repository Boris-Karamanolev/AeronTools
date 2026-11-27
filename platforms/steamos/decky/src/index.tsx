import { useCallback, useEffect, useRef, useState } from "react";
import { definePlugin, callable } from "@decky/api";
import {
  ButtonItem,
  DropdownItem,
  PanelSection,
  PanelSectionRow,
  SliderField,
  ToggleField,
} from "@decky/ui";
import type {
  AppSnapshot,
  DockLayout,
  GameModePolicy,
  MxWheelMode,
  RazerLighting,
  RazerMode,
  RgbEffect,
} from "../../../../ui/src/types";

const getState = callable<[], AppSnapshot>("get_state");
const postAction = callable<[path: string, payload: Record<string, unknown>], AppSnapshot>(
  "post_action"
);

const GAME_MODE_OPTIONS: Array<{ data: GameModePolicy; label: string }> = [
  { data: "automatic", label: "Automatic" },
  { data: "forcedOn", label: "Force On" },
  { data: "forcedOff", label: "Off" },
];

const RGB_EFFECT_LABELS: Record<RgbEffect, string> = {
  off: "Off",
  fixed: "Fixed Color",
  breathing: "Breathing",
  colorCycle: "Color Cycle",
  colorWave: "Color Wave",
};

const RAZER_MODE_LABELS: Record<RazerMode, string> = {
  off: "Off",
  staticColor: "Static",
  breathing: "Breathing",
  spectrum: "Spectrum Cycle",
  wave: "Wave",
};

const DEFAULT_RAZER_LIGHTING: RazerLighting = {
  mode: "spectrum",
  primary: { red: 0, green: 255, blue: 128 },
  secondary: { red: 0, green: 140, blue: 255 },
  breathing: "single",
  waveDirection: "leftToRight",
};

function formatBatterySubtitle(
  batteryPercent: number | null,
  isCharging: boolean,
  connection: string | null
): string {
  const parts: string[] = [];
  if (batteryPercent !== null) {
    parts.push(isCharging ? `${batteryPercent}% (Charging)` : `${batteryPercent}%`);
  }
  if (connection) {
    parts.push(connection);
  }
  return parts.join(" · ");
}

function formatRateHz(hz: number): string {
  return hz >= 1000 ? `${hz / 1000} kHz` : `${hz} Hz`;
}

function DockPortsSummary({ layout, hasEthernet }: { layout: DockLayout; hasEthernet?: boolean }) {
  const occupied = [...layout.thunderbolt, ...layout.usbA].filter((p) => p.devices.length > 0);
  const ethLabel = hasEthernet
    ? layout.ethernetInterface
      ? `Ethernet: ${layout.ethernetInterface}`
      : "Ethernet: Disconnected"
    : null;

  return (
    <PanelSectionRow>
      <div style={{ fontSize: "12px", opacity: 0.85, lineHeight: 1.45 }}>
        {occupied.length === 0 ? (
          <div>No devices plugged into dock ports</div>
        ) : (
          occupied.map((port) => (
            <div key={port.id}>
              <strong>{port.title}:</strong> {port.devices.map((d) => d.name).join(", ")}
            </div>
          ))
        )}
        {ethLabel && <div style={{ opacity: 0.75 }}>{ethLabel}</div>}
      </div>
    </PanelSectionRow>
  );
}

function AeronDeckyPanel() {
  const [state, setState] = useState<AppSnapshot | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [refreshing, setRefreshing] = useState(false);

  const lastInteractionRef = useRef<number>(0);
  const throttleTimersRef = useRef<Map<string, ReturnType<typeof setTimeout>>>(new Map());
  const latestPayloadsRef = useRef<
    Map<string, { path: string; payload: Record<string, unknown> }>
  >(new Map());

  const fetchState = useCallback((respectInteractionGuard = false) => {
    getState()
      .then((data) => {
        if (respectInteractionGuard && Date.now() - lastInteractionRef.current < 1200) {
          return;
        }
        setState(data);
        setError(null);
      })
      .catch(() => setError("Start aeron-daemon (systemctl --user start aeron-daemon)"));
  }, []);

  useEffect(() => {
    fetchState(false);
    const poll = setInterval(() => fetchState(true), 4000);
    return () => {
      clearInterval(poll);
      throttleTimersRef.current.forEach((t) => clearTimeout(t));
      throttleTimersRef.current.clear();
    };
  }, [fetchState]);

  const sendImmediate = useCallback(
    (
      path: string,
      payload: Record<string, unknown>,
      optimisticPatch?: (prev: AppSnapshot) => AppSnapshot
    ) => {
      lastInteractionRef.current = Date.now();
      if (optimisticPatch) {
        setState((prev) => (prev ? optimisticPatch(prev) : prev));
      }
      void postAction(path, payload)
        .then((next) => {
          setState(next);
          setError(null);
        })
        .catch(() => {
          // Keep UI responsive; next 4s poll reconciles state
        });
    },
    []
  );

  const sendThrottled = useCallback(
    (
      key: string,
      path: string,
      payload: Record<string, unknown>,
      optimisticPatch: (prev: AppSnapshot) => AppSnapshot,
      delayMs = 50
    ) => {
      lastInteractionRef.current = Date.now();
      setState((prev) => (prev ? optimisticPatch(prev) : prev));
      latestPayloadsRef.current.set(key, { path, payload });

      if (throttleTimersRef.current.has(key)) {
        return;
      }

      const timer = setTimeout(() => {
        throttleTimersRef.current.delete(key);
        const latest = latestPayloadsRef.current.get(key);
        if (!latest) return;
        latestPayloadsRef.current.delete(key);
        void postAction(latest.path, latest.payload)
          .then((next) => {
            if (Date.now() - lastInteractionRef.current >= 400) {
              setState(next);
            }
          })
          .catch(() => {});
      }, delayMs);

      throttleTimersRef.current.set(key, timer);
    },
    []
  );

  const handleRefreshAll = useCallback(() => {
    setRefreshing(true);
    void postAction("/api/refresh", {})
      .then((next) => {
        setState(next);
        setError(null);
      })
      .catch(() => setError("Failed to reach aeron-daemon"))
      .finally(() => setRefreshing(false));
  }, []);

  if (error || !state) {
    return (
      <PanelSection title="Aeron Tools">
        <PanelSectionRow>
          <div style={{ fontSize: "12px", opacity: 0.85 }}>
            {error ?? "Connecting to aeron-daemon…"}
          </div>
        </PanelSectionRow>
        <PanelSectionRow>
          <ButtonItem layout="below" onClick={() => fetchState(false)}>
            Retry Connection
          </ButtonItem>
        </PanelSectionRow>
      </PanelSection>
    );
  }

  const { accessories: acc, thermals, wattage, gameMode, caffeine, builtinDisplay } = state;

  const anyAccessoryConnected =
    acc.mxMaster.connected ||
    acc.logitechGMouse.connected ||
    acc.keychronM3Mini.connected ||
    acc.mxKeyboard.connected ||
    acc.logitechGKeyboard.connected ||
    acc.razerDock.connected ||
    acc.satechiHub.connected;

  const telemetryParts: string[] = [];
  if (thermals.cpuCelsius !== null) telemetryParts.push(`CPU ${Math.round(thermals.cpuCelsius)}°C`);
  if (thermals.gpuCelsius !== null) telemetryParts.push(`GPU ${Math.round(thermals.gpuCelsius)}°C`);
  if (thermals.fans.length > 0) {
    telemetryParts.push(`Fan ${thermals.fans[0].rpm} RPM`);
  }
  if (wattage.systemLoadWatts !== null) {
    telemetryParts.push(`${wattage.systemLoadWatts.toFixed(1)} W`);
  }
  if (wattage.batteryLevel !== null) {
    telemetryParts.push(
      wattage.isCharging ? `Bat ${wattage.batteryLevel}% ⚡` : `Bat ${wattage.batteryLevel}%`
    );
  }

  const keychronActiveDpi = acc.keychronM3Mini.stageDpis[acc.keychronM3Mini.activeStage] ?? 1600;
  const gKeyboardEffects: RgbEffect[] =
    acc.logitechGKeyboard.supportedEffects.length > 0
      ? acc.logitechGKeyboard.supportedEffects
      : ["off", "fixed", "breathing", "colorCycle", "colorWave"];
  const razerLighting = acc.razerDock.lighting ?? DEFAULT_RAZER_LIGHTING;
  const razerBrightnessPct = Math.round(((acc.razerDock.brightness ?? 255) / 255) * 100);

  return (
    <>
      {/* ---------- EXTERNAL DISPLAYS (DDC/CI) ---------- */}
      <PanelSection title="External Displays">
        {state.displays.length === 0 ? (
          <PanelSectionRow>
            <div style={{ fontSize: "12px", opacity: 0.7 }}>
              No external DDC/CI monitors detected
            </div>
          </PanelSectionRow>
        ) : (
          state.displays.map((d) => (
            <div key={d.id}>
              <PanelSectionRow>
                <SliderField
                  label={`${d.name} Brightness`}
                  description={d.hasHardwareControl ? "DDC/CI Hardware" : "Software"}
                  value={Math.round(d.brightness * 100)}
                  min={0}
                  max={100}
                  step={5}
                  showValue
                  valueSuffix="%"
                  onChange={(val) =>
                    sendThrottled(
                      `disp-br-${d.id}`,
                      `/api/displays/${encodeURIComponent(d.id)}/brightness`,
                      { level: val / 100 },
                      (prev) => ({
                        ...prev,
                        displays: prev.displays.map((item) =>
                          item.id === d.id ? { ...item, brightness: val / 100 } : item
                        ),
                      })
                    )
                  }
                />
              </PanelSectionRow>
              <PanelSectionRow>
                <SliderField
                  label={`${d.name} Volume`}
                  value={Math.round(d.volume * 100)}
                  min={0}
                  max={100}
                  step={5}
                  showValue
                  valueSuffix="%"
                  onChange={(val) =>
                    sendThrottled(
                      `disp-vol-${d.id}`,
                      `/api/displays/${encodeURIComponent(d.id)}/volume`,
                      { level: val / 100 },
                      (prev) => ({
                        ...prev,
                        displays: prev.displays.map((item) =>
                          item.id === d.id ? { ...item, volume: val / 100 } : item
                        ),
                      })
                    )
                  }
                />
              </PanelSectionRow>
              <PanelSectionRow>
                <ToggleField
                  label={`${d.name} Mute`}
                  checked={d.isMuted}
                  onChange={(muted) =>
                    sendImmediate(
                      `/api/displays/${encodeURIComponent(d.id)}/mute`,
                      { muted },
                      (prev) => ({
                        ...prev,
                        displays: prev.displays.map((item) =>
                          item.id === d.id ? { ...item, isMuted: muted } : item
                        ),
                      })
                    )
                  }
                />
              </PanelSectionRow>
              {d.inputSources.length > 0 && (
                <PanelSectionRow>
                  <DropdownItem
                    label={`${d.name} Input`}
                    rgOptions={d.inputSources.map((src) => ({
                      data: src.code,
                      label: src.name,
                    }))}
                    selectedOption={d.currentInput ?? d.inputSources[0].code}
                    onChange={(opt) =>
                      sendImmediate(
                        `/api/displays/${encodeURIComponent(d.id)}/input`,
                        { code: opt.data },
                        (prev) => ({
                          ...prev,
                          displays: prev.displays.map((item) =>
                            item.id === d.id ? { ...item, currentInput: opt.data } : item
                          ),
                        })
                      )
                    }
                  />
                </PanelSectionRow>
              )}
            </div>
          ))
        )}

        {builtinDisplay.present && builtinDisplay.canTurnOff && (
          <PanelSectionRow>
            <ToggleField
              label="Built-in Display"
              checked={!builtinDisplay.isTurnedOff}
              onChange={(enabled) =>
                sendImmediate("/api/displays/builtin", { enabled }, (prev) => ({
                  ...prev,
                  builtinDisplay: { ...prev.builtinDisplay, isTurnedOff: !enabled },
                }))
              }
            />
          </PanelSectionRow>
        )}
      </PanelSection>

      {/* ---------- SYSTEM ---------- */}
      <PanelSection title="System">
        <PanelSectionRow>
          <ToggleField
            label="Caffeine (Keep Awake)"
            description={caffeine.isAutomatic ? "Auto-enabled" : undefined}
            checked={caffeine.isActive}
            onChange={(active) =>
              sendImmediate("/api/caffeine", { active, durationSeconds: null }, (prev) => ({
                ...prev,
                caffeine: { ...prev.caffeine, isActive: active },
              }))
            }
          />
        </PanelSectionRow>

        {gameMode.supported && (
          <PanelSectionRow>
            <DropdownItem
              label="Game Mode"
              description={
                gameMode.isActive
                  ? `Active · ${gameMode.backendName}`
                  : gameMode.backendName
              }
              rgOptions={GAME_MODE_OPTIONS}
              selectedOption={gameMode.policy}
              onChange={(opt) =>
                sendImmediate("/api/game-mode", { policy: opt.data }, (prev) => ({
                  ...prev,
                  gameMode: { ...prev.gameMode, policy: opt.data },
                }))
              }
            />
          </PanelSectionRow>
        )}

        {telemetryParts.length > 0 && (
          <PanelSectionRow>
            <div style={{ fontSize: "12px", opacity: 0.85, lineHeight: 1.4 }}>
              {telemetryParts.join(" · ")}
            </div>
          </PanelSectionRow>
        )}
      </PanelSection>

      {/* ---------- MX MASTER ---------- */}
      {acc.mxMaster.connected && (
        <PanelSection title={acc.mxMaster.name}>
          <PanelSectionRow>
            <SliderField
              label="Pointer DPI"
              description={
                formatBatterySubtitle(
                  acc.mxMaster.batteryPercent,
                  acc.mxMaster.isCharging,
                  acc.mxMaster.connection
                ) || undefined
              }
              value={acc.mxMaster.dpi}
              min={acc.mxMaster.minDpi}
              max={acc.mxMaster.maxDpi}
              step={acc.mxMaster.dpiStep || 50}
              showValue
              onChange={(dpi) =>
                sendThrottled(
                  "mx-master-dpi",
                  "/api/accessories/mx-master/dpi",
                  { dpi },
                  (prev) => ({
                    ...prev,
                    accessories: {
                      ...prev.accessories,
                      mxMaster: { ...prev.accessories.mxMaster, dpi },
                    },
                  })
                )
              }
            />
          </PanelSectionRow>
          <PanelSectionRow>
            <ToggleField
              label="Free-Spin Wheel"
              checked={acc.mxMaster.wheelMode === "freeSpin"}
              onChange={(freeSpin) => {
                const wheelMode: MxWheelMode = freeSpin ? "freeSpin" : "ratchet";
                sendImmediate(
                  "/api/accessories/mx-master/smart-shift",
                  {
                    wheelMode,
                    smartShiftEnabled: acc.mxMaster.smartShiftEnabled,
                    threshold: acc.mxMaster.smartShiftThreshold,
                  },
                  (prev) => ({
                    ...prev,
                    accessories: {
                      ...prev.accessories,
                      mxMaster: { ...prev.accessories.mxMaster, wheelMode },
                    },
                  })
                );
              }}
            />
          </PanelSectionRow>
          <PanelSectionRow>
            <ToggleField
              label="SmartShift Auto-Switch"
              checked={acc.mxMaster.smartShiftEnabled}
              onChange={(smartShiftEnabled) =>
                sendImmediate(
                  "/api/accessories/mx-master/smart-shift",
                  {
                    wheelMode: acc.mxMaster.wheelMode,
                    smartShiftEnabled,
                    threshold: acc.mxMaster.smartShiftThreshold,
                  },
                  (prev) => ({
                    ...prev,
                    accessories: {
                      ...prev.accessories,
                      mxMaster: { ...prev.accessories.mxMaster, smartShiftEnabled },
                    },
                  })
                )
              }
            />
          </PanelSectionRow>
        </PanelSection>
      )}

      {/* ---------- LOGITECH G MOUSE ---------- */}
      {acc.logitechGMouse.connected && (
        <PanelSection title={acc.logitechGMouse.name}>
          <PanelSectionRow>
            <SliderField
              label="Pointer DPI"
              description={
                formatBatterySubtitle(
                  acc.logitechGMouse.batteryPercent,
                  acc.logitechGMouse.isCharging,
                  acc.logitechGMouse.connection
                ) || undefined
              }
              value={acc.logitechGMouse.dpi}
              min={acc.logitechGMouse.minDpi}
              max={acc.logitechGMouse.maxDpi}
              step={50}
              showValue
              onChange={(dpi) =>
                sendThrottled(
                  "logitech-g-dpi",
                  "/api/accessories/logitech-g/dpi",
                  { dpi },
                  (prev) => ({
                    ...prev,
                    accessories: {
                      ...prev.accessories,
                      logitechGMouse: { ...prev.accessories.logitechGMouse, dpi },
                    },
                  })
                )
              }
            />
          </PanelSectionRow>
          <PanelSectionRow>
            <DropdownItem
              label="Report Rate"
              rgOptions={(acc.logitechGMouse.supportedReportRates.length > 0
                ? acc.logitechGMouse.supportedReportRates
                : [125, 250, 500, 1000]
              ).map((hz) => ({
                data: hz,
                label: formatRateHz(hz),
              }))}
              selectedOption={acc.logitechGMouse.reportRateHz}
              onChange={(opt) =>
                sendImmediate(
                  "/api/accessories/logitech-g/report-rate",
                  { hz: opt.data },
                  (prev) => ({
                    ...prev,
                    accessories: {
                      ...prev.accessories,
                      logitechGMouse: {
                        ...prev.accessories.logitechGMouse,
                        reportRateHz: opt.data,
                      },
                    },
                  })
                )
              }
            />
          </PanelSectionRow>
          {acc.logitechGMouse.triggers && (
            <PanelSectionRow>
              <ToggleField
                label="Rapid Trigger"
                checked={acc.logitechGMouse.triggers.rapidTrigger > 0}
                onChange={(enabled) => {
                  const cur = acc.logitechGMouse.triggers!;
                  const next = { ...cur, rapidTrigger: enabled ? Math.max(cur.rapidTrigger, 1) : 0 };
                  sendImmediate("/api/accessories/logitech-g/triggers", next, (prev) => ({
                    ...prev,
                    accessories: {
                      ...prev.accessories,
                      logitechGMouse: { ...prev.accessories.logitechGMouse, triggers: next },
                    },
                  }));
                }}
              />
            </PanelSectionRow>
          )}
        </PanelSection>
      )}

      {/* ---------- KEYCHRON M3 MINI 4K ---------- */}
      {acc.keychronM3Mini.connected && (
        <PanelSection title={acc.keychronM3Mini.name}>
          <PanelSectionRow>
            <DropdownItem
              label="DPI Stage"
              description={
                formatBatterySubtitle(
                  acc.keychronM3Mini.batteryPercent,
                  acc.keychronM3Mini.isCharging,
                  acc.keychronM3Mini.connection
                ) || undefined
              }
              rgOptions={acc.keychronM3Mini.stageDpis.map((dpi, idx) => ({
                data: idx,
                label: `Stage ${idx + 1} (${dpi} DPI)`,
              }))}
              selectedOption={acc.keychronM3Mini.activeStage}
              onChange={(opt) => {
                const activeStage = opt.data;
                const dpi = acc.keychronM3Mini.stageDpis[activeStage] ?? 1600;
                sendImmediate(
                  "/api/accessories/keychron",
                  {
                    activeStage,
                    dpi,
                    reportRateHz: acc.keychronM3Mini.reportRateHz,
                    liftOffMm: acc.keychronM3Mini.liftOffMm,
                    motionSync: acc.keychronM3Mini.motionSync,
                    angleSnapping: acc.keychronM3Mini.angleSnapping,
                  },
                  (prev) => ({
                    ...prev,
                    accessories: {
                      ...prev.accessories,
                      keychronM3Mini: { ...prev.accessories.keychronM3Mini, activeStage },
                    },
                  })
                );
              }}
            />
          </PanelSectionRow>
          <PanelSectionRow>
            <SliderField
              label={`Stage ${acc.keychronM3Mini.activeStage + 1} DPI`}
              value={keychronActiveDpi}
              min={100}
              max={26000}
              step={100}
              showValue
              onChange={(dpi) =>
                sendThrottled(
                  "keychron-dpi",
                  "/api/accessories/keychron",
                  {
                    activeStage: acc.keychronM3Mini.activeStage,
                    dpi,
                    reportRateHz: acc.keychronM3Mini.reportRateHz,
                    liftOffMm: acc.keychronM3Mini.liftOffMm,
                    motionSync: acc.keychronM3Mini.motionSync,
                    angleSnapping: acc.keychronM3Mini.angleSnapping,
                  },
                  (prev) => {
                    const nextDpis = [...prev.accessories.keychronM3Mini.stageDpis];
                    nextDpis[prev.accessories.keychronM3Mini.activeStage] = dpi;
                    return {
                      ...prev,
                      accessories: {
                        ...prev.accessories,
                        keychronM3Mini: {
                          ...prev.accessories.keychronM3Mini,
                          stageDpis: nextDpis,
                        },
                      },
                    };
                  }
                )
              }
            />
          </PanelSectionRow>
          <PanelSectionRow>
            <DropdownItem
              label="Report Rate"
              rgOptions={[125, 250, 500, 1000, 2000, 4000]
                .filter((hz) => hz <= acc.keychronM3Mini.maxReportRateHz)
                .map((hz) => ({
                  data: hz,
                  label: formatRateHz(hz),
                }))}
              selectedOption={acc.keychronM3Mini.reportRateHz}
              onChange={(opt) =>
                sendImmediate(
                  "/api/accessories/keychron",
                  {
                    activeStage: acc.keychronM3Mini.activeStage,
                    dpi: keychronActiveDpi,
                    reportRateHz: opt.data,
                    liftOffMm: acc.keychronM3Mini.liftOffMm,
                    motionSync: acc.keychronM3Mini.motionSync,
                    angleSnapping: acc.keychronM3Mini.angleSnapping,
                  },
                  (prev) => ({
                    ...prev,
                    accessories: {
                      ...prev.accessories,
                      keychronM3Mini: {
                        ...prev.accessories.keychronM3Mini,
                        reportRateHz: opt.data,
                      },
                    },
                  })
                )
              }
            />
          </PanelSectionRow>
          <PanelSectionRow>
            <DropdownItem
              label="Lift-Off Distance"
              rgOptions={[
                { data: 1, label: "1 mm" },
                { data: 2, label: "2 mm" },
              ]}
              selectedOption={acc.keychronM3Mini.liftOffMm}
              onChange={(opt) =>
                sendImmediate(
                  "/api/accessories/keychron",
                  {
                    activeStage: acc.keychronM3Mini.activeStage,
                    dpi: keychronActiveDpi,
                    reportRateHz: acc.keychronM3Mini.reportRateHz,
                    liftOffMm: opt.data,
                    motionSync: acc.keychronM3Mini.motionSync,
                    angleSnapping: acc.keychronM3Mini.angleSnapping,
                  },
                  (prev) => ({
                    ...prev,
                    accessories: {
                      ...prev.accessories,
                      keychronM3Mini: {
                        ...prev.accessories.keychronM3Mini,
                        liftOffMm: opt.data,
                      },
                    },
                  })
                )
              }
            />
          </PanelSectionRow>
          <PanelSectionRow>
            <ToggleField
              label="Motion Sync"
              checked={acc.keychronM3Mini.motionSync}
              onChange={(motionSync) =>
                sendImmediate(
                  "/api/accessories/keychron",
                  {
                    activeStage: acc.keychronM3Mini.activeStage,
                    dpi: keychronActiveDpi,
                    reportRateHz: acc.keychronM3Mini.reportRateHz,
                    liftOffMm: acc.keychronM3Mini.liftOffMm,
                    motionSync,
                    angleSnapping: acc.keychronM3Mini.angleSnapping,
                  },
                  (prev) => ({
                    ...prev,
                    accessories: {
                      ...prev.accessories,
                      keychronM3Mini: { ...prev.accessories.keychronM3Mini, motionSync },
                    },
                  })
                )
              }
            />
          </PanelSectionRow>
          <PanelSectionRow>
            <ToggleField
              label="Angle Snapping"
              checked={acc.keychronM3Mini.angleSnapping}
              onChange={(angleSnapping) =>
                sendImmediate(
                  "/api/accessories/keychron",
                  {
                    activeStage: acc.keychronM3Mini.activeStage,
                    dpi: keychronActiveDpi,
                    reportRateHz: acc.keychronM3Mini.reportRateHz,
                    liftOffMm: acc.keychronM3Mini.liftOffMm,
                    motionSync: acc.keychronM3Mini.motionSync,
                    angleSnapping,
                  },
                  (prev) => ({
                    ...prev,
                    accessories: {
                      ...prev.accessories,
                      keychronM3Mini: { ...prev.accessories.keychronM3Mini, angleSnapping },
                    },
                  })
                )
              }
            />
          </PanelSectionRow>
        </PanelSection>
      )}

      {/* ---------- MX KEYBOARD ---------- */}
      {acc.mxKeyboard.connected && (
        <PanelSection title={acc.mxKeyboard.name}>
          <PanelSectionRow>
            <ToggleField
              label="Backlight"
              description={
                formatBatterySubtitle(
                  acc.mxKeyboard.batteryPercent,
                  acc.mxKeyboard.isCharging,
                  acc.mxKeyboard.connection
                ) || undefined
              }
              checked={acc.mxKeyboard.backlightEnabled}
              onChange={(enabled) =>
                sendImmediate(
                  "/api/accessories/mx-keyboard/backlight",
                  {
                    enabled,
                    autoBrightness: acc.mxKeyboard.automaticBrightness,
                    batterySaving: acc.mxKeyboard.batterySaving,
                    level: acc.mxKeyboard.backlightLevel,
                    durationSeconds: acc.mxKeyboard.durationSeconds,
                    effect: acc.mxKeyboard.backlightEffect,
                  },
                  (prev) => ({
                    ...prev,
                    accessories: {
                      ...prev.accessories,
                      mxKeyboard: { ...prev.accessories.mxKeyboard, backlightEnabled: enabled },
                    },
                  })
                )
              }
            />
          </PanelSectionRow>
          <PanelSectionRow>
            <SliderField
              label="Backlight Level"
              value={acc.mxKeyboard.backlightLevel}
              min={0}
              max={7}
              step={1}
              showValue
              onChange={(level) =>
                sendThrottled(
                  "mx-kb-level",
                  "/api/accessories/mx-keyboard/backlight",
                  {
                    enabled: level > 0,
                    autoBrightness: false,
                    batterySaving: acc.mxKeyboard.batterySaving,
                    level,
                    durationSeconds: acc.mxKeyboard.durationSeconds,
                    effect: acc.mxKeyboard.backlightEffect,
                  },
                  (prev) => ({
                    ...prev,
                    accessories: {
                      ...prev.accessories,
                      mxKeyboard: {
                        ...prev.accessories.mxKeyboard,
                        backlightEnabled: level > 0,
                        automaticBrightness: false,
                        backlightLevel: level,
                      },
                    },
                  })
                )
              }
            />
          </PanelSectionRow>
          {acc.mxKeyboard.fnInversion !== null && (
            <PanelSectionRow>
              <ToggleField
                label="Standard Fn Keys (F1–F12)"
                checked={acc.mxKeyboard.fnInversion}
                onChange={(standardFn) =>
                  sendImmediate(
                    "/api/accessories/mx-keyboard/fn-inversion",
                    { standardFn },
                    (prev) => ({
                      ...prev,
                      accessories: {
                        ...prev.accessories,
                        mxKeyboard: { ...prev.accessories.mxKeyboard, fnInversion: standardFn },
                      },
                    })
                  )
                }
              />
            </PanelSectionRow>
          )}
        </PanelSection>
      )}

      {/* ---------- LOGITECH G KEYBOARD (G515 LS TKL) ---------- */}
      {acc.logitechGKeyboard.connected && (
        <PanelSection title={acc.logitechGKeyboard.name}>
          <PanelSectionRow>
            <SliderField
              label="Backlight Brightness"
              description={
                [
                  formatBatterySubtitle(
                    acc.logitechGKeyboard.batteryPercent,
                    acc.logitechGKeyboard.isCharging,
                    acc.logitechGKeyboard.connection
                  ),
                  acc.logitechGKeyboard.gameModeOn ? "Game Mode On" : "",
                ]
                  .filter(Boolean)
                  .join(" · ") || undefined
              }
              value={acc.logitechGKeyboard.brightness}
              min={0}
              max={acc.logitechGKeyboard.maxBrightness || 100}
              step={5}
              showValue
              valueSuffix="%"
              onChange={(brightness) =>
                sendThrottled(
                  "g-kb-br",
                  "/api/accessories/g-keyboard/lighting",
                  {
                    brightness,
                    lighting: acc.logitechGKeyboard.lighting,
                  },
                  (prev) => ({
                    ...prev,
                    accessories: {
                      ...prev.accessories,
                      logitechGKeyboard: {
                        ...prev.accessories.logitechGKeyboard,
                        brightness,
                      },
                    },
                  })
                )
              }
            />
          </PanelSectionRow>
          <PanelSectionRow>
            <DropdownItem
              label="RGB Effect"
              rgOptions={gKeyboardEffects.map((effect) => ({
                data: effect,
                label: RGB_EFFECT_LABELS[effect] ?? effect,
              }))}
              selectedOption={acc.logitechGKeyboard.lighting.effect}
              onChange={(opt) => {
                const lighting = { ...acc.logitechGKeyboard.lighting, effect: opt.data };
                sendImmediate(
                  "/api/accessories/g-keyboard/lighting",
                  {
                    brightness: acc.logitechGKeyboard.brightness,
                    lighting,
                  },
                  (prev) => ({
                    ...prev,
                    accessories: {
                      ...prev.accessories,
                      logitechGKeyboard: {
                        ...prev.accessories.logitechGKeyboard,
                        lighting,
                      },
                    },
                  })
                );
              }}
            />
          </PanelSectionRow>
        </PanelSection>
      )}

      {/* ---------- RAZER DOCK CHROMA ---------- */}
      {acc.razerDock.connected && (
        <PanelSection title={acc.razerDock.name}>
          <PanelSectionRow>
            <DropdownItem
              label="Chroma Effect"
              rgOptions={(
                ["off", "staticColor", "breathing", "spectrum", "wave"] as RazerMode[]
              ).map((m) => ({
                data: m,
                label: RAZER_MODE_LABELS[m],
              }))}
              selectedOption={razerLighting.mode ?? "spectrum"}
              onChange={(opt) => {
                const nextLighting: RazerLighting = { ...razerLighting, mode: opt.data };
                sendImmediate(
                  "/api/accessories/razer-dock",
                  { brightness: null, lighting: nextLighting },
                  (prev) => ({
                    ...prev,
                    accessories: {
                      ...prev.accessories,
                      razerDock: { ...prev.accessories.razerDock, lighting: nextLighting },
                    },
                  })
                );
              }}
            />
          </PanelSectionRow>
          <PanelSectionRow>
            <SliderField
              label="Underglow Brightness"
              value={razerBrightnessPct}
              min={0}
              max={100}
              step={5}
              showValue
              valueSuffix="%"
              onChange={(pct) => {
                const raw = Math.round((pct / 100) * 255);
                sendThrottled(
                  "razer-dock-br",
                  "/api/accessories/razer-dock",
                  { brightness: raw, lighting: null },
                  (prev) => ({
                    ...prev,
                    accessories: {
                      ...prev.accessories,
                      razerDock: { ...prev.accessories.razerDock, brightness: raw },
                    },
                  })
                );
              }}
            />
          </PanelSectionRow>
          <DockPortsSummary layout={acc.razerDock.ports} hasEthernet />
        </PanelSection>
      )}

      {/* ---------- SATECHI SLIM HUB PRO ---------- */}
      {acc.satechiHub.connected && (
        <PanelSection title={acc.satechiHub.name}>
          <DockPortsSummary layout={acc.satechiHub.ports} />
        </PanelSection>
      )}

      {/* ---------- FALLBACK WHEN NO PERIPHERALS CONNECTED ---------- */}
      {!anyAccessoryConnected && (
        <PanelSection title="Accessories">
          <PanelSectionRow>
            <div style={{ fontSize: "12px", opacity: 0.7 }}>
              No supported peripherals detected
            </div>
          </PanelSectionRow>
        </PanelSection>
      )}

      {/* ---------- REFRESH ---------- */}
      <PanelSection>
        <PanelSectionRow>
          <ButtonItem layout="below" disabled={refreshing} onClick={handleRefreshAll}>
            {refreshing ? "Refreshing…" : "Refresh Devices"}
          </ButtonItem>
        </PanelSectionRow>
      </PanelSection>
    </>
  );
}

export default definePlugin(() => ({
  name: "Aeron Tools",
  content: <AeronDeckyPanel />,
  icon: <span>AT</span>,
}));
