import { useEffect, useRef, useState } from "react";
import {
  Camera,
  Check,
  ChevronsUpDown,
  Mic,
  MicOff,
  Minus,
  Play,
  Plus,
  Search,
  Smile,
  Sun,
  SunDim,
  Volume1,
  Volume2,
  VolumeX,
} from "lucide-react";
import type { AccessoryButtonAction, RazerLighting } from "../types";
import { MacSlider } from "./MacSlider";

// MARK: - Shared Action Metadata (matches AccessoryActions.swift)

export const ACCESSORY_ACTIONS: Array<{ id: AccessoryButtonAction; title: string }> = [
  { id: "systemDefault", title: "System Default" },
  { id: "missionControl", title: "Mission Control / Overview" },
  { id: "appExpose", title: "App Exposé" },
  { id: "showDesktop", title: "Show Desktop" },
  { id: "launchpad", title: "App Launcher" },
  { id: "spaceLeft", title: "Move a Workspace Left" },
  { id: "spaceRight", title: "Move a Workspace Right" },
  { id: "navigateBack", title: "Back" },
  { id: "navigateForward", title: "Forward" },
  { id: "playPause", title: "Play / Pause Media" },
  { id: "mutePointerDisplay", title: "Mute Display Under Pointer" },
  { id: "toggleBuiltinScreen", title: "Toggle Built-in Screen" },
  { id: "toggleCaffeine", title: "Toggle Caffeine" },
  { id: "toggleWheelMode", title: "Toggle Ratchet / Free-Spin" },
  { id: "copy", title: "Copy" },
  { id: "paste", title: "Paste" },
];

export const GENERAL_ACTIONS = ACCESSORY_ACTIONS.filter((a) => a.id !== "toggleWheelMode");

export function actionTitle(action: AccessoryButtonAction, defaultTitle?: string): string {
  if (action === "systemDefault" && defaultTitle) return defaultTitle;
  return ACCESSORY_ACTIONS.find((a) => a.id === action)?.title ?? "System Default";
}

// MARK: - Native macOS Grouped Form Primitives (matches SettingsComponents.swift)

export function SettingsSection({
  title,
  footer,
  trailing,
  children,
}: {
  title: string;
  footer?: string;
  trailing?: React.ReactNode;
  children: React.ReactNode;
}) {
  return (
    <section className="space-y-[7px]">
      <div className="flex items-center justify-between px-[8px]">
        <h3 className="text-[12px] font-semibold tracking-[-0.005em] text-white/82">{title}</h3>
        {trailing}
      </div>
      <div className="aeron-settings-group divide-y divide-white/[0.068]">{children}</div>
      {footer && (
        <p className="px-[8px] pt-[2px] text-[11px] leading-[1.45] text-white/44">{footer}</p>
      )}
    </section>
  );
}

export function StatusDot({ isActive }: { isActive: boolean }) {
  return (
    <span
      className={`inline-block h-[7px] w-[7px] shrink-0 rounded-full ${
        isActive
          ? "bg-[#30d158] shadow-[0_0_6px_rgba(48,209,88,0.55)]"
          : "bg-white/30"
      }`}
      aria-hidden="true"
    />
  );
}

export function LabeledRow({
  title,
  subtitle,
  disabled = false,
  children,
}: {
  title: string;
  subtitle?: string;
  disabled?: boolean;
  children: React.ReactNode;
}) {
  return (
    <div
      className={`flex min-h-[42px] items-center justify-between gap-4 px-4 py-[10px] ${
        disabled ? "pointer-events-none opacity-45" : ""
      }`}
    >
      <div className="min-w-0">
        <div className="text-[12.5px] font-normal text-white/92">{title}</div>
        {subtitle && (
          <div className="mt-[2px] text-[11px] leading-snug text-white/45">{subtitle}</div>
        )}
      </div>
      <div className="flex shrink-0 items-center gap-2">{children}</div>
    </div>
  );
}

