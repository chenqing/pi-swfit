// swift-tools-version:6.0
import PackageDescription

// Community Swift port of earendil-works/pi (upstream commit 16f5f0af4, 2026-10-21).
// Runtime targets mirror upstream packages; PiChat, PiUI and PiCLI are native additions.
// Runtime files mirror upstream `src/` paths
// (e.g. Sources/PiAI/api/anthropic-messages.swift <- packages/ai/src/api/anthropic-messages.ts).
let package = Package(
    name: "Pi",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "PiMCPConformance", targets: ["PiMCPConformance"]),
        .executable(name: "PiCodeModeRunner", targets: ["PiCodeModeRunner"]),
        .executable(name: "pf", targets: ["pf"]),
        .library(name: "PiCLI", targets: ["PiCLI"]),
        .library(name: "PiHost", targets: ["PiHost"]),
        .executable(name: "PiPlayground", targets: ["PiPlayground"]),
        .library(name: "PiChat", targets: ["PiChat"]),
        .library(name: "PiUI", targets: ["PiUI"]),
        .library(name: "PiAI", targets: ["PiAI"]),
        .library(name: "PiAgent", targets: ["PiAgent"]),
        .library(name: "PiCodingAgent", targets: ["PiCodingAgent"]),
        .library(name: "PiMCP", targets: ["PiMCP"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.1.0"),
    ],
    targets: [
        .executableTarget(name: "PiMCPConformance", dependencies: ["PiAI", "PiMCP"]),
        .executableTarget(name: "PiCodeModeRunner"),
        // packages/ai
        .target(name: "PiAI"),
        // packages/agent
        .target(name: "PiAgent", dependencies: ["PiAI"]),
        .target(name: "PiMCP", dependencies: ["PiAI"]),
        // packages/coding-agent (sessions, resource configuration and skills; partial port)
        .target(name: "PiCodingAgent", dependencies: ["PiAI", "PiAgent", "PiMCP", .product(name: "Yams", package: "Yams")]),

        .target(name: "PiHost", dependencies: ["PiAI", "PiAgent", "PiCodingAgent"]),
        .testTarget(name: "PiHostTests", dependencies: ["PiHost", "PiChat"]),
        .target(name: "PiCLI", dependencies: ["PiAI", "PiAgent", "PiCodingAgent", "PiHost"]),
        .executableTarget(name: "pf", dependencies: ["PiCLI"]),
        .testTarget(name: "PiCLITests", dependencies: ["PiCLI", "PiAI", "PiAgent"]),
        .target(name: "PiChat", dependencies: ["PiAI", "PiAgent", "PiCodingAgent", "PiHost"]),
        .target(name: "PiUI", dependencies: ["PiChat"]),
        .executableTarget(name: "PiPlayground", dependencies: ["PiUI", "PiChat", "PiAI", "PiHost", "PiCodingAgent"], path: "Examples/PiPlayground"),
        .testTarget(name: "PiChatTests", dependencies: ["PiChat", "PiAgent", "PiAI"]),
        .testTarget(name: "PiAITests", dependencies: ["PiAI"]),
        .testTarget(name: "PiMCPTests", dependencies: ["PiMCP", "PiAI"]),
        .testTarget(name: "PiAgentTests", dependencies: ["PiAgent", "PiAI"]),
        .testTarget(name: "PiCodingAgentTests", dependencies: ["PiCodingAgent", "PiAgent", "PiAI"]),
    ],
    swiftLanguageModes: [.v6]
)
