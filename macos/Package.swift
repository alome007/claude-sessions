// swift-tools-version: 6.0
import PackageDescription

let package = Package(
	name: "ClaudeSessions",
	platforms: [.macOS("26.0")],
	targets: [
		.target(name: "ClaudeSessionsCore"),
		.executableTarget(name: "ClaudeSessions", dependencies: ["ClaudeSessionsCore"]),
		.testTarget(name: "ClaudeSessionsCoreTests", dependencies: ["ClaudeSessionsCore"]),
	],
	swiftLanguageModes: [.v5]
)
