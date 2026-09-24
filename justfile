default:
    @just --list

skills-sync:
    python3 .origin89/sync-engineering.py

# Swift sources we own; the generated bindings in SetupCore/Generated are not formatted.
swift_sources := "apps/ios/Origin89 apps/ios/SetupKit/Package.swift apps/ios/SetupKit/Sources apps/ios/SetupKit/Tests apps/ios/SetupCore/Package.swift apps/ios/SetupCore/Sources apps/ios/SetupBench/Package.swift apps/ios/SetupBench/Sources"

fmt:
    xcrun swift-format format --in-place --recursive {{swift_sources}}
    cargo fmt --all

fmt-check:
    xcrun swift-format lint --strict --recursive {{swift_sources}}

rust-check:
    cargo fmt --all -- --check
    cargo clippy --workspace --all-targets --locked -- -D warnings
    cargo test --workspace --locked

swift-test:
    swift test --package-path apps/ios/SetupKit

# The Rust core as an XCFramework plus its Swift bindings, into apps/ios/SetupCore/Generated.
ios-core:
    scripts/build-ios-core.sh

build: ios-core
    xcodebuild -project apps/ios/Origin89.xcodeproj -scheme Origin89 -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/ios CODE_SIGNING_ALLOWED=NO build

# Compiles the bench tool; running it is `just bench`.
bench-build: ios-core
    swift build --package-path apps/ios/SetupBench

check: fmt-check rust-check swift-test build bench-build

# Operates equipment: the setup flow against a real controller over this Mac's Bluetooth. `just bench help` lists commands.
bench *args:
    swift run --quiet --package-path apps/ios/SetupBench SetupBench {{args}}

# Operates equipment. Build, install and launch the app on a connected iPhone, saving its console to .build/bench.
ios-bench device="": ios-core
    scripts/ios-bench.sh {{device}}

open: ios-core
    open apps/ios/Origin89.xcodeproj
