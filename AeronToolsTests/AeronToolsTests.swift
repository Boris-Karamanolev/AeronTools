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

// MARK: - HID++ Diversion

@Suite("HID++ input diversion packets and events")
struct HIDPPDiversionTests {
    @Test("Control reporting sets divert and raw XY bits only when diverting, and always marks both valid")
    func controlReportingFlags() {
        let divertedWithRawXY = HIDPPProtocol.setControlReportingPacket(
            deviceIndex: 0x01, featureIndex: 0x09, controlID: 0x00C3, diverted: true, rawXY: true
        )
        #expect(Array(divertedWithRawXY[0...6]) == [0x11, 0x01, 0x09, 0x3A, 0x00, 0xC3, 0x33])

        let divertedOnly = HIDPPProtocol.setControlReportingPacket(
            deviceIndex: 0x01, featureIndex: 0x09, controlID: 0x0053, diverted: true
        )
        #expect(divertedOnly[6] == 0x23)

        // Releasing must also clear raw XY, even if it was requested.
        let released = HIDPPProtocol.setControlReportingPacket(
            deviceIndex: 0x01, featureIndex: 0x09, controlID: 0x00C3, diverted: false, rawXY: true
        )
        #expect(released[6] == 0x22)
    }

    @Test("Wheel and thumbwheel reporting packets switch between HID++ and native")
    func wheelReportingPackets() {
        let wheel = HIDPPProtocol.setWheelModePacket(deviceIndex: 0x01, featureIndex: 0x0B, diverted: true)
        #expect(Array(wheel[0...4]) == [0x11, 0x01, 0x0B, 0x2A, 0x01])
        #expect(HIDPPProtocol.setWheelModePacket(deviceIndex: 0x01, featureIndex: 0x0B, diverted: false)[4] == 0x00)

        let thumb = HIDPPProtocol.setThumbwheelReportingPacket(deviceIndex: 0x01, featureIndex: 0x0C, diverted: true)
        #expect(Array(thumb[0...5]) == [0x11, 0x01, 0x0C, 0x2A, 0x01, 0x00])
    }

    @Test("Wheel movement events decode a signed notch delta")
    func wheelMovementEvent() {
        var event = [UInt8](repeating: 0, count: 20)
        event[0] = 0x11; event[1] = 0x01; event[2] = 0x0B; event[3] = 0x00
        event[5] = 0xFF; event[6] = 0xFE // -2
        #expect(HIDPPProtocol.parseWheelMovementEvent(event, expectedFeatureIndex: 0x0B) == -2)

        event[5] = 0x00; event[6] = 0x03
        #expect(HIDPPProtocol.parseWheelMovementEvent(event, expectedFeatureIndex: 0x0B) == 3)
    }

    @Test("Replies to this app's own requests are never mistaken for input events")
    func repliesAreNotEvents() {
        var reply = [UInt8](repeating: 0, count: 20)
        reply[0] = 0x11; reply[1] = 0x01; reply[2] = 0x0B
        reply[3] = 0x2A // setWheelMode reply: function 2, software ID 0x0A
        reply[5] = 0x00; reply[6] = 0x01
        #expect(HIDPPProtocol.parseWheelMovementEvent(reply, expectedFeatureIndex: 0x0B) == nil)
        #expect(HIDPPProtocol.parseWheelMovementEvent(reply, expectedFeatureIndex: 0x0C) == nil)
    }

