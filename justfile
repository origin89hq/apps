default:
    @just --list

skills-sync:
    python3 .origin89/sync-engineering.py

# Swift sources we own; the generated bindings in SetupCore/Generated are not formatted.
swift_sources := "apps/ios/Origin89 apps/ios/SetupKit/Package.swift apps/ios/SetupKit/Sources apps/ios/SetupKit/Tests apps/ios/SetupCore/Package.swift apps/ios/SetupCore/Sources"

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

check: fmt-check rust-check swift-test build

open: ios-core
    open apps/ios/Origin89.xcodeproj
