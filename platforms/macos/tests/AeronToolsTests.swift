import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import AeronTools

// MARK: - DDC Protocol

@Suite("DDC/CI packet framing and parsing")
struct DDCProtocolTests {
    @Test("XOR checksum starts from the 0x6E ^ 0x51 seed and covers every packet byte")
    func checksumComputation() {
        let bytes: [UInt8] = [0x82, 0x01, 0x10]
        #expect(DDCProtocol.checksummed(bytes) == bytes + [(0x6E ^ 0x51) ^ 0x82 ^ 0x01 ^ 0x10])
    }

    @Test("GET VCP request is 4 bytes with a valid seeded checksum")
    func getRequestLayout() {
        let packet = DDCProtocol.getVCPPacket(DDCVCP.brightness)
        #expect(packet == [0x82, 0x01, 0x10, (0x6E ^ 0x51) ^ 0x82 ^ 0x01 ^ 0x10])
    }

    @Test("SET VCP request splits a 16-bit value into high and low bytes")
    func setRequestLayout() {
        let packet = DDCProtocol.setVCPPacket(DDCVCP.brightness, value: 0x012C)
        let body: [UInt8] = [0x84, 0x03, 0x10, 0x01, 0x2C]
        #expect(packet == DDCProtocol.checksummed(body))
    }

    @Test("Valid VCP reply decodes current and maximum values")
    func parseValidVCPReply() {
        let reply = makeReply(resultCode: 0x00, vcpCode: DDCVCP.brightness, max: 100, current: 73)
        let reading = DDCProtocol.parseVCPReply(reply, vcp: DDCVCP.brightness)
        #expect(reading?.current == 73)
        #expect(reading?.max == 100)
    }

    @Test("VCP reply for a different code or an unsupported feature is rejected")
    func rejectMismatchedOrUnsupportedVCP() {
        let wrongCode = makeReply(resultCode: 0x00, vcpCode: DDCVCP.volume, max: 100, current: 50)
        #expect(DDCProtocol.parseVCPReply(wrongCode, vcp: DDCVCP.brightness) == nil)

        let unsupported = makeReply(resultCode: 0x01, vcpCode: DDCVCP.brightness, max: 100, current: 50)
        #expect(DDCProtocol.parseVCPReply(unsupported, vcp: DDCVCP.brightness) == nil)
    }

    @Test("MCCS capabilities string extracts VCP 60 input source codes")
    func parseCapabilitiesInputSources() {
        let caps = "(prot(monitor)type(lcd)vcp(10 12 60( 0F 11 12 )DF)mccs_ver(2.2))"
        #expect(DDCProtocol.inputSources(fromCapabilities: caps) == [0x0F, 0x11, 0x12])
        #expect(DDCProtocol.inputSources(fromCapabilities: "(vcp(10 12))").isEmpty)
    }

    private func makeReply(resultCode: UInt8, vcpCode: UInt8, max: UInt16, current: UInt16) -> [UInt8] {
        [
            0x6E, 0x88, 0x02, resultCode, vcpCode, 0x00,
            UInt8(max >> 8), UInt8(max & 0xFF),
            UInt8(current >> 8), UInt8(current & 0xFF),
            0x00
        ]
    }
}

// MARK: - Brightness Schedule

@Suite("Day and night brightness schedule")
struct BrightnessScheduleTests {
    @Test("Overnight window: 21:00 to 07:00 wraps across midnight")
    func overnightWindow() {
        let night = 21 * 60
        let day = 7 * 60
        #expect(BrightnessSchedule.isNight(minuteOfDay: 22 * 60, nightStart: night, dayStart: day))
        #expect(BrightnessSchedule.isNight(minuteOfDay: 0, nightStart: night, dayStart: day))
        #expect(BrightnessSchedule.isNight(minuteOfDay: 6 * 60 + 59, nightStart: night, dayStart: day))
        #expect(!BrightnessSchedule.isNight(minuteOfDay: 7 * 60, nightStart: night, dayStart: day))
        #expect(!BrightnessSchedule.isNight(minuteOfDay: 14 * 60, nightStart: night, dayStart: day))
        #expect(BrightnessSchedule.isNight(minuteOfDay: 21 * 60, nightStart: night, dayStart: day))
    }

