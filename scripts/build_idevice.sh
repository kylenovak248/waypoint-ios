#!/usr/bin/env bash
# Builds the idevice C library for iPhone (arm64) into Vendor/idevice.
# Runs on macOS with Xcode and Rust installed (the GitHub workflow does this).
set -euo pipefail
cd "$(dirname "$0")/.."

IDEVICE_REPO="https://github.com/jkcoxson/idevice.git"
IDEVICE_COMMIT="89702099f4d7552f704f93b4526756abda319ceb"   # tested revision
SRC="build/idevice"

if [ ! -d "$SRC/.git" ]; then
  git clone --filter=blob:none "$IDEVICE_REPO" "$SRC"
fi
git -C "$SRC" fetch --depth 1 origin "$IDEVICE_COMMIT" || true
git -C "$SRC" checkout --force "$IDEVICE_COMMIT"

rustup target add aarch64-apple-ios
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
(
  cd "$SRC/ffi"
  BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$SDK" \
  IPHONEOS_DEPLOYMENT_TARGET=17.0 \
  cargo build --release --target aarch64-apple-ios
)

mkdir -p Vendor/idevice
cp "$SRC/ffi/idevice.h" Vendor/idevice/idevice.h
cp "$SRC/target/aarch64-apple-ios/release/libidevice_ffi.a" Vendor/idevice/libidevice_ffi.a
ls -la Vendor/idevice