export function MacToggle({
  checked,
  disabled = false,
  onChange,
}: {
  checked: boolean;
  disabled?: boolean;
  onChange: (next: boolean) => void;
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      disabled={disabled}
      onClick={() => onChange(!checked)}
      className={`relative inline-flex h-[20px] w-[35px] shrink-0 items-center rounded-full border transition-colors ${
        checked
          ? "border-[#0a84ff] bg-[#0a84ff]"
          : "border-white/[0.08] bg-white/[0.15] hover:bg-white/[0.2]"
      } ${disabled ? "opacity-45" : ""}`}
    >
      <span
        className={`inline-block h-[16px] w-[16px] rounded-full bg-white shadow-[0_1px_2.5px_rgba(0,0,0,0.45)] transition-transform ${
          checked ? "translate-x-[16px]" : "translate-x-[1.5px]"
        }`}
      />
    </button>
  );
}

/** Authentic macOS NSPopUpButton dropdown styled with the subtle double-chevron pill. */
export function MacSelect<T extends string | number>({
  value,
  options,
  disabled = false,
  onChange,
}: {
  value: T;
  options: Array<{ value: T; label: string }>;
  disabled?: boolean;
  onChange: (next: T) => void;
}) {
  const isNumber = typeof value === "number";
  return (
    <div className={`relative inline-flex items-center ${disabled ? "opacity-45" : ""}`}>
      <select
        value={String(value)}
        disabled={disabled}
        onChange={(e) => {
          const raw = e.target.value;
          onChange((isNumber ? Number(raw) : raw) as T);
        }}
        className="h-[25px] max-w-[238px] appearance-none rounded-[7px] border border-white/[0.13] bg-white/[0.075] pl-[10px] pr-[26px] text-[12px] font-medium text-white/90 shadow-[inset_0_0.5px_0_rgba(255,255,255,0.1),0_0.5px_1px_rgba(0,0,0,0.28)] outline-none transition-colors hover:border-white/[0.2] hover:bg-white/[0.11] focus:border-[#0a84ff] focus:ring-2 focus:ring-[#0a84ff]/30"
      >
        {options.map((opt) => (
          <option key={String(opt.value)} value={String(opt.value)} className="bg-[#252528] text-white">
            {opt.label}
          </option>
        ))}
      </select>
      <span className="pointer-events-none absolute right-[4.5px] flex h-[16px] w-[16px] items-center justify-center rounded-[4px] bg-[#0a84ff]/85 text-white">
        <ChevronsUpDown className="h-[10px] w-[10px]" strokeWidth={2.5} />
      </span>
    </div>
  );
}

export function MacSegmented<T extends string | number>({
  value,
  options,
  onChange,
}: {
  value: T;
  options: Array<{ value: T; label: string }>;
  onChange: (next: T) => void;
}) {
  return (
    <div className="aeron-segmented">
      {options.map((opt) => {
        const active = opt.value === value;
        return (
          <button
            key={String(opt.value)}
            type="button"
            onClick={() => onChange(opt.value)}
            className={`aeron-segmented-item ${active ? "aeron-segmented-item-active" : ""}`}
          >
            {opt.label}
          </button>
        );
      })}
    </div>
  );
}

export function MacStepper({
  value,
  min,
  max,
  step = 1,
  disabled = false,
  format,
  onChange,
}: {
  value: number;
  min: number;
  max: number;
  step?: number;
  disabled?: boolean;
  format?: (val: number) => string;
  onChange: (next: number) => void;
}) {
  return (
    <div className={`flex items-center gap-2.5 ${disabled ? "opacity-45" : ""}`}>
      <span className="font-mono-tabular text-[12px] font-medium text-white/85">
        {format ? format(value) : value}
      </span>
      <div className="inline-flex overflow-hidden rounded-[7px] border border-white/[0.13] bg-white/[0.07] shadow-[inset_0_0.5px_0_rgba(255,255,255,0.1)]">
        <button
          type="button"
          disabled={disabled || value <= min}
          onClick={() => onChange(Math.max(min, value - step))}
          className="flex h-[23px] w-[23px] items-center justify-center border-r border-white/[0.1] text-white/80 hover:bg-white/[0.1] disabled:opacity-35"
        >
          <Minus className="h-[11px] w-[11px]" strokeWidth={2.2} />
        </button>
        <button
          type="button"
          disabled={disabled || value >= max}
          onClick={() => onChange(Math.min(max, value + step))}
          className="flex h-[23px] w-[23px] items-center justify-center text-white/80 hover:bg-white/[0.1] disabled:opacity-35"
        >
          <Plus className="h-[11px] w-[11px]" strokeWidth={2.2} />
        </button>
      </div>
    </div>
  );
}

