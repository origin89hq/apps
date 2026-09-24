# Origin89 apps

Web, desktop and mobile applications for Origin89 controllers. The first target
is a native iOS app in SwiftUI. It sets up a controller: scan or paste its setup
code, connect over Bluetooth, pair inside the panel's pairing window, read and
write the network section, and optionally set the controller's clock.

## iOS development

Use macOS with Xcode 26 and its iOS Simulator SDK. Install just 1.58.0 using the
pinned `mise.toml` (`mise install`), or install that version directly. Install
[rustup](https://rustup.rs); `rust-toolchain.toml` pins the Rust version and
adds the `aarch64-apple-ios` and `aarch64-apple-ios-sim` targets on first use.

```sh
just skills-sync
just check
just open
```

`just open` builds the Rust core first; Xcode cannot resolve the `SetupCore`
package until `apps/ios/SetupCore/Generated/` exists. Rebuild it with
`just ios-core` after changing `crates/`.

Select the Origin89 scheme and an iPhone simulator in Xcode, then Run. The
Rust core is built for arm64 only, so the simulator build needs an Apple silicon
Mac.
The deployment target is iOS 17. For a physical iPhone, select your development
team under Signing & Capabilities and use a bundle identifier available to that
team. Signing credentials and team IDs stay local. The scaffold uses
`com.origin89.apps.ios`; its registration is not assumed.

`just check` runs, in order:

- Swift formatting lint for the app, `SetupKit` and `SetupCore`;
- `cargo fmt --check`, Clippy with warnings denied, and `cargo test`, which
  include the KM43 vectors for pairing, configuration and BLE fragmentation;
- `swift test` for `SetupKit`, the setup flow and Bluetooth transport against fakes;
- the Rust core build for device and simulator, and the unsigned simulator app build.

The simulator has no Bluetooth, so a simulator build is compile evidence only.
It has no camera either, so it offers only paste; a phone offers both scan and paste.
Pairing, Bluetooth and the network write need the bench: a controller with the
BLE comms image, an iPhone, and the controller's printed setup code.

## Layout

`apps/ios/` owns the native Xcode project. Edit it directly in Xcode; no project
generator is needed.

- `apps/ios/Origin89/`: the SwiftUI app.
- `apps/ios/SetupKit/`: the setup flow, the transport seam and the Core Bluetooth
  transport; platform-neutral and tested on the host with `swift test`.
- `apps/ios/SetupCore/`: the Rust core as a Swift package. `Generated/` holds
  the XCFramework and UniFFI bindings from `scripts/build-ios-core.sh` and is not
  checked in; `Sources/` adapts them to `SetupKit`.
- `crates/setup/`: the Rust setup core over the [KM43](https://github.com/origin89hq/km43)
  crate: the setup code parser, the pairing and configuration exchange, and BLE
  fragmentation. Keys and session state never leave it.

Add `apps/android/`, `apps/web/` and `apps/desktop/` when work on those
applications starts. Shared TypeScript packages belong in `packages/`.

## Shared UI

The iOS target links `Origin89UI` through Swift Package Manager from
[Origin89 UI](https://github.com/origin89hq/ui). Import `Origin89UI` in screens
that use its components. The package includes native brand tokens, fonts and
resource licenses; do not copy those assets into the app.

The dependency uses the exact Swift package version `0.4.0`.
Commit the Xcode project and `Package.resolved` together when updating it.
Xcode resolves the dependency on first open; the initial build needs network
access, and later builds can use the cached checkout.

The wire format is the `km43` crate, pinned exactly in `Cargo.toml`. Do not
reimplement it in Swift.

See [contributing](CONTRIBUTING.md) for engineering instructions and checks.
