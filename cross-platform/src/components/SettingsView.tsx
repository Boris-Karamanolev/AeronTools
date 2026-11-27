import { useEffect, useState } from "react";
import {
  Cable,
  HardDrive,
  Info,
  Keyboard,
  Monitor,
  Mouse,
  RefreshCw,
  Settings,
  Sliders,
} from "lucide-react";
import type {
  AccessoryButtonAction,
  AppPreferences,
  AppSnapshot,
  BacklightEffect,
  BreathingStyle,
  GameModePolicy,
  MxMasterOptions,
  MxThumbwheelAction,
  MxWheelMode,
  RazerLighting,
  RazerMode,
  RgbEffect,
  RgbLighting,
  TriggerSettings,
  WaveDirection,
} from "../types";
import type { AccessoryKey } from "./AccessoriesSection";
import { formatConnectionLabel } from "./AccessoriesSection";
import { DisplayCard } from "./DisplayCard";
import { DockPortsView } from "./DockPortsView";
import {
  ACCESSORY_ACTIONS,
  ActionPickerRow,
  ChromaGlowBar,
  ColorPickerRow,
  DPIControlRow,
  KeyRowPicker,
  LabeledRow,
  LevelSliderRow,
  MacSegmented,
  MacSelect,
  MacStepper,
  MacToggle,
  SettingsSection,
  StatusDot,
} from "./SettingsPrimitives";

export type SettingsTab = "general" | "displays" | "accessories" | "about";

interface SettingsViewProps {
  snapshot: AppSnapshot;
  initialTab?: SettingsTab;
  initialAccessory?: AccessoryKey | null;
  onRefresh: () => void;
  onUpdatePreferences: (next: AppPreferences) => void;
  onSetGameMode: (policy: GameModePolicy) => void;
  onSetCaffeine: (active: boolean, durationSeconds: number | null) => void;
  onDisplayBrightness: (id: string, level: number) => void;
  onDisplayVolume: (id: string, level: number) => void;
  onDisplayMute: (id: string, muted: boolean) => void;
  onDisplayInput: (id: string, code: number) => void;
  onToggleBuiltinDisplay: () => void;
  onMxMasterDpi: (dpi: number) => void;
  onMxMasterSmartShift: (mode: MxWheelMode, enabled: boolean, threshold: number) => void;
  onMxMasterOptions: (options: MxMasterOptions) => void;
  onLogitechGDpi: (dpi: number) => void;
  onLogitechGReportRate: (hz: number) => void;
  onLogitechGTriggers: (triggers: TriggerSettings) => void;
  onLogitechGOptions: (
    backButton: AccessoryButtonAction,
    forwardButton: AccessoryButtonAction,
    savesToOnboardProfile: boolean
  ) => void;
  onMxKeyboardBacklight: (params: {
    enabled: boolean;
    autoBrightness: boolean;
    batterySaving: boolean;
    level: number;
    durationSeconds: number;
    effect: BacklightEffect;
  }) => void;
  onMxKeyboardFnInversion: (standardFn: boolean) => void;
  onMxKeyboardKeyAction: (position: number, action: AccessoryButtonAction) => void;
  onGKeyboardLighting: (brightness: number, lighting: RgbLighting) => void;
  onKeychronUpdate: (params: {
    activeStage: number;
    dpi: number;
    reportRateHz: number;
    liftOffMm: number;
    motionSync: boolean;
    angleSnapping: boolean;
  }) => void;
  onKeychronSideButtons: (
    backButton: AccessoryButtonAction,
    forwardButton: AccessoryButtonAction
  ) => void;
  onRazerDockLighting: (brightness: number | null, lighting: RazerLighting | null) => void;
}

const MX_MASTER_DPI_PRESETS = [800, 1200, 1600, 2400, 4000, 8000];
const GAMING_MOUSE_DPI_PRESETS = [400, 800, 1600, 3200, 6400];
const MX_BACKLIGHT_DURATIONS = [5, 10, 15, 30, 45, 60, 90, 120, 180, 300];

const BACKLIGHT_EFFECT_LABELS: Record<BacklightEffect, string> = {
  staticLight: "Static",
  contrast: "Contrast",
  breathing: "Breathing",
  waves: "Waves",
  reaction: "Reaction",
  random: "Random",
};

const RGB_EFFECT_LABELS: Record<RgbEffect, string> = {
  off: "Off",
  fixed: "Fixed",
  breathing: "Breathing",
  colorCycle: "Color Cycle",
  colorWave: "Color Wave",
};

const RAZER_MODE_LABELS: Record<RazerMode, string> = {
  off: "Off",
  staticColor: "Static",
  breathing: "Breathing",
  spectrum: "Spectrum Cycling",
  wave: "Wave",
};

const THUMBWHEEL_OPTIONS: Array<{ value: MxThumbwheelAction; label: string }> = [
  { value: "horizontalScroll", label: "Horizontal Scroll" },
  { value: "displayBrightness", label: "Brightness (Display Under Pointer)" },
  { value: "displayVolume", label: "Volume (Display Under Pointer)" },
  { value: "switchWorkspaces", label: "Switch Desktop Spaces" },
  { value: "switchTabs", label: "Switch Browser / App Tabs" },
  { value: "zoom", label: "Zoom In / Out" },
];

function rgbToHex(r: number, g: number, b: number): string {
  return `#${[r, g, b].map((c) => c.toString(16).padStart(2, "0")).join("")}`;
}

function hexToRgb(hex: string): { red: number; green: number; blue: number } {
  const clean = hex.replace("#", "");
  return {
    red: parseInt(clean.slice(0, 2), 16) || 0,
    green: parseInt(clean.slice(2, 4), 16) || 0,
    blue: parseInt(clean.slice(4, 6), 16) || 0,
  };
}

function formatRateHz(hz: number): string {
  return hz >= 1000 ? `${hz / 1000} kHz` : `${hz} Hz`;
}

function formatDuration(sec: number): string {
  return sec < 60 ? `${sec} sec` : `${sec / 60} min`;
}

function rgbEffectUsesColor(effect: RgbEffect): boolean {
  return effect === "fixed" || effect === "breathing";
}

function rgbEffectUsesSpeed(effect: RgbEffect): boolean {
  return effect === "breathing" || effect === "colorCycle" || effect === "colorWave";
}

