import { useEffect, useRef, useState } from "react";
import { Check, ChevronDown, Coffee, Gamepad2, Power, Settings } from "lucide-react";
import type { CaffeineState, GameModePolicy, GameModeState } from "../types";

interface HeaderBarProps {
  caffeine: CaffeineState;
  gameMode: GameModeState;
  hasExternalDisplays: boolean;
  onToggleCaffeine: () => void;
  onSetCaffeine: (active: boolean, durationSeconds: number | null) => void;
  onToggleGameMode: () => void;
  onSetGameMode: (policy: GameModePolicy) => void;
  onOpenSettings: () => void;
  onQuit: () => void;
}

const CAFFEINE_DURATIONS: Array<{ label: string; seconds: number | null }> = [
  { label: "15 Minutes", seconds: 15 * 60 },
  { label: "30 Minutes", seconds: 30 * 60 },
  { label: "1 Hour", seconds: 60 * 60 },
  { label: "2 Hours", seconds: 2 * 60 * 60 },
  { label: "4 Hours", seconds: 4 * 60 * 60 },
  { label: "Indefinitely", seconds: null },
];

/** Exact vector port of `AeronToolsIcon.menuBarImage` (Studio Display with 2 precision sliders). */
function AeronToolsGlyph({ hasExternal }: { hasExternal: boolean }) {
  return (
    <svg
      width="19"
      height="17"
      viewBox="0 0 22 18"
      fill="none"
      className="shrink-0 text-[#0a84ff]"
      aria-hidden="true"
    >
      {hasExternal && (
        <rect
          x="12.5"
          y="1.2"
          width="8.5"
          height="9.6"
          rx="1.6"
          stroke="currentColor"
          strokeWidth="1.2"
          strokeOpacity="0.45"
        />
      )}
      <rect
        x="1.2"
        y="2.2"
        width="15.2"
        height="10.8"
        rx="2"
        fill="#1e1e22"
        stroke="currentColor"
        strokeWidth="1.5"
      />
      <line
        x1="3.8"
        y1="5.8"
        x2="13.8"
        y2="5.8"
        stroke="currentColor"
        strokeWidth="1.25"
        strokeLinecap="round"
        strokeOpacity="0.7"
      />
      <circle cx="10.6" cy="5.8" r="1.45" fill="currentColor" />
      <line
        x1="3.8"
        y1="9.4"
        x2="13.8"
        y2="9.4"
        stroke="currentColor"
        strokeWidth="1.25"
        strokeLinecap="round"
        strokeOpacity="0.7"
      />
      <circle cx="6.8" cy="9.4" r="1.45" fill="currentColor" />
      <path
        d="M8.8 13.1V15.6M5.8 15.8H11.8"
        stroke="currentColor"
        strokeWidth="1.45"
        strokeLinecap="round"
      />
    </svg>
  );
}

