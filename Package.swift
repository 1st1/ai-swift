// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "ai-swift",
  platforms: [.macOS(.v13), .iOS(.v16)],
  products: [
    .library(name: "AI", targets: ["AI"]),
    .executable(name: "agent-example", targets: ["AgentExample"]),
  ],
  targets: [
    .target(name: "AI"),
    .executableTarget(name: "AgentExample", dependencies: ["AI"]),
    .testTarget(name: "AITests", dependencies: ["AI"]),
  ]
)