    @Test("Thumbwheel and raw XY events decode signed 16-bit values")
    func thumbwheelAndRawXYEvents() {
        var thumb = [UInt8](repeating: 0, count: 20)
        thumb[0] = 0x11; thumb[1] = 0x01; thumb[2] = 0x0C; thumb[3] = 0x00
        thumb[4] = 0xFF; thumb[5] = 0xF6 // -10
        #expect(HIDPPProtocol.parseThumbwheelEvent(thumb, expectedFeatureIndex: 0x0C) == -10)

        var rawXY = [UInt8](repeating: 0, count: 20)
        rawXY[0] = 0x11; rawXY[1] = 0x01; rawXY[2] = 0x09
        rawXY[3] = 0x10 // event 1
        rawXY[4] = 0x00; rawXY[5] = 0x05 // dx = 5
        rawXY[6] = 0xFF; rawXY[7] = 0xFD // dy = -3
        let motion = HIDPPProtocol.parseRawXYEvent(rawXY, expectedFeatureIndex: 0x09)
        #expect(motion?.dx == 5)
        #expect(motion?.dy == -3)

        // A diverted-buttons event (event 0) on the same feature isn't raw XY.
        rawXY[3] = 0x00
        #expect(HIDPPProtocol.parseRawXYEvent(rawXY, expectedFeatureIndex: 0x09) == nil)
    }
}

// MARK: - Logitech G Features

@Suite("Logitech G DPI, report rate and onboard profile parsing")
struct LogitechGProtocolTests {
    private func packet(_ hex: String) -> [UInt8] {
        hex.split(separator: " ").compactMap { UInt8($0, radix: 16) }
    }

    @Test("DPI ranges join a word split across pages and keep each segment's step")
    func dpiRangesAcrossPages() throws {
        // Captured from a PRO X2 SUPERSTRIKE: 0x03E8 (1000) is split between page 0 and page 1.
        let page0 = packet("11 01 09 2C 00 00 00 00 64 E0 01 00 C8 E0 02 01 F4 E0 05 03")
        let page1 = packet("11 01 09 2C 00 00 01 E8 E0 0A 07 D0 E0 14 13 88 E0 32 27 10")
        // Page 2 is constructed (not captured): 10000–44000 in steps of 100, then the 0x0000 terminator.
        let page2 = packet("11 01 09 2C 00 00 02 E0 64 AB E0 00 00 00 00 00 00 00 00 00")
        #expect(!HIDPPProtocol.dpiRangePageEndsList(page0))
        #expect(HIDPPProtocol.dpiRangePageEndsList(page2))

        let range = try #require(HIDPPProtocol.parseDPIRanges(pages: [page0, page1, page2]))
        #expect(range.minimum == 100)
        #expect(range.maximum == 44000)
        #expect(range.segments[0] == .init(lower: 100, upper: 200, step: 1))
        #expect(range.segments[3] == .init(lower: 1000, upper: 2000, step: 10))
        #expect(range.nearestSupported(1234) == 1230)
        #expect(range.nearestSupported(50) == 100)
        #expect(range.nearestSupported(99_999) == 44000)
    }

    @Test("Sensor DPI parameters decode current DPI and lift-off distance, and round-trip into a set request")
    func sensorDPI() {
        let reply = packet("11 01 09 5C 00 03 20 03 20 03 20 03 20 02 00 00 00 00 00 00")
        #expect(HIDPPProtocol.parseSensorDPI(reply) == .init(dpi: 800, liftOffDistance: 2))
        #expect(HIDPPProtocol.setSensorDPIParams(dpi: 800, liftOffDistance: 2) == [0x00, 0x03, 0x20, 0x03, 0x20, 0x02])
    }

    @Test("Report rate flags map to Hz, and the current rate index decodes")
    func reportRates() {
        let list = packet("11 01 0D 1C 00 7F 00 00 00 00 00 00 00 00 00 00 00 00 00 00")
        #expect(HIDPPProtocol.parseSupportedReportRates(list) == [125, 250, 500, 1000, 2000, 4000, 8000])

        let current = packet("11 01 0D 2C 03 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00")
        #expect(HIDPPProtocol.parseReportRate(current) == 1000)
        #expect(HIDPPProtocol.reportRateIndex(forHz: 8000) == 6)
        #expect(HIDPPProtocol.reportRateIndex(forHz: 333) == nil)
    }

