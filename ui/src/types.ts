export type ThermalPressure = "nominal" | "fair" | "serious" | "critical";
export type GameModePolicy = "automatic" | "forcedOn" | "forcedOff";
export type MxWheelMode = "ratchet" | "freeSpin";
export type BacklightEffect =
  | "staticLight"
  | "breathing"
  | "contrast"
  | "reaction"
  | "random"
  | "waves";
export type RgbEffect = "off" | "fixed" | "breathing" | "colorCycle" | "colorWave";
export type RazerMode = "off" | "staticColor" | "breathing" | "spectrum" | "wave";
export type BreathingStyle = "single" | "dual" | "random";
export type WaveDirection = "leftToRight" | "rightToLeft";

export type AccessoryButtonAction =
  | "systemDefault"
  | "missionControl"
  | "appExpose"
  | "showDesktop"
  | "launchpad"
  | "spaceLeft"
  | "spaceRight"
  | "navigateBack"
  | "navigateForward"
  | "playPause"
  | "mutePointerDisplay"
  | "toggleBuiltinScreen"
  | "toggleCaffeine"
  | "toggleWheelMode"
  | "copy"
  | "paste";

export type MxThumbwheelAction =
  | "horizontalScroll"
  | "displayBrightness"
  | "displayVolume"
  | "switchWorkspaces"
  | "switchTabs"
  | "zoom";

export interface InputSourceOption {
  code: number;
  name: string;
}

export interface ExternalDisplayInfo {
  id: string;
  settingsKey: string;
  name: string;
  brightness: number;
  volume: number;
  isMuted: boolean;
  extraDimming: number;
  inputSources: InputSourceOption[];
  currentInput: number | null;
  hasHardwareControl: boolean;
  isBuiltin: boolean;
  isEnabled: boolean;
}

export interface FanReading {
  index: number;
  name: string;
  rpm: number;
  maxRpm: number | null;
}

export interface ThermalSnapshot {
  supported: boolean;
  pressure: ThermalPressure;
  cpuCelsius: number | null;
  gpuCelsius: number | null;
  batteryCelsius: number | null;
  fans: FanReading[];
}

export interface WattageSnapshot {
  supported: boolean;
  isPluggedIn: boolean;
  isCharging: boolean;
  batteryLevel: number | null;
  systemLoadWatts: number | null;
  inputWatts: number | null;
  adapterWatts: number | null;
  batteryWatts: number | null;
  voltage: number | null;
  amperage: number | null;
  batteryHealthPercent: number | null;
  cycleCount: number | null;
}

export interface GameModeState {
  supported: boolean;
  isActive: boolean;
  policy: GameModePolicy;
  backendName: string;
}

export interface CaffeineState {
  isActive: boolean;
  endsAtMs: number | null;
  isAutomatic: boolean;
}

export interface DockAttachedDevice {
  id: string;
  name: string;
  detail: string;
  icon: string;
}

export interface DockPort {
  id: string;
  kind: "thunderbolt" | "usbA";
  number: number;
  title: string;
  devices: DockAttachedDevice[];
}

export interface DockLayout {
  isPresent: boolean;
  thunderbolt: DockPort[];
  usbA: DockPort[];
  ethernetInterface: string | null;
  serialNumber: string | null;
}

export interface RgbColor {
  red: number;
  green: number;
  blue: number;
}

export interface RgbLighting {
  effect: RgbEffect;
  color: RgbColor;
  speed: number;
}

export interface RazerLighting {
  mode: RazerMode | null;
  primary: RgbColor;
  secondary: RgbColor;
  breathing: BreathingStyle;
  waveDirection: WaveDirection;
}

export interface TriggerSettings {
  actuation: number;
  rapidTrigger: number;
  haptics: number;
}

export interface MxMasterOptions {
  standardVerticalScroll: boolean;
  smoothScrolling: boolean;
  scrollSpeedMultiplier: number;
  thumbwheelAction: MxThumbwheelAction;
  invertThumbwheel: boolean;
  middleButtonAction: AccessoryButtonAction;
  backButtonAction: AccessoryButtonAction;
  forwardButtonAction: AccessoryButtonAction;
  gestureButtonAction: AccessoryButtonAction;
  modeShiftButtonAction: AccessoryButtonAction;
  hapticPanelButtonAction: AccessoryButtonAction;
  gesturesEnabled: boolean;
  gestureUpAction: AccessoryButtonAction;
  gestureDownAction: AccessoryButtonAction;
  gestureLeftAction: AccessoryButtonAction;
  gestureRightAction: AccessoryButtonAction;
  savesToMouse: boolean;
}

