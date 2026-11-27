import {
  BatteryCharging,
  BatteryFull,
  BatteryLow,
  BatteryMedium,
  Cable,
  HardDrive,
  Keyboard,
  Mouse,
} from "lucide-react";
import type { AccessoriesSnapshot } from "../types";

export type AccessoryKey =
  | "mxMaster"
  | "logitechGMouse"
  | "keychronM3Mini"
  | "mxKeyboard"
  | "logitechGKeyboard"
  | "razerDock"
  | "satechiHub";

interface AccessoriesSectionProps {
  accessories: AccessoriesSnapshot;
  onOpenAccessory: (key: AccessoryKey) => void;
}

export function formatConnectionLabel(conn: string | null): string {
  switch (conn) {
    case "logiBolt":
      return "Logi Bolt Receiver";
    case "unifying":
      return "Unifying Receiver";
    case "lightspeed":
      return "LIGHTSPEED Receiver";
    case "bluetoothLe":
    case "bluetooth":
      return "Bluetooth";
    case "wireless4k":
      return "4K Wireless Receiver";
    case "usbWired":
      return "USB Cable";
    case "thunderbolt":
    case "thunderbolt4":
      return "Thunderbolt";
    default:
      return "Connected";
  }
}

function BatteryIndicator({
  percent,
  isCharging,
}: {
  percent: number | null;
  isCharging: boolean;
}) {
  if (percent === null) return null;
  const isLow = percent <= 15 && !isCharging;
  const colorClass = isCharging
    ? "text-[#30d158]"
    : isLow
      ? "text-[#ff9f0a]"
      : "text-white/60";

  const Icon = isCharging
    ? BatteryCharging
    : percent <= 20
      ? BatteryLow
      : percent <= 65
        ? BatteryMedium
        : BatteryFull;

  return (
    <div className={`flex shrink-0 items-center gap-[4px] ${colorClass}`}>
      <Icon className="h-[13px] w-[13px]" strokeWidth={2} />
      <span className="font-rounded text-[11.5px] font-semibold tabular-nums">{percent}%</span>
    </div>
  );
}

interface CompactAccessoryRowProps {
  title: string;
  subtitle: string;
  accentBg: string;
  accentColor: string;
  icon: React.ReactNode;
  trailing?: React.ReactNode;
  onClick: () => void;
}

/** Exact port of Swift `AccessoryCardHeader` inside the 320px popover. */
function CompactAccessoryCard({
  title,
  subtitle,
  accentBg,
  accentColor,
  icon,
  trailing,
  onClick,
}: CompactAccessoryRowProps) {
  return (
    <button
      type="button"
      onClick={onClick}
      className="aeron-card-interactive flex w-full items-center gap-[10px] text-left"
    >
      <div
        className="flex h-[30px] w-[30px] shrink-0 items-center justify-center rounded-full"
        style={{ backgroundColor: accentBg, color: accentColor }}
      >
        {icon}
      </div>

      <div className="min-w-0 flex-1">
        <div className="truncate text-[13px] font-semibold leading-tight text-white/92">
          {title}
        </div>
        <div className="mt-[2px] flex items-center gap-[4px]">
          <span className="h-[5px] w-[5px] shrink-0 rounded-full bg-[#30d158]" />
          <span className="truncate text-[11px] leading-tight text-white/55">{subtitle}</span>
        </div>
      </div>

      {trailing}
    </button>
  );
}