    @Test("Same-day window: 01:00 to 06:00 stays within one day")
    func sameDayWindow() {
        let night = 1 * 60
        let day = 6 * 60
        #expect(!BrightnessSchedule.isNight(minuteOfDay: 0, nightStart: night, dayStart: day))
        #expect(BrightnessSchedule.isNight(minuteOfDay: 3 * 60, nightStart: night, dayStart: day))
        #expect(!BrightnessSchedule.isNight(minuteOfDay: 6 * 60, nightStart: night, dayStart: day))
        #expect(!BrightnessSchedule.isNight(minuteOfDay: 23 * 60, nightStart: night, dayStart: day))
    }
}

// MARK: - Display Modes

@Suite("Display mode deduplication and sorting")
struct DisplayModeTests {
    @Test("HiDPI and non-HiDPI modes deduplicate per group and sort largest first")
    func deduplicateAndSort() {
        let candidates = [
            DisplayModeOption(id: 1, width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60),
            DisplayModeOption(id: 2, width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 60),
            DisplayModeOption(id: 3, width: 2560, height: 1440, pixelWidth: 5120, pixelHeight: 2880, refreshRate: 60),
            DisplayModeOption(id: 4, width: 2560, height: 1440, pixelWidth: 5120, pixelHeight: 2880, refreshRate: 120)
        ]

        let options = DisplayModeOption.menuOptions(from: candidates, keeping: 1)
        #expect(options.map(\.id) == [4, 3, 2, 1])
        #expect(options.first?.title == "2560 × 1440 (HiDPI) · 120 Hz")
    }
}

// MARK: - Audio Matching

@Suite("Monitor audio device name matching")
struct AudioDeviceMatchingTests {
    @Test("Prefers exact match and DisplayPort/HDMI transport over non-display devices")
    func nameMatching() {
        let candidates = [
            DisplayHardwareManager.AudioDeviceCandidate(id: 10, name: "DELL U2723QE", isDisplayTransport: false),
            DisplayHardwareManager.AudioDeviceCandidate(id: 11, name: "DELL U2723QE", isDisplayTransport: true),
            DisplayHardwareManager.AudioDeviceCandidate(id: 12, name: "MacBook Pro Speakers", isDisplayTransport: false)
        ]
        #expect(DisplayHardwareManager.bestAudioMatch(for: "DELL U2723QE", among: candidates) == 11)
        #expect(DisplayHardwareManager.bestAudioMatch(for: "LG UltraFine", among: candidates) == nil)
    }
}

// MARK: - Keyboard Shortcuts

@Suite("Global shortcut formatting and validation")
struct KeyboardShortcutTests {
    @Test("Modifier symbols format in standard macOS order ⌃⌥⇧⌘")
    func modifierOrder() {
        let all = UInt32(cmdKey | shiftKey | optionKey | controlKey)
        let shortcut = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_D), carbonModifiers: all, keyLabel: "D")
        #expect(shortcut.displayString == "⌃⌥⇧⌘D")
        #expect(KeyboardShortcut.defaultRestoreScreen.displayString == "⇧⌘D")
    }

    @Test("Shift alone is not a valid global shortcut modifier")
    func modifierValidation() {
        #expect(!KeyboardShortcut.isValidGlobal(modifiers: 0))
        #expect(!KeyboardShortcut.isValidGlobal(modifiers: UInt32(shiftKey)))
        #expect(KeyboardShortcut.isValidGlobal(modifiers: UInt32(cmdKey)))
        #expect(KeyboardShortcut.isValidGlobal(modifiers: UInt32(optionKey | shiftKey)))
    }
}

// MARK: - Telemetry & Persistence

