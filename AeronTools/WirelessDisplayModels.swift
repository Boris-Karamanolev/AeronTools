import Foundation
import CoreGraphics

// MARK: - Connection Mode

nonisolated enum ConnectionMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case sameNetwork = "Same Network (Wi-Fi / LAN)"
    case hotspotSharedInternet = "Hotspot · Share Internet"
    case hotspotScreenOnly = "Hotspot · Screen Only (Captive)"

    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .sameNetwork:
            return "Mac and client device are on the same Wi-Fi router or phone hotspot."
        case .hotspotSharedInternet:
            return "Mac shares internet via Wi-Fi hotspot while streaming the virtual display."
        case .hotspotScreenOnly:
            return "Local Wi-Fi hotspot for screen streaming only (intercepts captive portal checks)."
        }
    }

    var systemImage: String {
        switch self {
        case .sameNetwork: return "wifi"
        case .hotspotSharedInternet: return "personalhotspot"
        case .hotspotScreenOnly: return "antenna.radiowaves.left.and.right"
        }
    }
}

// MARK: - Display Resolution Presets

nonisolated enum DisplayPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case teslaModel3Y = "Tesla 15.4\" (1920×1200)"
    case teslaFullBrowser = "Tesla Browser Canvas (1920×1080)"
    case ipadPro13 = "iPad Pro 13\" (2064×1548)"
    case ipadAir11 = "iPad 11\" (1920×1340)"
    case fhd16x9 = "Full HD 16:9 (1920×1080)"
    case qhd16x9 = "QHD 16:9 (2560×1440)"
    case wuxga16x10 = "WUXGA 16:10 (1920×1200)"
    case hd720p = "Low Latency 720p (1280×720)"
    case ultrawide = "Ultrawide 21:9 (2560×1080)"

    var id: String { rawValue }

    var shortName: String {
        switch self {
        case .teslaModel3Y: return "Tesla 15.4\""
        case .teslaFullBrowser: return "Tesla Canvas"
        case .ipadPro13: return "iPad Pro 13\""
        case .ipadAir11: return "iPad 11\""
        case .fhd16x9: return "1080p Full HD"
        case .qhd16x9: return "1440p QHD"
        case .wuxga16x10: return "1200p WUXGA"
        case .hd720p: return "720p HD"
        case .ultrawide: return "Ultrawide 21:9"
        }
    }

    var width: Int {
        switch self {
        case .teslaModel3Y: return 1920
        case .teslaFullBrowser: return 1920
        case .ipadPro13: return 2064
        case .ipadAir11: return 1920
        case .fhd16x9: return 1920
        case .qhd16x9: return 2560
        case .wuxga16x10: return 1920
        case .hd720p: return 1280
        case .ultrawide: return 2560
        }
    }

    var height: Int {
        switch self {
        case .teslaModel3Y: return 1200
        case .teslaFullBrowser: return 1080
        case .ipadPro13: return 1548
        case .ipadAir11: return 1340
        case .fhd16x9: return 1080
        case .qhd16x9: return 1440
        case .wuxga16x10: return 1200
        case .hd720p: return 720
        case .ultrawide: return 1080
        }
    }

    var aspectRatioLabel: String {
        switch self {
        case .teslaModel3Y, .wuxga16x10: return "16:10"
        case .teslaFullBrowser, .fhd16x9, .qhd16x9, .hd720p: return "16:9"
        case .ipadPro13: return "4:3"
        case .ipadAir11: return "10:7"
        case .ultrawide: return "21:9"
        }
    }
}

// MARK: - Display Scale

nonisolated enum DisplayScale: String, CaseIterable, Identifiable, Codable, Sendable {
    case compact = "0.75× (More Space)"
    case standard = "1.0× (Native)"
    case crisp = "1.5× (HiDPI Scaled)"
    case retina = "2.0× (Retina HiDPI)"

    var id: String { rawValue }

    var multiplier: Double {
        switch self {
        case .compact: return 0.75
        case .standard: return 1.0
        case .crisp: return 1.5
        case .retina: return 2.0
        }
    }

    var usesHiDPI: Bool {
        switch self {
        case .compact, .standard: return false
        case .crisp, .retina: return true
        }
    }
}

// MARK: - Display Source Type

nonisolated enum DisplaySourceType: String, CaseIterable, Identifiable, Codable, Sendable {
    case virtualExtended = "Extended Virtual Display"
    case mainDisplayMirror = "Mirror MacBook Screen"

    var id: String { rawValue }
}

// MARK: - Single Wireless Display Configuration

nonisolated struct WirelessDisplayConfig: Codable, Equatable, Sendable {
    var sourceType: DisplaySourceType
    var preset: DisplayPreset
    var scale: DisplayScale
    var fps: Int
    var jpegQuality: Double
    var allowTouch: Bool

    init(
        sourceType: DisplaySourceType = .virtualExtended,
        preset: DisplayPreset = .teslaModel3Y,
        scale: DisplayScale = .standard,
        fps: Int = 30,
        jpegQuality: Double = 0.72,
        allowTouch: Bool = true
    ) {
        self.sourceType = sourceType
        self.preset = preset
        self.scale = scale
        self.fps = fps
        self.jpegQuality = jpegQuality
        self.allowTouch = allowTouch
    }

    /// Logical point width exposed to macOS WindowServer.
    var logicalWidth: Int {
        switch scale {
        case .compact:
            return Int((Double(preset.width) / scale.multiplier).rounded())
        case .standard, .crisp, .retina:
            return preset.width
        }
    }

    /// Logical point height exposed to macOS WindowServer.
    var logicalHeight: Int {
        switch scale {
        case .compact:
            return Int((Double(preset.height) / scale.multiplier).rounded())
        case .standard, .crisp, .retina:
            return preset.height
        }
    }

    /// Backing framebuffer width used for capture and HiDPI registration.
    var backingPixelWidth: Int {
        switch scale {
        case .compact, .standard:
            return logicalWidth
        case .crisp, .retina:
            return Int((Double(preset.width) * scale.multiplier).rounded())
        }
    }

    /// Backing framebuffer height used for capture and HiDPI registration.
    var backingPixelHeight: Int {
        switch scale {
        case .compact, .standard:
            return logicalHeight
        case .crisp, .retina:
            return Int((Double(preset.height) * scale.multiplier).rounded())
        }
    }
}

// MARK: - Touch / Input Event Payload

nonisolated struct TouchEventPayload: Codable, Sendable {
    let type: String // "down", "move", "up", "click", "rightClick", "doubleClick", "scroll"
    let x: Double    // Normalized 0.0 ... 1.0
    let y: Double    // Normalized 0.0 ... 1.0
    let deltaX: Double?
    let deltaY: Double?
}

// MARK: - Diagnostic Log Entry

nonisolated struct DiagnosticEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let level: Level
    let message: String

    enum Level: String, Sendable {
        case info = "INFO"
        case success = "OK"
        case warning = "WARN"
        case error = "ERR"
    }
}
