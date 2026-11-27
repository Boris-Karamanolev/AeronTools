//! Native macOS IOKit USB & Thunderbolt dock topology scanner.
//! Exact 1:1 port of `DockTopology.scanUSB()` and `DockTopology.scanThunderbolt()` in `platforms/macos/app/DockTopology.swift`.

use std::ffi::{c_char, c_void, CStr, CString};

use aeron_protocols::dock_topology::{
    self, DockLayout, DockModel, ThunderboltNode, UsbNode, USB_HUB_CLASS,
};

type KernReturn = i32;
type IoObjectT = u32;
type IoServiceT = u32;
type IoIteratorT = u32;
type CFTypeRef = *const c_void;
type CFAllocatorRef = *const c_void;
type CFDictionaryRef = *const c_void;
type CFStringRef = *const c_void;

const KERN_SUCCESS: KernReturn = 0;
const K_IO_MAIN_PORT_DEFAULT: u32 = 0;
const K_CF_STRING_ENCODING_UTF8: u32 = 0x0800_0100;
const K_IO_REGISTRY_ITERATE_RECURSIVELY: u32 = 0x0000_0001;
const K_CF_NUMBER_SINT64_TYPE: isize = 4;

#[link(name = "IOKit", kind = "framework")]
extern "C" {
    fn IOServiceMatching(name: *const c_char) -> CFDictionaryRef;
    fn IOServiceGetMatchingServices(
        main_port: u32,
        matching: CFDictionaryRef,
        existing: *mut IoIteratorT,
    ) -> KernReturn;
    fn IOIteratorNext(iterator: IoIteratorT) -> IoObjectT;
    fn IOObjectRelease(object: IoObjectT) -> KernReturn;
    fn IOObjectRetain(object: IoObjectT) -> KernReturn;
    fn IOObjectConformsTo(object: IoObjectT, class_name: *const c_char) -> u32;
    fn IORegistryEntryGetRegistryEntryID(entry: IoObjectT, entry_id: *mut u64) -> KernReturn;
    fn IORegistryEntryGetParentEntry(
        entry: IoObjectT,
        plane: *const c_char,
        parent: *mut IoObjectT,
    ) -> KernReturn;
    fn IORegistryEntryCreateCFProperty(
        entry: IoObjectT,
        key: CFStringRef,
        allocator: CFAllocatorRef,
        options: u32,
    ) -> CFTypeRef;
    fn IORegistryEntrySearchCFProperty(
        entry: IoObjectT,
        plane: *const c_char,
        key: CFStringRef,
        allocator: CFAllocatorRef,
        options: u32,
    ) -> CFTypeRef;
}

#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFStringCreateWithCString(
        alloc: CFAllocatorRef,
        c_str: *const c_char,
        encoding: u32,
    ) -> CFStringRef;
    fn CFStringGetCString(
        the_string: CFStringRef,
        buffer: *mut c_char,
        buffer_size: isize,
        encoding: u32,
    ) -> u8;
    fn CFRelease(cf: CFTypeRef);
    fn CFGetTypeID(cf: CFTypeRef) -> usize;
    fn CFStringGetTypeID() -> usize;
    fn CFNumberGetTypeID() -> usize;
    fn CFNumberGetValue(number: CFTypeRef, the_type: isize, value_ptr: *mut c_void) -> u8;
}

pub fn scan_macos_usb_docks() -> (DockLayout, DockLayout) {
    let usb = scan_usb();
    let tb = scan_thunderbolt();
    (
        dock_topology::build_layout(&DockModel::razer_thunderbolt_4(), &usb, &tb),
        dock_topology::build_layout(&DockModel::satechi_slim_hub_pro(), &usb, &tb),
    )
}

pub fn scan_usb() -> Vec<UsbNode> {
    let usb_plane = CString::new("IOUSB").unwrap();
    let usb_host_class = CString::new("IOUSBHostDevice").unwrap();

    services_matching("IOUSBHostDevice")
        .into_iter()
        .map(|service| {
            let id = entry_id(service);
            let device_class = read_cf_u64_prop(service, "bDeviceClass").unwrap_or(0) as u8;

            let mut parent_id = None;
            let mut parent: IoObjectT = 0;
            if unsafe { IORegistryEntryGetParentEntry(service, usb_plane.as_ptr(), &mut parent) }
                == KERN_SUCCESS
            {
                if unsafe { IOObjectConformsTo(parent, usb_host_class.as_ptr()) } != 0 {
                    parent_id = Some(entry_id(parent));
                }
                unsafe { IOObjectRelease(parent) };
            }

            // Hubs would match downstream devices' interfaces, so only non-hub devices are searched.
            let network_interface = if device_class == USB_HUB_CLASS {
                None
            } else {
                read_cf_string_recursive_prop(service, "IOService", "BSD Name")
                    .filter(|s| s.starts_with("en"))
            };

            let node = UsbNode {
                id,
                parent_id,
                location_id: read_cf_u64_prop(service, "locationID").unwrap_or(0) as u32,
                vendor_id: read_cf_u64_prop(service, "idVendor").unwrap_or(0) as u16,
                product_id: read_cf_u64_prop(service, "idProduct").unwrap_or(0) as u16,
                name: read_cf_string_prop(service, "USB Product Name")
                    .or_else(|| read_cf_string_prop(service, "kUSBProductString"))
                    .unwrap_or_else(|| "USB Device".to_string()),
                vendor_name: read_cf_string_prop(service, "USB Vendor Name"),
                device_class,
                speed: read_cf_u64_prop(service, "Device Speed").map(|v| v as u8),
                network_interface,
                serial_number: read_cf_string_prop(service, "kUSBSerialNumberString")
                    .or_else(|| read_cf_string_prop(service, "USB Serial Number")),
            };

            unsafe { IOObjectRelease(service) };
            node
        })
        .collect()
}