export interface MxMasterState extends MxMasterOptions {
  connected: boolean;
  name: string;
  connection: string | null;
  batteryPercent: number | null;
  isCharging: boolean;
  dpi: number;
  minDpi: number;
  maxDpi: number;
  dpiStep: number;
  wheelMode: MxWheelMode;
  smartShiftEnabled: boolean;
  smartShiftThreshold: number;
}

export interface MxKeyboardState {
  connected: boolean;
  name: string;
  connection: string | null;
  batteryPercent: number | null;
  isCharging: boolean;
  backlightEnabled: boolean;
  automaticBrightness: boolean;
  batterySaving: boolean;
  backlightLevel: number;
  backlightEffect: BacklightEffect;
  supportedEffects: BacklightEffect[];
  durationSeconds: number;
  fnInversion: boolean | null;
  currentHost: number | null;
  keyActions: Record<string, AccessoryButtonAction>;
}

export interface LogitechGMouseState {
  connected: boolean;
  name: string;
  connection: string | null;
  batteryPercent: number | null;
  isCharging: boolean;
  dpi: number;
  minDpi: number;
  maxDpi: number;
  reportRateHz: number;
  supportedReportRates: number[];
  liftOffDistance: number;
  triggers: TriggerSettings | null;
  backButtonAction: AccessoryButtonAction;
  forwardButtonAction: AccessoryButtonAction;
  savesToOnboardProfile: boolean;
}

export interface LogitechGKeyboardState {
  connected: boolean;
  name: string;
  connection: string | null;
  batteryPercent: number | null;
  isCharging: boolean;
  brightness: number;
  maxBrightness: number;
  lighting: RgbLighting;
  supportedEffects: RgbEffect[];
  gameModeOn: boolean;
}

export interface KeychronM3MiniState {
  connected: boolean;
  name: string;
  connection: string | null;
  batteryPercent: number | null;
  isCharging: boolean;
  activeStage: number;
  stageDpis: number[];
  reportRateHz: number;
  maxReportRateHz: number;
  liftOffMm: number;
  motionSync: boolean;
  angleSnapping: boolean;
  backButtonAction: AccessoryButtonAction;
  forwardButtonAction: AccessoryButtonAction;
}

export interface RazerDockState {
  connected: boolean;
  name: string;
  firmware: string | null;
  serialNumber: string | null;
  brightness: number | null;
  lighting: RazerLighting | null;
  ports: DockLayout;
}

export interface SatechiHubState {
  connected: boolean;
  name: string;
  ports: DockLayout;
}

export interface AccessoriesSnapshot {
  mxMaster: MxMasterState;
  mxKeyboard: MxKeyboardState;
  logitechGMouse: LogitechGMouseState;
  logitechGKeyboard: LogitechGKeyboardState;
  keychronM3Mini: KeychronM3MiniState;
  razerDock: RazerDockState;
  satechiHub: SatechiHubState;
}

export interface HotkeyBinding {
  action: string;
  label: string;
  accelerator: string | null;
}

export interface BuiltinDisplayState {
  present: boolean;
  isTurnedOff: boolean;
  canTurnOff: boolean;
}

export interface AppPreferences {
  showAccessoriesCard: boolean;
  showWattageMeter: boolean;
  showBatteryHealth: boolean;
  showThermals: boolean;
  autoTurnOffBuiltin: boolean;
  showInputSwitching: boolean;
  extraDimmingEnabled: boolean;
  restoreMonitorSettings: boolean;
  mediaKeysControlPointerDisplay: boolean;
  launchAtLogin: boolean;
  lowBatteryAlertEnabled: boolean;
  lowBatteryThreshold: number;
  caffeineWithExternalDisplay: boolean;
  caffeineOnPowerAdapter: boolean;
  daemonPort: number;
  hotkeys: HotkeyBinding[];
  monitorSettings: Record<string, unknown>;
}

export interface AppSnapshot {
  platform: string;
  isSteamos: boolean;
  displays: ExternalDisplayInfo[];
  builtinDisplay: BuiltinDisplayState;
  accessories: AccessoriesSnapshot;
  wattage: WattageSnapshot;
  thermals: ThermalSnapshot;
  caffeine: CaffeineState;
  gameMode: GameModeState;
  preferences: AppPreferences;
}
