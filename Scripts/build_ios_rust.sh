#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CORE_DIR="$APP_DIR/Rust/core"
RUST_DIR="$APP_DIR/Rust"

if [[ "${GOOSE_SKIP_RUST_CORE_BUILD:-0}" == "1" ]]; then
  echo "Skipping Goose Rust core build because GOOSE_SKIP_RUST_CORE_BUILD=1"
  exit 0
fi

# Xcode.app build phases do not inherit a login shell PATH, so cargo is often
# missing here even when it works in a terminal.
if ! command -v cargo >/dev/null 2>&1; then
  for candidate in "${CARGO_HOME:-$HOME/.cargo}/bin" /opt/homebrew/bin /usr/local/bin; do
    if [[ -x "$candidate/cargo" ]]; then
      export PATH="$candidate:$PATH"
      break
    fi
  done
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not found. Install Rust via rustup (https://rustup.rs), then add the iOS targets:" >&2
  echo "  rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios" >&2
  exit 1
fi

INPUT_FILE_LIST="$SCRIPT_DIR/rust-core-inputs.xcfilelist"
if [[ -f "$INPUT_FILE_LIST" ]]; then
  while IFS= read -r source_file; do
    listed_path="${source_file#\$(SRCROOT)/}"
    if ! grep -qxF "\$(SRCROOT)/$listed_path" "$INPUT_FILE_LIST"; then
      echo "warning: $listed_path is missing from Scripts/rust-core-inputs.xcfilelist; Xcode may skip the Rust core build after editing it" >&2
    fi
  done < <(cd "$APP_DIR" && find Rust/core/src -name '*.rs' | sort)
fi

CONFIGURATION="${CONFIGURATION:-Debug}"
PLATFORM_NAME="${PLATFORM_NAME:-iphonesimulator}"
CURRENT_ARCH="${CURRENT_ARCH:-${ARCHS:-arm64}}"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-${IPHONEOS_DEPLOYMENT_TARGET:-14.0}}"
export IPHONEOS_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET"

if [[ "${GOOSE_RUST_RELEASE:-0}" == "1" ]]; then
  CARGO_RELEASE=1
  CARGO_PROFILE_DIR="release"
elif [[ "$PLATFORM_NAME" == "iphoneos" && "${GOOSE_RUST_DEBUG_BUILD:-0}" != "1" ]]; then
  CARGO_RELEASE=1
  CARGO_PROFILE_DIR="release"
else
  case "$CONFIGURATION" in
    Release|Profile)
      CARGO_RELEASE=1
      CARGO_PROFILE_DIR="release"
      ;;
    *)
      CARGO_RELEASE=0
      CARGO_PROFILE_DIR="debug"
      ;;
  esac
fi

case "$PLATFORM_NAME" in
  iphoneos)
    RUST_TARGET="aarch64-apple-ios"
    SDK_NAME="iphoneos"
    CLANG_TARGET="arm64-apple-ios$IOS_DEPLOYMENT_TARGET"
    ;;
  iphonesimulator)
    SDK_NAME="iphonesimulator"
    if [[ "$CURRENT_ARCH" == *"x86_64"* && "$CURRENT_ARCH" != *"arm64"* ]]; then
      RUST_TARGET="x86_64-apple-ios"
      CLANG_TARGET="x86_64-apple-ios$IOS_DEPLOYMENT_TARGET-simulator"
    else
      RUST_TARGET="aarch64-apple-ios-sim"
      CLANG_TARGET="arm64-apple-ios$IOS_DEPLOYMENT_TARGET-simulator"
    fi
    ;;
  *)
    echo "Unsupported iOS platform: $PLATFORM_NAME" >&2
    exit 1
    ;;
esac

