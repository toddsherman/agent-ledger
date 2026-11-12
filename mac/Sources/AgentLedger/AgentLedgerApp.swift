import SwiftUI
import LedgerCore

@main
struct AgentLedgerApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var updater = UpdaterModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(model)
                .environmentObject(updater)
        } label: {
            Image(nsImage: Logo.image(model.logoState, points: 18))
                .accessibilityLabel(model.logoStateText)
        }
        .menuBarExtraStyle(.window)

        Window("Agent Ledger", id: "ledger") {
            LedgerWindow()
                .environmentObject(model)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1180, height: 760)
        .handlesExternalEvents(matching: ["ledger"])
        .commands {
            // Quit from the menu or with Command-Q counts as your choice, so the app isn't restarted.
            CommandGroup(replacing: .appTermination) {
                Button("Quit Agent Ledger") { model.quitByUser() }.keyboardShortcut("q")
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(updater)
        }
    }
}