    @Test("Trigger limits decode from the captured getInfo reply as user-facing levels")
    func triggerLimits() {
        // Captured from G HUB reading a PRO X2 SUPERSTRIKE.
        let reply = packet("11 01 0C 0C 00 03 28 14 14 01 00 00 00 00 00 00 00 00 00 00")
        #expect(HIDPPProtocol.parseTriggerLimits(reply) == .init(maxActuation: 10, maxRapidTrigger: 5, maxHaptics: 5))
    }

    @Test("Trigger settings encode as [key, actuation, rapid trigger, haptics]; rapid trigger's bit 0 switches it on")
    func triggerSettingsEncoding() {
        // G HUB sent "00 14 08 08" for actuation 5, rapid trigger off, haptics 2 on the left key.
        #expect(HIDPPProtocol.setTriggerParams(key: 0, .init(actuation: 5, rapidTrigger: 0, haptics: 2)) == [0x00, 0x14, 0x08, 0x08])
        // …and 0x09 / 0x05 for rapid trigger on at levels 2 and 1.
        #expect(HIDPPProtocol.setTriggerParams(key: 0, .init(actuation: 5, rapidTrigger: 2, haptics: 2))[2] == 0x09)
        #expect(HIDPPProtocol.setTriggerParams(key: 0, .init(actuation: 5, rapidTrigger: 1, haptics: 2))[2] == 0x05)
        #expect(HIDPPProtocol.setTriggerParams(key: 1, .init(actuation: 10, rapidTrigger: 5, haptics: 0)) == [0x01, 0x28, 0x15, 0x00])
        // The onboard profile stores 14 08 0C.
        #expect(HIDPPProtocol.setTriggerParams(key: 0, .profileDefault) == [0x00, 0x14, 0x08, 0x0C])
    }

    @Test("Button map keeps every button native except the silenced side buttons")
    func buttonMap() {
        // G HUB read the identity map "01 02 03 04 05" from the 5-button mouse.
        #expect(HIDPPProtocol.buttonMap(buttonCount: 5, silencing: []) == [1, 2, 3, 4, 5])
        #expect(HIDPPProtocol.buttonMap(buttonCount: 5, silencing: [4]) == [1, 2, 3, 0, 5])
        #expect(HIDPPProtocol.buttonMap(buttonCount: 5, silencing: [4, 5]) == [1, 2, 3, 0, 0])
    }

    /// Profile sector 0x0001 captured from a PRO X2 SUPERSTRIKE (factory settings), 255 bytes.
    private var capturedProfile: [UInt8] {
        packet("03 03 00 00 20 03 20 03 02 B0 04 B0 04 02 40 06 40 06 02 60 09 60 09 02 80 0C 80 0C 02 00 00 00 00 FF 00 FF FF FF 14 08 0C 14 08 0C 3C 00 2C 01 80 01 00 01 80 01 00 02 80 01 00 04 80 01 00 08 80 01 00 10 FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF 03 00 00 00 00 00 1F 40 00 00 00 03 00 00 00 00 00 1F 40 00 00 00 03 00 00 00 00 00 1F 40 32 00 00 03 00 00 00 00 00 1F 40 32 00 00 03 2A 38")
    }

    @Test("The captured profile's stored CRC verifies, and the directory points at sector 1")
    func profileChecksumAndDirectory() {
        #expect(capturedProfile.count == 255)
        #expect(HIDPPProtocol.hasValidCRC(sector: capturedProfile))
        let directory = packet("00 01 01 FF 00 02 00 FF 00 03 00 FF 00 04 00 FF 00 05 00 FF FF FF FF FF")
        #expect(HIDPPProtocol.firstEnabledProfileSector(directory: directory) == 0x0001)
        #expect(HIDPPProtocol.firstEnabledProfileSector(directory: packet("00 02 00 FF FF FF FF FF")) == nil)
        let info = packet("11 01 0E 0C 01 08 01 05 01 05 10 00 FF 0A 04 00 00 00 00 00")
        #expect(HIDPPProtocol.parseOnboardProfilesInfo(info) == .init(profileFormat: 8, sectorSize: 255))
    }

