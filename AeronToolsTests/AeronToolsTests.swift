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

    @Test("Side button bindings go in the profile's button table, and only over button or key bindings")
    func profileButtonBindings() throws {
        let original = capturedProfile
        // The factory table: buttons 1…5 as themselves.
        for button in 1...5 {
            let offset = HIDPPProtocol.profileButtonTableOffset + (button - 1) * 4
            #expect(Array(original[offset..<(offset + 4)]) == HIDPPProtocol.mouseButtonBinding(button))
        }

        // Back as ⌘[, forward left as the plain button.
        var settings = HIDPPProtocol.ProfileSettings()
        settings.buttonBindings = [
            HIDPPProtocol.backSideButton: HIDPPProtocol.keyBinding(usage: 0x2F, modifiers: 0x08),
            HIDPPProtocol.forwardSideButton: HIDPPProtocol.mouseButtonBinding(5),
        ]
        let patched = try #require(HIDPPProtocol.patchedProfileSector(original, with: settings))
        #expect(HIDPPProtocol.hasValidCRC(sector: patched))
        #expect(Array(patched[60..<64]) == [0x80, 0x02, 0x08, 0x2F])
        let changed = Set((0..<255).filter { patched[$0] != original[$0] })
        #expect(changed.isSubset(of: [60, 61, 62, 63, 253, 254]))

        // A slot holding something else (e.g. a G HUB macro) is left alone.
        var withMacro = original
        withMacro.replaceSubrange(60..<64, with: [0x00, 0x01, 0x02, 0x00])
        let crc = HIDPPProtocol.profileCRC(withMacro[..<253])
        withMacro[253] = UInt8(crc >> 8)
        withMacro[254] = UInt8(crc & 0xFF)
        #expect(HIDPPProtocol.patchedProfileSector(withMacro, with: settings) == withMacro)
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
        #expect(MXKeyboardConnector.isMXMechanical(paired.name))
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
        #expect(MXKeyboardConnector.isMXMechanical("MX Mechanical Mini for Mac"))
        #expect(!MXKeyboardConnector.isMXMechanical("MX Keys Mini"))
        #expect(MXKeyboardConnector.isMXKeysMini("MX Keys Mini"))
        #expect(!MXKeyboardConnector.isMXKeysMini("MX MCHNCL M"))
        #expect(!MXKeyboardConnector.isMXKeysMini("MX Master 4"))
    }

    @Test("Bolt pairing records decode the MX Keys Mini")
    func boltKeysMiniPairing() throws {
        // Captured from a Logi Bolt receiver: slot 1 pairing info and name ("MX Keys Mini").
        let info = packet("11 FF 83 B5 51 01 69 B3 ED 25 B9 82 01 00 01 14 01 00 00 00")
        let name = packet("11 FF 83 B5 61 01 0C 4D 58 20 4B 65 79 73 20 4D 69 6E 69 00")
        let paired = try #require(HIDPPSession.pairedDevice(kindByte: info[5], name: name, lengthAt: 6))
        #expect(paired.name == "MX Keys Mini")
        #expect(paired.kind == .keyboard)
        #expect(MXKeyboardConnector.isMXKeysMini(paired.name))
        #expect(!MXKeyboardConnector.isMXMechanical(paired.name))
        #expect(!MXMasterManager.isMXMasterName(paired.name))
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
        #expect(defaults.supportedEffects == HIDPPProtocol.BacklightEffect.allCases)

        // MX Keys Mini: static backlight only.
        let keysMini = try #require(HIDPPProtocol.parseBacklightConfig(packet("11 01 0B 0A 01 0D 3D 01 00 02 06 00 06 00 3C 00 00 00 00 00")))
        #expect(keysMini.isEnabled)
        #expect(keysMini.isAutomaticBrightness)
        #expect(keysMini.isBatterySaving)
        #expect(keysMini.level == 2)
        #expect(keysMini.durationSeconds == 30)
        #expect(keysMini.supportedEffects == [.staticLight])
        #expect(defaults.durationCharging == 60)
        #expect(defaults.effects == 0x007F)

        // Backlighting off.
        #expect(try #require(HIDPPProtocol.parseBacklightConfig(packet("11 02 0B 0E 00 0D 3D 7F 00 00 06 00 06 00 3C 00 00 00 00 00"))).isEnabled == false)
        // Automatic brightness off (manual level).
        #expect(try #require(HIDPPProtocol.parseBacklightConfig(packet("11 02 0B 0E 01 1D 3D 7F 00 02 06 00 06 00 06 00 00 00 00 00"))).isAutomaticBrightness == false)
        // Battery saving off.
        #expect(try #require(HIDPPProtocol.parseBacklightConfig(packet("11 02 0B 0E 01 09 3D 7F 00 04 06 00 06 00 06 00 00 00 00 00"))).isBatterySaving == false)
    }

    @Test("Backlight info reports the current effect in byte 7, with Options+'s numbering")
    func currentEffect() {
        // Captured while Options+ switched effects: Random (05), then Contrast (03), then Static (00).
        #expect(HIDPPProtocol.parseBacklightEffect(packet("11 02 0B 2C 08 04 02 05 03 00 06 00 3C 00 00 00 00 00 00 00")) == .random)
        #expect(HIDPPProtocol.parseBacklightEffect(packet("11 02 0B 2C 08 04 02 03 03 00 06 00 3C 00 00 00 00 00 00 00")) == .contrast)
        #expect(HIDPPProtocol.parseBacklightEffect(packet("11 02 0B 2C 08 04 02 00 03 00 06 00 3C 00 00 00 00 00 00 00")) == .staticLight)
        #expect(HIDPPProtocol.BacklightEffect.waves.rawValue == 6)
        #expect(HIDPPProtocol.BacklightEffect.breathing.rawValue == 2)
        #expect(HIDPPProtocol.BacklightEffect.reaction.rawValue == 4)
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

// MARK: - Keyboard Keys

@Suite("MX Mechanical Fn keys and remappable controls")
struct KeyboardKeysTests {
    private func packet(_ hex: String) -> [UInt8] {
        hex.split(separator: " ").compactMap { UInt8($0, radix: 16) }
    }

    @Test("Fn inversion decodes per host, as Options+ toggled it")
    func fnInversion() {
        // Captured: host 0 with media keys (00), then standard function keys (01).
        #expect(HIDPPProtocol.parseFnInversion(packet("11 02 0C 0D 00 00 01 01 00 00 00 00 00 00 00 00 00 00 00 00"), host: 0) == false)
        #expect(HIDPPProtocol.parseFnInversion(packet("11 02 0C 0D 00 01 01 01 00 00 00 00 00 00 00 00 00 00 00 00"), host: 0) == true)
        // A reply for another host isn't applied to this one.
        #expect(HIDPPProtocol.parseFnInversion(packet("11 02 0C 0D 01 01 01 01 00 00 00 00 00 00 00 00 00 00 00 00"), host: 0) == nil)
    }

    @Test("Control info decodes F4 as the control Options+ diverted to remap it")
    func f4ControlInfo() throws {
        // Captured from the keyboard: control 0x00E2 at F-key position 4, divertable.
        let control = try #require(HIDPPProtocol.parseKeyControl(packet("11 02 08 1B 00 E2 00 C1 3A 04 00 00 04 00 00 00 00 00 00 00")))
        #expect(control.cid == 0x00E2)
        #expect(control.task == 0x00C1)
        #expect(control.fKeyPosition == 4)
        #expect(control.isDivertable)
    }
}

@Suite("G515 lighting effects and brightness")
struct KeyboardLightingTests {
    @Test("Effect info replies decode the keyboard's index and effect, and unknown effects are skipped")
    func effectInfo() {
        // Captured from a G515 LIGHTSPEED TKL: zone 0, effects 1 (Fixed), 4 (Color Wave) and 5 (Ripple, unsupported).
        let fixed: [UInt8] = [0x11, 0xFF, 0x08, 0x0B, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let wave: [UInt8] = [0x11, 0xFF, 0x08, 0x0B, 0x00, 0x04, 0x00, 0x16, 0xDC, 0xE1, 0x00, 0x1E, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let ripple: [UInt8] = [0x11, 0xFF, 0x08, 0x0B, 0x00, 0x05, 0x00, 0x17, 0x00, 0x00, 0x00, 0x32, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        #expect(HIDPPProtocol.parseRGBZoneEffect(fixed)?.index == 1)
        #expect(HIDPPProtocol.parseRGBZoneEffect(fixed)?.effect == .fixed)
        #expect(HIDPPProtocol.parseRGBZoneEffect(wave)?.effect == .colorWave)
        #expect(HIDPPProtocol.parseRGBZoneEffect(ripple)?.effect == nil)
    }

    @Test("Effect writes match the layouts the keyboard accepted")
    func effectParams() {
        let green = HIDPPProtocol.RGBColor(red: 0, green: 0xFF, blue: 0)
        let fixed = HIDPPProtocol.RGBLighting(effect: .fixed, color: green, speed: 5)
        #expect(HIDPPProtocol.setRGBEffectParams(zone: 0, index: 1, lighting: fixed)
                == [0x00, 0x01, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01])
        // Speed 5: a 12 s wave, at full saturation and intensity.
        let wave = HIDPPProtocol.RGBLighting(effect: .colorWave, color: green, speed: 5)
        #expect(HIDPPProtocol.setRGBEffectParams(zone: 0, index: 4, lighting: wave)
                == [0x00, 0x04, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x2E, 0xE0, 0x64, 0x00, 0x01])
        let breathing = HIDPPProtocol.RGBLighting(effect: .breathing, color: green, speed: 10)
        #expect(HIDPPProtocol.setRGBEffectParams(zone: 0, index: 2, lighting: breathing)
                == [0x00, 0x02, 0x00, 0xFF, 0x00, 0x03, 0xE8, 0x00, 0x64, 0x00, 0x00, 0x00, 0x01])
    }

    @Test("Brightness decodes from replies and brightness-key events, and encodes big-endian")
    func brightness() {
        let event: [UInt8] = [0x11, 0xFF, 0x0D, 0x00, 0x00, 0x32, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        #expect(HIDPPProtocol.parseBrightnessLevel(event) == 50)
        #expect(HIDPPProtocol.setBrightnessParams(100) == [0x00, 0x64])
    }
}

// MARK: - Keychron Mouse Protocol

@Suite("Keychron 4K mouse packets, from an M3 Mini 4K on the 4K Link receiver")
struct KeychronMouseProtocolTests {
    /// A settings reply captured from the mouse through the receiver.
    static let settingsReply: [UInt8] = [
        0x44, 0x00, 0xB4, 0x01, 0x20, 0x00, 0x1F, 0x01, 0x90, 0x01, 0x90, 0x01, 0x20, 0x03, 0x20, 0x03,
        0x40, 0x06, 0x40, 0x06, 0x80, 0x0C, 0x80, 0x0C, 0x88, 0x13, 0x88, 0x13, 0xFF, 0x00, 0x00, 0x00,
        0xFF, 0x00, 0xFF, 0xFF, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0x01, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x84, 0x03, 0x84, 0x03, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1C,
    ]

    @Test("Packets are 64 bytes, routed with 0x40, and checksummed to 0xA1")
    func packetFraming() {
        let packet = KeychronMouseProtocol.packet(.readSettings, routed: true)
        #expect(packet.count == 64)
        #expect(Array(packet[0...3]) == [0x44, 0x00, 0x81, 0x01])
        #expect(packet[0..<64].reduce(0, &+) == 0xA1)
        #expect(KeychronMouseProtocol.packet(.power, routed: false)[0] == 0x01)
    }

    @Test("Replies match on the command byte, routing included, and the sub-command")
    func replyMatching() {
        let request = KeychronMouseProtocol.packet(.power, routed: true)
        #expect(KeychronMouseProtocol.isReply([0x41, 0x00, 0x8C, 0x01, 0x00], to: request))
        // The receiver's own link report must not answer a request meant for the mouse.
        #expect(!KeychronMouseProtocol.isReply([0x01, 0x00, 0x8C, 0x01, 0x0A], to: request))
    }

    @Test("Power reports carry battery, charging and the active DPI stage")
    func powerParsing() {
        let discharging = KeychronMouseProtocol.Power([0x41, 0x00, 0x8C, 0x01, 0x00, 0x00, 0x59, 0x00, 0x02, 0x00, 0x05])
        #expect(discharging?.percent == 89)
        #expect(discharging?.isCharging == false)
        #expect(discharging?.activeStage == 2)
        #expect(KeychronMouseProtocol.Power([0x01, 0x00, 0x8C, 0x01, 0x00, 0x01, 0x59, 0x00, 0x01])?.isCharging == true)
    }

    @Test("Version replies carry the model ID little-endian")
    func modelID() {
        #expect(KeychronMouseProtocol.modelID(fromVersion: [0x40, 0x00, 0x9A, 0x00, 0x22, 0x06]) == KeychronMouseProtocol.m3MiniModelID)
    }

    @Test("Settings decode stages, DPI, lift-off and flags")
    func settingsParsing() throws {
        let settings = try #require(KeychronMouseProtocol.Settings(Self.settingsReply))
        #expect(settings.stageCount == 5)
        #expect(settings.activeStage == 1)
        #expect((0..<5).map(settings.dpi(stage:)) == [400, 800, 1600, 3200, 5000])
        #expect(settings.liftOffMillimeters == 1)
        #expect(settings.isMotionSyncOn)
        #expect(!settings.isAngleSnappingOn)
    }

    @Test("Writes send the block back whole, changing only what was set")
    func settingsWrite() throws {
        var settings = try #require(KeychronMouseProtocol.Settings(Self.settingsReply))
        settings.setDPI(5050, stage: 4)
        settings.isAngleSnappingOn = true
        let packet = KeychronMouseProtocol.packet(.writeSettings, routed: true, payload: settings.block)
        var expected = Self.settingsReply
        expected[24...27] = [0xBA, 0x13, 0xBA, 0x13]
        expected[4] = 0x21
        #expect(Array(packet[0...3]) == [0x44, 0x00, 0xB5, 0x02])
        #expect(packet[4...55] == expected[4...55])
        #expect(packet[0..<64].reduce(0, &+) == 0xA1)
    }

    @Test("Report rate codes are 125 Hz doubled per step, as measured on the receiver")
    func reportRates() throws {
        var settings = try #require(KeychronMouseProtocol.Settings(Self.settingsReply))
        #expect(settings.reportRateHz == 125)
        settings.reportRateHz = 4000
        #expect(settings.block[5] == 5)
        settings.reportRateHz = 1000
        #expect(settings.block[5] == 3)
        settings.reportRateHz = 300
        #expect(settings.block[5] == 3, "unsupported rates are ignored")
        let power = KeychronMouseProtocol.Power([0x41, 0x00, 0x8C, 0x01, 0x00, 0x00, 0x59, 0x00, 0x01, 0x00, 0x05])
        #expect(power?.maxReportRateHz == 4000)
    }

    @Test("Side buttons read from the button map and encode the shortcuts the mouse accepted")
    @MainActor
    func sideButtons() throws {
        // A button map reply captured from the mouse: left, right, middle, back, forward, DPI, …, wheel.
        var reply: [UInt8] = [0x43, 0x00, 0xA4, 0x01]
        reply += [0x01, 0x00, 0xF0, 0x00, 0x01, 0x00, 0xF1, 0x00, 0x01, 0x00, 0xF2, 0x00, 0x01, 0x00, 0xF3, 0x00]
        reply += [0x01, 0x00, 0xF4, 0x00, 0x07, 0x00, 0x03, 0x00, 0x05, 0x00, 0x03, 0x00, 0x01, 0x00, 0xF8, 0x01]
        reply += [UInt8](repeating: 0, count: 64 - reply.count)

        let back = try #require(KeychronMouseProtocol.assignment(of: .back, inButtonMap: reply))
        let forward = try #require(KeychronMouseProtocol.assignment(of: .forward, inButtonMap: reply))
        #expect(back == KeychronMouseProtocol.SideButton.back.factoryAssignment)
        #expect(KeychronMouseProtocol.action(for: back, on: .back) == .systemDefault)
        #expect(KeychronMouseProtocol.action(for: forward, on: .forward) == .systemDefault)
        #expect(KeychronMouseProtocol.action(for: back, on: .forward) == nil)

        // ⌘[ as written to and confirmed on the mouse.
        #expect(KeychronMouseProtocol.assignment(for: .navigateBack, on: .back) == [0x00, 0x08, 0x2F, 0x00])
        #expect(KeychronMouseProtocol.assignment(for: .toggleCaffeine, on: .back) == nil)
        for action in KeychronMouseProtocol.buttonActions {
            // Shortcuts turned off on this Mac can't be assigned.
            guard let assignment = KeychronMouseProtocol.assignment(for: action, on: .forward) else { continue }
            #expect(KeychronMouseProtocol.action(for: assignment, on: .forward) == action)
        }

        let write = KeychronMouseProtocol.packet(.writeButton, routed: true, payload: [0x03, 0x00, 0x08, 0x2F, 0x00])
        #expect(Array(write[0...8]) == [0x43, 0x00, 0x85, 0x04, 0x03, 0x00, 0x08, 0x2F, 0x00])
    }

    @Test("Custom shortcuts become key entries with HID usages and modifier bits")
    @MainActor
    func shortcutEncoding() {
        // ⌘W, a custom Mission Control shortcut.
        let commandW = AccessoryActions.Shortcut(keyCode: UInt16(kVK_ANSI_W), flags: [.maskCommand])
        #expect(KeychronMouseProtocol.keyAssignment(commandW) == [0x00, 0x08, 0x1A, 0x00])
        // ⌃⌥⇧→
        let arrow = AccessoryActions.Shortcut(keyCode: UInt16(kVK_RightArrow), flags: [.maskControl, .maskAlternate, .maskShift])
        #expect(KeychronMouseProtocol.keyAssignment(arrow) == [0x00, 0x07, 0x4F, 0x00])
        // A key without a HID usage in the table can't be sent.
        let unknown = AccessoryActions.Shortcut(keyCode: 0xFF, flags: [])
        #expect(KeychronMouseProtocol.keyAssignment(unknown) == nil)
    }

    @Test("DPI rounds to 50 within 100…26000")
    func dpiClamping() {
        #expect(KeychronMouseProtocol.clampDPI(824) == 800)
        #expect(KeychronMouseProtocol.clampDPI(30) == 100)
        #expect(KeychronMouseProtocol.clampDPI(40_000) == 26_000)
    }
}

// MARK: - Razer Chroma Protocol

@Suite("Razer Chroma packet framing and parsing")
struct RazerChromaProtocolTests {
    typealias P = RazerChromaProtocol

    /// A 90-byte reply with the given status, command and arguments.
    private func reply(status: UInt8 = 0x02, _ command: P.Command, _ arguments: [UInt8]) -> [UInt8] {
        var reply = P.packet(command, arguments: arguments)
        reply[0] = status
        return reply
    }

    @Test("Packets are 90 bytes with transaction ID, size, command and an XOR checksum of bytes 2–87")
    func packetLayout() {
        let packet = P.setBrightnessPacket(0x80)
        #expect(packet.count == 90)
        #expect(Array(packet[0..<11]) == [0x00, 0x1F, 0x00, 0x00, 0x00, 0x03, 0x0F, 0x04, 0x01, 0x00, 0x80])
        #expect(packet[88] == 0x03 ^ 0x0F ^ 0x04 ^ 0x01 ^ 0x00 ^ 0x80)
        #expect(packet[89] == 0x00)
    }

    @Test("Effect requests use the size and arguments the dock accepted")
    func effectPackets() {
        var lighting = P.Lighting(mode: .staticColor, primary: P.RGB(red: 0, green: 255, blue: 0))
        #expect(Array(P.setEffectPacket(lighting)![5...16]) == [0x09, 0x0F, 0x02, 0x01, 0x00, 0x01, 0x00, 0x00, 0x01, 0x00, 0xFF, 0x00])
        lighting.mode = .breathing
        lighting.breathing = .dual
        lighting.secondary = P.RGB(red: 0, green: 0, blue: 255)
        #expect(Array(P.setEffectPacket(lighting)![5...19]) == [0x0C, 0x0F, 0x02, 0x01, 0x00, 0x02, 0x02, 0x00, 0x02, 0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF])
        lighting.mode = .wave
        lighting.waveDirection = .rightToLeft
        #expect(Array(P.setEffectPacket(lighting)![5...12]) == [0x06, 0x0F, 0x02, 0x01, 0x00, 0x04, 0x02, 0x28])
        lighting.mode = nil
        #expect(P.setEffectPacket(lighting) == nil)
    }

    @Test("Replies are matched to their request and report busy, success or unsupported")
    func replyStatus() {
        let request = P.getBrightnessPacket()
        #expect(P.status(of: reply(.getBrightness, [0x01, 0x00, 0xFF]), answering: request) == .success)
        #expect(P.status(of: reply(status: 0x01, .getBrightness, []), answering: request) == .busy)
        #expect(P.status(of: reply(status: 0x05, .getBrightness, []), answering: request) == .notSupported)
        #expect(P.status(of: reply(.firmware, []), answering: request) == nil)
    }

    @Test("Firmware, serial and brightness decode from the dock's replies")
    func identityReplies() {
        #expect(P.parseFirmware(reply(.firmware, [0x01, 0x00])) == "1.0")
        #expect(P.parseSerial(reply(.serial, Array("712324U11900409".utf8))) == "712324U11900409")
        #expect(P.parseBrightness(reply(.getBrightness, [0x01, 0x00, 0x80])) == 0x80)
    }

    @Test("Stored effects decode, keeping colors the effect doesn't use")
    func effectReplies() {
        let previous = P.Lighting(mode: .off, primary: P.RGB(red: 1, green: 2, blue: 3))
        let spectrum = P.parseLighting(reply(.getEffect, [0x01, 0x00, 0x03, 0x00, 0x04, 0x01, 0xFF, 0x00, 0x00]), previous: previous)
        #expect(spectrum?.mode == .spectrum)
        #expect(spectrum?.primary == P.RGB(red: 1, green: 2, blue: 3))

        let breathing = P.parseLighting(reply(.getEffect, [0x01, 0x00, 0x02, 0x02, 0x00, 0x02, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF]), previous: previous)
        #expect(breathing?.mode == .breathing)
        #expect(breathing?.breathing == .dual)
        #expect(breathing?.primary == P.RGB(red: 255, green: 0, blue: 0))
        #expect(breathing?.secondary == P.RGB(red: 0, green: 0, blue: 255))

        let wave = P.parseLighting(reply(.getEffect, [0x01, 0x00, 0x04, 0x02, 0x28]), previous: previous)
        #expect(wave?.mode == .wave)
        #expect(wave?.waveDirection == .rightToLeft)

        let unknown = P.parseLighting(reply(.getEffect, [0x01, 0x00, 0x07]), previous: previous)
        #expect(unknown != nil)
        #expect(unknown?.mode == nil)
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

// MARK: - MX Gestures

@Suite("MX Master hold-and-drag gesture recognition")
struct MXGestureTrackerTests {
    private let thumb: UInt16 = 0x00C3
    private let panel: UInt16 = 0x01A0

    @Test("Releasing with only a little wobble is a click")
    func smallWobbleIsClick() {
        var tracker = MXGestureTracker()
        tracker.press(thumb)
        tracker.move(dx: 10, dy: -12)
        #expect(tracker.release(thumb, threshold: 100) == .click)
    }

    @Test("Direction comes from the dominant axis of the whole drag", arguments: [
        (0, -150, MXGestureTracker.Direction.up),
        (0, 150, .down),
        (-150, 0, .left),
        (150, 0, .right)
    ])
    func directions(dx: Int, dy: Int, expected: MXGestureTracker.Direction) {
        var tracker = MXGestureTracker()
        tracker.press(thumb)
        tracker.move(dx: dx, dy: dy)
        #expect(tracker.release(thumb, threshold: 100) == .gesture(expected))
    }

    @Test("A drag that starts sideways but ends mostly upward is an up gesture")
    func curvedDragUsesTotal() {
        var tracker = MXGestureTracker()
        tracker.press(thumb)
        tracker.move(dx: 60, dy: 0)
        tracker.move(dx: 20, dy: -200)
        #expect(tracker.release(thumb, threshold: 50) == .gesture(.up))
    }

    @Test("Only the control that started the hold ends it")
    func otherControlIgnored() {
        var tracker = MXGestureTracker()
        tracker.press(thumb)
        tracker.press(panel)
        tracker.move(dx: 0, dy: 200)
        #expect(tracker.release(panel, threshold: 100) == .none)
        #expect(tracker.release(thumb, threshold: 100) == .gesture(.down))
    }

    @Test("Motion without a held control and a cancelled hold are ignored")
    func motionAndCancel() {
        var tracker = MXGestureTracker()
        tracker.move(dx: 500, dy: 0)
        tracker.press(panel)
        #expect(tracker.release(panel, threshold: 100) == .click)

        tracker.press(thumb)
        tracker.move(dx: 500, dy: 0)
        tracker.cancel()
        #expect(tracker.release(thumb, threshold: 100) == .none)
    }
}

// MARK: - MX Onboard Memory

@Suite("MX Master button remaps saved to the mouse")
struct MXMouseMemoryTests {
    @Test("Remap packet leaves diversion alone and names the target control")
    func remapPacket() {
        let packet = HIDPPProtocol.setControlRemapPacket(deviceIndex: 0x01, featureIndex: 0x09, controlID: 0x00C3, target: 0x0053)
        #expect(Array(packet[0...8]) == [0x11, 0x01, 0x09, 0x3A, 0x00, 0xC3, 0x00, 0x00, 0x53])
    }

    @Test("Remap read-back treats a zero target as not remapped")
    func remapReadBack() {
        var reply = [UInt8](repeating: 0, count: 20)
        reply[4] = 0x00; reply[5] = 0xC3
        #expect(HIDPPProtocol.parseControlRemap(reply, controlID: 0x00C3) == 0x00C3)
        reply[7] = 0x00; reply[8] = 0x53
        #expect(HIDPPProtocol.parseControlRemap(reply, controlID: 0x00C3) == 0x0053)
        #expect(HIDPPProtocol.parseControlRemap(reply, controlID: 0x0052) == nil)
    }

    @Test("A control can only be remapped onto a group in its mask")
    func remapGroups() {
        let thumb = HIDPPProtocol.ControlInfo(cid: 0x00C3, flags: 0x30, group: 3, groupMask: 0b0011)
        let back = HIDPPProtocol.ControlInfo(cid: 0x0053, flags: 0x30, group: 2, groupMask: 0b0011)
        let shift = HIDPPProtocol.ControlInfo(cid: 0x00C4, flags: 0x30, group: 4, groupMask: 0)
        let fixed = HIDPPProtocol.ControlInfo(cid: 0x0052, flags: 0x20, group: 1, groupMask: 0b0011)
        #expect(thumb.canRemap(to: back))
        #expect(!thumb.canRemap(to: shift))
        #expect(!fixed.canRemap(to: back))
        #expect(fixed.canRemap(to: fixed))
    }

    @Test("Only Back, Forward and the wheel-mode toggle have native controls")
    func nativeControls() {
        #expect(MXMasterManager.nativeControl(for: .navigateBack) == HIDPPProtocol.cidBackButton)
        #expect(MXMasterManager.nativeControl(for: .navigateForward) == HIDPPProtocol.cidForwardButton)
        #expect(MXMasterManager.nativeControl(for: .toggleWheelMode) == HIDPPProtocol.cidModeShiftButton)
        #expect(MXMasterManager.nativeControl(for: .missionControl) == nil)
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


