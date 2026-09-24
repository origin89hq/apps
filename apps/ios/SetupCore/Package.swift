// swift-tools-version: 6.0
import Foundation
import PackageDescription

// The Rust setup core (crates/setup) for the iOS app. `Generated/` is written by
// scripts/build-ios-core.sh and is not checked in.
let generated = Context.packageDirectory + "/Generated/Origin89SetupCoreFFI.xcframework"
if !FileManager.default.fileExists(atPath: generated) {
  fatalError("The Rust core is not built: run `just ios-core` from the repository root.")
}

let package = Package(
  name: "SetupCore",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [.library(name: "SetupCore", targets: ["SetupCore"])],
  dependencies: [.package(path: "../SetupKit")],
  targets: [
    .binaryTarget(
      name: "Origin89SetupCoreFFI", path: "Generated/Origin89SetupCoreFFI.xcframework"),
    .target(
      name: "Origin89SetupCore", dependencies: ["Origin89SetupCoreFFI"], path: "Generated/swift"),
    .target(
      name: "SetupCore",
      dependencies: ["Origin89SetupCore", .product(name: "SetupKit", package: "SetupKit")]),
  ],
  swiftLanguageModes: [.v6]
)