@Suite("Menu bar stats and per-monitor settings")
struct TelemetryAndStoreTests {
    @Test("Menu bar stat text formats available readings and omits missing ones")
    func menuBarStatText() {
        #expect(MenuBarStat.text(watts: 14.6, cpuCelsius: 52.3, showWatts: true, showTemperature: true) == "14.6 W · 52°")
        #expect(MenuBarStat.text(watts: 14.6, cpuCelsius: nil, showWatts: true, showTemperature: true) == "14.6 W")
        #expect(MenuBarStat.text(watts: nil, cpuCelsius: 52.3, showWatts: false, showTemperature: true) == "52°")
        #expect(MenuBarStat.text(watts: 14.6, cpuCelsius: 52.3, showWatts: false, showTemperature: false).isEmpty)
    }

    @Test("Fan speed fraction clamps neatly between 0 and 1 across normal and edge bounds")
    func fanFraction() {
        let half = FanReading(id: 0, rpm: 2000, maxRPM: 4000, isManual: false)
        #expect(half.fraction == 0.5)

        let stopped = FanReading(id: 0, rpm: 0, maxRPM: 4000, isManual: false)
        #expect(stopped.fraction == 0)

        let degenerate = FanReading(id: 0, rpm: 2000, maxRPM: 0, isManual: false)
        #expect(degenerate.fraction == 0)
    }

    @Test("MonitorSettings encodes and decodes cleanly")
    @MainActor
    func monitorSettingsCodableRoundTrip() throws {
        let original = MonitorSettings(
            brightness: 0.42,
            volume: 0.8,
            isMuted: true,
            extraDimming: 0.75,
            inputSources: [0x0F, 0x11]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MonitorSettings.self, from: data)
        #expect(decoded == original)
    }
}

// MARK: - Wireless Display & Networking

@Suite("Wireless display models, RFC1918 classification, and HTTP parsing")
struct WirelessDisplayTests {
    @Test("RFC1918 private IPv4 ranges are distinguished from non-RFC1918 Tesla benchmark IP")
    func rfc1918Classification() {
        #expect(NetworkEnvironmentService.isRFC1918PrivateIP("192.168.1.42"))
        #expect(NetworkEnvironmentService.isRFC1918PrivateIP("10.0.0.1"))
        #expect(NetworkEnvironmentService.isRFC1918PrivateIP("172.16.0.5"))
        #expect(NetworkEnvironmentService.isRFC1918PrivateIP("172.31.255.1"))
        #expect(!NetworkEnvironmentService.isRFC1918PrivateIP("172.32.0.1"))
        #expect(!NetworkEnvironmentService.isRFC1918PrivateIP("198.18.0.1"))
    }

    @Test("WirelessDisplayConfig calculates logical and HiDPI backing pixel dimensions and round-trips JSON")
    func wirelessConfigDimensionsAndCodable() throws {
        var config = WirelessDisplayConfig(
            sourceType: .virtualExtended,
            preset: .teslaModel3Y,
            scale: .retina,
            fps: 30,
            jpegQuality: 0.72,
            allowTouch: true
        )
        #expect(config.logicalWidth == 1920)
        #expect(config.logicalHeight == 1200)
        #expect(config.backingPixelWidth == 3840)
        #expect(config.backingPixelHeight == 2400)

        config.scale = .compact
        #expect(config.logicalWidth == 2560)
        #expect(config.logicalHeight == 1600)

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(WirelessDisplayConfig.self, from: data)
        #expect(decoded == config)
    }