    @Test("Patching changes only DPI, report rate and trigger bytes, and keeps the CRC valid")
    func profilePatching() throws {
        let original = capturedProfile
        let settings = HIDPPProtocol.ProfileSettings(
            dpi: 1600, reportRateHz: 2000, triggers: .init(actuation: 3, rapidTrigger: 2, haptics: 0)
        )
        let patched = try #require(HIDPPProtocol.patchedProfileSector(original, with: settings))
        #expect(HIDPPProtocol.hasValidCRC(sector: patched))
        // Default DPI level 0 (offset 4): 1600 = 0x0640, little-endian X and Y; lift-off kept.
        #expect(Array(patched[4...8]) == [0x40, 0x06, 0x40, 0x06, original[8]])
        #expect(Array(patched[0...1]) == [4, 4])
        #expect(Array(patched[38...43]) == [0x0C, 0x09, 0x00, 0x0C, 0x09, 0x00])
        let changed = Set((0..<255).filter { patched[$0] != original[$0] })
        #expect(changed.isSubset(of: [0, 1, 4, 5, 6, 7, 38, 39, 40, 41, 42, 43, 253, 254]))

        // Writing the current values changes nothing at all.
        let same = HIDPPProtocol.ProfileSettings(dpi: 800, reportRateHz: 1000, triggers: .profileDefault)
        #expect(HIDPPProtocol.patchedProfileSector(original, with: same) == original)

        // A sector whose CRC doesn't verify is never patched.
        var corrupt = original
        corrupt[100] ^= 0xFF
        #expect(HIDPPProtocol.patchedProfileSector(corrupt, with: settings) == nil)
    }

    @Test("A 255-byte sector reads as 16 chunks, the last one overlapping")
    func sectorAssembly() throws {
        let offsets = HIDPPProtocol.sectorReadOffsets(sectorSize: 255)
        #expect(offsets.count == 16)
        #expect(offsets.last == 239)
        let chunks = offsets.map { Array(capturedProfile[$0..<($0 + 16)]) }
        #expect(try #require(HIDPPProtocol.assembleSector(chunks, sectorSize: 255)) == capturedProfile)
    }

    @Test("Spy events decode the pressed-button mask; replies are ignored")
    func buttonSpyEvents() throws {
        // Captured left-button press and release.
        let press = packet("11 01 0F 00 00 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00")
        let mask = try #require(HIDPPProtocol.parseButtonSpyEvent(press, expectedFeatureIndex: 0x0F))
        #expect(HIDPPProtocol.isButtonPressed(1, in: mask))
        #expect(!HIDPPProtocol.isButtonPressed(4, in: mask))
        #expect(HIDPPProtocol.isButtonPressed(5, in: 0x0010))

        // G HUB's startSpy reply (function 1) is not a press event.
        let reply = packet("11 01 0F 1C 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00")
        #expect(HIDPPProtocol.parseButtonSpyEvent(reply, expectedFeatureIndex: 0x0F) == nil)
    }
}

// MARK: - Receiver Pairing Records

@Suite("Receiver pairing records and device names")
struct ReceiverPairingTests {
    private func packet(_ hex: String) -> [UInt8] {
        hex.split(separator: " ").compactMap { UInt8($0, radix: 16) }
    }

    @Test("Bolt pairing records decode kind and the receiver's short name")
    func boltPairing() throws {
        // Captured from a Logi Bolt receiver: slot 2 pairing info and name ("MX MCHNCL M").
        let info = packet("11 FF 83 B5 52 01 6D B3 8C 48 7B 70 01 00 01 14 01 00 00 00")
        let name = packet("11 FF 83 B5 62 01 0B 4D 58 20 4D 43 48 4E 43 4C 20 4D 00 00")
        let paired = try #require(HIDPPSession.pairedDevice(kindByte: info[5], name: name, lengthAt: 6))
        #expect(paired.name == "MX MCHNCL M")
        #expect(paired.kind == .keyboard)
        #expect(!paired.isPointingDevice)
        #expect(MXMechanicalConnector.isMXMechanical(paired.name))
        #expect(!MXMasterManager.isMXMasterName(paired.name))
    }

