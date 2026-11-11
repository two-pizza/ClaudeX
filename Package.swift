// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeXPolicy",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "ClaudeXPolicy", path: "Sources", exclude: [
            "Widget", "App/StatusController.swift", "App/UsageMenuView.swift",
            "App/Providers.swift", "App/Keychain.swift", "App/Log.swift", "App/main.swift"
        ], sources: ["Shared/Models.swift", "Shared/SharedStore.swift", "App/RefreshCoordinator.swift",
                     "App/HTTPClient.swift", "App/UsagePanelContent.swift",
                     "App/UpdateCheck.swift"]),
        .testTarget(name: "ClaudeXPolicyTests", dependencies: ["ClaudeXPolicy"], path: "Tests")
    ]
)