export function HeaderBar({
  caffeine,
  gameMode,
  hasExternalDisplays,
  onToggleCaffeine,
  onSetCaffeine,
  onToggleGameMode,
  onSetGameMode,
  onOpenSettings,
  onQuit,
}: HeaderBarProps) {
  const [openMenu, setOpenMenu] = useState<"caffeine" | "gamemode" | null>(null);
  const containerRef = useRef<HTMLElement | null>(null);

  useEffect(() => {
    if (!openMenu) return;
    const onPointerDown = (e: MouseEvent) => {
      if (containerRef.current && !containerRef.current.contains(e.target as Node)) {
        setOpenMenu(null);
      }
    };
    window.addEventListener("mousedown", onPointerDown);
    return () => window.removeEventListener("mousedown", onPointerDown);
  }, [openMenu]);

  const gameModeStatusText =
    gameMode.policy === "forcedOn"
      ? "Forced On"
      : gameMode.policy === "forcedOff"
        ? "Forced Off"
        : gameMode.isActive
          ? "Active"
          : "Automatic";

  return (
    <header
      ref={containerRef}
      className="relative flex items-center justify-between px-[3px] pb-[2px]"
      data-tauri-drag-region
    >
      {/* Left: Aeron Tools Brand */}
      <div className="flex items-center gap-[8px]" data-tauri-drag-region>
        <AeronToolsGlyph hasExternal={hasExternalDisplays} />
        <span
          className="text-[13.5px] font-semibold tracking-[-0.015em] text-white/94"
          data-tauri-drag-region
        >
          Aeron Tools
        </span>
      </div>

      {/* Right: Native macOS icon toolbar actions */}
      <div className="flex items-center gap-[4px]">
        {/* Game Mode split action + menu */}
        <div
          className={`relative flex items-center rounded-[7px] transition-colors ${
            gameMode.isActive ? "bg-[#30d158]/[0.16]" : "hover:bg-white/[0.07]"
          }`}
        >
          <button
            type="button"
            onClick={onToggleGameMode}
            title={`Game Mode (${gameModeStatusText}) – click to toggle`}
            className={`flex h-[26px] items-center rounded-l-[7px] pl-[7px] pr-[2px] transition-colors ${
              gameMode.isActive ? "text-[#30d158]" : "text-white/62 hover:text-white/92"
            }`}
          >
            <Gamepad2 className="h-[14.5px] w-[14.5px]" strokeWidth={2} />
          </button>
          <button
            type="button"
            onClick={() => setOpenMenu((m) => (m === "gamemode" ? null : "gamemode"))}
            title="Game Mode options"
            className={`flex h-[26px] items-center rounded-r-[7px] pl-[1px] pr-[6px] transition-colors ${
              gameMode.isActive ? "text-[#30d158]/80" : "text-white/42 hover:text-white/80"
            }`}
          >
            <ChevronDown className="h-[9.5px] w-[9.5px]" />
          </button>

          {openMenu === "gamemode" && (
            <div className="aeron-menu absolute right-0 top-[31px] z-40 w-[184px] p-[5px] text-[12px]">
              <div className="px-2.5 py-1 text-[10px] font-semibold text-white/45">
                Game Mode ({gameModeStatusText})
              </div>
              {(
                [
                  ["forcedOn", "Force Game Mode On"],
                  ["automatic", "Automatic"],
                  ["forcedOff", "Force Off"],
                ] as const
              ).map(([policy, label]) => (
                <button
                  key={policy}
                  type="button"
                  onClick={() => {
                    onSetGameMode(policy);
                    setOpenMenu(null);
                  }}
                  className="flex w-full items-center justify-between rounded-[6px] px-2.5 py-[5.5px] text-left text-white/90 hover:bg-[#0a84ff] hover:text-white"
                >
                  <span>{label}</span>
                  {gameMode.policy === policy && <Check className="h-3 w-3" />}
                </button>
              ))}
            </div>
          )}
        </div>

        {/* Caffeine split action + timer menu */}
        <div
          className={`relative flex items-center rounded-[7px] transition-colors ${
            caffeine.isActive ? "bg-[#ff9f0a]/[0.16]" : "hover:bg-white/[0.07]"
          }`}
        >
          <button
            type="button"
            onClick={onToggleCaffeine}
            title={caffeine.isActive ? "Caffeine on – click to turn off" : "Keep awake – click to toggle"}
            className={`flex h-[26px] items-center rounded-l-[7px] pl-[7px] pr-[2px] transition-colors ${
              caffeine.isActive ? "text-[#ff9f0a]" : "text-white/62 hover:text-white/92"
            }`}
          >
            <Coffee className="h-[14px] w-[14px]" strokeWidth={2} />
          </button>
          <button
            type="button"
            onClick={() => setOpenMenu((m) => (m === "caffeine" ? null : "caffeine"))}
            title="Caffeine timer options"
            className={`flex h-[26px] items-center rounded-r-[7px] pl-[1px] pr-[6px] transition-colors ${
              caffeine.isActive ? "text-[#ff9f0a]/80" : "text-white/42 hover:text-white/80"
            }`}
          >
            <ChevronDown className="h-[9.5px] w-[9.5px]" />
          </button>

          {openMenu === "caffeine" && (
            <div className="aeron-menu absolute right-0 top-[31px] z-40 w-[170px] p-[5px] text-[12px]">
              <div className="px-2.5 py-1 text-[10px] font-semibold text-white/45">Keep Awake</div>
              {CAFFEINE_DURATIONS.map((item) => (
                <button
                  key={item.label}
                  type="button"
                  onClick={() => {
                    onSetCaffeine(true, item.seconds);
                    setOpenMenu(null);
                  }}
                  className="flex w-full items-center justify-between rounded-[6px] px-2.5 py-[5.5px] text-left text-white/90 hover:bg-[#0a84ff] hover:text-white"
                >
                  <span>{item.label}</span>
                </button>
              ))}
              {caffeine.isActive && (
                <>
                  <div className="my-1 h-[0.5px] bg-white/10" />
                  <button
                    type="button"
                    onClick={() => {
                      onSetCaffeine(false, null);
                      setOpenMenu(null);
                    }}
                    className="w-full rounded-[6px] px-2.5 py-[5.5px] text-left text-[#ff9f0a] hover:bg-[#0a84ff] hover:text-white"
                  >
                    Turn Off Caffeine
                  </button>
                </>
              )}
            </div>
          )}
        </div>

        {/* Settings Window (Cog) */}
        <button
          type="button"
          onClick={onOpenSettings}
          title="Settings…"
          className="flex h-[26px] w-[26px] items-center justify-center rounded-[7px] text-white/62 transition-colors hover:bg-white/[0.08] hover:text-white/94"
        >
          <Settings className="h-[14px] w-[14px]" strokeWidth={2} />
        </button>

        {/* Quit */}
        <button
          type="button"
          onClick={onQuit}
          title="Quit Aeron Tools"
          className="flex h-[26px] w-[26px] items-center justify-center rounded-[7px] text-white/55 transition-colors hover:bg-[#ff453a]/[0.16] hover:text-[#ff453a]"
        >
          <Power className="h-[13.5px] w-[13.5px]" strokeWidth={2} />
        </button>
      </div>
    </header>
  );
}
