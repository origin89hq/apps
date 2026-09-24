# Contributing

Follow [Origin89 engineering](https://github.com/origin89hq/engineering/blob/main/CONTRIBUTING.md)
and the task-start instructions in [AGENTS.md](AGENTS.md). Shared skills refresh
with `just skills-sync`; edit common guidance in engineering and keep app-specific
commands here.

Run `just check` before submitting changes; it covers Swift formatting, Rust
formatting, Clippy and tests, the `SetupKit` tests and the simulator build. Run
`just fmt` to format Swift and Rust.
Workflow edits also need actionlint. Keep signing, distribution and connected-device
operations separate from ordinary checks.

Use SwiftUI for the iOS target and Swift 6 language mode. Test setup flow changes
in `SetupKit` and protocol changes in `crates/setup`. Simulator builds do not prove
Bluetooth, pairing or controller behavior; those changes need physical-device
evidence.

The checked-in Xcode project owns target settings and its shared scheme. Do not
commit user-specific Xcode data, signing credentials or generated build output.
