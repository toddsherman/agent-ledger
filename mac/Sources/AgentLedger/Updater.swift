import AppKit
import Sparkle

/// Wraps Sparkle's standard updater. Feed URL and public EdDSA key come from Info.plist
/// (SUFeedURL, SUPublicEDKey). Updates are only offered when the app runs from a bundle
/// that carries a real key, so development builds never try to update themselves.
final class UpdaterModel: ObservableObject {
    static let shared = UpdaterModel()
    private let controller: SPUStandardUpdaterController?
    @Published var canCheckForUpdates = false
    private var observation: NSKeyValueObservation?

    init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        let isBundled = Bundle.main.bundleURL.pathExtension == "app"
        guard isBundled, !key.isEmpty, !key.hasPrefix("REPLACE") else {
            controller = nil
            return
        }
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        controller = c
        observation = c.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            DispatchQueue.main.async { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
    }

    var isAvailable: Bool { controller != nil }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(v) (\(b))"
    }
}
