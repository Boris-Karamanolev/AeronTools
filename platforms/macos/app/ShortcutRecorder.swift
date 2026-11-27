import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Click to record a global shortcut. Esc cancels, Delete clears. Existing shortcuts are suspended while recording
/// so pressing one doesn't trigger its action.
struct ShortcutRecorder: View {
    let action: HotKeyAction
    var manager = HotKeyManager.shared

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var rejectedModifiers = false

    var body: some View {
        HStack(spacing: 8) {
            Text(action.title)

            Spacer()

            if manager.conflicts.contains(action) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help("This shortcut is already used by another app or macOS.")
            }

            Button {
                isRecording ? stopRecording() : startRecording()
            } label: {
                Text(buttonTitle)
                    .font(.system(.body, design: isRecording ? .default : .monospaced))
                    .frame(minWidth: 110)
            }
            .help(isRecording ? "Press a shortcut with ⌘, ⌃ or ⌥. Esc cancels, Delete clears." : "Click to record a shortcut")

            if manager.shortcut(for: action) != nil && !isRecording {
                Button {
                    manager.setShortcut(nil, for: action)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear shortcut")
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private var buttonTitle: String {
        if isRecording {
            return rejectedModifiers ? "Add ⌘, ⌃ or ⌥" : "Type Shortcut…"
        }
        return manager.shortcut(for: action)?.displayString ?? "Record Shortcut"
    }

    private func startRecording() {
        manager.suspend()
        rejectedModifiers = false
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        let modifiers = KeyboardShortcut.carbonModifiers(from: event.modifierFlags)
        let keyCode = Int(event.keyCode)

        if modifiers == 0 && keyCode == kVK_Escape {
            stopRecording()
            return
        }
        if modifiers == 0 && (keyCode == kVK_Delete || keyCode == kVK_ForwardDelete) {
            stopRecording()
            manager.setShortcut(nil, for: action)
            return
        }
        guard KeyboardShortcut.isValidGlobal(modifiers: modifiers) else {
            rejectedModifiers = true
            NSSound.beep()
            return
        }

        let shortcut = KeyboardShortcut(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: modifiers,
            keyLabel: KeyboardShortcut.keyLabel(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers)
        )
        stopRecording()
        manager.setShortcut(shortcut, for: action)
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        if isRecording {
            isRecording = false
            manager.resume()
        }
    }
}
