use aeron_platform::hid_devices::HidManager;
use aeron_protocols::hidpp;
use aeron_protocols::keychron;
use hidapi::HidApi;

#[test]
#[ignore]
fn live_hid_diagnostic() {
    let api = HidApi::new().expect("HidApi::new");
    println!("=== HIDAPI DEVICE LIST ===");
    for d in api.device_list() {
        let vid = d.vendor_id();
        let pid = d.product_id();
        if vid == 0x046D || vid == 0x3434 || vid == 0x1532 || vid == 0x310E {
            println!(
                "VID=0x{:04X} PID=0x{:04X} UP=0x{:04X} U=0x{:04X} iface={} prod={:?} path={:?}",
                vid,
                pid,
                d.usage_page(),
                d.usage(),
                d.interface_number(),
                d.product_string(),
                d.path()
            );

            if vid == 0x046D && (d.usage_page() == 0xFF00 || d.usage_page() == 0xFF43) {
                match api.open_path(d.path()) {
                    Ok(dev) => {
                        println!("  Opened Logitech path OK!");
                        for sub in [0x20u8, 0x40u8] {
                            let pkt = [0x10u8, 0xFF, 0x83, 0xB5, sub, 0x00, 0x00];
                            let w = dev.write(&pkt);
                            println!("  write short sub=0x{:02X} => {:?}", sub, w);
                            let mut buf = [0u8; 64];
                            let r = dev.read_timeout(&mut buf, 300);
                            println!(
                                "  read  short sub=0x{:02X} => {:?} {:02X?}",
                                sub,
                                r,
                                r.as_ref().map(|&n| &buf[..n])
                            );
                        }
                        for dev_idx in [1u8, 0xFFu8] {
                            let pkt = hidpp::get_feature_index_packet(
                                dev_idx,
                                hidpp::FEATURE_DEVICE_NAME,
                            );
                            let w = dev.write(&pkt);
                            println!("  write long idx=0x{:02X} => {:?}", dev_idx, w);
                            let mut buf = [0u8; 64];
                            let r = dev.read_timeout(&mut buf, 300);
                            println!(
                                "  read  long idx=0x{:02X} => {:?} {:02X?}",
                                dev_idx,
                                r,
                                r.as_ref().map(|&n| &buf[..n])
                            );
                        }
                    }
                    Err(e) => println!("  open_path FAILED: {e}"),
                }
            }

            if vid == 0x3434 && d.usage_page() == 0xFF0A {
                match api.open_path(d.path()) {
                    Ok(dev) => {
                        println!("  Opened Keychron path OK!");
                        for routed in [false, true] {
                            let pkt = keychron::packet(keychron::Command::POWER, routed, &[]);
                            let mut with_id = [0u8; 65];
                            with_id[0] = 0x00;
                            with_id[1..].copy_from_slice(&pkt);
                            let w = dev.write(&with_id);
                            println!("  write keychron routed={routed} (65B) => {:?}", w);
                            let mut buf = [0u8; 65];
                            let r = dev.read_timeout(&mut buf, 300);
                            println!(
                                "  read  keychron routed={routed} => {:?} {:02X?}",
                                r,
                                r.as_ref().map(|&n| &buf[..n.min(20)])
                            );
                        }
                    }
                    Err(e) => println!("  open_path FAILED: {e}"),
                }
            }
        }
    }

    println!("=== CURRENT HidManager SNAPSHOT ===");
    let mut mgr = HidManager::new();
    #[cfg(target_os = "macos")]
    {
        let (razer, satechi) = aeron_platform::macos_dock::scan_macos_usb_docks();
        println!("=== MACOS DOCK TOPOLOGY ===");
        println!("Razer: {razer:#?}");
        println!("Satechi: {satechi:#?}");
        mgr.set_dock_layouts(razer, satechi);
    }
    mgr.refresh();
    println!("{:#?}", mgr.snapshot());
}
