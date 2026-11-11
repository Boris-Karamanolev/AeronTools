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
