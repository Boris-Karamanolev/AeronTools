//! Native macOS hardware backend (mirrors Swift AeronTools' SMCConnection, WattageManager,
//! ThermalManager, DDCController, DisplayHardwareManager, GameModeManager, and DockTopology)
//! so local testing on macOS uses 100% real hardware readings and controls.

use std::collections::HashMap;
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::Duration;

use aeron_protocols::ddc;
use aeron_protocols::dock_topology::DockLayout;
use aeron_protocols::models::{
    BuiltinDisplayState, ExternalDisplayInfo, FanReading, GameModePolicy, GameModeState,
    InputSourceOption, ThermalPressure, ThermalSnapshot, WattageSnapshot,
};
use plist::Value as PlistValue;
use tracing::{debug, info, warn};

use crate::PlatformBackend;

// MARK: - CoreGraphics / IOKit / CoreFoundation FFI

type CGDirectDisplayID = u32;
type CGDisplayConfigRef = *mut c_void;
type CGError = i32;
const K_CG_CONFIGURE_FOR_SESSION: u32 = 1;
type KernReturn = i32;
type IOReturn = i32;
type IoObjectT = u32;
type IoServiceT = u32;
type IoConnectT = u32;
type IoIteratorT = u32;
type CFTypeRef = *const c_void;
type CFAllocatorRef = *const c_void;
type CFDictionaryRef = *const c_void;
type CFArrayRef = *const c_void;
type CFStringRef = *const c_void;

const KERN_SUCCESS: KernReturn = 0;
const K_IO_MAIN_PORT_DEFAULT: u32 = 0;
const K_CF_STRING_ENCODING_UTF8: u32 = 0x0800_0100;

#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGGetOnlineDisplayList(
        max_displays: u32,
        online_displays: *mut CGDirectDisplayID,
        display_count: *mut u32,
    ) -> CGError;
    fn CGDisplayIsOnline(display: CGDirectDisplayID) -> u32;
    fn CGDisplayIsActive(display: CGDirectDisplayID) -> i32;
    fn CGDisplayIsBuiltin(display: CGDirectDisplayID) -> u32;
    fn CGDisplayVendorNumber(display: CGDirectDisplayID) -> u32;
    fn CGDisplayModelNumber(display: CGDirectDisplayID) -> u32;
    fn CGDisplaySerialNumber(display: CGDirectDisplayID) -> u32;
    fn CGBeginDisplayConfiguration(config: *mut CGDisplayConfigRef) -> CGError;
    fn CGCompleteDisplayConfiguration(config: CGDisplayConfigRef, option: u32) -> CGError;
    fn CGCancelDisplayConfiguration(config: CGDisplayConfigRef) -> CGError;
}

/// `CGDisplayIsActive` returns -1 for a disabled panel once macOS's placeholder display takes over,
/// so only `1` means actively displaying (exact match to Swift `DisplayHardwareManager.swift`).
fn is_display_active(display_id: CGDirectDisplayID) -> bool {
    unsafe { CGDisplayIsActive(display_id) == 1 }
}

#[link(name = "IOKit", kind = "framework")]
extern "C" {
    fn IOServiceMatching(name: *const c_char) -> CFDictionaryRef;
    fn IOServiceGetMatchingService(main_port: u32, matching: CFDictionaryRef) -> IoServiceT;
    fn IOServiceGetMatchingServices(
        main_port: u32,
        matching: CFDictionaryRef,
        existing: *mut IoIteratorT,
    ) -> KernReturn;
    fn IOIteratorNext(iterator: IoIteratorT) -> IoObjectT;
    fn IOServiceOpen(
        service: IoServiceT,
        owning_task: u32,
        r#type: u32,
        connect: *mut IoConnectT,
    ) -> KernReturn;
    fn IOServiceClose(connect: IoConnectT) -> KernReturn;
    fn IOObjectRelease(object: IoObjectT) -> KernReturn;
    fn IOObjectRetain(object: IoObjectT) -> KernReturn;
    fn IORegistryEntryCreateCFProperty(
        entry: IoObjectT,
        key: CFStringRef,
        allocator: CFAllocatorRef,
        options: u32,
    ) -> CFTypeRef;
    fn IORegistryEntryGetParentEntry(
        entry: IoObjectT,
        plane: *const c_char,
        parent: *mut IoObjectT,
    ) -> KernReturn;
    fn IOConnectCallStructMethod(
        connection: IoConnectT,
        selector: u32,
        input_struct: *const c_void,
        input_struct_cnt: usize,
        output_struct: *mut c_void,
        output_struct_cnt: *mut usize,
    ) -> KernReturn;

    // Apple Silicon HID temperature sensor APIs (used as fallback when SMC die keys are hidden)
    fn IOHIDEventSystemClientCreate(allocator: CFAllocatorRef) -> CFTypeRef;
    fn IOHIDEventSystemClientSetMatching(client: CFTypeRef, matching: CFDictionaryRef);
    fn IOHIDEventSystemClientCopyServices(client: CFTypeRef) -> CFArrayRef;
    fn IOHIDServiceClientCopyProperty(service: CFTypeRef, key: CFStringRef) -> CFTypeRef;
    fn IOHIDServiceClientCopyEvent(
        service: CFTypeRef,
        event_type: i64,
        options: i32,
        timeout: i64,
    ) -> CFTypeRef;
    fn IOHIDEventGetFloatValue(event: CFTypeRef, field: u32) -> f64;
}

#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    static kCFTypeDictionaryKeyCallBacks: c_void;
    static kCFTypeDictionaryValueCallBacks: c_void;

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
    fn CFRetain(cf: CFTypeRef) -> CFTypeRef;
    fn CFRelease(cf: CFTypeRef);
    fn CFGetTypeID(cf: CFTypeRef) -> usize;
    fn CFStringGetTypeID() -> usize;
    fn CFDictionaryGetTypeID() -> usize;
    fn CFNumberGetTypeID() -> usize;
    fn CFDictionaryCreate(
        allocator: CFAllocatorRef,
        keys: *const *const c_void,
        values: *const *const c_void,
        num_values: isize,
        key_callbacks: *const c_void,
        value_callbacks: *const c_void,
    ) -> CFDictionaryRef;
    fn CFDictionaryGetValue(the_dict: CFDictionaryRef, key: *const c_void) -> *const c_void;
    fn CFNumberCreate(
        allocator: CFAllocatorRef,
        the_type: isize,
        value_ptr: *const c_void,
    ) -> CFTypeRef;
    fn CFNumberGetValue(number: CFTypeRef, the_type: isize, value_ptr: *mut c_void) -> u8;
    fn CFArrayGetCount(the_array: CFArrayRef) -> isize;
    fn CFArrayGetValueAtIndex(the_array: CFArrayRef, idx: isize) -> *const c_void;
}

extern "C" {
    static mach_task_self_: u32;
    fn sysctlbyname(
        name: *const c_char,
        oldp: *mut c_void,
        oldlenp: *mut usize,
        newp: *const c_void,
        newlen: usize,
    ) -> c_int;
}

