#!/usr/bin/env bash
# Build CADCraft for HarmonyOS PC (2in1) / tablet:
#   1. cross-compile the Node-API module with cargo (aarch64-unknown-linux-ohos, Tier 2)
#   2. drop the .so into the DevEco project
#   3. build a HAP (dev signature) or a release .app (AGC signature) with hvigorw
#
# Required environment (example, adjust to your DevEco install):
#   export OHOS_SDK_HOME="$LOCALAPPDATA/OpenHarmony/Sdk"     # contains native/, toolchains/
#   export DEVECO_HVIGOR="$HOME/AppData/Local/Huawei/Sdk/hvigor"  # or use DevEco Studio's GUI build
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HARMONY_DIR="$REPO_ROOT/packaging/harmony"
TARGET="aarch64-unknown-linux-ohos"
ABI_DIR="arm64-v8a"

: "${OHOS_SDK_HOME:?set OHOS_SDK_HOME to the OpenHarmony/HarmonyOS SDK directory (contains native/)}"
NATIVE="$OHOS_SDK_HOME/native"
CLANG="$NATIVE/llvm/bin/clang"
LLVM_AR="$NATIVE/llvm/bin/llvm-ar"

[ -x "$CLANG" ] || { echo "clang not found at $CLANG" >&2; exit 1; }

# Rust's ohos targets are Tier 2: rustup provides std; the SDK's clang links
# (see https://doc.rust-lang.org/rustc/platform-support/openharmony.html).
rustup target add "$TARGET"

export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER="$CLANG"
export RUSTFLAGS="-C link-arg=--target=aarch64-linux-ohos -C link-arg=--sysroot=$NATIVE/sysroot"
export CC_aarch64_unknown_linux_ohos="$CLANG"
export AR_aarch64_unknown_linux_ohos="$LLVM_AR"

cd "$REPO_ROOT"
cargo build -p cadcraft-ohos --release --target "$TARGET"

SO="target/$TARGET/release/libcadcraft_ohos.so"
[ -f "$SO" ] || { echo "build did not produce $SO" >&2; exit 1; }

mkdir -p "$HARMONY_DIR/entry/libs/$ABI_DIR"
cp "$SO" "$HARMONY_DIR/entry/libs/$ABI_DIR/libcadcraft_ohos.so"
echo "packaged: entry/libs/$ABI_DIR/libcadcraft_ohos.so"

# 3. HAP / APP — either build in DevEco Studio (Build > Build Hap(s)/APP(s)) or:
cd "$HARMONY_DIR"
if command -v hvigorw >/dev/null 2>&1; then
  hvigorw --mode module -p product=default assembleHap     # debug, dev-signed
  # hvigorw --mode module -p product=default assembleApp    # release, AGC-signed (needs signingConfigs)
else
  echo "hvigorw not on PATH — build from DevEco Studio instead (the .so is already in place)."
fi