    @Test("HTTPRequestParser waits for full Content-Length body across fragmented TCP chunks")
    func httpRequestFragmentedBodyParsing() throws {
        let jsonBody = #"{"type":"click","x":0.5,"y":0.25,"deltaX":0,"deltaY":0}"#
        let headerPart = "POST /api/touch HTTP/1.1\r\nHost: 198.18.0.1:8080\r\nContent-Length: \(jsonBody.utf8.count)\r\n\r\n"
        var buffer = Data(headerPart.utf8)

        // Incomplete body should return nil without discarding buffered header
        buffer.append(Data(jsonBody.prefix(10).utf8))
        #expect(HTTPRequestParser.parse(from: buffer) == nil)
        #expect(!buffer.isEmpty)

        // Appending remaining bytes completes the request
        buffer.append(Data(jsonBody.dropFirst(10).utf8))
        let parsed = HTTPRequestParser.parse(from: buffer)
        #expect(parsed != nil)
        #expect(parsed?.totalConsumedBytes == buffer.count)
        #expect(parsed?.method == "POST")
        #expect(parsed?.path == "/api/touch")

        let payload = try JSONDecoder().decode(TouchEventPayload.self, from: parsed!.body)
        #expect(payload.type == "click")
        #expect(payload.x == 0.5)
        #expect(payload.y == 0.25)
    }

    @Test("HTTPRequestParser extracts query parameters for frame polling and fast-path touch events")
    func httpRequestQueryParsing() {
        let raw = "GET /frame.jpg?last=148&wait=1 HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let buffer = Data(raw.utf8)
        let parsed = HTTPRequestParser.parse(from: buffer)
        #expect(parsed?.method == "GET")
        #expect(parsed?.path == "/frame.jpg")
        #expect(parsed?.queryItems["last"] == "148")
        #expect(parsed?.queryItems["wait"] == "1")

        let touchRaw = "POST /api/touch?t=move&x=0.3750&y=0.8125 HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let touchParsed = HTTPRequestParser.parse(from: Data(touchRaw.utf8))
        #expect(touchParsed?.method == "POST")
        #expect(touchParsed?.path == "/api/touch")
        #expect(touchParsed?.queryItems["t"] == "move")
        #expect(touchParsed?.queryItems["x"] == "0.3750")
        #expect(touchParsed?.queryItems["y"] == "0.8125")
    }
}

// MARK: - Dock Topology

@Suite("Dock port mapping")
struct DockTopologyTests {
    typealias T = DockTopology

    private func usb(_ id: UInt64, parent: UInt64?, _ location: UInt32, vendor: Int = 0x1234, product: Int = 1,
                     _ name: String, vendorName: String? = nil, deviceClass: Int = 0, speed: Int = 2,
                     interface: String? = nil, serial: String? = nil) -> T.USBNode {
        T.USBNode(id: id, parentID: parent, locationID: location, vendorID: vendor, productID: product, name: name,
                  vendorName: vendorName, deviceClass: deviceClass, speed: speed, networkInterface: interface,
                  serialNumber: serial)
    }

    /// A Razer Thunderbolt 4 Dock Chroma's tree: the controller's hubs, Razer's hubs on their port 4, an LG
    /// monitor hub on USB-A 2 (on both the USB 2 and USB 3 trees), a controller on USB-A 3, the built-in Ethernet
    /// adapter and lighting controller, and a USB-C display cable's billboard in Thunderbolt 2.
    private var razerTree: [T.USBNode] {
        [
            usb(1, parent: nil, 0x0210_0000, vendor: 0x1D5C, "USB2.0 Hub", deviceClass: 9),
            usb(2, parent: 1, 0x0214_0000, vendor: 0x1532, product: 0x0F2F, "USB2.0 Hub", deviceClass: 9),
            usb(3, parent: 2, 0x0214_2000, vendor: 0x0BDA, "USB2.1 Hub", deviceClass: 9),
            usb(4, parent: 3, 0x0214_2200, vendor: 0x046D, "USB Receiver", vendorName: "Logitech"),
            usb(5, parent: 3, 0x0214_2300, vendor: 0x0BDA, "LG Monitor Headset MIC", vendorName: "LG Electronics Inc."),
            usb(6, parent: 2, 0x0214_3000, vendor: 0x045E, "XBOX 360 For Windows", vendorName: "ShanWan", deviceClass: 255, speed: 1),
            usb(7, parent: 2, 0x0214_6000, vendor: 0x1532, product: 0x0F21, "RAZER THUNDERBOLT 4 DOCK CHROMA"),
            usb(8, parent: 1, 0x0212_0000, vendor: 0x2109, "USB 2.0 BILLBOARD", vendorName: "VIA Technologies Inc.", deviceClass: 0x11),
            usb(10, parent: nil, 0x0220_0000, vendor: 0x8087, "USB3.0 Hub", deviceClass: 9),
            usb(11, parent: 10, 0x0224_0000, vendor: 0x1532, product: 0x0F30, "USB3.0 Hub", deviceClass: 9),
            usb(12, parent: 11, 0x0224_5000, vendor: 0x0BDA, "USB 10/100/1000 LAN", speed: 3, interface: "en7"),
            usb(13, parent: 11, 0x0224_2000, vendor: 0x0BDA, "USB3.2 Hub", deviceClass: 9),
        ]
    }