// MARK: - AppleSMC Client (exact 80-byte kernel SMCParamStruct from SMCConnection.swift)

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct SmcVersion {
    major: u8,
    minor: u8,
    build: u8,
    reserved: u8,
    release: u16,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct SmcPLimitData {
    version: u16,
    length: u16,
    cpu_p_limit: u32,
    gpu_p_limit: u32,
    mem_p_limit: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct SmcKeyInfo {
    data_size: u32,
    data_type: u32,
    data_attributes: u8,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct SmcParamStruct {
    key: u32,
    vers: SmcVersion,
    p_limit_data: SmcPLimitData,
    key_info: SmcKeyInfo,
    result: u8,
    status: u8,
    data8: u8,
    data32: u32,
    bytes: [u8; 32],
}

impl Default for SmcParamStruct {
    fn default() -> Self {
        Self {
            key: 0,
            vers: SmcVersion::default(),
            p_limit_data: SmcPLimitData::default(),
            key_info: SmcKeyInfo::default(),
            result: 0,
            status: 0,
            data8: 0,
            data32: 0,
            bytes: [0u8; 32],
        }
    }
}

struct SmcClient {
    connection: IoConnectT,
    key_info_cache: HashMap<u32, SmcKeyInfo>,
}

impl SmcClient {
    const HANDLE_YPC_EVENT: u32 = 2;
    const CMD_READ_KEY: u8 = 5;
    const CMD_GET_KEY_INFO: u8 = 9;

    fn open() -> Option<Self> {
        let name = CString::new("AppleSMC").ok()?;
        let service = unsafe {
            IOServiceGetMatchingService(K_IO_MAIN_PORT_DEFAULT, IOServiceMatching(name.as_ptr()))
        };
        if service == 0 {
            return None;
        }
        let mut conn: IoConnectT = 0;
        let ret = unsafe { IOServiceOpen(service, mach_task_self_, 0, &mut conn) };
        unsafe { IOObjectRelease(service) };
        if ret != KERN_SUCCESS {
            return None;
        }
        Some(Self {
            connection: conn,
            key_info_cache: HashMap::new(),
        })
    }

    fn four_char_code(s: &str) -> u32 {
        s.bytes()
            .take(4)
            .fold(0u32, |acc, b| (acc << 8) | (b as u32))
    }

    fn type_string(code: u32) -> [u8; 4] {
        code.to_be_bytes()
    }

    fn call(&self, input: SmcParamStruct) -> Option<SmcParamStruct> {
        let mut output = SmcParamStruct::default();
        let mut output_size = std::mem::size_of::<SmcParamStruct>();
        let ret = unsafe {
            IOConnectCallStructMethod(
                self.connection,
                Self::HANDLE_YPC_EVENT,
                (&input as *const SmcParamStruct) as *const c_void,
                std::mem::size_of::<SmcParamStruct>(),
                (&mut output as *mut SmcParamStruct) as *mut c_void,
                &mut output_size,
            )
        };
        if ret == KERN_SUCCESS && output.result == 0 {
            Some(output)
        } else {
            None
        }
    }

    fn key_info(&mut self, code: u32) -> Option<SmcKeyInfo> {
        if let Some(&cached) = self.key_info_cache.get(&code) {
            return Some(cached);
        }
        let mut input = SmcParamStruct::default();
        input.key = code;
        input.data8 = Self::CMD_GET_KEY_INFO;
        let out = self.call(input)?;
        self.key_info_cache.insert(code, out.key_info);
        Some(out.key_info)
    }

    fn read_value(&mut self, key: &str) -> Option<f64> {
        let code = Self::four_char_code(key);
        let info = self.key_info(code)?;
        let mut input = SmcParamStruct::default();
        input.key = code;
        input.key_info.data_size = info.data_size;
        input.data8 = Self::CMD_READ_KEY;
        let out = self.call(input)?;
        let size = (info.data_size as usize).min(32);
        let bytes = &out.bytes[..size];
        match &Self::type_string(info.data_type) {
            b"flt " if bytes.len() >= 4 => {
                let val = f32::from_ne_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
                Some(val as f64)
            }
            b"fpe2" if bytes.len() >= 2 => {
                Some((((bytes[0] as u16) << 8) | (bytes[1] as u16)) as f64 / 4.0)
            }
            b"sp78" if bytes.len() >= 2 => {
                Some(i16::from_be_bytes([bytes[0], bytes[1]]) as f64 / 256.0)
            }
            b"ui8 " | b"ui16" | b"ui32" => {
                let v = bytes.iter().fold(0u32, |acc, &b| (acc << 8) | (b as u32));
                Some(v as f64)
            }
            _ => None,
        }
    }
}

impl Drop for SmcClient {
    fn drop(&mut self) {
        unsafe {
            IOServiceClose(self.connection);
        }
    }
}

/// Reads Apple Silicon HID thermal sensors (PMU tdie / SOC MTR / GPU MTR / gas gauge battery).
fn read_hid_temperatures() -> (Option<f64>, Option<f64>, Option<f64>) {
    let mut cpu_vals = Vec::new();
    let mut gpu_vals = Vec::new();
    let mut bat_vals = Vec::new();

    unsafe {
        let client = IOHIDEventSystemClientCreate(std::ptr::null());
        if client.is_null() {
            return (None, None, None);
        }

        let k_page = CString::new("PrimaryUsagePage").unwrap();
        let k_usage = CString::new("PrimaryUsage").unwrap();
        let k_prod = CString::new("Product").unwrap();
        let cf_k_page =
            CFStringCreateWithCString(std::ptr::null(), k_page.as_ptr(), K_CF_STRING_ENCODING_UTF8);
        let cf_k_usage = CFStringCreateWithCString(
            std::ptr::null(),
            k_usage.as_ptr(),
            K_CF_STRING_ENCODING_UTF8,
        );
        let cf_k_prod =
            CFStringCreateWithCString(std::ptr::null(), k_prod.as_ptr(), K_CF_STRING_ENCODING_UTF8);

        let page_num: i32 = 0xFF00;
        let usage_num: i32 = 5; // Temperature sensor
        // kCFNumberSInt32Type = 3
        let cf_v_page = CFNumberCreate(std::ptr::null(), 3, (&page_num as *const i32) as *const c_void);
        let cf_v_usage =
            CFNumberCreate(std::ptr::null(), 3, (&usage_num as *const i32) as *const c_void);

        let keys = [cf_k_page, cf_k_usage];
        let vals = [cf_v_page, cf_v_usage];
        let matching = CFDictionaryCreate(
            std::ptr::null(),
            keys.as_ptr(),
            vals.as_ptr(),
            2,
            &kCFTypeDictionaryKeyCallBacks as *const c_void,
            &kCFTypeDictionaryValueCallBacks as *const c_void,
        );

        IOHIDEventSystemClientSetMatching(client, matching);
        let services = IOHIDEventSystemClientCopyServices(client);

        if !services.is_null() {
            let count = CFArrayGetCount(services);
            for i in 0..count {
                let svc = CFArrayGetValueAtIndex(services, i);
                if svc.is_null() {
                    continue;
                }
                let prop = IOHIDServiceClientCopyProperty(svc, cf_k_prod);
                if prop.is_null() {
                    continue;
                }
                let mut name_buf = [0i8; 256];
                let mut name = String::new();
                if CFGetTypeID(prop) == CFStringGetTypeID()
                    && CFStringGetCString(
                        prop,
                        name_buf.as_mut_ptr(),
                        name_buf.len() as isize,
                        K_CF_STRING_ENCODING_UTF8,
                    ) != 0
                {
                    name = CStr::from_ptr(name_buf.as_ptr())
                        .to_string_lossy()
                        .into_owned();
                }
                CFRelease(prop);

                if name.is_empty() {
                    continue;
                }
                // kIOHIDEventTypeTemperature = 15, field = 15 << 16
                let event = IOHIDServiceClientCopyEvent(svc, 15, 0, 0);
                if event.is_null() {
                    continue;
                }
                let temp = IOHIDEventGetFloatValue(event, 15 << 16);
                CFRelease(event);

                if !(10.0..=120.0).contains(&temp) {
                    continue;
                }
                let lower = name.to_ascii_lowercase();
                if lower.contains("pmu tdie")
                    || lower.contains("pacc mtr")
                    || lower.contains("eacc mtr")
                    || lower.contains("soc mtr")
                {
                    cpu_vals.push(temp);
                } else if lower.contains("gpu mtr") {
                    gpu_vals.push(temp);
                } else if lower.contains("gas gauge battery") || lower.contains("battery") {
                    bat_vals.push(temp);
                }
            }
            CFRelease(services);
        }

        CFRelease(matching);
        CFRelease(cf_v_page);
        CFRelease(cf_v_usage);
        CFRelease(cf_k_page);
        CFRelease(cf_k_usage);
        CFRelease(cf_k_prod);
        CFRelease(client);
    }

    let mean = |v: Vec<f64>| -> Option<f64> {
        (!v.is_empty()).then(|| v.iter().sum::<f64>() / v.len() as f64)
    };
    (mean(cpu_vals), mean(gpu_vals), mean(bat_vals))
}

// MARK: - Dynamic Private Framework Handles (IOAVService + DisplayServices)

type IOAVServiceCreateFn = unsafe extern "C" fn(CFAllocatorRef, IoServiceT) -> CFTypeRef;
type IOAVServiceI2CFn = unsafe extern "C" fn(CFTypeRef, u32, u32, *mut c_void, u32) -> IOReturn;
type DisplayServicesGetBrightnessFn = unsafe extern "C" fn(CGDirectDisplayID, *mut f32) -> i32;
type DisplayServicesSetBrightnessFn = unsafe extern "C" fn(CGDirectDisplayID, f32) -> i32;
type SLSConfigureDisplayEnabledFn =
    unsafe extern "C" fn(CGDisplayConfigRef, CGDirectDisplayID, bool) -> CGError;
type SLSGetDisplayListFn =
    unsafe extern "C" fn(u32, *mut CGDirectDisplayID, *mut u32) -> CGError;

struct PrivateDisplayFns {
    av_create: Option<IOAVServiceCreateFn>,
    av_write: Option<IOAVServiceI2CFn>,
    av_read: Option<IOAVServiceI2CFn>,
    ds_get_brightness: Option<DisplayServicesGetBrightnessFn>,
    ds_set_brightness: Option<DisplayServicesSetBrightnessFn>,
    sls_configure_display_enabled: Option<SLSConfigureDisplayEnabledFn>,
    sls_get_display_list: Option<SLSGetDisplayListFn>,
}

unsafe impl Send for PrivateDisplayFns {}

impl PrivateDisplayFns {
    fn load() -> Self {
        unsafe fn sym(handle: *mut c_void, name: &str) -> Option<*mut c_void> {
            let cname = CString::new(name).ok()?;
            let ptr = libc::dlsym(handle, cname.as_ptr());
            (!ptr.is_null()).then_some(ptr)
        }
        unsafe {
            let cd_path =
                CString::new("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay")
                    .unwrap();
            let cd = libc::dlopen(cd_path.as_ptr(), libc::RTLD_LAZY);
            let cd_h = if cd.is_null() { libc::RTLD_DEFAULT } else { cd };

            let ds_path = CString::new(
                "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            )
            .unwrap();
            let ds = libc::dlopen(ds_path.as_ptr(), libc::RTLD_LAZY);
            let ds_h = if ds.is_null() { libc::RTLD_DEFAULT } else { ds };

            let sl_path = CString::new(
                "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            )
            .unwrap();
            let sl = libc::dlopen(sl_path.as_ptr(), libc::RTLD_LAZY);
            let sl_h = if sl.is_null() { libc::RTLD_DEFAULT } else { sl };

            let sls_cfg = sym(sl_h, "SLSConfigureDisplayEnabled")
                .or_else(|| sym(libc::RTLD_DEFAULT, "CGSConfigureDisplayEnabled"))
                .map(|p| std::mem::transmute(p));
            let sls_list = sym(sl_h, "SLSGetDisplayList")
                .or_else(|| sym(libc::RTLD_DEFAULT, "SLSGetDisplayList"))
                .map(|p| std::mem::transmute(p));

            Self {
                av_create: sym(cd_h, "IOAVServiceCreateWithService")
                    .map(|p| std::mem::transmute(p)),
                av_write: sym(cd_h, "IOAVServiceWriteI2C").map(|p| std::mem::transmute(p)),
                av_read: sym(cd_h, "IOAVServiceReadI2C").map(|p| std::mem::transmute(p)),
                ds_get_brightness: sym(ds_h, "DisplayServicesGetBrightness")
                    .map(|p| std::mem::transmute(p)),
                ds_set_brightness: sym(ds_h, "DisplayServicesSetBrightness")
                    .map(|p| std::mem::transmute(p)),
                sls_configure_display_enabled: sls_cfg,
                sls_get_display_list: sls_list,
            }
        }
    }
}

struct AVServiceEntry {
    identity: ddc::MonitorIdentity,
    service: CFTypeRef,
}

unsafe impl Send for AVServiceEntry {}

impl Drop for AVServiceEntry {
    fn drop(&mut self) {
        if !self.service.is_null() {
            unsafe { CFRelease(self.service) };
        }
    }
}

struct RetainedCF(CFTypeRef);

unsafe impl Send for RetainedCF {}

impl RetainedCF {
    fn retain(ptr: CFTypeRef) -> Option<Self> {
        if ptr.is_null() {
            return None;
        }
        unsafe {
            CFRetain(ptr);
        }
        Some(Self(ptr))
    }
}

impl Drop for RetainedCF {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { CFRelease(self.0) };
        }
    }
}

struct DdcQueueState {
    pending: HashMap<(CGDirectDisplayID, u8), (RetainedCF, u16)>,
    last_sent: HashMap<(CGDirectDisplayID, u8), u16>,
    shutdown: bool,
}

/// Non-blocking coalescing background DDC/I2C write queue (mirrors Swift `DDCController.swift`).
/// Rapid slider drags collapse into only the latest value per `(display_id, vcp)` so callers
/// return in microseconds and the monitor smoothly tracks the slider without building a lag backlog.
struct DdcWriteQueue {
    state: Arc<(Mutex<DdcQueueState>, Condvar)>,
}

impl DdcWriteQueue {
    fn new(av_write: Option<IOAVServiceI2CFn>) -> Self {
        let state = Arc::new((
            Mutex::new(DdcQueueState {
                pending: HashMap::new(),
                last_sent: HashMap::new(),
                shutdown: false,
            }),
            Condvar::new(),
        ));
        let worker_state = Arc::clone(&state);
        let _ = thread::Builder::new()
            .name("aeron-ddc-writer".into())
            .spawn(move || {
                let (lock, cvar) = &*worker_state;
                loop {
                    let next_job = {
                        let mut guard = match lock.lock() {
                            Ok(g) => g,
                            Err(_) => break,
                        };
                        while guard.pending.is_empty() && !guard.shutdown {
                            guard = match cvar.wait(guard) {
                                Ok(g) => g,
                                Err(_) => return,
                            };
                        }
                        if guard.shutdown {
                            break;
                        }
                        let key = *guard.pending.keys().next().unwrap();
                        let (svc, val) = guard.pending.remove(&key).unwrap();
                        guard.last_sent.insert(key, val);
                        (key, svc, val)
                    };

                    let ((_display_id, vcp), svc, val) = next_job;
                    if let Some(write_fn) = av_write {
                        let mut pkt = ddc::set_vcp_packet(vcp, val);
                        unsafe {
                            let _ = write_fn(
                                svc.0,
                                ddc::CHIP_ADDRESS as u32,
                                ddc::DATA_ADDRESS as u32,
                                pkt.as_mut_ptr() as *mut c_void,
                                pkt.len() as u32,
                            );
                        }
                    }
                    // MCCS inter-command spacing so monitors don't drop rapid I2C writes.
                    // Because newer values coalesce into `pending`, we never build a backlog.
                    thread::sleep(Duration::from_millis(32));
                }
            });
        Self { state }
    }

    fn enqueue(&self, display_id: CGDirectDisplayID, service: CFTypeRef, vcp: u8, value: u16) {
        let Some(retained) = RetainedCF::retain(service) else {
            return;
        };
        let (lock, cvar) = &*self.state;
        if let Ok(mut guard) = lock.lock() {
            let key = (display_id, vcp);
            // Skip duplicate writes when the quantized integer VCP value didn't change
            if guard.pending.get(&key).map(|(_, v)| *v) == Some(value) {
                return;
            }
            if !guard.pending.contains_key(&key) && guard.last_sent.get(&key) == Some(&value) {
                return;
            }
            guard.pending.insert(key, (retained, value));
            cvar.notify_one();
        }
    }

    fn clear_cache(&self) {
        let (lock, _) = &*self.state;
        if let Ok(mut guard) = lock.lock() {
            guard.last_sent.clear();
        }
    }
}

impl Drop for DdcWriteQueue {
    fn drop(&mut self) {
        let (lock, cvar) = &*self.state;
        if let Ok(mut guard) = lock.lock() {
            guard.shutdown = true;
            guard.pending.clear();
            cvar.notify_all();
        }
    }
}

struct SensorKeys {
    cpu: Vec<&'static str>,
    gpu: Vec<&'static str>,
}

impl SensorKeys {
    fn for_current_chip() -> Self {
        let brand = cpu_brand_string();
        if brand.contains("Intel") {
            return Self {
                cpu: vec!["TC0P", "TC0D", "TC0E", "TC0F"],
                gpu: vec!["TG0P", "TG0D", "TCGC"],
            };
        }
        if brand.contains("M1") {
            return Self {
                cpu: vec![
                    "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b",
                ],
                gpu: vec!["Tg05", "Tg0D", "Tg0L", "Tg0T"],
            };
        }
        if brand.contains("M2") {
            return Self {
                cpu: vec![
                    "Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b",
                    "Tp0f", "Tp0j",
                ],
                gpu: vec!["Tg0f", "Tg0j"],
            };
        }
        if brand.contains("M3") {
            return Self {
                cpu: vec![
                    "Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
                    "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E",
                ],
                gpu: vec!["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"],
            };
        }
        if brand.contains("M4") {
            return Self {
                cpu: vec![
                    "Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y",
                    "Tp0b", "Tp0e",
                ],
                gpu: vec![
                    "Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k",
                ],
            };
        }
        Self {
            cpu: vec![
                "Te05", "Te0S", "Te09", "Te0H", "Te0L", "Te0P", "Tp01", "Tp05", "Tp09", "Tp0D",
                "Tp0H", "Tp0L", "Tp0P", "Tp0T", "Tp0V", "Tp0X", "Tp0Y", "Tp0b", "Tp0e", "Tp0f",
                "Tp0j", "Tp1h", "Tp1l", "Tp1p", "Tp1t", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D",
            ],
            gpu: vec![
                "Tg05", "Tg0D", "Tg0L", "Tg0T", "Tg0f", "Tg0j", "Tg0G", "Tg0H", "Tg1U", "Tg1k",
                "Tg0K", "Tg0d", "Tg0e", "Tg0k", "Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28",
            ],
        }
    }
}

fn cpu_brand_string() -> String {
    let key = CString::new("machdep.cpu.brand_string").unwrap();
    let mut size: usize = 0;
    unsafe {
        sysctlbyname(
            key.as_ptr(),
            std::ptr::null_mut(),
            &mut size,
            std::ptr::null(),
            0,
        );
    }
    if size == 0 {
        return String::new();
    }
    let mut buf = vec![0u8; size];
    unsafe {
        sysctlbyname(
            key.as_ptr(),
            buf.as_mut_ptr() as *mut c_void,
            &mut size,
            std::ptr::null(),
            0,
        );
    }
    CStr::from_bytes_until_nul(&buf)
        .ok()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default()
}

// MARK: - MacosBackend

pub struct MacosBackend {
    smc: std::sync::Mutex<Option<SmcClient>>,
    sensor_keys: SensorKeys,
    fns: PrivateDisplayFns,
    ddc_queue: DdcWriteQueue,
    av_services: Vec<AVServiceEntry>,
    /// External displays online when `av_services` was discovered, and when.
    av_services_for: Vec<CGDirectDisplayID>,
    av_services_at: Option<std::time::Instant>,
    cached_displays: Vec<ExternalDisplayInfo>,
    builtin_display_id: Option<CGDirectDisplayID>,
    saved_panel_id: Option<CGDirectDisplayID>,
    saved_builtin_brightness: f32,
    is_builtin_turned_off: bool,
    real_external_ids: Vec<CGDirectDisplayID>,
    last_seen_external_ids: Vec<CGDirectDisplayID>,
    previous_external_count: usize,
    caffeinate_child: Option<Child>,
    game_mode_policy: GameModePolicy,
}

impl Default for MacosBackend {
    fn default() -> Self {
        Self::new()
    }
}

impl MacosBackend {
    pub fn new() -> Self {
        let fns = PrivateDisplayFns::load();
        let ddc_queue = DdcWriteQueue::new(fns.av_write);
        let mut backend = Self {
            smc: std::sync::Mutex::new(SmcClient::open()),
            sensor_keys: SensorKeys::for_current_chip(),
            fns,
            ddc_queue,
            av_services: Vec::new(),
            av_services_for: Vec::new(),
            av_services_at: None,
            cached_displays: Vec::new(),
            builtin_display_id: None,
            saved_panel_id: None,
            saved_builtin_brightness: 0.75,
            is_builtin_turned_off: false,
            real_external_ids: Vec::new(),
            last_seen_external_ids: Vec::new(),
            previous_external_count: 0,
            caffeinate_child: None,
            game_mode_policy: GameModePolicy::Automatic,
        };
        backend.refresh_displays();
        backend
    }

    fn online_display_ids() -> Vec<CGDirectDisplayID> {
        let mut ids = [0u32; 32];
        let mut count = 0u32;
        unsafe {
            CGGetOnlineDisplayList(32, ids.as_mut_ptr(), &mut count);
        }
        ids[..count as usize]
            .iter()
            .copied()
            .filter(|&id| unsafe { CGDisplayIsOnline(id) } != 0)
            .collect()
    }

    fn find_builtin_display_id(&self) -> Option<CGDirectDisplayID> {
        for id in Self::online_display_ids() {
            if unsafe { CGDisplayIsBuiltin(id) } != 0 {
                return Some(id);
            }
        }
        if let Some(list_fn) = self.fns.sls_get_display_list {
            let mut list = [0u32; 32];
            let mut count = 0u32;
            if unsafe { list_fn(32, list.as_mut_ptr(), &mut count) } == 0 {
                for &id in &list[..count as usize] {
                    if unsafe { CGDisplayIsBuiltin(id) } != 0 {
                        return Some(id);
                    }
                }
            }
        }
        None
    }

    fn external_display_ids(&self) -> Vec<CGDirectDisplayID> {
        Self::online_display_ids()
            .into_iter()
            .filter(|&id| {
                Some(id) != self.builtin_display_id
                    && Some(id) != self.saved_panel_id
                    && unsafe { CGDisplayIsBuiltin(id) } == 0
                    && is_display_active(id)
            })
            .collect()
    }

    fn set_display_enabled(&self, display_id: CGDirectDisplayID, enabled: bool) -> bool {
        let Some(configure_fn) = self.fns.sls_configure_display_enabled else {
            warn!("SLSConfigureDisplayEnabled not available");
            return false;
        };
        if enabled && is_display_active(display_id) {
            return true;
        }
        let mut config: CGDisplayConfigRef = std::ptr::null_mut();
        let begin_status = unsafe { CGBeginDisplayConfiguration(&mut config) };
        if begin_status != 0 || config.is_null() {
            warn!("CGBeginDisplayConfiguration failed: {begin_status}");
            return false;
        }
        let cfg_status = unsafe { configure_fn(config, display_id, enabled) };
        if cfg_status != 0 {
            warn!("SLSConfigureDisplayEnabled({display_id}, {enabled}) failed: {cfg_status}");
            unsafe { CGCancelDisplayConfiguration(config) };
            return false;
        }
        // kCGConfigureForSession so a disabled panel always recovers on logout/reboot.
        let complete_status =
            unsafe { CGCompleteDisplayConfiguration(config, K_CG_CONFIGURE_FOR_SESSION) };
        if complete_status != 0 {
            warn!("CGCompleteDisplayConfiguration failed: {complete_status}");
            unsafe { CGCancelDisplayConfiguration(config) };
            return false;
        }
        info!("macOS display {display_id} {}", if enabled { "enabled" } else { "disabled" });
        true
    }

    fn turn_off_builtin_display(&mut self) -> Result<(), String> {
        let Some(panel_id) = self
            .saved_panel_id
            .or(self.builtin_display_id)
            .or_else(|| self.find_builtin_display_id())
        else {
            return Err("No built-in display detected".to_string());
        };
        self.builtin_display_id = Some(panel_id);

        let externals = self.external_display_ids();
        if externals.is_empty() {
            return Err(
                "Cannot turn off built-in display when no external monitor is active".to_string(),
            );
        }

        if let Some(get_fn) = self.fns.ds_get_brightness {
            let mut br = 0.0f32;
            if unsafe { get_fn(panel_id, &mut br) } == 0 && br > 0.05 {
                self.saved_builtin_brightness = br.clamp(0.05, 1.0);
            }
        }

        self.real_external_ids = externals;

        if self.set_display_enabled(panel_id, false) {
            self.saved_panel_id = Some(panel_id);
            self.is_builtin_turned_off = true;
            Ok(())
        } else {
            Err("macOS rejected disabling the built-in display".to_string())
        }
    }

    fn turn_on_builtin_display(&mut self) -> Result<(), String> {
        let mut candidates = Vec::new();
        for id in [
            self.saved_panel_id,
            self.builtin_display_id,
            self.find_builtin_display_id(),
        ]
        .into_iter()
        .flatten()
        {
            if !candidates.contains(&id) {
                candidates.push(id);
            }
        }

        if candidates.is_empty() {
            self.is_builtin_turned_off = false;
            return Ok(());
        }

        let restore_level = if self.saved_builtin_brightness > 0.05 {
            self.saved_builtin_brightness
        } else {
            0.75
        };

        let mut ok = true;
        for id in candidates {
            if !is_display_active(id) {
                if !self.set_display_enabled(id, true) {
                    ok = false;
                }
                thread::sleep(Duration::from_millis(50));
            }
            if let Some(set_fn) = self.fns.ds_set_brightness {
                unsafe {
                    let _ = set_fn(id, restore_level);
                }
            }
        }

        self.saved_panel_id = None;
        self.is_builtin_turned_off = false;
        if ok {
            Ok(())
        } else {
            Err("Failed re-enabling built-in display".to_string())
        }
    }

    /// Exact port of Swift `DisplayStateModel.restoreIfRealExternalsGone`:
    /// Unplugging the last external monitor makes macOS spawn a placeholder display,
    /// so we track real external IDs seen while the panel was on and restore immediately
    /// as soon as none of those real externals remain active.
    fn restore_if_real_externals_gone(&mut self) -> bool {
        let Some(panel_id) = self.saved_panel_id.or(self.builtin_display_id) else {
            return false;
        };
        if is_display_active(panel_id) {
            self.is_builtin_turned_off = false;
            self.saved_panel_id = None;
            return false;
        }
        if !self.real_external_ids.is_empty()
            && !self
                .real_external_ids
                .iter()
                .any(|&id| is_display_active(id))
        {
            info!("All external displays disconnected; restoring built-in display");
            let _ = self.turn_on_builtin_display();
            return true;
        }
        false
    }

    fn discover_av_services(&self) -> Vec<AVServiceEntry> {
        let Some(create_fn) = self.fns.av_create else {
            return Vec::new();
        };
        let mut iterator: IoIteratorT = 0;
        let class_name = CString::new("DCPAVServiceProxy").unwrap();
        let ret = unsafe {
            IOServiceGetMatchingServices(
                K_IO_MAIN_PORT_DEFAULT,
                IOServiceMatching(class_name.as_ptr()),
                &mut iterator,
            )
        };
        if ret != KERN_SUCCESS {
            return Vec::new();
        }
        let mut out = Vec::new();
        loop {
            let entry = unsafe { IOIteratorNext(iterator) };
            if entry == 0 {
                break;
            }
            let location = read_cf_string_prop(entry, "Location");
            if location.as_deref() == Some("External") {
                let svc = unsafe { create_fn(std::ptr::null(), entry) };
                if !svc.is_null() {
                    let identity = read_ancestor_identity(entry).unwrap_or(ddc::MonitorIdentity {
                        vendor: 0,
                        model: 0,
                        serial: 0,
                    });
                    out.push(AVServiceEntry {
                        identity,
                        service: svc,
                    });
                }
            }
            unsafe { IOObjectRelease(entry) };
        }
        unsafe { IOObjectRelease(iterator) };
        out
    }

    fn rediscover_av_services(&mut self) {
        self.av_services = self.discover_av_services();
        self.av_services_for = self.external_display_ids();
        self.av_services_at = Some(std::time::Instant::now());
    }

    /// The service for a write. Rediscovers when displays changed, or when the last discovery is a
    /// few seconds old: a monitor that slept or replugged keeps its display ID but gets a new
    /// service, and the write dedup must not drop a value the monitor's own buttons changed since.
    /// A slider drag stays on one discovery.
    fn av_service_for_write(&mut self, display_id: CGDirectDisplayID) -> Option<CFTypeRef> {
        let changed = self.external_display_ids() != self.av_services_for;
        let stale = self
            .av_services_at
            .is_none_or(|at| at.elapsed() > Duration::from_secs(3));
        if changed || stale {
            self.rediscover_av_services();
            self.ddc_queue.clear_cache();
        }
        self.av_service_for(display_id)
    }

    fn av_service_for(&self, display_id: CGDirectDisplayID) -> Option<CFTypeRef> {
        if self.av_services.is_empty() {
            return None;
        }
        let identity = ddc::MonitorIdentity {
            vendor: unsafe { CGDisplayVendorNumber(display_id) },
            model: unsafe { CGDisplayModelNumber(display_id) },
            serial: unsafe { CGDisplaySerialNumber(display_id) },
        };
        let matches: Vec<&AVServiceEntry> = self
            .av_services
            .iter()
            .filter(|e| e.identity == identity)
            .collect();
        if matches.len() == 1 {
            return Some(matches[0].service);
        }
        if self.av_services.len() == 1 {
            return Some(self.av_services[0].service);
        }
        matches.first().map(|e| e.service)
    }

    fn ddc_read(&self, service: CFTypeRef, vcp: u8) -> Option<ddc::VcpValue> {
        let (write_fn, read_fn) = (self.fns.av_write?, self.fns.av_read?);
        for _ in 0..3 {
            let mut pkt = ddc::get_vcp_packet(vcp);
            let w = unsafe {
                write_fn(
                    service,
                    ddc::CHIP_ADDRESS as u32,
                    ddc::DATA_ADDRESS as u32,
                    pkt.as_mut_ptr() as *mut c_void,
                    pkt.len() as u32,
                )
            };
            if w != 0 {
                thread::sleep(Duration::from_millis(40));
                continue;
            }
            thread::sleep(Duration::from_millis(40));
            let mut reply = [0u8; 12];
            let r = unsafe {
                read_fn(
                    service,
                    ddc::CHIP_ADDRESS as u32,
                    ddc::DATA_ADDRESS as u32,
                    reply.as_mut_ptr() as *mut c_void,
                    reply.len() as u32,
                )
            };
            if r == 0 {
                if let Some(val) = ddc::parse_vcp_reply(&reply, vcp) {
                    return Some(val);
                }
            }
            thread::sleep(Duration::from_millis(40));
        }
        None
    }
}

impl Drop for MacosBackend {
    fn drop(&mut self) {
        if self.is_builtin_turned_off {
            let _ = self.turn_on_builtin_display();
        }
        if let Some(mut child) = self.caffeinate_child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

impl PlatformBackend for MacosBackend {
    fn platform_name(&self) -> &'static str {
        "macos"
    }

    fn is_steamos(&self) -> bool {
        false
    }

    fn refresh_displays(&mut self) -> Vec<ExternalDisplayInfo> {
        if let Some(builtin) = self.find_builtin_display_id() {
            self.builtin_display_id = Some(builtin);
        }

        self.rediscover_av_services();
        self.ddc_queue.clear_cache();
        let display_names = discover_macos_display_names();
        let external_ids = self.external_display_ids();

        let mut out = Vec::new();
        for &id in &external_ids {
            let identity = ddc::MonitorIdentity {
                vendor: unsafe { CGDisplayVendorNumber(id) },
                model: unsafe { CGDisplayModelNumber(id) },
                serial: unsafe { CGDisplaySerialNumber(id) },
            };

            let name = display_names
                .get(&(identity.vendor, identity.model))
                .cloned()
                .unwrap_or_else(|| format!("External Display ({:04X})", identity.model));

            let svc = self.av_service_for(id);
            let has_hw = svc.is_some();
            let brightness = svc
                .and_then(|s| self.ddc_read(s, ddc::vcp::BRIGHTNESS))
                .map(|v| {
                    if v.max > 0 {
                        (v.current as f32 / v.max as f32).clamp(0.0, 1.0)
                    } else {
                        0.75
                    }
                })
                .unwrap_or(0.75);
            let volume = svc
                .and_then(|s| self.ddc_read(s, ddc::vcp::AUDIO_SPEAKER_VOLUME))
                .map(|v| {
                    if v.max > 0 {
                        (v.current as f32 / v.max as f32).clamp(0.0, 1.0)
                    } else {
                        0.5
                    }
                })
                .unwrap_or(0.5);
            let current_input = svc
                .and_then(|s| self.ddc_read(s, ddc::vcp::INPUT_SOURCE))
                .map(|v| v.current as u8);

            let input_sources = vec![0x0F, 0x10, 0x11, 0x12, 0x1B]
                .into_iter()
                .map(|code| InputSourceOption {
                    code,
                    name: ddc::input_source_name(code),
                })
                .collect();

            out.push(ExternalDisplayInfo {
                id: format!("cg-{id}"),
                settings_key: identity.key(),
                name,
                brightness,
                volume,
                is_muted: false,
                extra_dimming: 1.0,
                input_sources,
                current_input,
                has_hardware_control: has_hw,
                is_builtin: false,
                is_enabled: true,
            });
        }

        if let Some(panel_id) = self.saved_panel_id.or(self.builtin_display_id) {
            self.is_builtin_turned_off = !is_display_active(panel_id);
        }
        if !self.is_builtin_turned_off || self.real_external_ids.is_empty() {
            self.real_external_ids = external_ids.clone();
        }
        self.last_seen_external_ids = external_ids.clone();
        self.previous_external_count = external_ids.len();

        self.cached_displays = out.clone();
        out
    }

    fn builtin_display_state(&self) -> BuiltinDisplayState {
        let present = self.saved_panel_id.is_some() || self.builtin_display_id.is_some();
        let is_turned_off = if let Some(panel_id) = self.saved_panel_id.or(self.builtin_display_id)
        {
            !is_display_active(panel_id)
        } else {
            self.is_builtin_turned_off
        };
        let can_turn_off = present && !self.cached_displays.is_empty();
        BuiltinDisplayState {
            present,
            is_turned_off,
            can_turn_off,
        }
    }

    fn set_builtin_display_enabled(&mut self, enabled: bool) -> Result<(), String> {
        let res = if enabled {
            self.turn_on_builtin_display()
        } else {
            self.turn_off_builtin_display()
        };
        self.refresh_displays();
        res
    }

    fn apply_auto_turn_off_preference(&mut self, auto_turn_off_builtin: bool) {
        if auto_turn_off_builtin {
            let has_externals = !self.external_display_ids().is_empty();
            if has_externals && !self.builtin_display_state().is_turned_off {
                let _ = self.turn_off_builtin_display();
                self.refresh_displays();
            }
        } else if self.builtin_display_state().is_turned_off {
            let _ = self.turn_on_builtin_display();
            self.refresh_displays();
        }
    }

    fn poll_display_topology(&mut self, auto_turn_off_builtin: bool) {
        if self.builtin_display_id.is_none() {
            self.builtin_display_id = self.find_builtin_display_id();
        }

        // 1. If the built-in display is turned off, immediately restore it as soon as all real
        //    external monitors disconnect (ignoring macOS's synthetic placeholder display).
        if self.restore_if_real_externals_gone() {
            self.refresh_displays();
            return;
        }

        // 2. Cheaply inspect active external display IDs (zero DDC I2C overhead unless changed).
        let current_externals = self.external_display_ids();
        let is_off = self.builtin_display_state().is_turned_off;
        self.is_builtin_turned_off = is_off;

        if !is_off {
            self.real_external_ids = current_externals.clone();
        }

        if current_externals != self.last_seen_external_ids {
            let prev_count = self.previous_external_count;
            let new_count = current_externals.len();
            self.refresh_displays();

            if auto_turn_off_builtin && prev_count == 0 && new_count > 0 && !is_off {
                info!("External monitor connected; automatically turning off built-in display");
                let _ = self.turn_off_builtin_display();
                self.refresh_displays();
            }
        }
    }

    fn displays(&self) -> Vec<ExternalDisplayInfo> {
        self.cached_displays.clone()
    }

    fn set_display_brightness(&mut self, display_id: &str, level: f32) -> Result<(), String> {
        let clamped = level.clamp(0.0, 1.0);
        if let Some(cg_id) = parse_cg_id(display_id) {
            let is_builtin = unsafe { CGDisplayIsBuiltin(cg_id) } != 0;
            if is_builtin {
                if let Some(set_fn) = self.fns.ds_set_brightness {
                    unsafe {
                        let _ = set_fn(cg_id, clamped);
                    }
                }
            } else if let Some(svc) = self.av_service_for_write(cg_id) {
                let val = (clamped * 100.0).round() as u16;
                self.ddc_queue.enqueue(cg_id, svc, ddc::vcp::BRIGHTNESS, val);
            }
        }
        if let Some(d) = self.cached_displays.iter_mut().find(|d| d.id == display_id) {
            d.brightness = clamped;
        }
        Ok(())
    }

    fn set_display_volume(&mut self, display_id: &str, level: f32) -> Result<(), String> {
        let clamped = level.clamp(0.0, 1.0);
        if let Some(cg_id) = parse_cg_id(display_id) {
            if let Some(svc) = self.av_service_for_write(cg_id) {
                let val = (clamped * 100.0).round() as u16;
                self.ddc_queue
                    .enqueue(cg_id, svc, ddc::vcp::AUDIO_SPEAKER_VOLUME, val);
            }
        }
        if let Some(d) = self.cached_displays.iter_mut().find(|d| d.id == display_id) {
            d.volume = clamped;
        }
        Ok(())
    }

    fn set_display_muted(&mut self, display_id: &str, muted: bool) -> Result<(), String> {
        if let Some(cg_id) = parse_cg_id(display_id) {
            if let Some(svc) = self.av_service_for_write(cg_id) {
                self.ddc_queue
                    .enqueue(cg_id, svc, ddc::vcp::AUDIO_MUTE, if muted { 1 } else { 2 });
            }
        }
        if let Some(d) = self.cached_displays.iter_mut().find(|d| d.id == display_id) {
            d.is_muted = muted;
        }
        Ok(())
    }

    fn set_display_input(&mut self, display_id: &str, input_code: u8) -> Result<(), String> {
        if let Some(cg_id) = parse_cg_id(display_id) {
            if let Some(svc) = self.av_service_for_write(cg_id) {
                self.ddc_queue
                    .enqueue(cg_id, svc, ddc::vcp::INPUT_SOURCE, input_code as u16);
            }
        }
        if let Some(d) = self.cached_displays.iter_mut().find(|d| d.id == display_id) {
            d.current_input = Some(input_code);
        }
        Ok(())
    }

    fn set_caffeine_active(&mut self, active: bool) -> Result<(), String> {
        if active {
            if self.caffeinate_child.is_none() {
                let child = Command::new("/usr/bin/caffeinate")
                    .args(["-di"])
                    .stdin(Stdio::null())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .spawn()
                    .map_err(|e| format!("Failed starting caffeinate: {e}"))?;
                self.caffeinate_child = Some(child);
            }
        } else if let Some(mut child) = self.caffeinate_child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        Ok(())
    }

    fn read_thermals(&self) -> ThermalSnapshot {
        let mut smc_guard = self.smc.lock().expect("smc mutex");

        let avg = |smc: &mut SmcClient, keys: &[&str]| -> Option<f64> {
            let vals: Vec<f64> = keys
                .iter()
                .filter_map(|k| smc.read_value(k))
                .filter(|&v| (10.0..=120.0).contains(&v))
                .collect();
            if vals.is_empty() {
                None
            } else {
                Some(vals.iter().sum::<f64>() / vals.len() as f64)
            }
        };

        let mut cpu_celsius = None;
        let mut gpu_celsius = None;
        let mut smc_battery_celsius = None;
        let mut fans = Vec::new();

        if let Some(smc) = smc_guard.as_mut() {
            cpu_celsius = avg(smc, &self.sensor_keys.cpu);
            gpu_celsius = avg(smc, &self.sensor_keys.gpu);
            smc_battery_celsius = avg(smc, &["TB0T", "TB1T", "TB2T"]);

            let fan_count = smc.read_value("FNum").unwrap_or(0.0).round() as usize;
            for i in 0..fan_count {
                if let Some(rpm) = smc.read_value(&format!("F{i}Ac")) {
                    let max_rpm = smc
                        .read_value(&format!("F{i}Mx"))
                        .map(|v| v.max(0.0).round() as u32);
                    fans.push(FanReading {
                        index: i,
                        name: if fan_count > 1 {
                            format!("Fan {}", i + 1)
                        } else {
                            "Fan".into()
                        },
                        rpm: rpm.max(0.0).round() as u32,
                        max_rpm,
                    });
                }
            }
        }
        drop(smc_guard);

        let mut battery_celsius = read_smart_battery_dict()
            .and_then(|dict| {
                dict_i64(&dict, "Temperature")
                    .filter(|&v| v > 0)
                    .map(|v| v as f64 / 100.0)
            })
            .or(smc_battery_celsius);

        // Fallback to Apple Silicon IOHIDEventSystemClient thermal sensors whenever SMC keys are unavailable
        if cpu_celsius.is_none() || gpu_celsius.is_none() || battery_celsius.is_none() {
            let (hid_cpu, hid_gpu, hid_bat) = read_hid_temperatures();
            if cpu_celsius.is_none() {
                cpu_celsius = hid_cpu;
            }
            if gpu_celsius.is_none() {
                gpu_celsius = hid_gpu;
            }
            if battery_celsius.is_none() {
                battery_celsius = hid_bat;
            }
        }

        let peak = cpu_celsius
            .into_iter()
            .chain(gpu_celsius)
            .fold(0.0_f64, f64::max);
        let pressure = if peak >= 95.0 {
            ThermalPressure::Critical
        } else if peak >= 85.0 {
            ThermalPressure::Serious
        } else if peak >= 72.0 {
            ThermalPressure::Fair
        } else {
            ThermalPressure::Nominal
        };

        ThermalSnapshot {
            supported: cpu_celsius.is_some()
                || gpu_celsius.is_some()
                || battery_celsius.is_some()
                || !fans.is_empty(),
            pressure,
            cpu_celsius,
            gpu_celsius,
            battery_celsius,
            fans,
        }
    }

    fn read_wattage(&self) -> WattageSnapshot {
        let mut smc_guard = self.smc.lock().expect("smc mutex");
        let live_system_watts = smc_guard
            .as_mut()
            .and_then(|s| s.read_value("PSTR"))
            .filter(|&v| v > 0.0);
        let live_input_watts = smc_guard
            .as_mut()
            .and_then(|s| s.read_value("PDTR"))
            .filter(|&v| v > 0.0);
        drop(smc_guard);

        let Some(dict) = read_smart_battery_dict() else {
            return WattageSnapshot {
                supported: live_system_watts.is_some(),
                is_plugged_in: true,
                is_charging: false,
                battery_level: None,
                system_load_watts: live_system_watts,
                input_watts: live_input_watts,
                adapter_watts: None,
                battery_watts: None,
                voltage: None,
                amperage: None,
                battery_health_percent: None,
                cycle_count: None,
            };
        };

        let is_plugged_in = dict_bool(&dict, "ExternalConnected").unwrap_or(false)
            || dict_i64(&dict, "AppleRawExternalConnected") == Some(1);
        let is_charging = dict_bool(&dict, "IsCharging").unwrap_or(false);
        let battery_level = dict_i64(&dict, "CurrentCapacity").map(|v| v.clamp(0, 100) as u8);

        let raw_voltage = dict_f64(&dict, "Voltage")
            .or_else(|| dict_f64(&dict, "AppleRawBatteryVoltage"))
            .unwrap_or(0.0);
        let voltage = (raw_voltage > 0.0).then_some(raw_voltage / 1000.0);

        let raw_amp = dict_f64(&dict, "InstantAmperage")
            .or_else(|| dict_f64(&dict, "Amperage"))
            .unwrap_or(0.0);
        let amperage = Some(raw_amp / 1000.0);

        let telemetry = dict.get("PowerTelemetryData").and_then(|v| v.as_dictionary());
        let mut battery_watts = telemetry
            .and_then(|t| dict_f64(t, "BatteryPower"))
            .map(|mw| mw / 1000.0);
        if battery_watts.is_none() {
            if let (Some(v), Some(a)) = (voltage, amperage) {
                battery_watts = Some((if is_charging { 1.0 } else { -1.0 }) * (v * a).abs());
            }
        }

        // Exact WattageManager.swift logic: live SMC PSTR is total system load; on battery it equals discharge.
        if !is_plugged_in {
            if let Some(live) = live_system_watts {
                battery_watts = Some(-live);
            }
        }

        let mut system_load_watts = live_system_watts;
        if system_load_watts.is_none() {
            system_load_watts = telemetry
                .and_then(|t| dict_f64(t, "SystemLoad"))
                .map(|mw| mw / 1000.0);
        }
        if system_load_watts.is_none() && !is_plugged_in {
            system_load_watts = battery_watts.map(|w| w.abs());
        }

        let mut input_watts = if is_plugged_in { live_input_watts } else { None };
        if input_watts.is_none() && is_plugged_in {
            input_watts = dict
                .get("PowerDistribution")
                .and_then(|v| v.as_dictionary())
                .and_then(|d| dict_f64(d, "IPDInputPower"))
                .map(|mw| mw / 1000.0)
                .or_else(|| {
                    telemetry
                        .and_then(|t| dict_f64(t, "SystemPowerIn"))
                        .map(|mw| mw / 1000.0)
                });
        }

        let adapter_watts = dict
            .get("AdapterDetails")
            .and_then(|v| v.as_dictionary())
            .and_then(|a| dict_i64(a, "Watts"))
            .map(|w| w as u32);

        let battery_data = dict.get("BatteryData").and_then(|v| v.as_dictionary());
        let nominal = battery_data
            .and_then(|b| dict_i64(b, "NominalChargeCapacity"))
            .or_else(|| dict_i64(&dict, "NominalChargeCapacity"))
            .or_else(|| dict_i64(&dict, "AppleRawMaxCapacity"));
        let design = battery_data
            .and_then(|b| dict_i64(b, "DesignCapacity"))
            .or_else(|| dict_i64(&dict, "DesignCapacity"));
        let battery_health_percent = match (nominal, design) {
            (Some(n), Some(d)) if n > 0 && d > 0 => {
                Some(((n as f64 / d as f64) * 100.0).round().clamp(0.0, 100.0) as u8)
            }
            _ => None,
        };
        let cycle_count = dict_i64(&dict, "CycleCount").map(|c| c.max(0) as u32);

        WattageSnapshot {
            supported: true,
            is_plugged_in,
            is_charging,
            battery_level,
            system_load_watts,
            input_watts,
            adapter_watts,
            battery_watts,
            voltage,
            amperage,
            battery_health_percent,
            cycle_count,
        }
    }

    fn read_game_mode(&self) -> GameModeState {
        if let Some(output) = run_gamepolicyctl(&["game-mode", "status"]) {
            let lower = strip_ansi(&output).to_ascii_lowercase();
            let is_active = lower.contains("game mode is on");
            let policy = if lower.contains("forced always on") {
                GameModePolicy::ForcedOn
            } else if lower.contains("forced always off") || lower.contains("currently disabled") {
                GameModePolicy::ForcedOff
            } else {
                GameModePolicy::Automatic
            };
            return GameModeState {
                supported: true,
                is_active,
                policy,
                backend_name: "macOS Game Mode".into(),
            };
        }
        GameModeState {
            supported: false,
            is_active: false,
            policy: self.game_mode_policy,
            backend_name: "macOS Game Mode".into(),
        }
    }

    fn set_game_mode_policy(&mut self, policy: GameModePolicy) -> Result<GameModeState, String> {
        self.game_mode_policy = policy;
        let arg = match policy {
            GameModePolicy::Automatic => "auto",
            GameModePolicy::ForcedOn => "on",
            GameModePolicy::ForcedOff => "off",
        };
        let _ = run_gamepolicyctl(&["game-mode", "set", arg]);
        Ok(self.read_game_mode())
    }

    fn read_dock_layouts(&self) -> (DockLayout, DockLayout) {
        crate::macos_dock::scan_macos_usb_docks()
    }
}

// MARK: - Helpers

fn parse_cg_id(display_id: &str) -> Option<CGDirectDisplayID> {
    display_id.strip_prefix("cg-")?.parse::<u32>().ok()
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
            Some(
                unsafe { CStr::from_ptr(buf.as_ptr()) }
                    .to_string_lossy()
                    .into_owned(),
            )
        } else {
            None
        }
    } else {
        None
    };
    unsafe { CFRelease(val) };
    result
}

fn read_ancestor_identity(entry: IoObjectT) -> Option<ddc::MonitorIdentity> {
    let plane = CString::new("IOService").unwrap();
    let attr_key = CString::new("DisplayAttributes").unwrap();
    let prod_key = CString::new("ProductAttributes").unwrap();
    let mfg_key = CString::new("LegacyManufacturerID").unwrap();
    let model_key = CString::new("ProductID").unwrap();
    let serial_key = CString::new("SerialNumber").unwrap();

    unsafe {
        let cf_attr = CFStringCreateWithCString(
            std::ptr::null(),
            attr_key.as_ptr(),
            K_CF_STRING_ENCODING_UTF8,
        );
        let cf_prod = CFStringCreateWithCString(
            std::ptr::null(),
            prod_key.as_ptr(),
            K_CF_STRING_ENCODING_UTF8,
        );
        let cf_mfg = CFStringCreateWithCString(
            std::ptr::null(),
            mfg_key.as_ptr(),
            K_CF_STRING_ENCODING_UTF8,
        );
        let cf_model = CFStringCreateWithCString(
            std::ptr::null(),
            model_key.as_ptr(),
            K_CF_STRING_ENCODING_UTF8,
        );
        let cf_serial = CFStringCreateWithCString(
            std::ptr::null(),
            serial_key.as_ptr(),
            K_CF_STRING_ENCODING_UTF8,
        );

        let mut current = entry;
        IOObjectRetain(current);
        let mut found = None;

        for _ in 0..12 {
            let val = IORegistryEntryCreateCFProperty(current, cf_attr, std::ptr::null(), 0);
            if !val.is_null() {
                if CFGetTypeID(val) == CFDictionaryGetTypeID() {
                    let prod = CFDictionaryGetValue(val, cf_prod);
                    if !prod.is_null() && CFGetTypeID(prod) == CFDictionaryGetTypeID() {
                        let vendor = cf_dict_u32(prod, cf_mfg).unwrap_or(0);
                        let model = cf_dict_u32(prod, cf_model).unwrap_or(0);
                        let serial = cf_dict_u32(prod, cf_serial).unwrap_or(0);
                        found = Some(ddc::MonitorIdentity {
                            vendor,
                            model,
                            serial,
                        });
                    }
                }
                CFRelease(val);
                if found.is_some() {
                    break;
                }
            }
            let mut parent: IoObjectT = 0;
            if IORegistryEntryGetParentEntry(current, plane.as_ptr(), &mut parent) != KERN_SUCCESS {
                break;
            }
            IOObjectRelease(current);
            current = parent;
        }

        IOObjectRelease(current);
        CFRelease(cf_attr);
        CFRelease(cf_prod);
        CFRelease(cf_mfg);
        CFRelease(cf_model);
        CFRelease(cf_serial);
        found
    }
}

unsafe fn cf_dict_u32(dict: CFDictionaryRef, key: CFStringRef) -> Option<u32> {
    let v = CFDictionaryGetValue(dict, key);
    if v.is_null() || CFGetTypeID(v) != CFNumberGetTypeID() {
        return None;
    }
    let mut out: i64 = 0;
    if CFNumberGetValue(v, 4, (&mut out as *mut i64) as *mut c_void) != 0 {
        Some(out as u32)
    } else {
        None
    }
}

fn read_smart_battery_dict() -> Option<plist::Dictionary> {
    let out = Command::new("/usr/sbin/ioreg")
        .args(["-r", "-c", "AppleSmartBattery", "-a"])
        .output()
        .ok()?;
    if !out.status.success() || out.stdout.is_empty() {
        return None;
    }
    let val = PlistValue::from_reader_xml(out.stdout.as_slice()).ok()?;
    let arr = val.as_array()?;
    arr.first()?.as_dictionary().cloned()
}

fn discover_macos_display_names() -> HashMap<(u32, u32), String> {
    let mut map = HashMap::new();
    for cls in ["AppleCLCD2", "IOMobileFramebufferShim", "IODisplayConnect"] {
        let Ok(out) = Command::new("/usr/sbin/ioreg")
            .args(["-r", "-c", cls, "-a"])
            .output()
        else {
            continue;
        };
        if let Ok(PlistValue::Array(items)) = PlistValue::from_reader_xml(out.stdout.as_slice()) {
            for item in items {
                if let Some(dict) = item.as_dictionary() {
                    if let Some(attrs) = dict
                        .get("DisplayAttributes")
                        .and_then(|v| v.as_dictionary())
                        .and_then(|d| d.get("ProductAttributes"))
                        .and_then(|v| v.as_dictionary())
                    {
                        let vendor = dict_i64(attrs, "LegacyManufacturerID").unwrap_or(0) as u32;
                        let model = dict_i64(attrs, "ProductID").unwrap_or(0) as u32;
                        if let Some(name) = attrs.get("ProductName").and_then(|v| v.as_string()) {
                            if !name.trim().is_empty() {
                                map.entry((vendor, model))
                                    .or_insert_with(|| name.trim().to_string());
                            }
                        }
                    }
                }
            }
        }
    }
    map
}

fn run_gamepolicyctl(args: &[&str]) -> Option<String> {
    let paths = [
        "/Applications/Xcode.app/Contents/Developer/usr/bin/gamepolicyctl",
        "/Library/Developer/CommandLineTools/usr/bin/gamepolicyctl",
        "/usr/libexec/gamepolicyctl",
    ];
    for p in paths {
        if std::path::Path::new(p).exists() {
            if let Ok(out) = Command::new(p).args(args).output() {
                let text = format!(
                    "{}{}",
                    String::from_utf8_lossy(&out.stdout),
                    String::from_utf8_lossy(&out.stderr)
                );
                if !text.trim().is_empty() {
                    return Some(text);
                }
            }
        }
    }
    debug!("gamepolicyctl not found");
    None
}

fn strip_ansi(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut chars = input.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\x1B' && chars.peek() == Some(&'[') {
            chars.next();
            for nc in chars.by_ref() {
                if nc.is_ascii_alphabetic() {
                    break;
                }
            }
        } else {
            out.push(c);
        }
    }
    out
}

fn dict_bool(dict: &plist::Dictionary, key: &str) -> Option<bool> {
    dict.get(key).and_then(|v| v.as_boolean())
}

fn dict_i64(dict: &plist::Dictionary, key: &str) -> Option<i64> {
    dict.get(key).and_then(|v| {
        v.as_signed_integer()
            .or_else(|| v.as_unsigned_integer().map(|u| u as i64))
    })
}

fn dict_f64(dict: &plist::Dictionary, key: &str) -> Option<f64> {
    dict.get(key).and_then(|v| {
        v.as_real()
            .or_else(|| v.as_signed_integer().map(|i| i as f64))
            // AppleSmartBattery encodes negative InstantAmperage / BatteryPower as 64-bit two's complement u64
            .or_else(|| v.as_unsigned_integer().map(|u| (u as i64) as f64))
            .or_else(|| v.as_string().and_then(|s| s.parse::<f64>().ok()))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn smc_param_struct_is_80_bytes() {
        assert_eq!(std::mem::size_of::<SmcParamStruct>(), 80);
    }

    #[test]
    #[ignore]
    fn live_macos_hardware_probe() {
        let backend = MacosBackend::new();
        println!("DISPLAYS: {:#?}", backend.displays());
        println!("WATTAGE:  {:#?}", backend.read_wattage());
        println!("THERMALS: {:#?}", backend.read_thermals());
        println!("GAMEMODE: {:#?}", backend.read_game_mode());
    }
}
