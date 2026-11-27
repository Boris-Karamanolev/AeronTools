import { useEffect, useRef, useState } from "react";
import {
  Check,
  CircleEllipsis,
  Laptop,
  Monitor,
  Sun,
  SunDim,
  Volume1,
  Volume2,
  VolumeX,
} from "lucide-react";
import type { ExternalDisplayInfo } from "../types";
import { MacSlider } from "./MacSlider";

interface DisplayCardProps {
  display: ExternalDisplayInfo;
  showInputSwitching: boolean;
  onBrightnessChange: (level: number) => void;
  onVolumeChange: (level: number) => void;
  onToggleMute: () => void;
  onSelectInput: (code: number) => void;
}

export function DisplayCard({
  display,
  showInputSwitching,
  onBrightnessChange,
  onVolumeChange,
  onToggleMute,
  onSelectInput,
}: DisplayCardProps) {
  const [liveBrightness, setLiveBrightness] = useState(display.brightness);
  const [liveVolume, setLiveVolume] = useState(display.volume);
  const [menuOpen, setMenuOpen] = useState(false);
  const menuRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (!menuOpen) return;
    const onDown = (e: MouseEvent) => {
      if (menuRef.current && !menuRef.current.contains(e.target as Node)) {
        setMenuOpen(false);
      }
    };
    window.addEventListener("mousedown", onDown);
    return () => window.removeEventListener("mousedown", onDown);
  }, [menuOpen]);

  const canShowInputMenu =
    showInputSwitching &&
    !display.isBuiltin &&
    display.hasHardwareControl &&
    display.inputSources.length > 0;

  return (
    <section className="aeron-card space-y-[10px]">
      {/* Monitor Title Row */}
      <div className="flex items-center gap-[7px]">
        {display.isBuiltin ? (
          <Laptop className="h-[13.5px] w-[13.5px] shrink-0 text-white/55" strokeWidth={1.8} />
        ) : (
          <Monitor className="h-[13.5px] w-[13.5px] shrink-0 text-white/55" strokeWidth={1.8} />
        )}
        <h2 className="min-w-0 flex-1 truncate text-[13px] font-semibold text-white/92">
          {display.name}
        </h2>

        {canShowInputMenu && (
          <div ref={menuRef} className="relative">
            <button
              type="button"
              onClick={() => setMenuOpen((v) => !v)}
              title="Input Source"
              className="flex h-[20px] w-[20px] items-center justify-center rounded-full text-white/50 transition-colors hover:text-white/85"
            >
              <CircleEllipsis className="h-[14px] w-[14px]" strokeWidth={1.75} />
            </button>

            {menuOpen && (
              <div className="aeron-menu absolute right-0 top-[24px] z-40 w-[160px] p-[4px] text-[12px]">
                <div className="px-2 py-1 text-[10px] font-medium text-white/45">Input</div>
                {display.inputSources.map((src) => {
                  const selected = display.currentInput === src.code;
                  return (
                    <button
                      key={src.code}
                      type="button"
                      onClick={() => {
                        onSelectInput(src.code);
                        setMenuOpen(false);
                      }}
                      className="flex w-full items-center justify-between rounded-[5px] px-2 py-[5px] text-left text-white/90 hover:bg-[#0a84ff] hover:text-white"
                    >
                      <span>{src.name}</span>
                      {selected && <Check className="h-3 w-3" />}
                    </button>
                  );
                })}
              </div>
            )}
          </div>
        )}
      </div>

      {!display.hasHardwareControl && !display.isBuiltin && (
        <p className="text-[10px] leading-snug text-white/38">
          This monitor doesn&apos;t support DDC/CI, so brightness is dimmed in software.
        </p>
      )}

      {/* Brightness Slider Row */}
      <div className="flex items-center gap-[8px]">
        <SunDim className="h-[13px] w-[14px] shrink-0 text-white/55" strokeWidth={2} />
        <MacSlider
          value={display.brightness}
          min={0}
          max={1}
          step={0.01}
          ariaLabel={`${display.name} brightness`}
          onDisplayValueChange={setLiveBrightness}
          onChange={onBrightnessChange}
        />
        <Sun className="h-[12.5px] w-[14px] shrink-0 text-white/55" strokeWidth={2} />
        <span className="font-mono-tabular w-[36px] shrink-0 text-right text-[11px] font-medium text-white/55">
          {Math.round(liveBrightness * 100)}%
        </span>
      </div>

      {/* Volume Slider Row (External Monitors Only) */}
      {!display.isBuiltin && (
        <div className="flex items-center gap-[8px]">
          <button
            type="button"
            onClick={onToggleMute}
            title={display.isMuted ? "Unmute Monitor" : "Mute Monitor"}
            className={`flex h-[14px] w-[14px] shrink-0 items-center justify-center transition-colors ${
              display.isMuted ? "text-[#ff453a]" : "text-white/55 hover:text-white/85"
            }`}
          >
            {display.isMuted ? (
              <VolumeX className="h-[13px] w-[13px]" strokeWidth={2} />
            ) : (
              <Volume1 className="h-[13px] w-[13px]" strokeWidth={2} />
            )}
          </button>
          <MacSlider
            value={display.volume}
            min={0}
            max={1}
            step={0.01}
            disabled={display.isMuted}
            ariaLabel={`${display.name} volume`}
            onDisplayValueChange={setLiveVolume}
            onChange={onVolumeChange}
          />
          <Volume2 className="h-[12.5px] w-[14px] shrink-0 text-white/55" strokeWidth={2} />
          <span className="font-mono-tabular w-[36px] shrink-0 text-right text-[11px] font-medium text-white/55">
            {display.isMuted ? "Mute" : `${Math.round(liveVolume * 100)}%`}
          </span>
        </div>
      )}
    </section>
  );
}
