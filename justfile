default:
    @just --list

skills-sync:
    python3 .origin89/sync-engineering.py

fmt:
    xcrun swift-format format --in-place --recursive apps/ios/Origin89

fmt-check:
    xcrun swift-format lint --strict --recursive apps/ios/Origin89

build:
    xcodebuild -project apps/ios/Origin89.xcodeproj -scheme Origin89 -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/ios CODE_SIGNING_ALLOWED=NO build

check: fmt-check build

open:
    open apps/ios/Origin89.xcodeproj
