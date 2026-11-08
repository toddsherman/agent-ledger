// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentLedger",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LedgerCore", targets: ["LedgerCore"]),
        .executable(name: "AgentLedger", targets: ["AgentLedger"]),
        .executable(name: "ledger-host", targets: ["ledger-host"]),
        .executable(name: "ledger-hook", targets: ["ledger-hook"]),
        .executable(name: "ledgerctl", targets: ["ledgerctl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(
            name: "LedgerCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "AgentLedger", dependencies: ["LedgerCore", .product(name: "Sparkle", package: "Sparkle")]),
        .executableTarget(name: "ledger-host", dependencies: ["LedgerCore"]),
        .executableTarget(name: "ledger-hook", dependencies: ["LedgerCore"]),
        .executableTarget(name: "ledgerctl", dependencies: ["LedgerCore"]),
        .testTarget(
            name: "LedgerCoreTests",
            dependencies: ["LedgerCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