    @Test("LIGHTSPEED pairing records decode a mouse and its name")
    func lightspeedPairing() throws {
        // Captured from a LIGHTSPEED receiver: slot 1 pairing info and name ("X2 SUPERSTRIKE").
        let info = packet("11 FF 83 B5 20 08 08 40 BD 11 00 02 B1 01 00 00 7F 24 00 00")
        let name = packet("11 FF 83 B5 40 0E 58 32 20 53 55 50 45 52 53 54 52 49 4B 45")
        let paired = try #require(HIDPPSession.pairedDevice(kindByte: info[4 + 7], name: name, lengthAt: 5))
        #expect(paired.name == "X2 SUPERSTRIKE")
        #expect(paired.isPointingDevice)
    }

    @Test("Device names are matched to the right connector")
    func nameMatching() {
        #expect(MXMasterManager.isMXMasterName("MX Master 4"))
        #expect(MXMasterManager.isMXMasterName("MX Master 3S for Mac"))
        #expect(!MXMasterManager.isMXMasterName("MX Keys Mini"))
        #expect(MXMechanicalConnector.isMXMechanical("MX Mechanical Mini for Mac"))
        #expect(!MXMechanicalConnector.isMXMechanical("MX Keys Mini"))
    }
}

// MARK: - Keyboard Backlight

@Suite("MX Mechanical backlight configuration")
struct KeyboardBacklightTests {
    private func packet(_ hex: String) -> [UInt8] {
        hex.split(separator: " ").compactMap { UInt8($0, radix: 16) }
    }

    @Test("Captured replies decode on/off, mode, battery saving, level and durations")
    func decodeCapturedConfigs() throws {
        // Options+ defaults: on, automatic brightness, battery saving, level 4, 30 s / 30 s / 5 min.
        let defaults = try #require(HIDPPProtocol.parseBacklightConfig(packet("11 02 0B 0E 01 0D 3D 7F 00 04 06 00 06 00 3C 00 00 00 00 00")))
        #expect(defaults.isEnabled)
        #expect(defaults.isAutomaticBrightness)
        #expect(defaults.isBatterySaving)
        #expect(defaults.level == 4)
        #expect(defaults.durationSeconds == 30)
        #expect(defaults.durationCharging == 60)
        #expect(defaults.effects == 0x007F)

        // Backlighting off.
        #expect(try #require(HIDPPProtocol.parseBacklightConfig(packet("11 02 0B 0E 00 0D 3D 7F 00 00 06 00 06 00 3C 00 00 00 00 00"))).isEnabled == false)
        // Automatic brightness off (manual level).
        #expect(try #require(HIDPPProtocol.parseBacklightConfig(packet("11 02 0B 0E 01 1D 3D 7F 00 02 06 00 06 00 06 00 00 00 00 00"))).isAutomaticBrightness == false)
        // Battery saving off.
        #expect(try #require(HIDPPProtocol.parseBacklightConfig(packet("11 02 0B 0E 01 09 3D 7F 00 04 06 00 06 00 06 00 00 00 00 00"))).isBatterySaving == false)
    }

    @Test("Editing fields sets the same option bits Options+ did, and writes all three durations")
    func editAndEncode() throws {
        var config = try #require(HIDPPProtocol.parseBacklightConfig(packet("11 02 0B 0E 01 0D 3D 7F 00 04 06 00 06 00 3C 00 00 00 00 00")))
        config.isAutomaticBrightness = false
        #expect(config.options == 0x1D)
        config.isAutomaticBrightness = true
        config.isBatterySaving = false
        #expect(config.options == 0x09)
        config.durationSeconds = 45
        #expect(HIDPPProtocol.setBacklightConfigParams(config) == [0x01, 0x09, 0xFF, 0x04, 0x09, 0x00, 0x09, 0x00, 0x09, 0x00])
    }
}
