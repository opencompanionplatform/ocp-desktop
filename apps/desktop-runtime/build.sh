#!/usr/bin/env bash
# Build the OcpRuntimeBridge GDExtension and stage it where Godot expects it
# (godot/ocp_runtime.gdextension points at godot/bin/...). Linux/macOS
# companion to build.ps1 (Windows, proven working 2026-07-20 on ARM64).
#
# UNVERIFIED as of 2026-07-20 -- nobody has run this on Linux or macOS yet.
# Written against the same cargo invocation pattern as build.ps1; expect a
# possible first-run fix-up (target triple availability, linker setup, etc).
#
# Usage: ./build.sh [--release] [--arch x86_64|arm64]
#   --arch defaults to the host's own architecture (uname -m).

set -euo pipefail

PROFILE="debug"
ARCH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release) PROFILE="release"; shift ;;
        --arch) ARCH="$2"; shift 2 ;;
        *) echo "Usage: $0 [--release] [--arch x86_64|arm64]"; exit 1 ;;
    esac
done

cd "$(dirname "$0")"

case "$(uname -s)" in
    Linux*)  PLATFORM="linux" ;;
    Darwin*) PLATFORM="macos" ;;
    *) echo "Unsupported OS for build.sh: $(uname -s) -- use build.ps1 on Windows"; exit 1 ;;
esac

if [[ -z "$ARCH" ]]; then
    case "$(uname -m)" in
        arm64|aarch64) ARCH="arm64" ;;
        x86_64|amd64)  ARCH="x86_64" ;;
        *) echo "Unrecognized host arch: $(uname -m), pass --arch explicitly"; exit 1 ;;
    esac
fi

if [[ "$PLATFORM" == "linux" ]]; then
    if [[ "$ARCH" == "arm64" ]]; then
        TARGET="aarch64-unknown-linux-gnu"
    else
        TARGET="x86_64-unknown-linux-gnu"
    fi
    LIBNAME="libocp_desktop_runtime_ext.so"
    DEST_DIR="godot/bin/linux/$ARCH"
else
    if [[ "$ARCH" == "arm64" ]]; then
        TARGET="aarch64-apple-darwin"
    else
        TARGET="x86_64-apple-darwin"
    fi
    LIBNAME="libocp_desktop_runtime_ext.dylib"
    DEST_DIR="godot/bin/macos"
fi

rustup target add "$TARGET" >/dev/null

pushd rust >/dev/null
if [[ "$PROFILE" == "release" ]]; then
    cargo build --release --target "$TARGET"
else
    cargo build --target "$TARGET"
fi
popd >/dev/null

SRC="rust/target/$TARGET/$PROFILE/$LIBNAME"
mkdir -p "$DEST_DIR"
cp "$SRC" "$DEST_DIR/$LIBNAME"
echo "Staged: $DEST_DIR/$LIBNAME"
echo "If Godot fails to load the extension with an 'entry symbol not found'"
echo "error, check the real exported symbol name and fix entry_symbol in"
echo "godot/ocp_runtime.gdextension (see the comment in that file)."
