import { BatteryMedium, Cpu, Fan, Layers, Thermometer } from "lucide-react";
import type { ThermalPressure, ThermalSnapshot } from "../types";

interface ThermalsCardProps {
  thermals: ThermalSnapshot;
}

function pressureMeta(pressure: ThermalPressure): {
  label: string;
  color: string;
  bg: string;
} {
  switch (pressure) {
    case "critical":
      return { label: "Critical Pressure", color: "#ff453a", bg: "rgba(255,69,58,0.18)" };
    case "serious":
      return { label: "Serious Pressure", color: "#ff9f0a", bg: "rgba(255,159,10,0.18)" };
    case "fair":
      return { label: "Fair Pressure", color: "#ffd60a", bg: "rgba(255,214,10,0.18)" };
    default:
      return { label: "Normal Pressure", color: "#30d158", bg: "rgba(48,209,88,0.18)" };
  }
}

function tempColorClass(celsius: number): string {
  if (celsius >= 90) return "text-[#ff453a]";
  if (celsius >= 70) return "text-[#ff9f0a]";
  return "text-white/92";
}

export function ThermalsCard({ thermals }: ThermalsCardProps) {
  if (!thermals.supported) {
    return (
      <section className="aeron-card">
        <div className="flex items-center gap-[8px] py-1 text-[11px] text-white/55">
          <Thermometer className="h-[13px] w-[13px] shrink-0 text-white/45" />
          <span>Thermal sensors are unavailable on this hardware.</span>
        </div>
      </section>
    );
  }

  const meta = pressureMeta(thermals.pressure);
  const hasAnyTemp =
    thermals.cpuCelsius !== null ||
    thermals.gpuCelsius !== null ||
    thermals.batteryCelsius !== null;

  return (
    <section className="aeron-card space-y-[10px]">
      {/* Header Row */}
      <div className="flex items-center gap-[10px]">
        <div
          className="flex h-[30px] w-[30px] shrink-0 items-center justify-center rounded-full"
          style={{ backgroundColor: meta.bg, color: meta.color }}
        >
          <Thermometer className="h-[14px] w-[14px]" strokeWidth={2.2} />
        </div>

        <div className="min-w-0 flex-1">
          <div className="text-[13px] font-semibold leading-tight text-white/92">Thermals</div>
          <div className="mt-[2px] flex items-center gap-[4px]">
            <span
              className="h-[5px] w-[5px] shrink-0 rounded-full"
              style={{ backgroundColor: meta.color }}
            />
            <span className="text-[11px] leading-tight text-white/55">{meta.label}</span>
          </div>
        </div>

        {/* Primary CPU Temperature Display */}
        {thermals.cpuCelsius !== null && (
          <div className="shrink-0 text-right">
            <div className="flex items-baseline justify-end gap-[1.5px] leading-none">
              <span className="font-rounded text-[18px] font-bold tracking-[-0.02em] text-white/95">
                {Math.round(thermals.cpuCelsius)}
              </span>
              <span className="font-rounded text-[11px] font-semibold text-white/55">°C</span>
            </div>
            <div className="mt-[2px] text-[9px] font-medium text-white/38">CPU</div>
          </div>
        )}
      </div>

      {/* Temperature Rows */}
      {hasAnyTemp && (
        <>
          <div className="aeron-divider" />
          <div className="space-y-[6px] text-[11px]">
            {thermals.cpuCelsius !== null && (
              <div className="flex items-center gap-[8px]">
                <Cpu className="h-[11.5px] w-[14px] shrink-0 text-white/50" strokeWidth={2} />
                <span className="text-white/55">CPU</span>
                <span className="flex-1" />
                <span className={`font-rounded font-medium ${tempColorClass(thermals.cpuCelsius)}`}>
                  {thermals.cpuCelsius.toFixed(1)} °C
                </span>
              </div>
            )}
            {thermals.gpuCelsius !== null && (
              <div className="flex items-center gap-[8px]">
                <Layers className="h-[11.5px] w-[14px] shrink-0 text-white/50" strokeWidth={2} />
                <span className="text-white/55">GPU</span>
                <span className="flex-1" />
                <span className={`font-rounded font-medium ${tempColorClass(thermals.gpuCelsius)}`}>
                  {thermals.gpuCelsius.toFixed(1)} °C
                </span>
              </div>
            )}
            {thermals.batteryCelsius !== null && (
              <div className="flex items-center gap-[8px]">
                <BatteryMedium className="h-[12px] w-[14px] shrink-0 text-white/50" strokeWidth={2} />
                <span className="text-white/55">Battery</span>
                <span className="flex-1" />
                <span
                  className={`font-rounded font-medium ${tempColorClass(thermals.batteryCelsius)}`}
                >
                  {thermals.batteryCelsius.toFixed(1)} °C
                </span>
              </div>
            )}
          </div>
        </>
      )}

      <div className="aeron-divider" />

      {/* Fan Rows */}
      {thermals.fans.length === 0 ? (
        <div className="flex items-center gap-[8px] text-[11px] text-white/55">
          <Fan className="h-[11.5px] w-[14px] shrink-0 text-white/45" strokeWidth={2} />
          <span>No fans – passively cooled</span>
        </div>
      ) : (
        <div className="space-y-[8px]">
          {thermals.fans.map((fan) => {
            const maxRpm = fan.maxRpm && fan.maxRpm > 0 ? fan.maxRpm : 6000;
            const fraction = Math.min(1, Math.max(0, fan.rpm / maxRpm));
            const pct = Math.round(fraction * 100);
            return (
              <div key={fan.index} className="space-y-[4px]">
                <div className="flex items-center gap-[8px] text-[11px]">
                  <Fan className="h-[11.5px] w-[14px] shrink-0 text-white/50" strokeWidth={2} />
                  <span className="text-white/55">
                    {thermals.fans.length > 1 ? `Fan ${fan.index + 1}` : "Fan"}
                  </span>
                  <span className="flex-1" />
                  <span className="font-rounded font-medium text-white/92">
                    {Math.round(fan.rpm)} RPM
                  </span>
                  <span className="font-mono-tabular w-[34px] text-right text-[10px] font-semibold text-white/55">
                    {pct}%
                  </span>
                </div>
                <div className="pl-[22px]">
                  <div className="h-[5px] w-full overflow-hidden rounded-full bg-white/[0.08]">
                    <div
                      className="h-full rounded-full transition-all duration-300"
                      style={{
                        width: `${Math.max(fraction * 100, fan.rpm > 0 ? 4 : 2)}%`,
                        backgroundColor: fraction > 0.75 ? "#ff9f0a" : "#0a84ff",
                      }}
                    />
                  </div>
                </div>
              </div>
            );
          })}
        </div>
      )}
    </section>
  );
}
