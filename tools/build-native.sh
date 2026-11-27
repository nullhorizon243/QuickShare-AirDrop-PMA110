#!/usr/bin/env bash
set -euo pipefail

# Build the 3 original arm64 native helpers:
#   1. native/bin/nearby-flag              (Phenotype snapshot flag editor / inspector)
#   2. native/bin/query_declared           (VINTF AServiceManager_isDeclared query tool)
#   3. native/bin/libmosey_local_binder.so (LD_PRELOAD lazy-service persistence shim)
#
# Supported toolchains (set one):
#   Option A (recommended): Android NDK
#     ANDROID_NDK_HOME=/path/to/android-ndk ./tools/build-native.sh
#     (or NDK_CLANG=/path/to/aarch64-linux-android35-clang ./tools/build-native.sh)
#
#   Option B: Zig (>= 0.15) + zlib sources (for static nearby-flag) + Android libc.so/libdl.so stubs
#     ZIG=/path/to/zig ZLIB_DIR=/path/to/zlib-src BIONIC_LIB_DIR=/path/to/dir ./tools/build-native.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${OUT_DIR:-$ROOT/native/bin}"
mkdir -p "$OUT"

resolve_ndk_clang() {
    if [ -n "${NDK_CLANG:-}" ]; then
        echo "$NDK_CLANG"
        return 0
    fi
    if [ -n "${ANDROID_NDK_HOME:-}" ]; then
        for candidate in "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin/aarch64-linux-android35-clang \
                         "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin/aarch64-linux-android34-clang \
                         "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin/aarch64-linux-android29-clang; do
            if [ -x "$candidate" ]; then
                echo "$candidate"
                return 0
            fi
        done
    fi
    return 1
}

if CLANG="$(resolve_ndk_clang)"; then
    echo "Building native binaries with Android NDK: $CLANG"
    "$CLANG" -O2 -Wall -Wextra -fPIE -pie -Wl,-s \
        "$ROOT/native/nearby-flag.c" -lz -o "$OUT/nearby-flag"
    "$CLANG" -O2 -Wall -Wextra -fPIE -pie -Wl,-s \
        "$ROOT/native/query_declared.c" -ldl -o "$OUT/query_declared"
    "$CLANG" -O2 -Wall -Wextra -fPIC -shared -Wl,-s \
        "$ROOT/native/mosey_lazy_hold.c" -ldl -o "$OUT/libmosey_local_binder.so"
elif [ -n "${ZIG:-}" ] || command -v zig >/dev/null 2>&1; then
    ZIG_BIN="${ZIG:-$(command -v zig)}"
    echo "Building native binaries with Zig: $ZIG_BIN"

    if [ -z "${ZLIB_DIR:-}" ] || [ ! -f "$ZLIB_DIR/zlib.h" ]; then
        echo "ERROR: When building with Zig, set ZLIB_DIR to a zlib source directory containing zlib.h and *.c" >&2
        exit 1
    fi
    ZLIB_SOURCES=(
        adler32.c compress.c crc32.c deflate.c infback.c inffast.c
        inflate.c inftrees.c trees.c uncompr.c zutil.c
    )
    ZLIB_FILES=()
    for src in "${ZLIB_SOURCES[@]}"; do
        ZLIB_FILES+=("$ZLIB_DIR/$src")
    done

    "$ZIG_BIN" cc -target aarch64-linux-musl -O2 -s -static \
        -I"$ZLIB_DIR" "$ROOT/native/nearby-flag.c" "${ZLIB_FILES[@]}" \
        -o "$OUT/nearby-flag"

    "$ZIG_BIN" cc -target aarch64-linux-gnu -O2 -s -shared -fPIC -nostdlib \
        -Wl,--allow-shlib-undefined \
        "$ROOT/native/mosey_lazy_hold.c" -o "$OUT/libmosey_local_binder.so"

    if [ -n "${BIONIC_LIB_DIR:-}" ] && [ -f "$BIONIC_LIB_DIR/libc.so" ] && [ -f "$BIONIC_LIB_DIR/libdl.so" ]; then
        "$ZIG_BIN" cc -target aarch64-linux-musl -O2 -s -fPIE -pie -nostdlib -nodefaultlibs -DUSE_NOSTDLIB_ENTRY \
            -Wl,--dynamic-linker=/system/bin/linker64 \
            "$ROOT/native/query_declared.c" "$BIONIC_LIB_DIR/libc.so" "$BIONIC_LIB_DIR/libdl.so" \
            -o "$OUT/query_declared"
    else
        echo "WARNING: BIONIC_LIB_DIR (containing Android libc.so & libdl.so) not set; skipping query_declared." >&2
        echo "         Provide ANDROID_NDK_HOME or BIONIC_LIB_DIR to build query_declared." >&2
        exit 1
    fi
else
    echo "ERROR: Set ANDROID_NDK_HOME (recommended) or ZIG + ZLIB_DIR + BIONIC_LIB_DIR." >&2
    exit 1
fi

chmod 0755 "$OUT/nearby-flag" "$OUT/query_declared" "$OUT/libmosey_local_binder.so"
ls -lh "$OUT/nearby-flag" "$OUT/query_declared" "$OUT/libmosey_local_binder.so"