    /// A Satechi Thunderbolt 4 Slim Hub Pro's tree: a monitor's hub in Thunderbolt 2 (with its own billboard), a
    /// USB-C to DisplayPort cable in Thunderbolt 3, a receiver in the USB-A port and the hub's own billboard
    /// device on controller port 5.
    private var satechiTree: [T.USBNode] {
        [
            usb(1, parent: nil, 0x0010_0000, vendor: 0x1D5C, "USB2.0 Hub", deviceClass: 9),
            usb(2, parent: 1, 0x0012_0000, vendor: 0x05F6, "USB2.0 Hub", deviceClass: 9),
            usb(3, parent: 2, 0x0012_5000, vendor: 0x2109, "USB Billboard Device", deviceClass: 254),
            usb(4, parent: 2, 0x0012_3000, vendor: 0x3434, "Keychron 4K Link", vendorName: "Keychron"),
            usb(5, parent: 1, 0x0013_0000, vendor: 0x0639, "Billboard", vendorName: "Chrontel", deviceClass: 0x11, speed: 1),
            usb(6, parent: 1, 0x0014_0000, vendor: 0x046D, "USB Receiver", vendorName: "Logitech", speed: 1),
            usb(7, parent: 1, 0x0015_0000, vendor: 0x310E, product: 0x0952, "ST-HT4SHM-US", vendorName: "Sariana LLC dba Satechi",
                speed: 1, serial: "11AD1D0AB7B17E08371B0B00"),
            usb(10, parent: nil, 0x0020_0000, vendor: 0x8087, "USB3.0 Hub", deviceClass: 9),
            usb(11, parent: 10, 0x0022_0000, vendor: 0x05F6, "USB3.0 Hub", deviceClass: 9, speed: 3),
            // The Mac's other ports are on other buses and must be left out.
            usb(20, parent: nil, 0x0110_0000, vendor: 0x05E3, "USB2.0 Hub", deviceClass: 9),
            usb(21, parent: 20, 0x0111_0000, vendor: 0x1234, "Flash Drive"),
        ]
    }

    @Test("A device's hub port comes from the first location digit its hub leaves empty")
    func portNumbers() {
        #expect(T.portNumber(of: 0x0214_2000, under: 0x0214_0000) == 2)
        #expect(T.portNumber(of: 0x0214_2300, under: 0x0214_2000) == 3)
        #expect(T.portNumber(of: 0x0224_5000, under: 0x0224_0000) == 5)
    }

    @Test("Razer: USB-A ports on Razer's hubs list devices behind hubs once, internal devices are left out")
    func razerUSBAPorts() {
        let layout = T.layout(model: .razerThunderbolt4, usb: razerTree, thunderbolt: [])
        #expect(layout.isPresent)
        #expect(layout.ethernetInterface == "en7")
        #expect(layout.usbA.count == 4)
        #expect(layout.usbA[0].devices.isEmpty)
        #expect(layout.usbA[1].devices.map(\.name) == ["Logitech USB Receiver", "LG Monitor Headset MIC"])
        #expect(layout.usbA[2].devices.map(\.name) == ["ShanWan XBOX 360 For Windows"])
        #expect(layout.usbA[3].devices.isEmpty)
        #expect(layout.thunderbolt.map { $0.devices.map(\.name) } == [[], ["USB-C Display Adapter"], []])
    }

