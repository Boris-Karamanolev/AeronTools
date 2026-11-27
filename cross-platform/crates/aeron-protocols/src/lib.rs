//! OS-agnostic hardware protocols and domain models ported from AeronTools (macOS).
//!
//! Covers DDC/CI, Logitech HID++ 2.0 (MX Master, MX Keyboard, Logitech G mice & G515 keyboard),
//! Keychron M3 Mini 4K, Razer Thunderbolt 4 Dock Chroma, USB/Thunderbolt dock port topology,
//! and shared application state models.

pub mod ddc;
pub mod dock_topology;
pub mod hidpp;
pub mod keychron;
pub mod logitech_g;
pub mod logitech_keyboard;
pub mod models;
pub mod razer_chroma;