export function SettingsView({
  snapshot,
  initialTab = "general",
  initialAccessory = null,
  onRefresh,
  onUpdatePreferences,
  onSetGameMode,
  onSetCaffeine,
  onDisplayBrightness,
  onDisplayVolume,
  onDisplayMute,
  onDisplayInput,
  onToggleBuiltinDisplay,
  onMxMasterDpi,
  onMxMasterSmartShift,
  onMxMasterOptions,
  onLogitechGDpi,
  onLogitechGReportRate,
  onLogitechGTriggers,
  onLogitechGOptions,
  onMxKeyboardBacklight,
  onMxKeyboardFnInversion,
  onMxKeyboardKeyAction,
  onGKeyboardLighting,
  onKeychronUpdate,
  onKeychronSideButtons,
  onRazerDockLighting,
}: SettingsViewProps) {
  const firstConnectedAccessory = (a: AppSnapshot["accessories"]): AccessoryKey | null => {
    if (a.mxMaster.connected) return "mxMaster";
    if (a.logitechGMouse.connected) return "logitechGMouse";
    if (a.mxKeyboard.connected) return "mxKeyboard";
    if (a.logitechGKeyboard.connected) return "logitechGKeyboard";
    if (a.keychronM3Mini.connected) return "keychronM3Mini";
    if (a.razerDock.connected) return "razerDock";
    if (a.satechiHub.connected) return "satechiHub";
    return null;
  };

  const [tab, setTab] = useState<SettingsTab>(initialTab);
  const [userPickedAcc, setUserPickedAcc] = useState<boolean>(initialAccessory !== null);
  const [selectedAcc, setSelectedAcc] = useState<AccessoryKey>(
    () => initialAccessory ?? firstConnectedAccessory(snapshot.accessories) ?? "mxMaster"
  );

  useEffect(() => {
    setTab(initialTab);
  }, [initialTab]);

  useEffect(() => {
    if (initialAccessory) {
      setUserPickedAcc(true);
      setSelectedAcc(initialAccessory);
    }
  }, [initialAccessory]);

  useEffect(() => {
    if (!userPickedAcc) {
      const connectedKey = firstConnectedAccessory(snapshot.accessories);
      if (connectedKey) {
        setSelectedAcc(connectedKey);
      }
    }
  }, [
    userPickedAcc,
    snapshot.accessories.mxMaster.connected,
    snapshot.accessories.logitechGMouse.connected,
    snapshot.accessories.mxKeyboard.connected,
    snapshot.accessories.logitechGKeyboard.connected,
    snapshot.accessories.keychronM3Mini.connected,
    snapshot.accessories.razerDock.connected,
    snapshot.accessories.satechiHub.connected,
  ]);

  const prefs = snapshot.preferences;
  const acc = snapshot.accessories;

  const setPref = <K extends keyof AppPreferences>(key: K, value: AppPreferences[K]) => {
    onUpdatePreferences({ ...prefs, [key]: value });
  };

  const updateMxOptions = (patch: Partial<MxMasterOptions>) => {
    const m = acc.mxMaster;
    onMxMasterOptions({
      standardVerticalScroll: m.standardVerticalScroll,
      smoothScrolling: m.smoothScrolling,
      scrollSpeedMultiplier: m.scrollSpeedMultiplier,
      thumbwheelAction: m.thumbwheelAction,
      invertThumbwheel: m.invertThumbwheel,
      middleButtonAction: m.middleButtonAction,
      backButtonAction: m.backButtonAction,
      forwardButtonAction: m.forwardButtonAction,
      gestureButtonAction: m.gestureButtonAction,
      modeShiftButtonAction: m.modeShiftButtonAction,
      hapticPanelButtonAction: m.hapticPanelButtonAction,
      gesturesEnabled: m.gesturesEnabled,
      gestureUpAction: m.gestureUpAction,
      gestureDownAction: m.gestureDownAction,
      gestureLeftAction: m.gestureLeftAction,
      gestureRightAction: m.gestureRightAction,
      savesToMouse: m.savesToMouse,
      ...patch,
    });
  };

  const accessoryCatalog: Array<{
    key: AccessoryKey;
    shortName: string;
    fullName: string;
    connected: boolean;
    connection: string | null;
    batteryPercent: number | null;
    isCharging: boolean;
    hasBattery: boolean;
    icon: React.ReactNode;
  }> = [
    {
      key: "mxMaster",
      shortName: "MX Master",
      fullName: acc.mxMaster.name,
      connected: acc.mxMaster.connected,
      connection: acc.mxMaster.connection,
      batteryPercent: acc.mxMaster.batteryPercent,
      isCharging: acc.mxMaster.isCharging,
      hasBattery: true,
      icon: <Mouse className="h-[19px] w-[19px]" strokeWidth={1.65} />,
    },
    {
      key: "logitechGMouse",
      shortName: "G2 Superstrike",
      fullName: acc.logitechGMouse.name,
      connected: acc.logitechGMouse.connected,
      connection: acc.logitechGMouse.connection,
      batteryPercent: acc.logitechGMouse.batteryPercent,
      isCharging: acc.logitechGMouse.isCharging,
      hasBattery: true,
      icon: <Mouse className="h-[19px] w-[19px]" strokeWidth={1.65} />,
    },
    {
      key: "mxKeyboard",
      shortName: "MX Keyboard",
      fullName: acc.mxKeyboard.name,
      connected: acc.mxKeyboard.connected,
      connection: acc.mxKeyboard.connection,
      batteryPercent: acc.mxKeyboard.batteryPercent,
      isCharging: acc.mxKeyboard.isCharging,
      hasBattery: true,
      icon: <Keyboard className="h-[19px] w-[19px]" strokeWidth={1.65} />,
    },
    {
      key: "logitechGKeyboard",
      shortName: "G515 TKL",
      fullName: acc.logitechGKeyboard.name,
      connected: acc.logitechGKeyboard.connected,
      connection: acc.logitechGKeyboard.connection,
      batteryPercent: acc.logitechGKeyboard.batteryPercent,
      isCharging: acc.logitechGKeyboard.isCharging,
      hasBattery: true,
      icon: <Keyboard className="h-[19px] w-[19px]" strokeWidth={1.65} />,
    },
    {
      key: "keychronM3Mini",
      shortName: "M3 Mini 4K",
      fullName: acc.keychronM3Mini.name,
      connected: acc.keychronM3Mini.connected,
      connection: acc.keychronM3Mini.connection,
      batteryPercent: acc.keychronM3Mini.batteryPercent,
      isCharging: acc.keychronM3Mini.isCharging,
      hasBattery: true,
      icon: <Mouse className="h-[19px] w-[19px]" strokeWidth={1.65} />,
    },
    {
      key: "razerDock",
      shortName: "Razer Dock",
      fullName: acc.razerDock.name,
      connected: acc.razerDock.connected,
      connection: acc.razerDock.connected ? "thunderbolt" : null,
      batteryPercent: null,
      isCharging: false,
      hasBattery: false,
      icon: <HardDrive className="h-[19px] w-[19px]" strokeWidth={1.65} />,
    },
    {
      key: "satechiHub",
      shortName: "Satechi Hub",
      fullName: acc.satechiHub.name,
      connected: acc.satechiHub.connected,
      connection: acc.satechiHub.connected ? "thunderbolt" : null,
      batteryPercent: null,
      isCharging: false,
      hasBattery: false,
      icon: <Cable className="h-[19px] w-[19px]" strokeWidth={1.65} />,
    },
  ];

  const activeCatalogItem =
    accessoryCatalog.find((c) => c.key === selectedAcc) ?? accessoryCatalog[0];

  const tabs: Array<{ id: SettingsTab; label: string; icon: React.ReactNode }> = [
    { id: "general", label: "General", icon: <Settings className="h-[18px] w-[18px]" strokeWidth={1.65} /> },
    { id: "displays", label: "Displays", icon: <Monitor className="h-[18px] w-[18px]" strokeWidth={1.65} /> },
    { id: "accessories", label: "Accessories", icon: <Sliders className="h-[18px] w-[18px]" strokeWidth={1.65} /> },
    { id: "about", label: "About", icon: <Info className="h-[18px] w-[18px]" strokeWidth={1.65} /> },
  ];

  const razerLighting: RazerLighting = acc.razerDock.lighting ?? {
    mode: "spectrum",
    primary: { red: 0, green: 255, blue: 128 },
    secondary: { red: 0, green: 132, blue: 255 },
    breathing: "single",
    waveDirection: "leftToRight",
  };
  const razerBrightnessPct = Math.round(((acc.razerDock.brightness ?? 255) / 255) * 100);

  const gTriggers: TriggerSettings = acc.logitechGMouse.triggers ?? {
    actuation: 5,
    rapidTrigger: 0,
    haptics: 2,
  };

  return (
    <div className="aeron-settings-surface flex h-screen flex-col text-white/92">
      {/* Native macOS Unified Preferences Toolbar (leaves room for Overlay traffic lights) */}
      <nav
        className="aeron-toolbar flex items-center justify-center gap-2 px-[84px] pb-[10px] pt-[12px]"
        data-tauri-drag-region
      >
        {tabs.map((item) => {
          const active = tab === item.id;
          return (
            <button
              key={item.id}
              type="button"
              onClick={() => setTab(item.id)}
              className={`flex min-w-[82px] flex-col items-center gap-[3.5px] rounded-[9px] px-3.5 py-[6px] transition-all ${
                active
                  ? "bg-white/[0.13] text-[#0a84ff] shadow-[inset_0_0.5px_0_rgba(255,255,255,0.14),0_0.5px_1.5px_rgba(0,0,0,0.3)]"
                  : "text-white/56 hover:bg-white/[0.06] hover:text-white/88"
              }`}
            >
              {item.icon}
              <span className="text-[10.5px] font-medium tracking-[-0.005em]">{item.label}</span>
            </button>
          );
        })}
      </nav>

      {/* Scrollable Grouped Form Content */}
      <div className="flex-1 overflow-y-auto px-8 py-6">
        {/* ======================== GENERAL TAB ======================== */}
        {tab === "general" && (
          <div className="mx-auto max-w-[540px] space-y-6">
            <SettingsSection title="App">
              <LabeledRow title="Launch at login">
                <MacToggle
                  checked={prefs.launchAtLogin}
                  onChange={(v) => setPref("launchAtLogin", v)}
                />
              </LabeledRow>
            </SettingsSection>

            <SettingsSection
              title="Menu Bar Popover"
              footer="Choose which live hardware modules appear in the menu bar popover."
            >
              <LabeledRow title="Accessories cards" subtitle="Connected mice, keyboards, and Thunderbolt docks">
                <MacToggle
                  checked={prefs.showAccessoriesCard}
                  onChange={(v) => setPref("showAccessoriesCard", v)}
                />
              </LabeledRow>
              <LabeledRow title="Power & Battery card" subtitle="Live wattage draw, adapter rating, and battery reserve">
                <MacToggle
                  checked={prefs.showWattageMeter}
                  onChange={(v) => setPref("showWattageMeter", v)}
                />
              </LabeledRow>
              <LabeledRow
                title="Battery health & cycle count"
                disabled={!prefs.showWattageMeter}
              >
                <MacToggle
                  checked={prefs.showBatteryHealth}
                  disabled={!prefs.showWattageMeter}
                  onChange={(v) => setPref("showBatteryHealth", v)}
                />
              </LabeledRow>
              <LabeledRow title="Thermals card" subtitle="CPU, GPU, battery temperatures, pressure, and fan RPM">
                <MacToggle
                  checked={prefs.showThermals}
                  onChange={(v) => setPref("showThermals", v)}
                />
              </LabeledRow>
            </SettingsSection>

            <SettingsSection
              title="Game Mode"
              footer={`Backend: ${snapshot.gameMode.backendName}. Automatic enables Game Mode when a fullscreen game runs; Force On prioritizes CPU/GPU scheduling immediately.`}
            >
              <LabeledRow title="Status">
                <div className="flex items-center gap-2">
                  <StatusDot isActive={snapshot.gameMode.isActive} />
                  <span className="text-[12px] font-medium text-white/85">
                    {snapshot.gameMode.policy === "forcedOn"
                      ? "Forced On"
                      : snapshot.gameMode.policy === "forcedOff"
                        ? "Forced Off"
                        : snapshot.gameMode.isActive
                          ? "Active"
                          : "Automatic"}
                  </span>
                </div>
              </LabeledRow>
              <LabeledRow title="Policy">
                <MacSegmented<GameModePolicy>
                  value={snapshot.gameMode.policy}
                  options={[
                    { value: "automatic", label: "Automatic" },
                    { value: "forcedOn", label: "Force On" },
                    { value: "forcedOff", label: "Off" },
                  ]}
                  onChange={onSetGameMode}
                />
              </LabeledRow>
            </SettingsSection>

            <SettingsSection
              title="Caffeine"
              footer="Prevents display and system sleep while active."
            >
              <LabeledRow title="Keep awake">
                <MacToggle
                  checked={snapshot.caffeine.isActive}
                  onChange={(v) => onSetCaffeine(v, null)}
                />
              </LabeledRow>
              <LabeledRow title="Keep awake while external display connected">
                <MacToggle
                  checked={prefs.caffeineWithExternalDisplay}
                  onChange={(v) => setPref("caffeineWithExternalDisplay", v)}
                />
              </LabeledRow>
              <LabeledRow title="Keep awake while on power adapter">
                <MacToggle
                  checked={prefs.caffeineOnPowerAdapter}
                  onChange={(v) => setPref("caffeineOnPowerAdapter", v)}
                />
              </LabeledRow>
            </SettingsSection>

            <SettingsSection title="Global Shortcuts">
              {prefs.hotkeys.map((hk) => (
                <LabeledRow key={hk.action} title={hk.label}>
                  <kbd className="font-mono-tabular rounded-[5px] border border-white/[0.14] bg-white/[0.07] px-2 py-[2.5px] text-[11px] font-medium text-white/80 shadow-[inset_0_0.5px_0_rgba(255,255,255,0.1)]">
                    {hk.accelerator ?? "Not Set"}
                  </kbd>
                </LabeledRow>
              ))}
            </SettingsSection>

            <SettingsSection
              title="Local Companion API"
              footer="Used by the SteamOS Decky Loader Quick Access plugin and local automation scripts. Bound strictly to localhost."
            >
              <LabeledRow title="HTTP Loopback Endpoint">
                <span className="font-mono-tabular rounded-[5px] border border-white/[0.1] bg-black/25 px-2 py-[2.5px] text-[11px] text-white/75">
                  http://127.0.0.1:{prefs.daemonPort}
                </span>
              </LabeledRow>
            </SettingsSection>
          </div>
        )}

        {/* ======================== DISPLAYS TAB ======================== */}
        {tab === "displays" && (
          <div className="mx-auto max-w-[540px] space-y-6">
            {snapshot.builtinDisplay?.present && (
              <SettingsSection
                title={snapshot.platform === "macos" ? "MacBook Screen" : "Built-in Screen"}
                footer="Automatically turns off the built-in screen when an external monitor connects and restores it immediately when external monitors disconnect."
              >
                <LabeledRow
                  title={snapshot.builtinDisplay.isTurnedOff ? "Turned Off" : "Active"}
                  subtitle={
                    snapshot.builtinDisplay.canTurnOff || snapshot.builtinDisplay.isTurnedOff
                      ? undefined
                      : "Connect an external monitor to turn off the built-in screen"
                  }
                >
                  <StatusDot isActive={!snapshot.builtinDisplay.isTurnedOff} />
                  <button
                    type="button"
                    disabled={
                      !snapshot.builtinDisplay.canTurnOff && !snapshot.builtinDisplay.isTurnedOff
                    }
                    onClick={onToggleBuiltinDisplay}
                    className="aeron-btn disabled:opacity-40"
                  >
                    {snapshot.builtinDisplay.isTurnedOff ? "Turn Screen On" : "Turn Screen Off"}
                  </button>
                </LabeledRow>
                <LabeledRow title="Turn off automatically when an external screen is connected">
                  <MacToggle
                    checked={prefs.autoTurnOffBuiltin}
                    onChange={(v) => setPref("autoTurnOffBuiltin", v)}
                  />
                </LabeledRow>
              </SettingsSection>
            )}

            <SettingsSection
              title="Monitor Controls"
              footer="Settings are saved per display EDID identity and restored automatically when monitors reconnect."
            >
              <LabeledRow
                title="Input source switching"
                subtitle="Show the DDC/CI input menu on external display cards"
              >
                <MacToggle
                  checked={prefs.showInputSwitching}
                  onChange={(v) => setPref("showInputSwitching", v)}
                />
              </LabeledRow>
              <LabeledRow
                title="Restore monitor brightness & volume"
                subtitle="Reapply saved levels on reconnect"
              >
                <MacToggle
                  checked={prefs.restoreMonitorSettings}
                  onChange={(v) => setPref("restoreMonitorSettings", v)}
                />
              </LabeledRow>
              <LabeledRow
                title="Extra software dimming"
                subtitle="Allow dimming below hardware minimum brightness"
              >
                <MacToggle
                  checked={prefs.extraDimmingEnabled}
                  onChange={(v) => setPref("extraDimmingEnabled", v)}
                />
              </LabeledRow>
              <LabeledRow
                title="Media keys follow pointer display"
                subtitle="Adjust brightness and volume on the screen under the cursor"
              >
                <MacToggle
                  checked={prefs.mediaKeysControlPointerDisplay}
                  onChange={(v) => setPref("mediaKeysControlPointerDisplay", v)}
                />
              </LabeledRow>
            </SettingsSection>

            <div className="space-y-2.5">
              <div className="flex items-center justify-between px-[8px]">
                <h3 className="text-[12px] font-semibold text-white/82">
                  Connected External Displays ({snapshot.displays.filter((d) => !d.isBuiltin).length})
                </h3>
                <button type="button" onClick={onRefresh} className="aeron-btn">
                  <RefreshCw className="h-[11px] w-[11px]" />
                  <span>Rescan</span>
                </button>
              </div>

              {snapshot.displays.filter((d) => !d.isBuiltin).length === 0 ? (
                <div className="aeron-settings-group px-4 py-4 text-center text-[12px] text-white/45">
                  No external displays connected.
                </div>
              ) : (
                <div className="space-y-3">
                  {snapshot.displays
                    .filter((d) => !d.isBuiltin)
                    .map((d) => (
                      <DisplayCard
                        key={d.id}
                        display={d}
                        showInputSwitching={prefs.showInputSwitching}
                        onBrightnessChange={(lvl) => onDisplayBrightness(d.id, lvl)}
                        onVolumeChange={(lvl) => onDisplayVolume(d.id, lvl)}
                        onToggleMute={() => onDisplayMute(d.id, !d.isMuted)}
                        onSelectInput={(code) => onDisplayInput(d.id, code)}
                      />
                    ))}
                </div>
              )}
            </div>
          </div>
        )}

        {/* ======================== ACCESSORIES TAB ======================== */}
        {tab === "accessories" && (
          <div className="mx-auto max-w-[544px] space-y-6">
            {/* Native macOS Accessory Tile Strip (exact port of AccessorySelector / AccessoryTile) */}
            <div className="flex items-center gap-2">
              <div className="no-scrollbar flex flex-1 items-start gap-[6px] overflow-x-auto py-1">
                {accessoryCatalog.map((item) => {
                  const selected = selectedAcc === item.key;
                  return (
                    <button
                      key={item.key}
                      type="button"
                      onClick={() => { setUserPickedAcc(true); setSelectedAcc(item.key); }}
                      title={
                        item.connected
                          ? `${item.fullName} · Connected`
                          : `${item.shortName} · Not connected`
                      }
                      className={`group flex w-[72px] shrink-0 flex-col items-center gap-[5px] transition-opacity ${
                        item.connected
                          ? "opacity-100"
                          : selected
                            ? "opacity-85"
                            : "opacity-45 hover:opacity-75"
                      }`}
                    >
                      <div
                        className={`flex h-[42px] w-[60px] items-center justify-center rounded-[10px] border transition-all ${
                          selected
                            ? "border-[#0a84ff] bg-[#0a84ff]/[0.16] text-[#0a84ff] shadow-[0_0_0_1px_rgba(10,132,255,0.35)]"
                            : "border-white/[0.1] bg-white/[0.05] text-white/85 group-hover:border-white/[0.18] group-hover:bg-white/[0.08]"
                        }`}
                      >
                        {item.icon}
                      </div>
                      <div className="flex max-w-[72px] items-center gap-[4px]">
                        <StatusDot isActive={item.connected} />
                        <span
                          className={`truncate text-[10.5px] leading-tight ${
                            selected ? "font-semibold text-white" : "font-normal text-white/75"
                          }`}
                        >
                          {item.shortName}
                        </span>
                      </div>
                    </button>
                  );
                })}
              </div>

              <button
                type="button"
                onClick={onRefresh}
                title="Rescan HID & USB devices"
                className="aeron-btn !h-[30px] !w-[30px] shrink-0 self-start !mt-[7px] !p-0"
              >
                <RefreshCw className="h-[13px] w-[13px]" />
              </button>
            </div>

            {/* Shared Device Status Section (exact port of AccessoriesSettingsTabView.deviceSection) */}
            <SettingsSection
              title="Device"
              footer={
                activeCatalogItem.connected
                  ? undefined
                  : `Not connected right now. Controls below are disabled until ${activeCatalogItem.shortName} connects.`
              }
            >
              <div className="flex items-center justify-between px-3.5 py-2.5">
                <div className="flex items-center gap-2">
                  <StatusDot isActive={activeCatalogItem.connected} />
                  <span className="text-[13px] font-semibold text-white/95">
                    {activeCatalogItem.fullName}
                  </span>
                </div>
                <span
                  className={`rounded-full px-2 py-[2px] text-[10.5px] font-medium ${
                    activeCatalogItem.connected
                      ? "bg-[#30d158]/[0.16] text-[#30d158]"
                      : "bg-white/[0.07] text-white/45"
                  }`}
                >
                  {activeCatalogItem.connected ? "Connected" : "Offline"}
                </span>
              </div>

              <LabeledRow title="Connection">
                <span className="text-[12px] text-white/65">
                  {activeCatalogItem.connected
                    ? formatConnectionLabel(activeCatalogItem.connection)
                    : "Not connected"}
                </span>
              </LabeledRow>

              {activeCatalogItem.batteryPercent !== null && (
                <LabeledRow title="Battery">
                  <span className="font-mono-tabular text-[12px] text-white/80">
                    {activeCatalogItem.isCharging
                      ? `${activeCatalogItem.batteryPercent}% · Charging`
                      : `${activeCatalogItem.batteryPercent}%`}
                  </span>
                </LabeledRow>
              )}
            </SettingsSection>

            {/* Device-specific controls: fully grayed out and non-interactive when disconnected */}
            <fieldset
              disabled={!activeCatalogItem.connected}
              aria-disabled={!activeCatalogItem.connected}
              className={
                activeCatalogItem.connected
                  ? "m-0 min-w-0 space-y-6 border-0 p-0 transition-opacity"
                  : "pointer-events-none m-0 min-w-0 select-none space-y-6 border-0 p-0 opacity-35 grayscale saturate-0 transition-opacity"
              }
            >
            {/* ---------- 1. MX MASTER (complete parity with MXMasterViews.swift) ---------- */}
            {selectedAcc === "mxMaster" && (
              <>
                <SettingsSection
                  title="Performance"
                  footer="SmartShift switches the MagSpeed wheel to free-spin automatically when you flick it."
                >
                  <DPIControlRow
                    dpi={acc.mxMaster.dpi}
                    presets={MX_MASTER_DPI_PRESETS}
                    min={acc.mxMaster.minDpi}
                    max={acc.mxMaster.maxDpi}
                    onCommit={onMxMasterDpi}
                  />
                  <LabeledRow title="Wheel Mode">
                    <MacSegmented<MxWheelMode>
                      value={acc.mxMaster.wheelMode}
                      options={[
                        { value: "ratchet", label: "Ratchet" },
                        { value: "freeSpin", label: "Free-Spin" },
                      ]}
                      onChange={(mode) =>
                        onMxMasterSmartShift(
                          mode,
                          acc.mxMaster.smartShiftEnabled,
                          acc.mxMaster.smartShiftThreshold
                        )
                      }
                    />
                  </LabeledRow>
                  <LabeledRow title="SmartShift">
                    <MacToggle
                      checked={acc.mxMaster.smartShiftEnabled}
                      onChange={(enabled) =>
                        onMxMasterSmartShift(
                          acc.mxMaster.wheelMode,
                          enabled,
                          acc.mxMaster.smartShiftThreshold
                        )
                      }
                    />
                  </LabeledRow>
                  {acc.mxMaster.smartShiftEnabled && acc.mxMaster.wheelMode === "ratchet" && (
                    <LevelSliderRow
                      title="SmartShift Sensitivity"
                      value={acc.mxMaster.smartShiftThreshold}
                      min={1}
                      max={50}
                      step={1}
                      onChange={(v) =>
                        onMxMasterSmartShift(
                          acc.mxMaster.wheelMode,
                          acc.mxMaster.smartShiftEnabled,
                          Math.round(v)
                        )
                      }
                    />
                  )}
                </SettingsSection>

                <SettingsSection
                  title="Scrolling"
                  footer="Only this mouse is affected; trackpads and other mice keep the system setting."
                >
                  <LabeledRow title="Standard scroll direction">
                    <MacToggle
                      checked={acc.mxMaster.standardVerticalScroll}
                      onChange={(v) => updateMxOptions({ standardVerticalScroll: v })}
                    />
                  </LabeledRow>
                  <LabeledRow title="Smooth scrolling">
                    <MacToggle
                      checked={acc.mxMaster.smoothScrolling}
                      onChange={(v) => updateMxOptions({ smoothScrolling: v })}
                    />
                  </LabeledRow>
                  <LevelSliderRow
                    title="Scroll Speed"
                    value={acc.mxMaster.scrollSpeedMultiplier}
                    min={0.5}
                    max={3.0}
                    step={0.25}
                    format={(v) => `${v.toFixed(2)}×`}
                    onChange={(v) => updateMxOptions({ scrollSpeedMultiplier: v })}
                  />
                </SettingsSection>

                <SettingsSection title="Thumbwheel">
                  <LabeledRow title="Action">
                    <MacSelect<MxThumbwheelAction>
                      value={acc.mxMaster.thumbwheelAction}
                      options={THUMBWHEEL_OPTIONS}
                      onChange={(v) => updateMxOptions({ thumbwheelAction: v })}
                    />
                  </LabeledRow>
                  <LabeledRow title="Invert direction">
                    <MacToggle
                      checked={acc.mxMaster.invertThumbwheel}
                      onChange={(v) => updateMxOptions({ invertThumbwheel: v })}
                    />
                  </LabeledRow>
                </SettingsSection>

                <SettingsSection
                  title="Buttons"
                  footer="Only this mouse's buttons change. System Default keeps each button's normal behavior."
                >
                  <ActionPickerRow
                    title="Middle Button"
                    value={acc.mxMaster.middleButtonAction}
                    actions={ACCESSORY_ACTIONS}
                    onChange={(v) => updateMxOptions({ middleButtonAction: v })}
                  />
                  <ActionPickerRow
                    title="Back Button"
                    value={acc.mxMaster.backButtonAction}
                    actions={ACCESSORY_ACTIONS}
                    onChange={(v) => updateMxOptions({ backButtonAction: v })}
                  />
                  <ActionPickerRow
                    title="Forward Button"
                    value={acc.mxMaster.forwardButtonAction}
                    actions={ACCESSORY_ACTIONS}
                    onChange={(v) => updateMxOptions({ forwardButtonAction: v })}
                  />
                  <ActionPickerRow
                    title="Thumb Button"
                    value={acc.mxMaster.gestureButtonAction}
                    actions={ACCESSORY_ACTIONS}
                    onChange={(v) => updateMxOptions({ gestureButtonAction: v })}
                  />
                  <ActionPickerRow
                    title="Button Behind Wheel"
                    value={acc.mxMaster.modeShiftButtonAction}
                    actions={ACCESSORY_ACTIONS}
                    defaultTitle="System Default (Ratchet / Free-Spin)"
                    onChange={(v) => updateMxOptions({ modeShiftButtonAction: v })}
                  />
                  <ActionPickerRow
                    title="Haptic Panel"
                    value={acc.mxMaster.hapticPanelButtonAction}
                    actions={ACCESSORY_ACTIONS}
                    onChange={(v) => updateMxOptions({ hapticPanelButtonAction: v })}
                  />
                </SettingsSection>

                <SettingsSection
                  title="Gestures"
                  footer="Hold the thumb button or haptic panel and move the mouse in a direction."
                >
                  <LabeledRow title="Hold & drag gestures">
                    <MacToggle
                      checked={acc.mxMaster.gesturesEnabled}
                      onChange={(v) => updateMxOptions({ gesturesEnabled: v })}
                    />
                  </LabeledRow>
                  {acc.mxMaster.gesturesEnabled && (
                    <>
                      <ActionPickerRow
                        title="Up"
                        value={acc.mxMaster.gestureUpAction}
                        actions={ACCESSORY_ACTIONS}
                        onChange={(v) => updateMxOptions({ gestureUpAction: v })}
                      />
                      <ActionPickerRow
                        title="Down"
                        value={acc.mxMaster.gestureDownAction}
                        actions={ACCESSORY_ACTIONS}
                        onChange={(v) => updateMxOptions({ gestureDownAction: v })}
                      />
                      <ActionPickerRow
                        title="Left"
                        value={acc.mxMaster.gestureLeftAction}
                        actions={ACCESSORY_ACTIONS}
                        onChange={(v) => updateMxOptions({ gestureLeftAction: v })}
                      />
                      <ActionPickerRow
                        title="Right"
                        value={acc.mxMaster.gestureRightAction}
                        actions={ACCESSORY_ACTIONS}
                        onChange={(v) => updateMxOptions({ gestureRightAction: v })}
                      />
                    </>
                  )}
                </SettingsSection>

                <SettingsSection
                  title="Onboard Memory"
                  footer="Saves buttons set to Back, Forward, or Ratchet / Free-Spin to the mouse so they keep working without Aeron Tools."
                >
                  <LabeledRow title="Save settings to the mouse">
                    <MacToggle
                      checked={acc.mxMaster.savesToMouse}
                      onChange={(v) => updateMxOptions({ savesToMouse: v })}
                    />
                  </LabeledRow>
                </SettingsSection>
              </>
            )}

            {/* ---------- 2. LOGITECH G MOUSE (complete parity with LogitechGConnector.swift) ---------- */}
            {selectedAcc === "logitechGMouse" && (
              <>
                <SettingsSection
                  title="Performance"
                  footer="Higher report rates reduce latency and use more battery."
                >
                  <DPIControlRow
                    dpi={acc.logitechGMouse.dpi}
                    presets={GAMING_MOUSE_DPI_PRESETS}
                    min={acc.logitechGMouse.minDpi}
                    max={acc.logitechGMouse.maxDpi}
                    onCommit={onLogitechGDpi}
                  />
                  <LabeledRow title="Report Rate">
                    <MacSelect<number>
                      value={acc.logitechGMouse.reportRateHz}
                      options={acc.logitechGMouse.supportedReportRates.map((hz) => ({
                        value: hz,
                        label: formatRateHz(hz),
                      }))}
                      onChange={onLogitechGReportRate}
                    />
                  </LabeledRow>
                </SettingsSection>

                <SettingsSection
                  title="Triggers"
                  footer="Applies to both primary buttons. Lower actuation triggers a click earlier in the press."
                >
                  <LevelSliderRow
                    title="Actuation Point"
                    value={gTriggers.actuation}
                    min={1}
                    max={10}
                    step={1}
                    onChange={(v) =>
                      onLogitechGTriggers({ ...gTriggers, actuation: Math.round(v) })
                    }
                  />
                  <LevelSliderRow
                    title="Rapid Trigger"
                    value={gTriggers.rapidTrigger}
                    min={0}
                    max={5}
                    step={1}
                    lowestLabel="Off"
                    onChange={(v) =>
                      onLogitechGTriggers({ ...gTriggers, rapidTrigger: Math.round(v) })
                    }
                  />
                  <LevelSliderRow
                    title="Haptic Feedback"
                    value={gTriggers.haptics}
                    min={0}
                    max={5}
                    step={1}
                    lowestLabel="Off"
                    onChange={(v) =>
                      onLogitechGTriggers({ ...gTriggers, haptics: Math.round(v) })
                    }
                  />
                </SettingsSection>

                <SettingsSection
                  title="Side Buttons"
                  footer="Only this mouse's side buttons change. System Default keeps the normal back and forward behavior."
                >
                  <ActionPickerRow
                    title="Back Button"
                    value={acc.logitechGMouse.backButtonAction}
                    onChange={(v) =>
                      onLogitechGOptions(
                        v,
                        acc.logitechGMouse.forwardButtonAction,
                        acc.logitechGMouse.savesToOnboardProfile
                      )
                    }
                  />
                  <ActionPickerRow
                    title="Forward Button"
                    value={acc.logitechGMouse.forwardButtonAction}
                    onChange={(v) =>
                      onLogitechGOptions(
                        acc.logitechGMouse.backButtonAction,
                        v,
                        acc.logitechGMouse.savesToOnboardProfile
                      )
                    }
                  />
                </SettingsSection>

                <SettingsSection
                  title="Onboard Memory"
                  footer="Saves DPI, report rate, triggers, and side buttons to the mouse's onboard profile with CRC verification so they persist without Aeron Tools."
                >
                  <LabeledRow title="Save settings to the mouse">
                    <MacToggle
                      checked={acc.logitechGMouse.savesToOnboardProfile}
                      onChange={(v) =>
                        onLogitechGOptions(
                          acc.logitechGMouse.backButtonAction,
                          acc.logitechGMouse.forwardButtonAction,
                          v
                        )
                      }
                    />
                  </LabeledRow>
                </SettingsSection>
              </>
            )}

            {/* ---------- 3. MX KEYBOARD (complete parity with MXKeyboardConnector.swift) ---------- */}
            {selectedAcc === "mxKeyboard" && (
              <>
                <SettingsSection
                  title="Backlight"
                  footer="Battery saving turns the backlight off below 10% battery. The keyboard's own backlight keys still work."
                >
                  <LabeledRow title="Backlight">
                    <MacToggle
                      checked={acc.mxKeyboard.backlightEnabled}
                      onChange={(enabled) =>
                        onMxKeyboardBacklight({
                          enabled,
                          autoBrightness: acc.mxKeyboard.automaticBrightness,
                          batterySaving: acc.mxKeyboard.batterySaving,
                          level: acc.mxKeyboard.backlightLevel,
                          durationSeconds: acc.mxKeyboard.durationSeconds,
                          effect: acc.mxKeyboard.backlightEffect,
                        })
                      }
                    />
                  </LabeledRow>

                  {acc.mxKeyboard.supportedEffects.length > 1 && (
                    <LabeledRow title="Effect" disabled={!acc.mxKeyboard.backlightEnabled}>
                      <MacSelect<BacklightEffect>
                        value={acc.mxKeyboard.backlightEffect}
                        disabled={!acc.mxKeyboard.backlightEnabled}
                        options={acc.mxKeyboard.supportedEffects.map((e) => ({
                          value: e,
                          label: BACKLIGHT_EFFECT_LABELS[e] ?? e,
                        }))}
                        onChange={(effect) =>
                          onMxKeyboardBacklight({
                            enabled: acc.mxKeyboard.backlightEnabled,
                            autoBrightness: acc.mxKeyboard.automaticBrightness,
                            batterySaving: acc.mxKeyboard.batterySaving,
                            level: acc.mxKeyboard.backlightLevel,
                            durationSeconds: acc.mxKeyboard.durationSeconds,
                            effect,
                          })
                        }
                      />
                    </LabeledRow>
                  )}

                  <LabeledRow
                    title="Automatic brightness"
                    disabled={!acc.mxKeyboard.backlightEnabled}
                  >
                    <MacToggle
                      checked={acc.mxKeyboard.automaticBrightness}
                      disabled={!acc.mxKeyboard.backlightEnabled}
                      onChange={(autoBrightness) =>
                        onMxKeyboardBacklight({
                          enabled: acc.mxKeyboard.backlightEnabled,
                          autoBrightness,
                          batterySaving: acc.mxKeyboard.batterySaving,
                          level: acc.mxKeyboard.backlightLevel,
                          durationSeconds: acc.mxKeyboard.durationSeconds,
                          effect: acc.mxKeyboard.backlightEffect,
                        })
                      }
                    />
                  </LabeledRow>

                  {!acc.mxKeyboard.automaticBrightness && (
                    <LevelSliderRow
                      title="Brightness"
                      value={acc.mxKeyboard.backlightLevel}
                      min={1}
                      max={7}
                      step={1}
                      disabled={!acc.mxKeyboard.backlightEnabled}
                      onChange={(level) =>
                        onMxKeyboardBacklight({
                          enabled: acc.mxKeyboard.backlightEnabled,
                          autoBrightness: acc.mxKeyboard.automaticBrightness,
                          batterySaving: acc.mxKeyboard.batterySaving,
                          level: Math.round(level),
                          durationSeconds: acc.mxKeyboard.durationSeconds,
                          effect: acc.mxKeyboard.backlightEffect,
                        })
                      }
                    />
                  )}

                  <LabeledRow title="Turn off after" disabled={!acc.mxKeyboard.backlightEnabled}>
                    <MacSelect<number>
                      value={acc.mxKeyboard.durationSeconds}
                      disabled={!acc.mxKeyboard.backlightEnabled}
                      options={(MX_BACKLIGHT_DURATIONS.includes(acc.mxKeyboard.durationSeconds)
                        ? MX_BACKLIGHT_DURATIONS
                        : [...MX_BACKLIGHT_DURATIONS, acc.mxKeyboard.durationSeconds].sort(
                            (a, b) => a - b
                          )
                      ).map((sec) => ({
                        value: sec,
                        label: formatDuration(sec),
                      }))}
                      onChange={(durationSeconds) =>
                        onMxKeyboardBacklight({
                          enabled: acc.mxKeyboard.backlightEnabled,
                          autoBrightness: acc.mxKeyboard.automaticBrightness,
                          batterySaving: acc.mxKeyboard.batterySaving,
                          level: acc.mxKeyboard.backlightLevel,
                          durationSeconds,
                          effect: acc.mxKeyboard.backlightEffect,
                        })
                      }
                    />
                  </LabeledRow>

                  <LabeledRow title="Battery saving" disabled={!acc.mxKeyboard.backlightEnabled}>
                    <MacToggle
                      checked={acc.mxKeyboard.batterySaving}
                      disabled={!acc.mxKeyboard.backlightEnabled}
                      onChange={(batterySaving) =>
                        onMxKeyboardBacklight({
                          enabled: acc.mxKeyboard.backlightEnabled,
                          autoBrightness: acc.mxKeyboard.automaticBrightness,
                          batterySaving,
                          level: acc.mxKeyboard.backlightLevel,
                          durationSeconds: acc.mxKeyboard.durationSeconds,
                          effect: acc.mxKeyboard.backlightEffect,
                        })
                      }
                    />
                  </LabeledRow>
                </SettingsSection>

                <SettingsSection
                  title="Keys"
                  footer="When on, press Fn for the media functions printed on the keys."
                >
                  <LabeledRow title="Use F1–F12 as standard function keys">
                    <MacToggle
                      checked={acc.mxKeyboard.fnInversion ?? false}
                      onChange={onMxKeyboardFnInversion}
                    />
                  </LabeledRow>
                </SettingsSection>

                <SettingsSection
                  title="Key Remapping"
                  footer="Click a key to choose its action. Easy-Switch keys (F1–F3) can't be remapped. Quit Logi Options+ so it doesn't intercept the same keys."
                >
                  <KeyRowPicker
                    keyActions={acc.mxKeyboard.keyActions}
                    onSelect={onMxKeyboardKeyAction}
                  />
                </SettingsSection>
              </>
            )}

            {/* ---------- 4. LOGITECH G515 TKL (complete parity with LogitechG515Connector.swift) ---------- */}
            {selectedAcc === "logitechGKeyboard" && (
              <>
                <SettingsSection
                  title="Lighting"
                  footer="Quit G HUB so it doesn't overwrite onboard effects."
                >
                  <LabeledRow title="Effect">
                    <MacSelect<RgbEffect>
                      value={acc.logitechGKeyboard.lighting.effect}
                      options={acc.logitechGKeyboard.supportedEffects.map((e) => ({
                        value: e,
                        label: RGB_EFFECT_LABELS[e] ?? e,
                      }))}
                      onChange={(effect) =>
                        onGKeyboardLighting(acc.logitechGKeyboard.brightness, {
                          ...acc.logitechGKeyboard.lighting,
                          effect,
                        })
                      }
                    />
                  </LabeledRow>

                  {rgbEffectUsesColor(acc.logitechGKeyboard.lighting.effect) && (
                    <ColorPickerRow
                      title="Color"
                      hex={rgbToHex(
                        acc.logitechGKeyboard.lighting.color.red,
                        acc.logitechGKeyboard.lighting.color.green,
                        acc.logitechGKeyboard.lighting.color.blue
                      )}
                      onChange={(hex) =>
                        onGKeyboardLighting(acc.logitechGKeyboard.brightness, {
                          ...acc.logitechGKeyboard.lighting,
                          color: hexToRgb(hex),
                        })
                      }
                    />
                  )}

                  {rgbEffectUsesSpeed(acc.logitechGKeyboard.lighting.effect) && (
                    <LevelSliderRow
                      title="Speed"
                      value={acc.logitechGKeyboard.lighting.speed}
                      min={1}
                      max={10}
                      step={1}
                      onChange={(speed) =>
                        onGKeyboardLighting(acc.logitechGKeyboard.brightness, {
                          ...acc.logitechGKeyboard.lighting,
                          speed: Math.round(speed),
                        })
                      }
                    />
                  )}

                  <LevelSliderRow
                    title="Brightness"
                    value={acc.logitechGKeyboard.brightness}
                    min={0}
                    max={acc.logitechGKeyboard.maxBrightness}
                    step={1}
                    lowestLabel="Off"
                    format={(v) => `${Math.round(v)}%`}
                    onChange={(b) =>
                      onGKeyboardLighting(Math.round(b), acc.logitechGKeyboard.lighting)
                    }
                  />
                </SettingsSection>

                <SettingsSection
                  title="Game Mode"
                  footer="Switch game mode with the game mode key on the keyboard."
                >
                  <LabeledRow title="Keyboard Game Mode">
                    <div className="flex items-center gap-2">
                      <StatusDot isActive={acc.logitechGKeyboard.gameModeOn} />
                      <span className="text-[12px] text-white/80">
                        {acc.logitechGKeyboard.gameModeOn ? "On" : "Off"}
                      </span>
                    </div>
                  </LabeledRow>
                </SettingsSection>
              </>
            )}

            {/* ---------- 5. KEYCHRON M3 MINI 4K (complete parity with KeychronM3MiniConnector.swift) ---------- */}
            {selectedAcc === "keychronM3Mini" && (
              <>
                <SettingsSection
                  title="Performance"
                  footer="DPI applies to the active stage; the button under the wheel switches stages. Changes are saved to onboard memory."
                >
                  <LabeledRow title="Active DPI Stage">
                    <MacSegmented<number>
                      value={acc.keychronM3Mini.activeStage}
                      options={acc.keychronM3Mini.stageDpis.map((dpi, idx) => ({
                        value: idx,
                        label: `S${idx + 1} · ${dpi}`,
                      }))}
                      onChange={(stage) =>
                        onKeychronUpdate({
                          activeStage: stage,
                          dpi: acc.keychronM3Mini.stageDpis[stage] ?? 1600,
                          reportRateHz: acc.keychronM3Mini.reportRateHz,
                          liftOffMm: acc.keychronM3Mini.liftOffMm,
                          motionSync: acc.keychronM3Mini.motionSync,
                          angleSnapping: acc.keychronM3Mini.angleSnapping,
                        })
                      }
                    />
                  </LabeledRow>

                  <DPIControlRow
                    dpi={acc.keychronM3Mini.stageDpis[acc.keychronM3Mini.activeStage] ?? 1600}
                    presets={GAMING_MOUSE_DPI_PRESETS}
                    min={100}
                    max={26000}
                    onCommit={(dpi) =>
                      onKeychronUpdate({
                        activeStage: acc.keychronM3Mini.activeStage,
                        dpi,
                        reportRateHz: acc.keychronM3Mini.reportRateHz,
                        liftOffMm: acc.keychronM3Mini.liftOffMm,
                        motionSync: acc.keychronM3Mini.motionSync,
                        angleSnapping: acc.keychronM3Mini.angleSnapping,
                      })
                    }
                  />

                  <LabeledRow title="Report Rate">
                    <MacSelect<number>
                      value={acc.keychronM3Mini.reportRateHz}
                      options={[125, 250, 500, 1000, 2000, 4000]
                        .filter((hz) => hz <= acc.keychronM3Mini.maxReportRateHz)
                        .map((hz) => ({
                          value: hz,
                          label: formatRateHz(hz),
                        }))}
                      onChange={(reportRateHz) =>
                        onKeychronUpdate({
                          activeStage: acc.keychronM3Mini.activeStage,
                          dpi:
                            acc.keychronM3Mini.stageDpis[acc.keychronM3Mini.activeStage] ?? 1600,
                          reportRateHz,
                          liftOffMm: acc.keychronM3Mini.liftOffMm,
                          motionSync: acc.keychronM3Mini.motionSync,
                          angleSnapping: acc.keychronM3Mini.angleSnapping,
                        })
                      }
                    />
                  </LabeledRow>
                </SettingsSection>

                <SettingsSection title="Sensor">
                  <LabeledRow title="Lift-off distance">
                    <MacSegmented<number>
                      value={acc.keychronM3Mini.liftOffMm}
                      options={[
                        { value: 1, label: "1 mm" },
                        { value: 2, label: "2 mm" },
                      ]}
                      onChange={(liftOffMm) =>
                        onKeychronUpdate({
                          activeStage: acc.keychronM3Mini.activeStage,
                          dpi:
                            acc.keychronM3Mini.stageDpis[acc.keychronM3Mini.activeStage] ?? 1600,
                          reportRateHz: acc.keychronM3Mini.reportRateHz,
                          liftOffMm,
                          motionSync: acc.keychronM3Mini.motionSync,
                          angleSnapping: acc.keychronM3Mini.angleSnapping,
                        })
                      }
                    />
                  </LabeledRow>
                  <LabeledRow title="Motion sync">
                    <MacToggle
                      checked={acc.keychronM3Mini.motionSync}
                      onChange={(motionSync) =>
                        onKeychronUpdate({
                          activeStage: acc.keychronM3Mini.activeStage,
                          dpi:
                            acc.keychronM3Mini.stageDpis[acc.keychronM3Mini.activeStage] ?? 1600,
                          reportRateHz: acc.keychronM3Mini.reportRateHz,
                          liftOffMm: acc.keychronM3Mini.liftOffMm,
                          motionSync,
                          angleSnapping: acc.keychronM3Mini.angleSnapping,
                        })
                      }
                    />
                  </LabeledRow>
                  <LabeledRow title="Angle snapping">
                    <MacToggle
                      checked={acc.keychronM3Mini.angleSnapping}
                      onChange={(angleSnapping) =>
                        onKeychronUpdate({
                          activeStage: acc.keychronM3Mini.activeStage,
                          dpi:
                            acc.keychronM3Mini.stageDpis[acc.keychronM3Mini.activeStage] ?? 1600,
                          reportRateHz: acc.keychronM3Mini.reportRateHz,
                          liftOffMm: acc.keychronM3Mini.liftOffMm,
                          motionSync: acc.keychronM3Mini.motionSync,
                          angleSnapping,
                        })
                      }
                    />
                  </LabeledRow>
                </SettingsSection>

                <SettingsSection
                  title="Side Buttons"
                  footer="Saved to the mouse so buttons keep working without Aeron Tools and over Bluetooth."
                >
                  <ActionPickerRow
                    title="Back Button"
                    value={acc.keychronM3Mini.backButtonAction}
                    onChange={(v) =>
                      onKeychronSideButtons(v, acc.keychronM3Mini.forwardButtonAction)
                    }
                  />
                  <ActionPickerRow
                    title="Forward Button"
                    value={acc.keychronM3Mini.forwardButtonAction}
                    onChange={(v) =>
                      onKeychronSideButtons(acc.keychronM3Mini.backButtonAction, v)
                    }
                  />
                </SettingsSection>
              </>
            )}

            {/* ---------- 6. RAZER DOCK CHROMA (complete parity with RazerDockConnector.swift) ---------- */}
            {selectedAcc === "razerDock" && (
              <>
                <SettingsSection
                  title="Ports"
                  footer="Click a port to see what's plugged into it. Thunderbolt devices take the first free Thunderbolt port, since macOS doesn't tell which one they're in."
                >
                  <div className="space-y-3 p-3.5">
                    <DockPortsView layout={acc.razerDock.ports} hasEthernet />
                    <ChromaGlowBar
                      lighting={acc.razerDock.lighting ?? razerLighting}
                      brightness={acc.razerDock.brightness ?? 255}
                    />
                  </div>
                </SettingsSection>

                <SettingsSection
                  title="Lighting"
                  footer="Saved on the dock, so it keeps its Chroma underglow without the app."
                >
                  <LabeledRow title="Effect">
                    <MacSelect<RazerMode>
                      value={razerLighting.mode ?? "spectrum"}
                      options={(
                        ["off", "staticColor", "breathing", "spectrum", "wave"] as RazerMode[]
                      ).map((m) => ({
                        value: m,
                        label: RAZER_MODE_LABELS[m],
                      }))}
                      onChange={(mode) =>
                        onRazerDockLighting(null, { ...razerLighting, mode })
                      }
                    />
                  </LabeledRow>

                  {razerLighting.mode === "staticColor" && (
                    <ColorPickerRow
                      title="Color"
                      hex={rgbToHex(
                        razerLighting.primary.red,
                        razerLighting.primary.green,
                        razerLighting.primary.blue
                      )}
                      onChange={(hex) =>
                        onRazerDockLighting(null, {
                          ...razerLighting,
                          primary: hexToRgb(hex),
                        })
                      }
                    />
                  )}

                  {razerLighting.mode === "breathing" && (
                    <>
                      <LabeledRow title="Colors">
                        <MacSegmented<BreathingStyle>
                          value={razerLighting.breathing}
                          options={[
                            { value: "single", label: "Single" },
                            { value: "dual", label: "Dual" },
                            { value: "random", label: "Random" },
                          ]}
                          onChange={(breathing) =>
                            onRazerDockLighting(null, { ...razerLighting, breathing })
                          }
                        />
                      </LabeledRow>
                      {razerLighting.breathing !== "random" && (
                        <ColorPickerRow
                          title={razerLighting.breathing === "dual" ? "First Color" : "Color"}
                          hex={rgbToHex(
                            razerLighting.primary.red,
                            razerLighting.primary.green,
                            razerLighting.primary.blue
                          )}
                          onChange={(hex) =>
                            onRazerDockLighting(null, {
                              ...razerLighting,
                              primary: hexToRgb(hex),
                            })
                          }
                        />
                      )}
                      {razerLighting.breathing === "dual" && (
                        <ColorPickerRow
                          title="Second Color"
                          hex={rgbToHex(
                            razerLighting.secondary.red,
                            razerLighting.secondary.green,
                            razerLighting.secondary.blue
                          )}
                          onChange={(hex) =>
                            onRazerDockLighting(null, {
                              ...razerLighting,
                              secondary: hexToRgb(hex),
                            })
                          }
                        />
                      )}
                    </>
                  )}

                  {razerLighting.mode === "wave" && (
                    <LabeledRow title="Direction">
                      <MacSegmented<WaveDirection>
                        value={razerLighting.waveDirection}
                        options={[
                          { value: "leftToRight", label: "Left → Right" },
                          { value: "rightToLeft", label: "Right → Left" },
                        ]}
                        onChange={(waveDirection) =>
                          onRazerDockLighting(null, { ...razerLighting, waveDirection })
                        }
                      />
                    </LabeledRow>
                  )}

                  {razerLighting.mode !== "off" && (
                    <LevelSliderRow
                      title="Brightness"
                      value={razerBrightnessPct}
                      min={0}
                      max={100}
                      step={1}
                      lowestLabel="Off"
                      format={(v) => `${Math.round(v)}%`}
                      onChange={(pct) =>
                        onRazerDockLighting(Math.round((pct / 100) * 255), null)
                      }
                    />
                  )}
                </SettingsSection>

                {(acc.razerDock.serialNumber || acc.razerDock.firmware) && (
                  <SettingsSection title="About">
                    {acc.razerDock.serialNumber && (
                      <LabeledRow title="Serial Number">
                        <span className="font-mono-tabular text-[12px] text-white/70">
                          {acc.razerDock.serialNumber}
                        </span>
                      </LabeledRow>
                    )}
                    {acc.razerDock.firmware && (
                      <LabeledRow title="Lighting Firmware">
                        <span className="font-mono-tabular text-[12px] text-white/70">
                          {acc.razerDock.firmware}
                        </span>
                      </LabeledRow>
                    )}
                  </SettingsSection>
                )}
              </>
            )}

            {/* ---------- 7. SATECHI SLIM HUB PRO ---------- */}
            {selectedAcc === "satechiHub" && (
              <>
                <SettingsSection
                  title="Ports"
                  footer="Click a port to see what's plugged into it. Thunderbolt devices take the first free Thunderbolt port, since macOS doesn't tell which one they're in."
                >
                  <div className="p-3.5">
                    <DockPortsView layout={acc.satechiHub.ports} />
                  </div>
                </SettingsSection>

                {acc.satechiHub.ports.serialNumber && (
                  <SettingsSection title="About">
                    <LabeledRow title="Serial Number">
                      <span className="font-mono-tabular text-[12px] text-white/70">
                        {acc.satechiHub.ports.serialNumber}
                      </span>
                    </LabeledRow>
                  </SettingsSection>
                )}
              </>
            )}

            </fieldset>

            {/* Shared Battery Alerts Section (matches AccessoryBatteryAlerts in AccessoryConnector.swift) */}
            {activeCatalogItem.hasBattery && (
              <SettingsSection
                title="Battery"
                footer="Applies to every battery-powered accessory. You're notified once per discharge cycle."
              >
                <LabeledRow title="Low battery notification">
                  <MacToggle
                    checked={prefs.lowBatteryAlertEnabled}
                    onChange={(v) => setPref("lowBatteryAlertEnabled", v)}
                  />
                </LabeledRow>
                <LabeledRow
                  title="Notify at or below"
                  disabled={!prefs.lowBatteryAlertEnabled}
                >
                  <MacStepper
                    value={prefs.lowBatteryThreshold}
                    min={5}
                    max={50}
                    step={5}
                    disabled={!prefs.lowBatteryAlertEnabled}
                    format={(v) => `${v}%`}
                    onChange={(v) => setPref("lowBatteryThreshold", v)}
                  />
                </LabeledRow>
              </SettingsSection>
            )}
          </div>
        )}

        {/* ======================== ABOUT TAB ======================== */}
        {tab === "about" && (
          <div className="mx-auto flex h-full max-w-[420px] flex-col items-center justify-center py-8 text-center">
            {/* Official Aeron Tools macOS app icon */}
            <img
              src="/app-icon.png"
              alt="Aeron Tools"
              draggable={false}
              className="mb-5 h-[92px] w-[92px] select-none drop-shadow-[0_12px_28px_rgba(0,0,0,0.5)]"
            />

            <h2 className="text-[20px] font-bold tracking-[-0.02em] text-white/95">Aeron Tools</h2>
            <p className="mt-1 text-[11.5px] font-medium text-white/45">
              Cross-Platform Edition · Version 1.0.0
            </p>
            <p className="mt-4 max-w-[340px] text-[12px] leading-relaxed text-white/60">
              Hardware DDC/CI monitor brightness, volume &amp; input switching, Logitech &amp;
              Keychron HID accessories, Razer &amp; Satechi Thunderbolt docks, Game Mode, Caffeine,
              and live power &amp; thermal telemetry.
            </p>
            <div className="mt-5 inline-flex items-center gap-2 rounded-full border border-white/[0.1] bg-white/[0.04] px-3 py-1 text-[11px] text-white/60">
              <StatusDot isActive={true} />
              <span>
                {snapshot.platform}
                {snapshot.isSteamos ? " · SteamOS" : ""} · {snapshot.gameMode.backendName}
              </span>
            </div>
            <p className="mt-7 text-[10.5px] text-white/30">© 2026 Aeron Labs</p>
          </div>
        )}
      </div>
    </div>
  );
}
