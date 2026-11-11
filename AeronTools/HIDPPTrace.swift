#if DEBUG
import Foundation

/// Debug-only, passive HID++ trace for mapping undocumented features. Records every report a Logitech receiver
/// delivers (replies to other software such as G HUB, device events, and this app's own replies, which only
/// happen right after launch), so the bytes a setting changes can be read without sending anything to an
/// unknown feature. Other software may use the same software IDs as this app, so nothing is filtered out.
///
/// Off unless enabled: `defaults write com.aeronlabs.aerontools hidppTrace -bool YES`
/// Output: /tmp/aeron-hidpp-trace.log
enum HIDPPTrace {
    private static let isEnabled = UserDefaults.standard.bool(forKey: "hidppTrace")
    private static let url = URL(fileURLWithPath: "/tmp/aeron-hidpp-trace.log")

    static func record(_ report: [UInt8]) {
        guard isEnabled, report.count >= 4 else { return }

        let time = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second().secondFraction(.fractional(3)))
        let line = time + "  " + report.map { String(format: "%02X", $0) }.joined(separator: " ") + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
#endif
