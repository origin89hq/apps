# Contributing

Follow [Origin89 engineering](https://github.com/origin89hq/engineering/blob/main/CONTRIBUTING.md)
and the task-start instructions in [AGENTS.md](AGENTS.md). Shared skills refresh
with `just skills-sync`; edit common guidance in engineering and keep app-specific
commands here.

Run `just check` before submitting changes. Run `just fmt` to format Swift.
Workflow edits also need actionlint. Keep signing, distribution and connected-device
operations separate from ordinary checks.

Use SwiftUI for the iOS target and Swift 6 language mode. Add tests when application
behavior is introduced. Simulator builds do not prove Bluetooth, pairing or
controller behavior; those changes need physical-device evidence.

The checked-in Xcode project owns target settings and its shared scheme. Do not
commit user-specific Xcode data, signing credentials or generated build output.
