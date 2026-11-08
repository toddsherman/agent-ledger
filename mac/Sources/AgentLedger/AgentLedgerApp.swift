import SwiftUI
import LedgerCore

@main
struct AgentLedgerApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var updater = UpdaterModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(model)
                .environmentObject(updater)
        } label: {
            Image(systemName: menuIcon)
        }
        .menuBarExtraStyle(.window)

        Window("Agent Ledger", id: "ledger") {
            LedgerWindow()
                .environmentObject(model)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1180, height: 760)

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(updater)
        }
    }

    private var menuIcon: String {
        if model.status.paused { return "pause.circle" }
        if model.status.sessions.contains(where: { $0.state == "recording" }) { return "record.circle.fill" }
        if !model.status.sessions.isEmpty { return "record.circle" }
        return "circle.dashed"
    }
}
