# Origin89 apps

Web, desktop and mobile applications for Origin89 controllers. The first target
is a native iOS app in SwiftUI. It currently opens a blank window; connection,
pairing and product screens are not implemented.

## iOS development

Use macOS with Xcode 26 and its iOS Simulator SDK. Install just 1.58.0 using the
pinned `mise.toml` (`mise install`), or install that version directly.

```sh
just skills-sync
just check
just open
```

Select the Origin89 scheme and an iPhone simulator in Xcode, then Run.
The deployment target is iOS 17. For a physical iPhone, select your development
team under Signing & Capabilities and use a bundle identifier available to that
team. Signing credentials and team IDs stay local. The scaffold uses
`com.origin89.apps.ios`; its registration is not assumed.

`just check` checks Swift formatting and builds the simulator app without signing.
It does not test a device connection. There are no behavioral tests yet because
the scaffold has no application behavior. Add them with the first feature.

## Layout

`apps/ios/` owns the native Xcode project. Edit it directly in Xcode; no project
generator is needed. Add `apps/android/`, `apps/web/` and `apps/desktop/` when
work on those applications starts. Shared TypeScript packages belong in
`packages/` and Rust libraries in `crates/`, once they have actual consumers.

## Shared UI

The iOS target links `Origin89UI` through Swift Package Manager from
[Origin89 UI](https://github.com/origin89hq/ui). Import `Origin89UI` in screens
that use its components. The package includes native brand tokens, fonts and
resource licenses; do not copy those assets into the app.

The dependency uses the exact Swift package version `0.2.0`.
Commit the Xcode project and `Package.resolved` together when updating it.
Xcode resolves the dependency on first open; the initial build needs network
access, and later builds can use the cached checkout.

Use [KM43](https://github.com/origin89hq/km43) for protocol contracts when
connection features are introduced.

See [contributing](CONTRIBUTING.md) for engineering instructions and checks.
