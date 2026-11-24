import Foundation
import SwiftUI

// MARK: - GameModePolicy & Status

public enum GameModePolicy: String, CaseIterable, Identifiable, Equatable, Sendable {
    case automatic = "auto"
    case forcedOn = "on"
    case forcedOff = "off"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .forcedOn: return "Forced On"
        case .forcedOff: return "Forced Off"
        }
    }
}

public struct GameModeStatus: Equatable, Sendable {
    public let isActive: Bool
    public let policy: GameModePolicy

    public var isForcedOn: Bool {
        policy == .forcedOn
    }

    public var displayText: String {
        let state = isActive ? "On" : "Off"
        return "\(state) · \(policy.title)"
    }
}

// MARK: - GameModeManager

@Observable
@MainActor
public final class GameModeManager {
    public static let shared = GameModeManager()

    public private(set) var status: GameModeStatus?
    public private(set) var isUpdating: Bool = false
    public private(set) var errorMessage: String?

    public var isGameModeActive: Bool {
        status?.isActive == true
    }

    public var isForcedOn: Bool {
        status?.isForcedOn == true
    }

    public var statusText: String {
        if let status {
            return status.displayText
        }
        if let errorMessage {
            return errorMessage
        }
        return "Checking…"
    }

    private nonisolated static let directToolPaths = [
        "/Applications/Xcode.app/Contents/Developer/usr/bin/gamepolicyctl",
        "/Library/Developer/CommandLineTools/usr/bin/gamepolicyctl",
        "/usr/libexec/gamepolicyctl"
    ]

    private init() {
        guard !AppDelegate.isRunningTests else { return }
        Task {
            await refreshStatus()
        }
    }

    /// Strips ANSI CSI color/style escape sequences (e.g. `\u{001B}[0;32mon\u{001B}[0;0m`) emitted by `gamepolicyctl`.
    nonisolated static func strippingANSIEscapeCodes(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{001B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }

    /// Parses the output of `gamepolicyctl game-mode status`.
    nonisolated static func parseStatusOutput(_ output: String) -> GameModeStatus? {
        let lower = strippingANSIEscapeCodes(output).lowercased()
        let isActive: Bool
        if lower.contains("game mode is on") {
            isActive = true
        } else if lower.contains("game mode is off") {
            isActive = false
        } else {
            return nil
        }

        let policy: GameModePolicy
        if lower.contains("forced always on") {
            policy = .forcedOn
        } else if lower.contains("forced always off") || lower.contains("currently disabled") {
            policy = .forcedOff
        } else if lower.contains("currently automatic") {
            policy = .automatic
        } else {
            return nil
        }

        return GameModeStatus(isActive: isActive, policy: policy)
    }

    public func refreshStatus() async {
        guard let result = await Self.runGamePolicyCtl(arguments: ["game-mode", "status"]) else {
            status = nil
            errorMessage = "Unavailable"
            return
        }
        if let parsed = Self.parseStatusOutput(result.output) {
            status = parsed
            errorMessage = nil
        } else if result.exitCode != 0 {
            errorMessage = "Unavailable"
        }
    }

    public func forceGameModeOn() {
        setPolicy(.forcedOn)
    }

    public func toggleForcedOn() {
        setPolicy(isForcedOn ? .automatic : .forcedOn)
    }

    public func setPolicy(_ policy: GameModePolicy) {
        guard !isUpdating else { return }
        isUpdating = true
        Task {
            defer { isUpdating = false }
            let setResult = await Self.runGamePolicyCtl(arguments: ["game-mode", "set", policy.rawValue])
            if setResult == nil || setResult?.exitCode != 0 {
                errorMessage = "Unable to set Game Mode"
            }
            await refreshStatus()
        }
    }

    private nonisolated static func resolveExecutable() -> (url: URL, prefixArguments: [String])? {
        let fm = FileManager.default
        for path in directToolPaths where fm.isExecutableFile(atPath: path) {
            return (URL(fileURLWithPath: path), [])
        }
        let xcrunPath = "/usr/bin/xcrun"
        if fm.isExecutableFile(atPath: xcrunPath) {
            return (URL(fileURLWithPath: xcrunPath), ["gamepolicyctl"])
        }
        return nil
    }

    nonisolated static func runGamePolicyCtl(arguments: [String]) async -> (exitCode: Int32, output: String)? {
        guard let executable = resolveExecutable() else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable.url
            process.arguments = executable.prefixArguments + arguments

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
            } catch {
                return nil
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus, output)
        }.value
    }
}
