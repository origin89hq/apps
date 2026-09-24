// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "SetupKit",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [.library(name: "SetupKit", targets: ["SetupKit"])],
  targets: [
    .target(name: "SetupKit"), .testTarget(name: "SetupKitTests", dependencies: ["SetupKit"]),
  ],
  swiftLanguageModes: [.v6]
)
