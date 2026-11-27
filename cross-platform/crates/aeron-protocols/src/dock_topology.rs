//! USB / Thunderbolt 4 dock port topology definitions and layout solver for the
//! Razer Thunderbolt 4 Dock Chroma and Satechi Thunderbolt 4 Slim Hub Pro.
//! Exact port of `AeronTools/DockTopology.swift`.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::razer_chroma;

pub const SATECHI_VENDOR_ID: u16 = 0x310E;
pub const SATECHI_SLIM_HUB_PRO_ANCHOR_PID: u16 = 0x0952;
pub const USB_HUB_CLASS: u8 = 0x09;
/// USB-C alternate-mode announcement devices. On a Thunderbolt port one means a display cable or adapter.
pub const USB_BILLBOARD_CLASS: u8 = 0x11;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DockPortKind {
    Thunderbolt,
    UsbA,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DockAttachedDevice {
    pub id: String,
    pub name: String,
    pub detail: String,
    pub icon: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DockPort {
    pub id: String,
    pub kind: DockPortKind,
    pub number: u8,
    pub title: String,
    pub devices: Vec<DockAttachedDevice>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DockLayout {
    pub is_present: bool,
    pub thunderbolt: Vec<DockPort>,
    pub usb_a: Vec<DockPort>,
    pub ethernet_interface: Option<String>,
    pub serial_number: Option<String>,
}

impl DockLayout {
    pub fn empty_razer() -> Self {
        Self::empty(3, 4)
    }

    pub fn empty_satechi() -> Self {
        Self::empty(3, 1)
    }

    pub fn empty(tb_count: u8, usb_a_count: u8) -> Self {
        let thunderbolt = (1..=tb_count)
            .map(|n| DockPort {
                id: format!("thunderbolt-{n}"),
                kind: DockPortKind::Thunderbolt,
                number: n,
                title: format!("Thunderbolt {n}"),
                devices: Vec::new(),
            })
            .collect();
        let usb_a = (1..=usb_a_count)
            .map(|n| DockPort {
                id: format!("usbA-{n}"),
                kind: DockPortKind::UsbA,
                number: n,
                title: format!("USB-A {n}"),
                devices: Vec::new(),
            })
            .collect();
        Self {
            is_present: false,
            thunderbolt,
            usb_a,
            ethernet_interface: None,
            serial_number: None,
        }
    }
}

/// Identifies a known Thunderbolt dock from USB VID/PID pairs.
pub fn is_razer_dock_usb_hub(vid: u16, pid: u16) -> bool {
    vid == razer_chroma::VENDOR_ID
        && (pid == razer_chroma::DOCK_USB2_HUB_PRODUCT_ID
            || pid == razer_chroma::DOCK_USB3_HUB_PRODUCT_ID)
}

pub fn is_satechi_slim_hub_anchor(vid: u16, pid: u16) -> bool {
    vid == SATECHI_VENDOR_ID && pid == SATECHI_SLIM_HUB_PRO_ANCHOR_PID
}

// MARK: - Dock Model & Topology Solver (exact port of `DockTopology.swift`)

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UsbAPlacement {
    /// Directly on the controller's hubs: `(controller_port, usb_a_port_number)`.
    ControllerPorts(Vec<(u8, u8)>),
    /// Ports `1..=usb_a_port_count` of the dock's own hubs (matching these product IDs).
    DockHubs(Vec<u16>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DockModel {
    pub vendor_id: u16,
    pub anchor_product_id: u16,
    pub switch_model_id: u16,
    pub thunderbolt_port_count: u8,
    pub usb_a_port_count: u8,
    pub usb_a_placement: UsbAPlacement,
    pub has_ethernet: bool,
}

impl DockModel {
    /// Razer Thunderbolt 4 Dock Chroma: 3 Thunderbolt, 4 USB-A on Razer's hubs, Gigabit Ethernet.
    pub fn razer_thunderbolt_4() -> Self {
        Self {
            vendor_id: razer_chroma::VENDOR_ID,
            anchor_product_id: razer_chroma::DOCK_USB2_HUB_PRODUCT_ID,
            switch_model_id: 0x122E,
            thunderbolt_port_count: 3,
            usb_a_port_count: 4,
            usb_a_placement: UsbAPlacement::DockHubs(vec![
                razer_chroma::DOCK_USB2_HUB_PRODUCT_ID,
                razer_chroma::DOCK_USB3_HUB_PRODUCT_ID,
            ]),
            has_ethernet: true,
        }
    }

    /// Satechi Thunderbolt 4 Slim Hub Pro (ST-HT4SHM): 3 Thunderbolt and 1 USB-A on controller port 4.
    /// Its anchor is the hub's billboard/firmware device on controller port 5.
    pub fn satechi_slim_hub_pro() -> Self {
        Self {
            vendor_id: SATECHI_VENDOR_ID,
            anchor_product_id: SATECHI_SLIM_HUB_PRO_ANCHOR_PID,
            switch_model_id: 0x0952,
            thunderbolt_port_count: 3,
            usb_a_port_count: 1,
            usb_a_placement: UsbAPlacement::ControllerPorts(vec![(4, 1)]),
            has_ethernet: false,
        }
    }
}

/// One USB device as read from IOKit / sysfs / Windows USB enumeration.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UsbNode {
    pub id: u64,
    /// The hub it's attached to; `None` on a root hub / root port.
    pub parent_id: Option<u64>,
    pub location_id: u32,
    pub vendor_id: u16,
    pub product_id: u16,
    pub name: String,
    pub vendor_name: Option<String>,
    pub device_class: u8,
    /// 0 low (1.5M), 1 full (12M), 2 high (480M), 3 SuperSpeed (5G), 4 SuperSpeed+ (10G), 5 (20G).
    pub speed: Option<u8>,
    /// Network interface provided by the device, e.g. `"en7"`.
    pub network_interface: Option<String>,
    pub serial_number: Option<String>,
}

/// One Thunderbolt switch (a dock, display, or drive).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ThunderboltNode {
    pub id: u64,
    pub parent_switch_id: Option<u64>,
    pub vendor_id: Option<u16>,
    pub model_id: Option<u16>,
    pub vendor_name: Option<String>,
    pub model_name: Option<String>,
}

#[derive(Debug, Clone)]
struct SolvedDevice {
    device: DockAttachedDevice,
    is_empty_hub: bool,
}

/// Builds a dock's port layout from flat lists of USB and Thunderbolt nodes.
pub fn build_layout(
    model: &DockModel,
    usb: &[UsbNode],
    thunderbolt: &[ThunderboltNode],
) -> DockLayout {
    let mut layout = DockLayout::empty(model.thunderbolt_port_count, model.usb_a_port_count);
    let Some(anchor) = usb
        .iter()
        .find(|n| n.vendor_id == model.vendor_id && n.product_id == model.anchor_product_id)
    else {
        return layout;
    };

    layout.is_present = true;
    layout.serial_number = anchor.serial_number.clone();

    let mut by_id: HashMap<u64, &UsbNode> = HashMap::new();
    let mut children: HashMap<Option<u64>, Vec<&UsbNode>> = HashMap::new();
    for node in usb {
        by_id.entry(node.id).or_insert(node);
        children.entry(node.parent_id).or_default().push(node);
    }

    // Walk up from anchor to controller's root USB hub; its USB 3 twin shares the same bus (top byte).
    let mut root = anchor;
    let mut guard = 0;
    while let Some(pid) = root.parent_id {
        if guard > 16 {
            break;
        }
        guard += 1;
        if let Some(parent) = by_id.get(&pid) {
            root = parent;
        } else {
            break;
        }
    }
    let bus = root.location_id >> 24;
    let controller_hubs: Vec<&UsbNode> = usb
        .iter()
        .filter(|n| {
            n.parent_id.is_none() && n.device_class == USB_HUB_CLASS && (n.location_id >> 24) == bus
        })
        .collect();

    let mut thunderbolt_devices: HashMap<u8, Vec<SolvedDevice>> = HashMap::new();
    let mut usb_a_devices: HashMap<u8, Vec<SolvedDevice>> = HashMap::new();

    for hub in controller_hubs {
        let Some(hub_children) = children.get(&Some(hub.id)) else {
            continue;
        };
        for &child in hub_children {
            let port = port_number(child.location_id, hub.location_id);
            if (1..=model.thunderbolt_port_count).contains(&port) {
                let list = if child.device_class == USB_BILLBOARD_CLASS {
                    vec![display_adapter(child)]
                } else {
                    attached_devices(child, &children)
                };
                thunderbolt_devices.entry(port).or_default().extend(list);
                continue;
            }

            match &model.usb_a_placement {
                UsbAPlacement::ControllerPorts(mapping) => {
                    if let Some(&(_, usb_a_num)) = mapping.iter().find(|&&(p, _)| p == port) {
                        usb_a_devices
                            .entry(usb_a_num)
                            .or_default()
                            .extend(attached_devices(child, &children));
                        continue;
                    }
                }
                UsbAPlacement::DockHubs(pids) => {
                    if child.vendor_id == model.vendor_id && pids.contains(&child.product_id) {
                        if let Some(dock_children) = children.get(&Some(child.id)) {
                            for &device in dock_children {
                                let dock_port = port_number(device.location_id, child.location_id);
                                if (1..=model.usb_a_port_count).contains(&dock_port) {
                                    usb_a_devices
                                        .entry(dock_port)
                                        .or_default()
                                        .extend(attached_devices(device, &children));
                                } else if device.vendor_id != model.vendor_id {
                                    if let Some(ref iface) = device.network_interface {
                                        layout.ethernet_interface = Some(iface.clone());
                                    }
                                }
                            }
                        }
                        continue;
                    }
                }
            }

            if model.has_ethernet && child.vendor_id != model.vendor_id {
                if let Some(ref iface) = child.network_interface {
                    layout.ethernet_interface = Some(iface.clone());
                }
            }
        }
    }

    // Thunderbolt devices directly behind the dock's switch take the first free Thunderbolt ports.
    let dock_switch = thunderbolt.iter().find(|s| {
        s.vendor_id == Some(model.vendor_id) && s.model_id == Some(model.switch_model_id)
    });
    if let Some(sw) = dock_switch {
        let mut chained: Vec<SolvedDevice> = thunderbolt
            .iter()
            .filter(|n| n.parent_switch_id == Some(sw.id))
            .map(|node| SolvedDevice {
                device: DockAttachedDevice {
                    id: node.id.to_string(),
                    name: thunderbolt_name(node),
                    detail: "Thunderbolt".to_string(),
                    icon: icon_for_device(
                        node.model_name.as_deref().unwrap_or(""),
                        None,
                        "thunderbolt",
                    )
                    .to_string(),
                },
                is_empty_hub: false,
            })
            .collect();

        for port in 1..=model.thunderbolt_port_count {
            if !thunderbolt_devices.contains_key(&port) && !chained.is_empty() {
                thunderbolt_devices.insert(port, vec![chained.remove(0)]);
            }
        }
    }

    layout.thunderbolt = (1..=model.thunderbolt_port_count)
        .map(|n| DockPort {
            id: format!("thunderbolt-{n}"),
            kind: DockPortKind::Thunderbolt,
            number: n,
            title: format!("Thunderbolt {n}"),
            devices: merged(thunderbolt_devices.remove(&n).unwrap_or_default()),
        })
        .collect();

    layout.usb_a = (1..=model.usb_a_port_count)
        .map(|n| DockPort {
            id: format!("usbA-{n}"),
            kind: DockPortKind::UsbA,
            number: n,
            title: format!("USB-A {n}"),
            devices: merged(usb_a_devices.remove(&n).unwrap_or_default()),
        })
        .collect();

    layout
}

/// The hub port a device is on: a location ID holds one hex digit per tier below the bus byte,
/// so the child's digit at the first tier the hub leaves empty is its port.
pub fn port_number(child_location_id: u32, hub_location_id: u32) -> u8 {
    let mut shift = 20i32;
    while shift >= 0 {
        if ((hub_location_id >> shift) & 0xF) == 0 {
            return ((child_location_id >> shift) & 0xF) as u8;
        }
        shift -= 4;
    }
    0
}

fn display_adapter(node: &UsbNode) -> SolvedDevice {
    let vendor = node
        .vendor_name
        .as_deref()
        .and_then(|s| s.split_whitespace().next());
    let detail = match vendor {
        Some(v) if !v.is_empty() => format!("Alternate mode · {v}"),
        _ => "Alternate mode".to_string(),
    };
    SolvedDevice {
        device: DockAttachedDevice {
            id: node.id.to_string(),
            name: "USB-C Display Adapter".to_string(),
            detail,
            icon: "display".to_string(),
        },
        is_empty_hub: false,
    }
}

fn is_billboard(node: &UsbNode) -> bool {
    node.device_class == USB_BILLBOARD_CLASS || node.name.to_ascii_lowercase().contains("billboard")
}

fn attached_devices(
    node: &UsbNode,
    children: &HashMap<Option<u64>, Vec<&UsbNode>>,
) -> Vec<SolvedDevice> {
    if node.device_class != USB_HUB_CLASS {
        return vec![SolvedDevice {
            device: DockAttachedDevice {
                id: node.id.to_string(),
                name: display_name(node),
                detail: speed_title(node.speed).unwrap_or("USB").to_string(),
                icon: icon_for_device(&node.name, Some(node.device_class), "usb").to_string(),
            },
            is_empty_hub: false,
        }];
    }

    let leaves: Vec<&UsbNode> = descendants(node, children)
        .into_iter()
        .filter(|n| n.device_class != USB_HUB_CLASS && !is_billboard(n))
        .collect();

    if leaves.is_empty() {
        return vec![SolvedDevice {
            device: DockAttachedDevice {
                id: node.id.to_string(),
                name: display_name(node),
                detail: "Hub with nothing connected".to_string(),
                icon: "hub".to_string(),
            },
            is_empty_hub: true,
        }];
    }

    leaves
        .into_iter()
        .map(|leaf| {
            let speed_prefix = speed_title(leaf.speed)
                .map(|s| format!("{s} · "))
                .unwrap_or_default();
            SolvedDevice {
                device: DockAttachedDevice {
                    id: leaf.id.to_string(),
                    name: display_name(leaf),
                    detail: format!("{speed_prefix}Through {}", node.name),
                    icon: icon_for_device(&leaf.name, Some(leaf.device_class), "usb").to_string(),
                },
                is_empty_hub: false,
            }
        })
        .collect()
}

fn descendants<'a>(
    node: &'a UsbNode,
    children: &HashMap<Option<u64>, Vec<&'a UsbNode>>,
) -> Vec<&'a UsbNode> {
    let mut direct = children.get(&Some(node.id)).cloned().unwrap_or_default();
    direct.sort_by_key(|n| n.location_id);
    let mut out = Vec::new();
    for ch in direct {
        out.push(ch);
        out.extend(descendants(ch, children));
    }
    out
}

/// A USB 3 hub appears on both USB 2 and USB 3 trees; drop empty hub entries whenever real devices exist.
fn merged(devices: Vec<SolvedDevice>) -> Vec<DockAttachedDevice> {
    let real: Vec<DockAttachedDevice> = devices
        .iter()
        .filter(|d| !d.is_empty_hub)
        .map(|d| d.device.clone())
        .collect();
    if real.is_empty() {
        devices.into_iter().take(1).map(|d| d.device).collect()
    } else {
        real
    }
}

pub fn display_name(node: &UsbNode) -> String {
    if let Some(vendor) = node
        .vendor_name
        .as_deref()
        .and_then(|s| s.split_whitespace().next())
    {
        let vendor_clean = vendor.trim_end_matches([',', '.']);
        if !vendor_clean.is_empty()
            && !vendor_clean.eq_ignore_ascii_case("generic")
            && !node
                .name
                .to_ascii_lowercase()
                .contains(&vendor_clean.to_ascii_lowercase())
        {
            return format!("{vendor_clean} {}", node.name);
        }
    }
    node.name.clone()
}

fn thunderbolt_name(node: &ThunderboltNode) -> String {
    let parts: Vec<&str> = [node.vendor_name.as_deref(), node.model_name.as_deref()]
        .into_iter()
        .flatten()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .collect();
    if parts.is_empty() {
        "Thunderbolt Device".to_string()
    } else {
        parts.join(" ")
    }
}

pub fn speed_title(speed: Option<u8>) -> Option<&'static str> {
    match speed {
        Some(0) => Some("1.5 Mb/s"),
        Some(1) => Some("12 Mb/s"),
        Some(2) => Some("480 Mb/s"),
        Some(3) => Some("5 Gb/s"),
        Some(4) => Some("10 Gb/s"),
        Some(5) => Some("20 Gb/s"),
        _ => None,
    }
}

