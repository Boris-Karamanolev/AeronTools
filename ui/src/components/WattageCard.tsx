import {
  BatteryCharging,
  BatteryFull,
  BatteryMedium,
  Gauge,
  Heart,
  Plug,
  Zap,
  ZapOff,
} from "lucide-react";
import type { WattageSnapshot } from "../types";

interface WattageCardProps {
  wattage: WattageSnapshot;
  showBatteryHealth?: boolean;
}

export function WattageCard({ wattage, showBatteryHealth = true }: WattageCardProps) {
  if (!wattage.supported) {
    return (
      <section className="aeron-card">
        <div className="flex items-center gap-[8px] py-1 text-[11px] text-white/55">
          <ZapOff className="h-[13px] w-[13px] shrink-0 text-white/45" />
          <span>Wattage metering is unavailable on this hardware.</span>
        </div>
      </section>
    );
  }

  const loadW = wattage.systemLoadWatts ?? 0;
  const plugged = wattage.isPluggedIn;
  const batteryPct = wattage.batteryLevel ?? 0;

  const showAdapterGauge = plugged && wattage.adapterWatts !== null && wattage.adapterWatts > 0;
  const gaugeRatio = showAdapterGauge
    ? Math.min(1, Math.max(0, loadW / (wattage.adapterWatts ?? 1)))
    : Math.min(1, Math.max(0, batteryPct / 100));

  const gaugeColor = showAdapterGauge
    ? gaugeRatio > 0.85
      ? "#ff9f0a"
      : "#30d158"
    : gaugeRatio < 0.2
      ? "#ff453a"
      : "#30d158";

  const telemetryParts: string[] = [];
  if (wattage.voltage !== null) {
    telemetryParts.push(`${wattage.voltage.toFixed(1)}V`);
  }
  if (wattage.amperage !== null) {
    telemetryParts.push(`${Math.abs(wattage.amperage).toFixed(2)}A`);
  }
  const telemetryText = telemetryParts.join(" • ");

  const healthParts: string[] = [];
  if (wattage.batteryHealthPercent !== null) {
    healthParts.push(`${wattage.batteryHealthPercent}%`);
  }
  if (wattage.cycleCount !== null) {
    healthParts.push(`${wattage.cycleCount} ${wattage.cycleCount === 1 ? "cycle" : "cycles"}`);
  }
  const healthText = healthParts.join(" · ");

  return (
    <section className="aeron-card space-y-[10px]">
      {/* Header Row */}
      <div className="flex items-center gap-[10px]">
        <div
          className={`flex h-[30px] w-[30px] shrink-0 items-center justify-center rounded-full ${
            plugged
              ? "bg-[#30d158]/[0.18] text-[#30d158]"
              : "bg-[#ff9f0a]/[0.18] text-[#ff9f0a]"
          }`}
        >
          {plugged ? (
            <Zap className="h-[14px] w-[14px]" strokeWidth={2.2} fill="currentColor" />
          ) : (
            <BatteryMedium className="h-[15px] w-[15px]" strokeWidth={2.1} />
          )}
        </div>

        <div className="min-w-0 flex-1">
          <div className="text-[13px] font-semibold leading-tight text-white/92">
            Power &amp; Battery
          </div>
          <div className="mt-[2px] flex items-center gap-[4px]">
            <span
              className="h-[5px] w-[5px] shrink-0 rounded-full"
              style={{ backgroundColor: plugged ? "#30d158" : "#ff9f0a" }}
            />
            <span className="text-[11px] leading-tight text-white/55">
              {plugged ? "Power Adapter" : "Battery Power"}
            </span>
          </div>
        </div>

        <div className="shrink-0 text-right">
          <div className="flex items-baseline justify-end gap-[2px] leading-none">
            <span className="font-rounded text-[18px] font-bold tracking-[-0.02em] text-white/95">
              {loadW.toFixed(1)}
            </span>
            <span className="font-rounded text-[11px] font-semibold text-white/55">W</span>
          </div>
          <div className="mt-[2px] text-[9px] font-medium text-white/38">System Draw</div>
        </div>
      </div>

      {/* Native 7px Capsule Power / Battery Gauge */}
      {(showAdapterGauge || wattage.batteryLevel !== null) && (
        <div className="space-y-[4px]">
          <div className="h-[7px] w-full overflow-hidden rounded-full bg-white/[0.085] shadow-inner">
            <div
              className="h-full rounded-full transition-all duration-300"
              style={{
                width: `${Math.max(gaugeRatio * 100, 2.5)}%`,
                backgroundColor: gaugeColor,
              }}
            />
          </div>
          <div className="flex items-center justify-between text-[10px]">
            <span className="text-white/55">
              {showAdapterGauge
                ? `${loadW.toFixed(1)}W of ${wattage.adapterWatts}W capacity`
                : "Battery Reserve"}
            </span>
            <span className="font-mono-tabular font-semibold text-white/55">
              {Math.round(gaugeRatio * 100)}%
            </span>
          </div>
        </div>
      )}

      <div className="aeron-divider" />

      {/* Control Center Detail Rows */}
      <div className="space-y-[6px] text-[11px]">
        {plugged && (
          <div className="flex items-center gap-[8px]">
            <Plug className="h-[11.5px] w-[14px] shrink-0 text-white/50" strokeWidth={2} />
            <span className="text-white/55">
              {wattage.adapterWatts ? `${wattage.adapterWatts}W USB-C Charger` : "Power Adapter"}
            </span>
            <span className="flex-1" />
            {wattage.inputWatts !== null ? (
              <span className="font-rounded font-medium text-white/92">
                {wattage.inputWatts.toFixed(1)} W In
              </span>
            ) : wattage.adapterWatts !== null ? (
              <span className="font-rounded font-medium text-white/55">
                {wattage.adapterWatts} W Rating
              </span>
            ) : null}
          </div>
        )}

        {wattage.batteryLevel !== null && (
          <div className="flex items-center gap-[8px]">
            {wattage.isCharging ? (
              <BatteryCharging className="h-[12px] w-[14px] shrink-0 text-[#30d158]" strokeWidth={2} />
            ) : (
              <BatteryFull className="h-[12px] w-[14px] shrink-0 text-white/50" strokeWidth={2} />
            )}
            <span className="text-white/55">
              {wattage.isCharging
                ? `Battery Charging (${wattage.batteryLevel}%)`
                : `Battery Level (${wattage.batteryLevel}%)`}
            </span>
            <span className="flex-1" />
            {wattage.batteryWatts !== null ? (
              wattage.isCharging ? (
                <span className="font-rounded font-semibold text-[#30d158]">
                  +{Math.abs(wattage.batteryWatts).toFixed(1)} W
                </span>
              ) : (
                <span className="font-rounded font-medium text-white/55">
                  -{Math.abs(wattage.batteryWatts).toFixed(1)} W
                </span>
              )
            ) : (
              <span className="font-rounded font-medium text-white/55">
                {wattage.batteryLevel}%
              </span>
            )}
          </div>
        )}

        {telemetryText && (
          <div className="flex items-center gap-[8px]">
            <Gauge className="h-[11.5px] w-[14px] shrink-0 text-white/50" strokeWidth={2} />
            <span className="text-white/55">Telemetry</span>
            <span className="flex-1" />
            <span className="font-mono-tabular text-[10px] text-white/40">{telemetryText}</span>
          </div>
        )}

        {showBatteryHealth && healthText && (
          <div className="flex items-center gap-[8px]">
            <Heart
              className="h-[11px] w-[14px] shrink-0 text-white/50"
              strokeWidth={2}
              fill="currentColor"
            />
            <span className="text-white/55">Battery Health</span>
            <span className="flex-1" />
            <span
              className={`font-rounded font-medium ${
                (wattage.batteryHealthPercent ?? 100) < 80 ? "text-[#ff9f0a]" : "text-white/92"
              }`}
            >
              {healthText}
            </span>
          </div>
        )}
      </div>
    </section>
  );
}