export function AccessoriesSection({
  accessories,
  onOpenAccessory,
}: AccessoriesSectionProps) {
  const {
    mxMaster,
    mxKeyboard,
    logitechGMouse,
    logitechGKeyboard,
    keychronM3Mini,
    razerDock,
    satechiHub,
  } = accessories;

  const razerOccupied =
    razerDock.ports.thunderbolt.filter((p) => p.devices.length > 0).length +
    razerDock.ports.usbA.filter((p) => p.devices.length > 0).length +
    (razerDock.ports.ethernetInterface ? 1 : 0);

  const satechiOccupied =
    satechiHub.ports.thunderbolt.filter((p) => p.devices.length > 0).length +
    satechiHub.ports.usbA.filter((p) => p.devices.length > 0).length;

  const hasAny =
    mxMaster.connected ||
    logitechGMouse.connected ||
    keychronM3Mini.connected ||
    mxKeyboard.connected ||
    logitechGKeyboard.connected ||
    razerDock.connected ||
    satechiHub.connected;

  if (!hasAny) {
    return null;
  }

  return (
    <div className="space-y-[10px]">
      {mxMaster.connected && (
        <CompactAccessoryCard
          title={mxMaster.name}
          subtitle={`${formatConnectionLabel(mxMaster.connection)} · ${mxMaster.dpi} DPI`}
          accentBg="rgba(10,132,255,0.18)"
          accentColor="#0a84ff"
          icon={<Mouse className="h-[14px] w-[14px]" strokeWidth={2} />}
          trailing={
            <BatteryIndicator
              percent={mxMaster.batteryPercent}
              isCharging={mxMaster.isCharging}
            />
          }
          onClick={() => onOpenAccessory("mxMaster")}
        />
      )}

      {logitechGMouse.connected && (
        <CompactAccessoryCard
          title={logitechGMouse.name}
          subtitle={`${formatConnectionLabel(logitechGMouse.connection)} · ${logitechGMouse.dpi} DPI`}
          accentBg="rgba(10,132,255,0.18)"
          accentColor="#0a84ff"
          icon={<Mouse className="h-[14px] w-[14px]" strokeWidth={2} />}
          trailing={
            <BatteryIndicator
              percent={logitechGMouse.batteryPercent}
              isCharging={logitechGMouse.isCharging}
            />
          }
          onClick={() => onOpenAccessory("logitechGMouse")}
        />
      )}

      {keychronM3Mini.connected && (
        <CompactAccessoryCard
          title={keychronM3Mini.name}
          subtitle={`${formatConnectionLabel(keychronM3Mini.connection)} · ${
            keychronM3Mini.stageDpis[keychronM3Mini.activeStage] ?? 1600
          } DPI`}
          accentBg="rgba(10,132,255,0.18)"
          accentColor="#0a84ff"
          icon={<Mouse className="h-[14px] w-[14px]" strokeWidth={2} />}
          trailing={
            <BatteryIndicator
              percent={keychronM3Mini.batteryPercent}
              isCharging={keychronM3Mini.isCharging}
            />
          }
          onClick={() => onOpenAccessory("keychronM3Mini")}
        />
      )}

      {mxKeyboard.connected && (
        <CompactAccessoryCard
          title={mxKeyboard.name}
          subtitle={formatConnectionLabel(mxKeyboard.connection)}
          accentBg="rgba(10,132,255,0.18)"
          accentColor="#0a84ff"
          icon={<Keyboard className="h-[14px] w-[14px]" strokeWidth={2} />}
          trailing={
            <BatteryIndicator
              percent={mxKeyboard.batteryPercent}
              isCharging={mxKeyboard.isCharging}
            />
          }
          onClick={() => onOpenAccessory("mxKeyboard")}
        />
      )}

      {logitechGKeyboard.connected && (
        <CompactAccessoryCard
          title={logitechGKeyboard.name}
          subtitle={formatConnectionLabel(logitechGKeyboard.connection)}
          accentBg="rgba(10,132,255,0.18)"
          accentColor="#0a84ff"
          icon={<Keyboard className="h-[14px] w-[14px]" strokeWidth={2} />}
          trailing={
            <BatteryIndicator
              percent={logitechGKeyboard.batteryPercent}
              isCharging={logitechGKeyboard.isCharging}
            />
          }
          onClick={() => onOpenAccessory("logitechGKeyboard")}
        />
      )}

      {razerDock.connected && (
        <CompactAccessoryCard
          title="Razer Dock Chroma"
          subtitle={`Thunderbolt · ${razerOccupied} ${razerOccupied === 1 ? "port" : "ports"} in use`}
          accentBg="rgba(48,209,88,0.18)"
          accentColor="#30d158"
          icon={<HardDrive className="h-[14px] w-[14px]" strokeWidth={2} />}
          onClick={() => onOpenAccessory("razerDock")}
        />
      )}

      {satechiHub.connected && (
        <CompactAccessoryCard
          title="Satechi Slim Hub Pro"
          subtitle={`Thunderbolt · ${satechiOccupied} ${satechiOccupied === 1 ? "port" : "ports"} in use`}
          accentBg="rgba(10,132,255,0.18)"
          accentColor="#0a84ff"
          icon={<Cable className="h-[14px] w-[14px]" strokeWidth={2} />}
          onClick={() => onOpenAccessory("satechiHub")}
        />
      )}
    </div>
  );
}