pub fn icon_for_device(name: &str, device_class: Option<u8>, fallback: &'static str) -> &'static str {
    let lower = name.to_ascii_lowercase();
    let rules: &[(&[&str], &str)] = &[
        (&["controller", "xbox", "gamepad", "joystick"], "gamepad"),
        (&["headset", "headphone"], "headphones"),
        (&["mic"], "mic"),
        (&["camera", "webcam"], "camera"),
        (&["keyboard"], "keyboard"),
        (&["mouse"], "mouse"),
        (&["receiver", "dongle", "bluetooth", "link"], "wireless"),
        (&["monitor", "display"], "display"),
        (&["light"], "light"),
        (&["audio", "speaker", "dac"], "audio"),
        (&["disk", "drive", "ssd", "flash", "storage", "card"], "storage"),
        (&["hub"], "hub"),
    ];
    for (words, icon) in rules {
        if words.iter().any(|w| lower.contains(w)) {
            return icon;
        }
    }
    match device_class {
        Some(0x01) => "audio",
        Some(0x08) => "storage",
        Some(0x0E) => "camera",
        _ => fallback,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn solves_satechi_slim_hub_pro_real_usb_tree() {
        let usb = vec![
            UsbNode {
                id: 1,
                parent_id: None,
                location_id: 0x0010_0000,
                vendor_id: 0x1D5C,
                product_id: 0x5801,
                name: "USB2.0 Hub".into(),
                vendor_name: Some("Fresco Logic, Inc.".into()),
                device_class: USB_HUB_CLASS,
                speed: Some(2),
                network_interface: None,
                serial_number: None,
            },
            UsbNode {
                id: 2,
                parent_id: Some(1),
                location_id: 0x0012_0000,
                vendor_id: 0x05F6,
                product_id: 0x1003,
                name: "USB2.0 Hub".into(),
                vendor_name: Some("VIA Labs, Inc.".into()),
                device_class: USB_HUB_CLASS,
                speed: Some(2),
                network_interface: None,
                serial_number: None,
            },
            UsbNode {
                id: 3,
                parent_id: Some(2),
                location_id: 0x0012_5000,
                vendor_id: 0x2109,
                product_id: 0x8884,
                name: "USB Billboard Device".into(),
                vendor_name: Some("VIA Labs, Inc.".into()),
                device_class: 0xFE,
                speed: Some(2),
                network_interface: None,
                serial_number: None,
            },
            UsbNode {
                id: 4,
                parent_id: Some(2),
                location_id: 0x0012_3000,
                vendor_id: 0x3434,
                product_id: 0xD038,
                name: "Keychron 4K Link".into(),
                vendor_name: Some("Keychron".into()),
                device_class: 0x00,
                speed: Some(2),
                network_interface: None,
                serial_number: None,
            },
            UsbNode {
                id: 5,
                parent_id: Some(2),
                location_id: 0x0012_4000,
                vendor_id: 0x05F6,
                product_id: 0xAC37,
                name: "AGON3 AG276QZD2 Light FX Device".into(),
                vendor_name: Some("ENE".into()),
                device_class: 0x00,
                speed: Some(1),
                network_interface: None,
                serial_number: None,
            },
            UsbNode {
                id: 6,
                parent_id: Some(1),
                location_id: 0x0013_0000,
                vendor_id: 0x0639,
                product_id: 0x7213,
                name: "Billboard".into(),
                vendor_name: Some("Chrontel".into()),
                device_class: USB_BILLBOARD_CLASS,
                speed: Some(1),
                network_interface: None,
                serial_number: None,
            },
            UsbNode {
                id: 7,
                parent_id: Some(1),
                location_id: 0x0014_0000,
                vendor_id: 0x046D,
                product_id: 0xC547,
                name: "USB Receiver".into(),
                vendor_name: Some("Logitech".into()),
                device_class: 0x00,
                speed: Some(1),
                network_interface: None,
                serial_number: None,
            },
            UsbNode {
                id: 8,
                parent_id: Some(1),
                location_id: 0x0015_0000,
                vendor_id: SATECHI_VENDOR_ID,
                product_id: SATECHI_SLIM_HUB_PRO_ANCHOR_PID,
                name: "ST-HT4SHM-US".into(),
                vendor_name: Some("Sariana LLC dba Satechi".into()),
                device_class: 0x00,
                speed: Some(1),
                network_interface: None,
                serial_number: Some("SN12345".into()),
            },
            UsbNode {
                id: 9,
                parent_id: None,
                location_id: 0x0020_0000,
                vendor_id: 0x8087,
                product_id: 0x0B40,
                name: "USB3.0 Hub".into(),
                vendor_name: Some("Intel Corporation.".into()),
                device_class: USB_HUB_CLASS,
                speed: Some(4),
                network_interface: None,
                serial_number: None,
            },
            UsbNode {
                id: 10,
                parent_id: Some(9),
                location_id: 0x0022_0000,
                vendor_id: 0x05F6,
                product_id: 0x1004,
                name: "USB3.0 Hub".into(),
                vendor_name: Some("VIA Labs, Inc.".into()),
                device_class: USB_HUB_CLASS,
                speed: Some(3),
                network_interface: None,
                serial_number: None,
            },
        ];

        let layout = build_layout(&DockModel::satechi_slim_hub_pro(), &usb, &[]);
        assert!(layout.is_present);
        assert_eq!(layout.serial_number.as_deref(), Some("SN12345"));
        assert!(layout.thunderbolt[0].devices.is_empty());
        assert_eq!(layout.thunderbolt[1].devices.len(), 2);
        assert_eq!(layout.thunderbolt[1].devices[0].name, "Keychron 4K Link");
        assert_eq!(
            layout.thunderbolt[1].devices[1].name,
            "ENE AGON3 AG276QZD2 Light FX Device"
        );
        assert_eq!(layout.thunderbolt[2].devices.len(), 1);
        assert_eq!(
            layout.thunderbolt[2].devices[0].name,
            "USB-C Display Adapter"
        );
        assert_eq!(
            layout.thunderbolt[2].devices[0].detail,
            "Alternate mode · Chrontel"
        );
        assert_eq!(layout.usb_a[0].devices.len(), 1);
        assert_eq!(layout.usb_a[0].devices[0].name, "Logitech USB Receiver");
    }
}
