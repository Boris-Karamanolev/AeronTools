import SwiftUI
import AppKit

// MARK: - ContentView

public struct ContentView: View {
    @Bindable var model = DisplayStateModel.shared
    @Bindable var wireless = WirelessDisplayManager.shared
    @Bindable var gameMode = GameModeManager.shared

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header Bar
            HStack(spacing: 8) {
                Label {
                    Text("Aeron Tools")
                        .font(.system(size: 13, weight: .bold))
                } icon: {
                    Image(nsImage: AeronToolsIcon.menuBarImage(
                        isCaffeineActive: false,
                        isStreaming: wireless.isStreaming,
                        hasExternalDisplays: true
                    ))
                    .foregroundStyle(Color.accentColor)
                }

                Spacer()

                // Game Mode: click forces Game Mode on (or restores automatic), menu shows status and policy options.
                Menu {
                    Section("Game Mode (\(gameMode.statusText))") {
                        Button("Force Game Mode On") {
                            gameMode.forceGameModeOn()
                        }
                        Button("Automatic") {
                            gameMode.setPolicy(.automatic)
                        }
                        Button("Force Off") {
                            gameMode.setPolicy(.forcedOff)
                        }
                    }
                } label: {
                    Image(systemName: gameMode.isGameModeActive ? "gamecontroller.fill" : "gamecontroller")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(gameMode.isGameModeActive ? Color.green : Color.secondary)
                } primaryAction: {
                    gameMode.toggleForcedOn()
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
                .help(gameModeHelp)

                // Caffeine: click toggles, the menu offers timed sessions.
                Menu {
                    Section("Keep Mac Awake") {
                        ForEach(CaffeineDuration.allCases) { duration in
                            Button(duration.title) {
                                model.startCaffeine(for: duration.seconds)
                            }
                        }
                    }
                    if model.isCaffeinated {
                        Divider()
                        Button("Turn Off Caffeine") {
                            model.isCaffeinated = false
                        }
                    }
                } label: {
                    Image(systemName: model.isCaffeineActive ? "cup.and.heat.waves.fill" : "cup.and.saucer")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(model.isCaffeineActive ? Color.orange : Color.secondary)
                } primaryAction: {
                    model.toggleCaffeine()
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
                .help(caffeineHelp)

                // Settings Button
                Button {
                    StatusBarController.shared.closePopover()
                    SettingsWindowController.shared.show()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(5)
                }
                .buttonStyle(.plain)
                .help("Settings… (⌘,)")

                // Quit Button
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(5)
                }
                .buttonStyle(.plain)
                .help("Quit Aeron Tools")
            }
            .padding(.horizontal, 2)

            // External Monitors Section
            ForEach(model.externalDisplays) { display in
                ExternalDisplayCard(display: display, model: model)
            }

            // MacBook Built-in Screen Card: only useful when another screen can take over (or to turn it back on)
            if model.isBuiltinPresent && (model.canTurnOffBuiltin || model.isBuiltinTurnedOff) {
                MacBookDisplayCard(model: model)
            }

            // Wireless Virtual Display & Web Stream Card
            if model.showWirelessDisplayCard {
                WirelessDisplayCardView()
            }

            // One card per connected accessory; each appears and disappears as its device connects
            if model.showAccessoriesCard {
                AccessoryCardsView()
            }

            // Wattage Meter Card
            if model.showWattageMeter {
                WattageCardView()
            }

            // Thermals Card
            if model.showThermals {
                ThermalsCardView()
            }

            // Quick Options Footer
            FooterSection(model: model, gameMode: gameMode)
        }
        .padding(14)
        .frame(width: 320)
    }

    private var gameModeHelp: String {
        if gameMode.isForcedOn {
            return "Game Mode: \(gameMode.statusText) – click to restore automatic"
        }
        return "Game Mode: \(gameMode.statusText) – click to force Game Mode on"
    }

    private var caffeineHelp: String {
        if model.isCaffeinated, let end = model.caffeineEndDate {
            return "Caffeine on until \(end.formatted(date: .omitted, time: .shortened)) – click to turn off"
        }
        if model.isCaffeinated {
            return "Caffeine on – click to turn off"
        }
        if model.isCaffeineAutomatic {
            return "Kept awake automatically (see Settings)"
        }
        return "Keep Mac awake – click, or use the arrow for a timer"
    }
}

// MARK: - FooterSection

private struct FooterSection: View {
    @Bindable var model: DisplayStateModel
    @Bindable var gameMode: GameModeManager

    /// Timed caffeine is rendered separately as a system-driven countdown, so this only covers the static states.
    private var caffeineStatus: String? {
        if model.isCaffeinated {
            return "Awake until turned off"
        }
        if model.isCaffeineAutomatic {
            return "Kept awake automatically"
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if gameMode.isGameModeActive {
                Label("Game Mode: \(gameMode.statusText)", systemImage: "gamecontroller.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            }

            if model.isCaffeinated, let end = model.caffeineEndDate {
                // Text(timerInterval:) is updated by the system, so the popover never re-renders to tick.
                Label {
                    Text("Awake for \(Text(timerInterval: min(Date(), end)...end, countsDown: true))")
                } icon: {
                    Image(systemName: "cup.and.heat.waves")
                }
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            } else if let status = caffeineStatus {
                Label(status, systemImage: "cup.and.heat.waves")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            HStack {
                if let shortcut = HotKeyManager.shared.shortcut(for: .restoreBuiltinScreen) {
                    Label("\(shortcut.displayString) restores MacBook screen", systemImage: "keyboard")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Button("More Settings…") {
                    StatusBarController.shared.closePopover()
                    SettingsWindowController.shared.show()
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 2)
    }
}