/** Exact port of Swift `LevelSlider` / `ValueSlider` inside grouped Form rows. */
export function LevelSliderRow({
  title,
  value,
  min,
  max,
  step = 1,
  lowestLabel,
  format,
  disabled = false,
  onChange,
}: {
  title: string;
  value: number;
  min: number;
  max: number;
  step?: number;
  lowestLabel?: string;
  format?: (v: number) => string;
  disabled?: boolean;
  onChange: (next: number) => void;
}) {
  const [live, setLive] = useState(value);
  useEffect(() => setLive(value), [value]);

  const label =
    lowestLabel && live <= min
      ? lowestLabel
      : format
        ? format(live)
        : String(Math.round(live));

  return (
    <LabeledRow title={title} disabled={disabled}>
      <div className="flex items-center gap-[10px]">
        <div className="w-[156px]">
          <MacSlider
            value={value}
            min={min}
            max={max}
            step={step}
            disabled={disabled}
            ariaLabel={title}
            onDisplayValueChange={setLive}
            onChange={onChange}
          />
        </div>
        <span className="font-mono-tabular w-[42px] text-right text-[11.5px] font-medium text-white/80">
          {label}
        </span>
      </div>
    </LabeledRow>
  );
}

/** Exact port of Swift `DPIControl`: preset buttons + aligned numeric field. */
export function DPIControlRow({
  dpi,
  presets,
  min,
  max,
  onCommit,
}: {
  dpi: number;
  presets: number[];
  min: number;
  max: number;
  onCommit: (next: number) => void;
}) {
  const [text, setText] = useState(String(dpi));
  useEffect(() => setText(String(dpi)), [dpi]);

  const commitText = () => {
    const parsed = parseInt(text.trim(), 10);
    if (!Number.isNaN(parsed)) {
      const clamped = Math.min(Math.max(parsed, min), max);
      onCommit(clamped);
      setText(String(clamped));
    } else {
      setText(String(dpi));
    }
  };

  return (
    <LabeledRow title="DPI">
      <div className="flex flex-wrap items-center justify-end gap-[5px]">
        {presets
          .filter((p) => p >= min && p <= max)
          .map((preset) => {
            const active = dpi === preset;
            return (
              <button
                key={preset}
                type="button"
                onClick={() => onCommit(preset)}
                className={`aeron-btn !px-[7.5px] !py-[3px] !text-[11px] font-mono-tabular ${
                  active ? "aeron-btn-accent" : ""
                }`}
              >
                {preset}
              </button>
            );
          })}
        <input
          type="text"
          inputMode="numeric"
          value={text}
          onChange={(e) => setText(e.target.value)}
          onBlur={commitText}
          onKeyDown={(e) => {
            if (e.key === "Enter") {
              commitText();
              (e.currentTarget as HTMLInputElement).blur();
            }
          }}
          className="aeron-input font-mono-tabular h-[24px] w-[60px] text-right"
          aria-label="Custom DPI"
        />
      </div>
    </LabeledRow>
  );
}

export function ActionPickerRow({
  title,
  value,
  actions = GENERAL_ACTIONS,
  defaultTitle,
  onChange,
}: {
  title: string;
  value: AccessoryButtonAction;
  actions?: Array<{ id: AccessoryButtonAction; title: string }>;
  defaultTitle?: string;
  onChange: (next: AccessoryButtonAction) => void;
}) {
  return (
    <LabeledRow title={title}>
      <MacSelect
        value={value}
        options={actions.map((a) => ({
          value: a.id,
          label: a.id === "systemDefault" && defaultTitle ? defaultTitle : a.title,
        }))}
        onChange={onChange}
      />
    </LabeledRow>
  );
}