    @Test("USB-C devices go to their Thunderbolt port; Thunderbolt devices behind the dock take the free ones")
    func thunderboltPorts() {
        let tree = razerTree + [usb(20, parent: 10, 0x0221_0000, vendor: 0x0781, "Extreme SSD", vendorName: "SanDisk", speed: 4)]
        let thunderbolt = [
            T.ThunderboltNode(id: 100, parentSwitchID: nil, vendorID: 0x05AC, modelID: nil, vendorName: "Apple Inc.", modelName: "iOS"),
            T.ThunderboltNode(id: 101, parentSwitchID: 100, vendorID: 0x1532, modelID: 0x122E, vendorName: "Razer", modelName: "Thunderbolt 4 Dock"),
            T.ThunderboltNode(id: 102, parentSwitchID: 101, vendorID: 0x05AC, modelID: 1, vendorName: "Apple Inc.", modelName: "Studio Display"),
            T.ThunderboltNode(id: 103, parentSwitchID: 102, vendorID: 0x1234, modelID: 1, vendorName: "Other", modelName: "Daisy-chained Drive"),
        ]
        let layout = T.layout(model: .razerThunderbolt4, usb: tree, thunderbolt: thunderbolt)
        #expect(layout.thunderbolt[0].devices.map(\.name) == ["SanDisk Extreme SSD"])
        #expect(layout.thunderbolt[1].devices.map(\.name) == ["USB-C Display Adapter"])
        #expect(layout.thunderbolt[2].devices.map(\.name) == ["Apple Inc. Studio Display"])
    }

    @Test("Satechi: Thunderbolt ports, the single USB-A port and the serial number come from its own bus")
    func satechiPorts() {
        let layout = T.layout(model: .satechiSlimHubPro, usb: satechiTree, thunderbolt: [])
        #expect(layout.isPresent)
        #expect(layout.serialNumber == "11AD1D0AB7B17E08371B0B00")
        #expect(layout.ethernetInterface == nil)
        #expect(layout.thunderbolt.map { $0.devices.map(\.name) } == [[], ["Keychron 4K Link"], ["USB-C Display Adapter"]])
        #expect(layout.thunderbolt[2].devices.first?.detail == "Alternate mode · Chrontel")
        #expect(layout.usbA.map { $0.devices.map(\.name) } == [["Logitech USB Receiver"]])
    }

    @Test("Each model only finds its own dock")
    func absentDock() {
        #expect(!T.layout(model: .satechiSlimHubPro, usb: razerTree, thunderbolt: []).isPresent)
        #expect(!T.layout(model: .razerThunderbolt4, usb: satechiTree, thunderbolt: []).isPresent)
        let empty = T.layout(model: .razerThunderbolt4, usb: [usb(1, parent: nil, 0x0100_0000, "Keyboard")], thunderbolt: [])
        #expect(!empty.isPresent)
        #expect(empty.usbA.allSatisfy { $0.devices.isEmpty })
    }
}


// MARK: - Last Window Quit