pub fn scan_thunderbolt() -> Vec<ThunderboltNode> {
    services_matching("IOThunderboltSwitch")
        .into_iter()
        .map(|service| {
            let node = ThunderboltNode {
                id: entry_id(service),
                parent_switch_id: parent_switch_id(service),
                vendor_id: read_cf_u64_prop(service, "Device Vendor ID").map(|v| v as u16),
                model_id: read_cf_u64_prop(service, "Device Model ID").map(|v| v as u16),
                vendor_name: read_cf_string_prop(service, "Device Vendor Name"),
                model_name: read_cf_string_prop(service, "Device Model Name"),
            };
            unsafe { IOObjectRelease(service) };
            node
        })
        .collect()
}

fn parent_switch_id(service: IoObjectT) -> Option<u64> {
    let service_plane = CString::new("IOService").unwrap();
    let switch_class = CString::new("IOThunderboltSwitch").unwrap();
    let mut entry = service;
    unsafe { IOObjectRetain(entry) };

    let mut found = None;
    for _ in 0..8 {
        let mut parent: IoObjectT = 0;
        let ret =
            unsafe { IORegistryEntryGetParentEntry(entry, service_plane.as_ptr(), &mut parent) };
        unsafe { IOObjectRelease(entry) };
        if ret != KERN_SUCCESS {
            return None;
        }
        entry = parent;
        if unsafe { IOObjectConformsTo(entry, switch_class.as_ptr()) } != 0 {
            found = Some(entry_id(entry));
            break;
        }
    }
    unsafe { IOObjectRelease(entry) };
    found
}

fn services_matching(class_name: &str) -> Vec<IoServiceT> {
    let Ok(cname) = CString::new(class_name) else {
        return Vec::new();
    };
    let mut iterator: IoIteratorT = 0;
    let ret = unsafe {
        IOServiceGetMatchingServices(
            K_IO_MAIN_PORT_DEFAULT,
            IOServiceMatching(cname.as_ptr()),
            &mut iterator,
        )
    };
    if ret != KERN_SUCCESS {
        return Vec::new();
    }
    let mut result = Vec::new();
    loop {
        let svc = unsafe { IOIteratorNext(iterator) };
        if svc == 0 {
            break;
        }
        result.push(svc);
    }
    unsafe { IOObjectRelease(iterator) };
    result
}

fn entry_id(entry: IoObjectT) -> u64 {
    let mut id = 0u64;
    unsafe {
        IORegistryEntryGetRegistryEntryID(entry, &mut id);
    }
    id
}

fn read_cf_u64_prop(entry: IoObjectT, key: &str) -> Option<u64> {
    let ckey = CString::new(key).ok()?;
    let cf_key = unsafe {
        CFStringCreateWithCString(std::ptr::null(), ckey.as_ptr(), K_CF_STRING_ENCODING_UTF8)
    };
    if cf_key.is_null() {
        return None;
    }
    let val = unsafe { IORegistryEntryCreateCFProperty(entry, cf_key, std::ptr::null(), 0) };
    unsafe { CFRelease(cf_key) };
    if val.is_null() {
        return None;
    }
    let result = if unsafe { CFGetTypeID(val) == CFNumberGetTypeID() } {
        let mut out: i64 = 0;
        if unsafe {
            CFNumberGetValue(
                val,
                K_CF_NUMBER_SINT64_TYPE,
                (&mut out as *mut i64) as *mut c_void,
            )
        } != 0
        {
            Some(out as u64)
        } else {
            None
        }
    } else {
        None
    };
    unsafe { CFRelease(val) };
    result
}

fn read_cf_string_prop(entry: IoObjectT, key: &str) -> Option<String> {
    let ckey = CString::new(key).ok()?;
    let cf_key = unsafe {
        CFStringCreateWithCString(std::ptr::null(), ckey.as_ptr(), K_CF_STRING_ENCODING_UTF8)
    };
    if cf_key.is_null() {
        return None;
    }
    let val = unsafe { IORegistryEntryCreateCFProperty(entry, cf_key, std::ptr::null(), 0) };
    unsafe { CFRelease(cf_key) };
    cf_to_string_and_release(val)
}

fn read_cf_string_recursive_prop(entry: IoObjectT, plane: &str, key: &str) -> Option<String> {
    let cplane = CString::new(plane).ok()?;
    let ckey = CString::new(key).ok()?;
    let cf_key = unsafe {
        CFStringCreateWithCString(std::ptr::null(), ckey.as_ptr(), K_CF_STRING_ENCODING_UTF8)
    };
    if cf_key.is_null() {
        return None;
    }
    let val = unsafe {
        IORegistryEntrySearchCFProperty(
            entry,
            cplane.as_ptr(),
            cf_key,
            std::ptr::null(),
            K_IO_REGISTRY_ITERATE_RECURSIVELY,
        )
    };
    unsafe { CFRelease(cf_key) };
    cf_to_string_and_release(val)
}

fn cf_to_string_and_release(val: CFTypeRef) -> Option<String> {
    if val.is_null() {
        return None;
    }
    let result = if unsafe { CFGetTypeID(val) == CFStringGetTypeID() } {
        let mut buf = [0i8; 256];
        let ok = unsafe {
            CFStringGetCString(
                val,
                buf.as_mut_ptr(),
                buf.len() as isize,
                K_CF_STRING_ENCODING_UTF8,
            )
        };
        if ok != 0 {
            let s = unsafe { CStr::from_ptr(buf.as_ptr()) }
                .to_string_lossy()
                .trim()
                .to_string();
            (!s.is_empty()).then_some(s)
        } else {
            None
        }
    } else {
        None
    };
    unsafe { CFRelease(val) };
    result
}