export function ColorPickerRow({
  title,
  hex,
  onChange,
}: {
  title: string;
  hex: string;
  onChange: (hex: string) => void;
}) {
  return (
    <LabeledRow title={title}>
      <label className="flex cursor-pointer items-center gap-2 rounded-[7px] border border-white/[0.13] bg-white/[0.06] px-2.5 py-[3.5px] hover:bg-white/[0.1]">
        <span
          className="h-[14px] w-[22px] rounded-[4px] border border-white/25 shadow-inner"
          style={{ backgroundColor: hex }}
        />
        <span className="font-mono-tabular text-[11px] uppercase text-white/75">{hex}</span>
        <input
          type="color"
          value={hex}
          onChange={(e) => onChange(e.target.value)}
          className="sr-only"
        />
      </label>
    </LabeledRow>
  );
}

// MARK: - MX Keyboard KeyRowPicker (exact port of Swift KeyRowPicker)

interface KeyDef {
  position: number;
  label: string;
  icon: React.ReactNode;
  divertable: boolean;
}

const MX_FUNCTION_KEYS: KeyDef[] = [
  { position: 1, label: "F1", icon: <span className="text-[10px] font-bold">1</span>, divertable: false },
  { position: 2, label: "F2", icon: <span className="text-[10px] font-bold">2</span>, divertable: false },
  { position: 3, label: "F3", icon: <span className="text-[10px] font-bold">3</span>, divertable: false },
  { position: 4, label: "F4", icon: <SunDim className="h-[11px] w-[11px]" />, divertable: true },
  { position: 5, label: "F5", icon: <Sun className="h-[11px] w-[11px]" />, divertable: true },
  { position: 6, label: "F6", icon: <Mic className="h-[11px] w-[11px]" />, divertable: true },
  { position: 7, label: "F7", icon: <Smile className="h-[11px] w-[11px]" />, divertable: true },
  { position: 8, label: "F8", icon: <Camera className="h-[11px] w-[11px]" />, divertable: true },
  { position: 9, label: "F9", icon: <MicOff className="h-[11px] w-[11px]" />, divertable: true },
  { position: 10, label: "F10", icon: <Play className="h-[11px] w-[11px]" />, divertable: true },
  { position: 11, label: "F11", icon: <VolumeX className="h-[11px] w-[11px]" />, divertable: true },
  { position: 12, label: "F12", icon: <Volume2 className="h-[11px] w-[11px]" />, divertable: true },
];

// Unused lucide imports guard for future key variants
void Search;
void Volume1;

