import { useState } from "react";
import {
  Cable,
  Camera,
  Gamepad2,
  HardDrive,
  Headphones,
  Keyboard,
  Lightbulb,
  Mic,
  Monitor,
  Mouse,
  Network,
  Radio,
  Usb,
  Volume2,
  Zap,
} from "lucide-react";
import type { DockLayout, DockPort, RazerLighting } from "../types";

interface DockPortsViewProps {
  layout: DockLayout;
  hasEthernet?: boolean;
  accent?: string;
  razerLighting?: RazerLighting | null;
  razerBrightness?: number | null;
}

const ETHERNET_PORT_ID = "ethernet";

function DeviceIcon({ icon }: { icon: string }) {
  const cls = "h-3.5 w-3.5 shrink-0 text-white/55";
  switch (icon) {
    case "display":
      return <Monitor className={cls} />;
    case "wireless":
      return <Radio className={cls} />;
    case "keyboard":
      return <Keyboard className={cls} />;
    case "mouse":
      return <Mouse className={cls} />;
    case "light":
      return <Lightbulb className={cls} />;
    case "storage":
      return <HardDrive className={cls} />;
    case "audio":
      return <Volume2 className={cls} />;
    case "camera":
      return <Camera className={cls} />;
    case "gamepad":
      return <Gamepad2 className={cls} />;
    case "headphones":
      return <Headphones className={cls} />;
    case "mic":
      return <Mic className={cls} />;
    case "hub":
      return <Cable className={cls} />;
    case "thunderbolt":
      return <Zap className={cls} />;
    case "ethernet":
      return <Network className="h-3.5 w-3.5 shrink-0 text-[#30d158]" />;
    default:
      return <Usb className={cls} />;
  }
}

/** USB-C capsule glyph matching `DockPortsView.swift`. */
function UsbCGlyph({
  occupied,
  selected,
  accent,
}: {
  occupied: boolean;
  selected: boolean;
  accent: string;
}) {
  return (
    <svg width="24" height="14" viewBox="0 0 24 14" fill="none" aria-hidden="true">
      <rect
        x="0.75"
        y="2"
        width="22.5"
        height="10"
        rx="5"
        fill={occupied ? accent : "rgba(255,255,255,0.04)"}
        fillOpacity={occupied ? (selected ? 0.45 : 0.3) : 1}
        stroke={occupied || selected ? accent : "rgba(255,255,255,0.28)"}
        strokeWidth={selected ? "1.4" : "1.15"}
      />
      <rect
        x="5.25"
        y="6.1"
        width="13.5"
        height="1.8"
        rx="0.9"
        fill={occupied ? accent : "rgba(255,255,255,0.25)"}
      />
    </svg>
  );
}

/** USB-A rectangular slot with top tongue bar matching `DockPortsView.swift`. */
function UsbAGlyph({
  occupied,
  selected,
  accent,
}: {
  occupied: boolean;
  selected: boolean;
  accent: string;
}) {
  return (
    <svg width="27" height="14" viewBox="0 0 27 14" fill="none" aria-hidden="true">
      <rect
        x="0.75"
        y="1"
        width="25.5"
        height="12"
        rx="1.75"
        fill={occupied ? accent : "rgba(255,255,255,0.04)"}
        fillOpacity={occupied ? (selected ? 0.45 : 0.28) : 1}
        stroke={occupied || selected ? accent : "rgba(255,255,255,0.28)"}
        strokeWidth={selected ? "1.4" : "1.15"}
      />
      {/* Top tongue bar */}
      <rect
        x="4"
        y="3"
        width="19"
        height="3"
        rx="0.6"
        fill={occupied ? accent : "rgba(255,255,255,0.28)"}
      />
    </svg>
  );
}

/** RJ45 Ethernet jack with bottom latch notch matching `DockPortsView.swift`. */
function EthernetGlyph({
  occupied,
  selected,
  accent,
}: {
  occupied: boolean;
  selected: boolean;
  accent: string;
}) {
  return (
    <svg width="20" height="15" viewBox="0 0 20 15" fill="none" aria-hidden="true">
      <path
        d="M1.5 1H18.5C18.776 1 19 1.224 19 1.5V10.8H14.2V14H5.8V10.8H1V1.5C1 1.224 1.224 1 1.5 1Z"
        fill={occupied ? accent : "rgba(255,255,255,0.04)"}
        fillOpacity={occupied ? (selected ? 0.45 : 0.28) : 1}
        stroke={occupied || selected ? accent : "rgba(255,255,255,0.28)"}
        strokeWidth={selected ? "1.35" : "1.15"}
      />
      <line x1="4.5" y1="3" x2="4.5" y2="5.8" stroke={occupied ? accent : "rgba(255,255,255,0.25)"} strokeWidth="1" />
      <line x1="7.2" y1="3" x2="7.2" y2="5.8" stroke={occupied ? accent : "rgba(255,255,255,0.25)"} strokeWidth="1" />
      <line x1="10" y1="3" x2="10" y2="5.8" stroke={occupied ? accent : "rgba(255,255,255,0.25)"} strokeWidth="1" />
      <line x1="12.8" y1="3" x2="12.8" y2="5.8" stroke={occupied ? accent : "rgba(255,255,255,0.25)"} strokeWidth="1" />
      <line x1="15.5" y1="3" x2="15.5" y2="5.8" stroke={occupied ? accent : "rgba(255,255,255,0.25)"} strokeWidth="1" />
    </svg>
  );
}