PLATFORM_RUST_DIR="$RUST_DIR/$PLATFORM_NAME"
PLATFORM_OUTPUT_LIB="$PLATFORM_RUST_DIR/libgoose_core.a"
PLATFORM_TARGET_FILE="$PLATFORM_RUST_DIR/.goose_core.target"
PLATFORM_PROFILE_FILE="$PLATFORM_RUST_DIR/.goose_core.profile"

if [[ -f "$PLATFORM_OUTPUT_LIB" && -f "$PLATFORM_TARGET_FILE" && -f "$PLATFORM_PROFILE_FILE" ]]; then
  CURRENT_BUILT_TARGET="$(cat "$PLATFORM_TARGET_FILE")"
  CURRENT_BUILT_PROFILE="$(cat "$PLATFORM_PROFILE_FILE")"
  NEWER_INPUT="$(
    find \
      "$CORE_DIR/Cargo.toml" \
      "$CORE_DIR/Cargo.lock" \
      "$CORE_DIR/include" \
      "$CORE_DIR/src" \
      -newer "$PLATFORM_OUTPUT_LIB" \
      -print \
      -quit
  )"
  if [[ -z "$NEWER_INPUT" && "$CURRENT_BUILT_TARGET" == "$RUST_TARGET" && "$CURRENT_BUILT_PROFILE" == "$CARGO_PROFILE_DIR" ]]; then
    mkdir -p "$PLATFORM_RUST_DIR"
    echo "Goose Rust iOS library already current for $RUST_TARGET ($CARGO_PROFILE_DIR)"
    exit 0
  fi
fi

SDK_PATH="$(xcrun --sdk "$SDK_NAME" --show-sdk-path)"
CLANG="$(xcrun --sdk "$SDK_NAME" --find clang)"
AR="$(xcrun --sdk "$SDK_NAME" --find ar)"

case "$RUST_TARGET" in
  aarch64-apple-ios)
    export CC_aarch64_apple_ios="$CLANG"
    export AR_aarch64_apple_ios="$AR"
    export CFLAGS_aarch64_apple_ios="-isysroot $SDK_PATH -target $CLANG_TARGET"
    export CARGO_TARGET_AARCH64_APPLE_IOS_LINKER="$CLANG"
    ;;
  aarch64-apple-ios-sim)
    export CC_aarch64_apple_ios_sim="$CLANG"
    export AR_aarch64_apple_ios_sim="$AR"
    export CFLAGS_aarch64_apple_ios_sim="-isysroot $SDK_PATH -target $CLANG_TARGET"
    export CARGO_TARGET_AARCH64_APPLE_IOS_SIM_LINKER="$CLANG"
    ;;
  x86_64-apple-ios)
    export CC_x86_64_apple_ios="$CLANG"
    export AR_x86_64_apple_ios="$AR"
    export CFLAGS_x86_64_apple_ios="-isysroot $SDK_PATH -target $CLANG_TARGET"
    export CARGO_TARGET_X86_64_APPLE_IOS_LINKER="$CLANG"
    ;;
  esac

export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$APP_DIR/build/rust-target/goose-core}"

cargo_args=(
  build
  --lib
  --manifest-path "$CORE_DIR/Cargo.toml"
  --target "$RUST_TARGET"
)
if [[ "$CARGO_RELEASE" == "1" ]]; then
  cargo_args+=(--release)
fi
cargo "${cargo_args[@]}"

mkdir -p "$PLATFORM_RUST_DIR"
cp "$CARGO_TARGET_DIR/$RUST_TARGET/$CARGO_PROFILE_DIR/libgoose_core.a" \
  "$PLATFORM_RUST_DIR/libgoose_core.a"
printf '%s\n' "$RUST_TARGET" > "$PLATFORM_TARGET_FILE"
printf '%s\n' "$CARGO_PROFILE_DIR" > "$PLATFORM_PROFILE_FILE"

echo "Built Goose Rust iOS library for $RUST_TARGET ($CARGO_PROFILE_DIR) at $PLATFORM_RUST_DIR/libgoose_core.a"