export function KeyRowPicker({
  keyActions,
  onSelect,
}: {
  keyActions: Record<string, AccessoryButtonAction>;
  onSelect: (position: number, action: AccessoryButtonAction) => void;
}) {
  const [openKey, setOpenKey] = useState<number | null>(null);
  const containerRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (openKey === null) return;
    const onDown = (e: MouseEvent) => {
      if (containerRef.current && !containerRef.current.contains(e.target as Node)) {
        setOpenKey(null);
      }
    };
    window.addEventListener("mousedown", onDown);
    return () => window.removeEventListener("mousedown", onDown);
  }, [openKey]);

  return (
    <div ref={containerRef} className="relative px-4 py-3.5">
      <div className="flex items-center justify-between gap-[4px]">
        {MX_FUNCTION_KEYS.map((key) => {
          const current = keyActions[String(key.position)] ?? "systemDefault";
          const remapped = current !== "systemDefault";
          return (
            <div key={key.position} className="relative">
              <button
                type="button"
                disabled={!key.divertable}
                onClick={() =>
                  setOpenKey((cur) => (cur === key.position ? null : key.position))
                }
                title={
                  !key.divertable
                    ? `${key.label}: Easy-Switch (cannot be remapped)`
                    : remapped
                      ? `${key.label}: ${actionTitle(current)}`
                      : `${key.label}: Key's Own Function`
                }
                className={`flex h-[38px] w-[36px] flex-col items-center justify-center gap-[2px] rounded-[7px] border transition-colors ${
                  !key.divertable
                    ? "cursor-not-allowed border-white/[0.14] bg-white/[0.02] text-white/30 opacity-45"
                    : remapped
                      ? "border-[#0a84ff] bg-[#0a84ff]/[0.18] text-white shadow-[0_0_8px_rgba(10,132,255,0.25)]"
                      : "border-white/[0.22] bg-white/[0.03] text-white/80 hover:border-white/40 hover:bg-white/[0.08]"
                }`}
              >
                <span>{key.icon}</span>
                <span className="text-[8px] font-semibold tracking-tight text-white/55">
                  {key.label}
                </span>
              </button>

              {openKey === key.position && (
                <div
                  className={`aeron-menu absolute top-[42px] z-50 max-h-[240px] w-[204px] overflow-y-auto p-[5px] text-[12px] ${
                    key.position >= 9 ? "right-0" : "left-0"
                  }`}
                >
                  <div className="px-2.5 py-1 text-[10px] font-semibold text-white/45">
                    {key.label} Action
                  </div>
                  {GENERAL_ACTIONS.map((opt) => {
                    const selected = current === opt.id;
                    const label =
                      opt.id === "systemDefault" ? "Key's Own Function" : opt.title;
                    return (
                      <button
                        key={opt.id}
                        type="button"
                        onClick={() => {
                          onSelect(key.position, opt.id);
                          setOpenKey(null);
                        }}
                        className="flex w-full items-center justify-between rounded-[6px] px-2.5 py-[5px] text-left text-white/90 hover:bg-[#0a84ff] hover:text-white"
                      >
                        <span className="truncate">{label}</span>
                        {selected && <Check className="h-3 w-3 shrink-0" />}
                      </button>
                    );
                  })}
                </div>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}

// MARK: - Animated Razer Chroma Glow Bar (exact port of Swift ChromaGlowBar)

export function ChromaGlowBar({
  lighting,
  brightness,
}: {
  lighting: RazerLighting | null;
  brightness: number | null;
}) {
  const mode = lighting?.mode ?? "off";
  const level = Math.max(0.14, (brightness ?? 255) / 255);

  if (!lighting || mode === "off") {
    return <div className="mx-4 h-[5px] rounded-full bg-white/[0.12]" />;
  }

  const pHex = `rgb(${lighting.primary.red}, ${lighting.primary.green}, ${lighting.primary.blue})`;
  const sHex = `rgb(${lighting.secondary.red}, ${lighting.secondary.green}, ${lighting.secondary.blue})`;

  let background = pHex;
  let animClass = "";
  let glowColor = pHex;

  if (mode === "breathing") {
    background =
      lighting.breathing === "dual"
        ? `linear-gradient(90deg, ${pHex}, ${sHex})`
        : lighting.breathing === "random"
          ? "linear-gradient(90deg, #00ff88, #00aaff, #bf5af2)"
          : pHex;
    animClass = "chroma-anim-breathe";
  } else if (mode === "spectrum") {
    background = "linear-gradient(90deg, #ff3b30, #ff9f0a, #30d158, #0a84ff, #bf5af2)";
    animClass = "chroma-anim-spectrum";
    glowColor = "#30d158";
  } else if (mode === "wave") {
    background =
      "linear-gradient(90deg, #ff3b30, #ffd60a, #30d158, #32ade6, #5e5ce6, #ff375f, #ff3b30)";
    animClass =
      lighting.waveDirection === "rightToLeft"
        ? "chroma-anim-wave-rtl"
        : "chroma-anim-wave-ltr";
    glowColor = "#0a84ff";
  }

  return (
    <div className="px-4 pb-1">
      <div
        className={`h-[5px] w-full rounded-full ${animClass}`}
        style={{
          background,
          opacity: level,
          boxShadow: `0 0 10px ${glowColor}`,
        }}
      />
    </div>
  );
}