@Suite("Quit app when last window closes eligibility and window filtering")
struct LastWindowQuitTests {
    @Test("Only active regular apps outside Finder and Aeron Tools are tracked")
    func applicationEligibility() {
        #expect(LastWindowQuitController.shouldTrackApplication(
            bundleIdentifier: "com.apple.Safari",
            activationPolicy: .regular,
            isTerminated: false,
            isCurrentProcess: false
        ))
        #expect(!LastWindowQuitController.shouldTrackApplication(
            bundleIdentifier: "com.apple.finder",
            activationPolicy: .regular,
            isTerminated: false,
            isCurrentProcess: false
        ))
        #expect(!LastWindowQuitController.shouldTrackApplication(
            bundleIdentifier: "com.example.menubar",
            activationPolicy: .accessory,
            isTerminated: false,
            isCurrentProcess: false
        ))
        #expect(!LastWindowQuitController.shouldTrackApplication(
            bundleIdentifier: "com.apple.Safari",
            activationPolicy: .regular,
            isTerminated: true,
            isCurrentProcess: false
        ))
        #expect(!LastWindowQuitController.shouldTrackApplication(
            bundleIdentifier: "com.aeron.AeronTools",
            activationPolicy: .regular,
            isTerminated: false,
            isCurrentProcess: true
        ))
    }

    @Test("Standard and dialog windows qualify while sheets, popovers and non-windows do not")
    func windowQualification() {
        #expect(LastWindowQuitController.isQualifyingWindow(role: "AXWindow", subrole: "AXStandardWindow"))
        #expect(LastWindowQuitController.isQualifyingWindow(role: "AXWindow", subrole: "AXDialog"))
        #expect(!LastWindowQuitController.isQualifyingWindow(role: "AXWindow", subrole: "AXSystemDialog"))
        #expect(!LastWindowQuitController.isQualifyingWindow(role: "AXWindow", subrole: "AXFloatingWindow"))
        #expect(!LastWindowQuitController.isQualifyingWindow(role: "AXSheet", subrole: "AXStandardWindow"))
        #expect(!LastWindowQuitController.isQualifyingWindow(role: "AXWindow", subrole: nil))
    }
}

// MARK: - macOS Game Mode

@Suite("macOS Game Mode gamepolicyctl status parsing")
struct GameModeStatusTests {
    @Test("Parses automatic, forced on and forced off outputs from gamepolicyctl")
    func parseGamePolicyOutputs() {
        let autoOff = """
        Game mode is off.
        Game mode enablement policy is currently automatic. The system must meet all specified requirements to enable game mode.
        """
        let parsedAutoOff = GameModeManager.parseStatusOutput(autoOff)
        #expect(parsedAutoOff == GameModeStatus(isActive: false, policy: .automatic))
        #expect(parsedAutoOff?.displayText == "Off · Automatic")
        #expect(parsedAutoOff?.isForcedOn == false)

        let forcedOn = """
        Game mode is on.
        Game mode enablement policy is currently disabled. Game mode is forced always on.
        """
        let parsedForcedOn = GameModeManager.parseStatusOutput(forcedOn)
        #expect(parsedForcedOn == GameModeStatus(isActive: true, policy: .forcedOn))
        #expect(parsedForcedOn?.displayText == "On · Forced On")
        #expect(parsedForcedOn?.isForcedOn == true)

        let forcedOff = """
        Game mode is off.
        Game mode enablement policy is currently disabled. Game mode is forced always off.
        """
        let parsedForcedOff = GameModeManager.parseStatusOutput(forcedOff)
        #expect(parsedForcedOff == GameModeStatus(isActive: false, policy: .forcedOff))
        #expect(parsedForcedOff?.displayText == "Off · Forced Off")
        #expect(parsedForcedOff?.isForcedOn == false)

        let ansiForcedOn = "Game mode is \u{001B}[0;32mon\u{001B}[0;0m.\u{001B}[0;33m\u{001B}[0;0m\nGame mode enablement policy is currently disabled. Game mode is forced always on.\n"
        #expect(GameModeManager.parseStatusOutput(ansiForcedOn) == GameModeStatus(isActive: true, policy: .forcedOn))

        let ansiAutoOff = "Game mode is \u{001B}[0;31moff\u{001B}[0;0m.\nGame mode enablement policy is currently automatic. The system must meet all specified requirements to enable game mode.\n"
        #expect(GameModeManager.parseStatusOutput(ansiAutoOff) == GameModeStatus(isActive: false, policy: .automatic))

        #expect(GameModeManager.parseStatusOutput("unexpected output") == nil)
    }
}


