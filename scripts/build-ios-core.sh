#!/usr/bin/env bash
# Build origin89-setup for iOS devices and the simulator, wrap the static
# libraries in an XCFramework, and generate the Swift bindings.
#
#   scripts/build-ios-core.sh [output-dir]    (default: apps/ios/SetupCore/Generated)
#
# The default is where the SetupCore Swift package expects it.
#
# Output:
#   <output-dir>/Origin89SetupCoreFFI.xcframework   static library + C module
#   <output-dir>/swift/Origin89SetupCore.swift      the Swift API over it
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$root/apps/ios/SetupCore/Generated}"
lib=liborigin89_setup.a
targets=(aarch64-apple-ios aarch64-apple-ios-sim)

cd "$root"
for target in "${targets[@]}"; do
    cargo build --locked --release -p origin89-setup --target "$target"
done

rm -rf "$out"
mkdir -p "$out/swift" "$out/headers"

# Library mode reads the interface from the compiled library itself, so the
# bindings describe exactly what was built.
cargo run --locked --quiet -p uniffi-bindgen -- generate \
    --library "target/aarch64-apple-ios/release/$lib" \
    --language swift \
    --out-dir "$out/swift"

mv "$out/swift/Origin89SetupCoreFFI.h" "$out/headers/"
mv "$out/swift/Origin89SetupCoreFFI.modulemap" "$out/headers/module.modulemap"

xcodebuild -create-xcframework \
    -library "target/aarch64-apple-ios/release/$lib" -headers "$out/headers" \
    -library "target/aarch64-apple-ios-sim/release/$lib" -headers "$out/headers" \
    -output "$out/Origin89SetupCoreFFI.xcframework"
rm -rf "$out/headers"

echo "XCFramework: $out/Origin89SetupCoreFFI.xcframework"
echo "Swift:       $out/swift/Origin89SetupCore.swift"