export function DockPortsView({
  layout,
  hasEthernet = false,
  accent = "#0a84ff",
  razerLighting,
  razerBrightness,
}: DockPortsViewProps) {
  const [selectedPortId, setSelectedPortId] = useState<string | null>(null);

  const allPorts: DockPort[] = [...layout.thunderbolt, ...layout.usbA];
  const filteredPorts = selectedPortId
    ? allPorts.filter((p) => p.id === selectedPortId)
    : allPorts.filter((p) => p.devices.length > 0);

  const ethernetAvailable = layout.ethernetInterface !== null;
  const showEthernetPanel = hasEthernet || ethernetAvailable;
  const showEthernetRow =
    ethernetAvailable && (selectedPortId === null || selectedPortId === ETHERNET_PORT_ID);

  const underglowStyle = (() => {
    if (!razerLighting || razerLighting.mode === "off" || (razerBrightness ?? 0) === 0) {
      return null;
    }
    const opacity = Math.max(0.25, (razerBrightness ?? 255) / 255);
    if (razerLighting.mode === "spectrum" || razerLighting.mode === "wave") {
      return {
        background:
          "linear-gradient(90deg, #ff3b30, #ff9f0a, #30d158, #0a84ff, #bf5af2, #ff3b30)",
        opacity,
      };
    }
    const { red, green, blue } = razerLighting.primary;
    return {
      backgroundColor: `rgb(${red}, ${green}, ${blue})`,
      boxShadow: `0 0 12px rgba(${red}, ${green}, ${blue}, ${opacity * 0.7})`,
      opacity,
    };
  })();

  const togglePort = (id: string) =>
    setSelectedPortId((cur) => (cur === id ? null : id));

  const selectedPort = allPorts.find((p) => p.id === selectedPortId);
  const hasVisibleDevices =
    filteredPorts.some((p) => p.devices.length > 0) || showEthernetRow;

  return (
    <div className="space-y-3">
      {/* Vector Dock Port Chassis (matches DockPortsView.swift) */}
      <div className="overflow-hidden rounded-[10px] border border-white/[0.1] bg-black/30">
        <div className="flex flex-wrap items-start justify-center gap-5 px-4 py-3.5">
          {/* Thunderbolt 4 Group (includes host Mac uplink glyph) */}
          {layout.thunderbolt.length > 0 && (
            <div className="flex flex-col items-center gap-1.5">
              <div className="flex items-start gap-1">
                <div
                  title={layout.isPresent ? "Connected to this computer" : "Host uplink (disconnected)"}
                  className="flex flex-col items-center gap-1 rounded-[5px] px-1 py-1"
                >
                  <UsbCGlyph occupied={layout.isPresent} selected={false} accent={accent} />
                  <span className="text-[8.5px] font-medium text-white/50">Host</span>
                </div>
                {layout.thunderbolt.map((port) => {
                  const occupied = port.devices.length > 0;
                  const selected = selectedPortId === port.id;
                  const names = port.devices.map((d) => d.name).join(", ");
                  return (
                    <button
                      key={port.id}
                      type="button"
                      onClick={() => togglePort(port.id)}
                      title={names ? `${port.title}: ${names}` : `${port.title}: empty`}
                      className={`flex flex-col items-center gap-1 rounded-[5px] px-1 py-1 transition-colors ${
                        selected ? "bg-[#0a84ff]/[0.18]" : "hover:bg-white/[0.06]"
                      }`}
                    >
                      <UsbCGlyph occupied={occupied} selected={selected} accent={accent} />
                      <span className="text-[8.5px] font-medium text-white/55">{port.number}</span>
                    </button>
                  );
                })}
              </div>
              <span className="text-[9px] font-medium text-white/45">Thunderbolt 4</span>
            </div>
          )}

          {/* USB-A Group */}
          {layout.usbA.length > 0 && (
            <div className="flex flex-col items-center gap-1.5">
              <div className="flex items-start gap-1">
                {layout.usbA.map((port) => {
                  const occupied = port.devices.length > 0;
                  const selected = selectedPortId === port.id;
                  const names = port.devices.map((d) => d.name).join(", ");
                  return (
                    <button
                      key={port.id}
                      type="button"
                      onClick={() => togglePort(port.id)}
                      title={names ? `${port.title}: ${names}` : `${port.title}: empty`}
                      className={`flex flex-col items-center gap-1 rounded-[5px] px-1 py-1 transition-colors ${
                        selected ? "bg-[#0a84ff]/[0.18]" : "hover:bg-white/[0.06]"
                      }`}
                    >
                      <UsbAGlyph occupied={occupied} selected={selected} accent={accent} />
                      <span className="text-[8.5px] font-medium text-white/55">{port.number}</span>
                    </button>
                  );
                })}
              </div>
              <span className="text-[9px] font-medium text-white/45">USB-A</span>
            </div>
          )}

          {/* Ethernet Group */}
          {showEthernetPanel && (
            <div className="flex flex-col items-center gap-1.5">
              <div className="flex items-start gap-1">
                <button
                  type="button"
                  onClick={() => togglePort(ETHERNET_PORT_ID)}
                  title={
                    ethernetAvailable
                      ? `Ethernet (${layout.ethernetInterface})`
                      : "Ethernet: not connected"
                  }
                  className={`flex flex-col items-center gap-1 rounded-[5px] px-1.5 py-1 transition-colors ${
                    selectedPortId === ETHERNET_PORT_ID
                      ? "bg-[#0a84ff]/[0.18]"
                      : "hover:bg-white/[0.06]"
                  }`}
                >
                  <EthernetGlyph
                    occupied={ethernetAvailable}
                    selected={selectedPortId === ETHERNET_PORT_ID}
                    accent="#30d158"
                  />
                  <span className="text-[8.5px] font-medium text-white/55">
                    {layout.ethernetInterface ?? "—"}
                  </span>
                </button>
              </div>
              <span className="text-[9px] font-medium text-white/45">Ethernet</span>
            </div>
          )}
        </div>

        {/* Razer Chroma Underglow Strip */}
        {underglowStyle && <div className="h-[3px] w-full transition-all" style={underglowStyle} />}
      </div>

      {/* Connected Devices List */}
      <div className="space-y-1.5">
        {selectedPortId && (
          <div className="flex items-center justify-between text-[11px]">
            <span className="text-white/55">
              Showing{" "}
              {selectedPortId === ETHERNET_PORT_ID
                ? "Ethernet"
                : selectedPort?.title ?? selectedPortId}
            </span>
            <button
              type="button"
              onClick={() => setSelectedPortId(null)}
              className="text-[#0a84ff] hover:underline"
            >
              Show all
            </button>
          </div>
        )}

        {!hasVisibleDevices ? (
          <p className="py-1 text-[11.5px] text-white/45">
            {selectedPort
              ? `Nothing is plugged into ${selectedPort.title}.`
              : selectedPortId === ETHERNET_PORT_ID
                ? "No Ethernet interface detected."
                : "Nothing is plugged in."}
          </p>
        ) : (
          <div className="divide-y divide-white/[0.06] rounded-[8px] border border-white/[0.07] bg-white/[0.03]">
            {filteredPorts.flatMap((port) =>
              port.devices.map((dev) => (
                <div
                  key={`${port.id}-${dev.id}`}
                  className="flex items-center gap-2.5 px-3 py-2"
                >
                  <DeviceIcon icon={dev.icon} />
                  <div className="min-w-0 flex-1">
                    <div className="truncate text-[12px] font-medium leading-tight text-white/90">
                      {dev.name}
                    </div>
                    <div className="mt-[2px] truncate text-[10.5px] leading-tight text-white/48">
                      {dev.detail ? `${port.title} · ${dev.detail}` : port.title}
                    </div>
                  </div>
                </div>
              ))
            )}
            {showEthernetRow && (
              <div className="flex items-center gap-2.5 px-3 py-2">
                <DeviceIcon icon="ethernet" />
                <div className="min-w-0 flex-1">
                  <div className="truncate text-[12px] font-medium leading-tight text-white/90">
                    Ethernet
                  </div>
                  <div className="mt-[2px] truncate text-[10.5px] leading-tight text-white/48">
                    Interface {layout.ethernetInterface}
                  </div>
                </div>
              </div>
            )}
          </div>
        )}
      </div>
    </div>
  );
}
