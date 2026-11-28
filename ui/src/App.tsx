import { useCallback, useEffect, useRef, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { Coffee, Gamepad2 } from "lucide-react";
import { aeronApi, isTauriRuntime } from "./api";
import { AccessoriesSection, type AccessoryKey } from "./components/AccessoriesSection";
import { DisplayCard } from "./components/DisplayCard";
import { HeaderBar } from "./components/HeaderBar";
import { SettingsView, type SettingsTab } from "./components/SettingsView";
import { ThermalsCard } from "./components/ThermalsCard";
import { WattageCard } from "./components/WattageCard";
import type { AppSnapshot } from "./types";

function formatCountdown(endsAtMs: number, nowMs: number): string {
  const remainingSec = Math.max(0, Math.floor((endsAtMs - nowMs) / 1000));
  const h = Math.floor(remainingSec / 3600);
  const m = Math.floor((remainingSec % 3600) / 60);
  const s = remainingSec % 60;
  if (h > 0) {
    return `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
  }
  return `${m}:${String(s).padStart(2, "0")}`;
}

export default function App() {
  const isSettingsWindow =
    typeof window !== "undefined" &&
    new URLSearchParams(window.location.search).get("window") === "settings";

  const [snapshot, setSnapshot] = useState<AppSnapshot | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [settingsTab, setSettingsTab] = useState<SettingsTab>("general");
  const [selectedAccessory, setSelectedAccessory] = useState<AccessoryKey | null>(null);
  const [inlineSettingsOpen, setInlineSettingsOpen] = useState(false);
  const [nowMs, setNowMs] = useState(() => Date.now());
  const popoverRootRef = useRef<HTMLElement | null>(null);
  const lastPopoverHeightRef = useRef<number>(0);
  const lastSliderEditAtRef = useRef<number>(0);
  const displaySeqRef = useRef<Record<string, number>>({});

  const load = useCallback(async () => {
    try {
      const startedAt = performance.now();
      const data = await aeronApi.getSnapshot();
      setSnapshot((prev) => {
        // Don't let an in-flight background poll overwrite an active/recent display slider drag
        if (prev && performance.now() - lastSliderEditAtRef.current < 600) {
          return { ...data, displays: prev.displays };
        }
        if (prev && lastSliderEditAtRef.current > startedAt) {
          return { ...data, displays: prev.displays };
        }
        return data;
      });
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }, []);

  const handleDisplayBrightness = useCallback((id: string, level: number) => {
    lastSliderEditAtRef.current = performance.now();
    const key = `br:${id}`;
    const seq = (displaySeqRef.current[key] ?? 0) + 1;
    displaySeqRef.current[key] = seq;

    // Optimistically update the display level without waiting on IPC
    setSnapshot((prev) => {
      if (!prev) return prev;
      return {
        ...prev,
        displays: prev.displays.map((d) => (d.id === id ? { ...d, brightness: level } : d)),
      };
    });

    void aeronApi.setDisplayBrightness(id, level).then((next) => {
      if (displaySeqRef.current[key] === seq) {
        setSnapshot((prev) => {
          if (!prev) return next;
          // Preserve any other slider currently being dragged
          return {
            ...next,
            displays: next.displays.map((d) =>
              d.id === id ? { ...d, brightness: level } : prev.displays.find((p) => p.id === d.id) ?? d
            ),
          };
        });
      }
    });
  }, []);

  const handleDisplayVolume = useCallback((id: string, level: number) => {
    lastSliderEditAtRef.current = performance.now();
    const key = `vol:${id}`;
    const seq = (displaySeqRef.current[key] ?? 0) + 1;
    displaySeqRef.current[key] = seq;

    setSnapshot((prev) => {
      if (!prev) return prev;
      return {
        ...prev,
        displays: prev.displays.map((d) => (d.id === id ? { ...d, volume: level } : d)),
      };
    });

    void aeronApi.setDisplayVolume(id, level).then((next) => {
      if (displaySeqRef.current[key] === seq) {
        setSnapshot((prev) => {
          if (!prev) return next;
          return {
            ...next,
            displays: next.displays.map((d) =>
              d.id === id ? { ...d, volume: level } : prev.displays.find((p) => p.id === d.id) ?? d
            ),
          };
        });
      }
    });
  }, []);

  useEffect(() => {
    void load();
    const interval = window.setInterval(() => {
      if (document.visibilityState === "visible") {
        void load();
      }
    }, 3000);
    return () => window.clearInterval(interval);
  }, [load]);

  // Live 1-second tick only while timed caffeine is active
  useEffect(() => {
    if (!snapshot?.caffeine.isActive || snapshot.caffeine.endsAtMs === null) {
      return;
    }
    const id = window.setInterval(() => setNowMs(Date.now()), 1000);
    return () => window.clearInterval(id);
  }, [snapshot?.caffeine.isActive, snapshot?.caffeine.endsAtMs]);

  // Listen for `navigate-settings` event sent by `open_settings` Tauri command
  useEffect(() => {
    if (!isSettingsWindow || !isTauriRuntime()) return;
    let unlisten: (() => void) | null = null;
    void listen<{ tab?: string; accessory?: string | null }>("navigate-settings", (ev) => {
      const t = ev.payload.tab;
      if (t === "general" || t === "displays" || t === "accessories" || t === "about") {
        setSettingsTab(t);
      }
      if (ev.payload.accessory) {
        setSelectedAccessory(ev.payload.accessory as AccessoryKey);
      }
      void load();
    }).then((fn) => {
      unlisten = fn;
    });
    return () => {
      unlisten?.();
    };
  }, [isSettingsWindow, load]);

  const hasSnapshot = snapshot !== null;

  // Auto-size the frameless 340px popover ONLY when its actual pixel height changes
  useEffect(() => {
    if (isSettingsWindow || !isTauriRuntime() || !hasSnapshot) return;
    const el = popoverRootRef.current;
    if (!el) return;
    const updateSize = () => {
      const h = Math.ceil(el.getBoundingClientRect().height);
      if (h > 40 && h !== lastPopoverHeightRef.current) {
        lastPopoverHeightRef.current = h;
        void aeronApi.resizePopover(h);
      }
    };
    updateSize();
    const observer = new ResizeObserver(updateSize);
    observer.observe(el);
    return () => observer.disconnect();
  }, [isSettingsWindow, hasSnapshot]);

  const openSettingsTarget = (tab: SettingsTab = "general", accessory?: AccessoryKey) => {
    if (isTauriRuntime()) {
      void aeronApi.openSettings(tab, accessory);
    } else {
      setSettingsTab(tab);
      if (accessory) setSelectedAccessory(accessory);
      setInlineSettingsOpen(true);
    }
  };

  if (error && !snapshot) {
    return (
      <main className="aeron-popover-surface w-[340px] p-[18px] text-[12px] text-[#ff453a]">
        <p className="font-semibold">Unable to reach AeronTools backend</p>
        <p className="mt-1.5 text-white/55">{error}</p>
      </main>
    );
  }

  if (!snapshot) {
    return (
      <main className="aeron-popover-surface flex h-[200px] w-[340px] items-center justify-center p-[18px] text-[12px] text-white/45">
        Loading Aeron Tools…
      </main>
    );
  }

  if (isSettingsWindow || inlineSettingsOpen) {
    return (
      <SettingsView
        snapshot={snapshot}
        initialTab={settingsTab}
        initialAccessory={selectedAccessory}
        onRefresh={() => void aeronApi.refreshAll().then(setSnapshot)}
        onUpdatePreferences={(next) => void aeronApi.updatePreferences(next).then(setSnapshot)}
        onSetGameMode={(policy) => void aeronApi.setGameModePolicy(policy).then(setSnapshot)}
        onSetCaffeine={(active, dur) => void aeronApi.setCaffeine(active, dur).then(setSnapshot)}
        onDisplayBrightness={handleDisplayBrightness}
        onDisplayVolume={handleDisplayVolume}
        onDisplayMute={(id, muted) => void aeronApi.setDisplayMuted(id, muted).then(setSnapshot)}
        onDisplayInput={(id, code) => void aeronApi.setDisplayInput(id, code).then(setSnapshot)}
        onMxMasterDpi={(dpi) => void aeronApi.setMxMasterDpi(dpi).then(setSnapshot)}
        onMxMasterSmartShift={(mode, enabled, threshold) =>
          void aeronApi.setMxMasterSmartShift(mode, enabled, threshold).then(setSnapshot)
        }
        onLogitechGDpi={(dpi) => void aeronApi.setLogitechGDpi(dpi).then(setSnapshot)}
        onLogitechGReportRate={(hz) =>
          void aeronApi.setLogitechGReportRate(hz).then(setSnapshot)
        }
        onLogitechGTriggers={(triggers) =>
          void aeronApi.setLogitechGTriggers(triggers).then(setSnapshot)
        }
        onMxKeyboardBacklight={(params) =>
          void aeronApi.setMxKeyboardBacklight(params).then(setSnapshot)
        }
        onMxKeyboardFnInversion={(standardFn) =>
          void aeronApi.setMxKeyboardFnInversion(standardFn).then(setSnapshot)
        }
        onGKeyboardLighting={(brightness, lighting) =>
          void aeronApi.setGKeyboardLighting(brightness, lighting).then(setSnapshot)
        }
        onKeychronUpdate={(params) => void aeronApi.setKeychronSettings(params).then(setSnapshot)}
        onRazerDockLighting={(brightness, lighting) =>
          void aeronApi.setRazerDockLighting(brightness, lighting).then(setSnapshot)
        }
      />
    );
  }

  const prefs = snapshot.preferences;
  const externalDisplays = snapshot.displays.filter((d) => !d.isBuiltin);
  const hasExternalDisplays = externalDisplays.length > 0;
  const showActiveStatusFooter = snapshot.gameMode.isActive || snapshot.caffeine.isActive;

  return (
    <main
      ref={popoverRootRef}
      className="aeron-popover-surface w-[340px] space-y-[13px] p-[18px]"
    >
      {/* Header Bar */}
      <HeaderBar
        caffeine={snapshot.caffeine}
        gameMode={snapshot.gameMode}
        hasExternalDisplays={hasExternalDisplays}
        onToggleCaffeine={() => void aeronApi.toggleCaffeine().then(setSnapshot)}
        onSetCaffeine={(active, duration) =>
          void aeronApi.setCaffeine(active, duration).then(setSnapshot)
        }
        onToggleGameMode={() => void aeronApi.toggleGameModeForced().then(setSnapshot)}
        onSetGameMode={(policy) => void aeronApi.setGameModePolicy(policy).then(setSnapshot)}
        onOpenSettings={() => openSettingsTarget("general")}
        onQuit={() => void aeronApi.quitApp()}
      />

      {/* External Displays Only (no internal monitor card) */}
      {externalDisplays.map((display) => (
        <DisplayCard
          key={display.id}
          display={display}
          showInputSwitching={prefs.showInputSwitching}
          onBrightnessChange={(level) => handleDisplayBrightness(display.id, level)}
          onVolumeChange={(level) => handleDisplayVolume(display.id, level)}
          onToggleMute={() =>
            void aeronApi.setDisplayMuted(display.id, !display.isMuted).then(setSnapshot)
          }
          onSelectInput={(code) =>
            void aeronApi.setDisplayInput(display.id, code).then(setSnapshot)
          }
        />
      ))}

      {/* Connected Accessories (compact cards; click opens Settings to that device) */}
      {prefs.showAccessoriesCard && (
        <AccessoriesSection
          accessories={snapshot.accessories}
          onOpenAccessory={(key) => openSettingsTarget("accessories", key)}
        />
      )}

      {/* Power & Battery */}
      {prefs.showWattageMeter && (
        <WattageCard
          wattage={snapshot.wattage}
          showBatteryHealth={prefs.showBatteryHealth}
        />
      )}

      {/* Thermals */}
      {prefs.showThermals && <ThermalsCard thermals={snapshot.thermals} />}

      {/* Active Status Footer (only shown when Game Mode or Caffeine is active) */}
      {showActiveStatusFooter && (
        <footer className="space-y-[6px] px-[4px] pt-[2px]">
          {snapshot.gameMode.isActive && (
            <div className="flex items-center gap-[6px] text-[11px] font-medium text-[#30d158]">
              <Gamepad2 className="h-[12.5px] w-[12.5px]" strokeWidth={2.2} />
              <span>
                Game Mode:{" "}
                {snapshot.gameMode.policy === "forcedOn" ? "Forced On" : "Active"}
              </span>
            </div>
          )}

          {snapshot.caffeine.isActive && (
            <div className="flex items-center gap-[6px] text-[11px] font-medium text-[#ff9f0a]">
              <Coffee className="h-[12.5px] w-[12.5px]" strokeWidth={2.2} />
              <span>
                {snapshot.caffeine.endsAtMs !== null
                  ? `Awake for ${formatCountdown(snapshot.caffeine.endsAtMs, nowMs)}`
                  : "Awake until turned off"}
              </span>
            </div>
          )}
        </footer>
      )}
    </main>
  );
}
