// swift-tools-version: 6.0
import PackageDescription

// A macOS command-line tool that runs the app's setup flow against a real
// controller over this Mac's Bluetooth, for bench debugging. It needs the Rust
// core built with `just ios-core`. It operates equipment: never run it from
// `just check`.
let package = Package(
  name: "SetupBench",
  platforms: [.macOS(.v14)],
  dependencies: [.package(path: "../SetupKit"), .package(path: "../SetupCore")],
  targets: [
    .executableTarget(
      name: "SetupBench",
      dependencies: [
        .product(name: "SetupKit", package: "SetupKit"),
        .product(name: "SetupCore", package: "SetupCore"),
      ],
      // macOS asks for Bluetooth permission with this usage string.
      linkerSettings: [
        .unsafeFlags([
          "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
          "-Xlinker", Context.packageDirectory + "/Info.plist",
        ])
      ])
  ],
  swiftLanguageModes: [.v6]
)
