#!/usr/bin/env bash
set -euo pipefail

# Build and sign the standalone Quick Share Restore APK.
# Prerequisites:
#   1. Run ./tools/build-native.sh
#   2. Run ./tools/extract_vendor.py to populate vendor/
#   3. Set ANDROID_SDK_ROOT (or BUILD_TOOLS + ANDROID_JAR)
#
# Optional:
#   ALLOW_UNVERIFIED_VENDOR=1  Allow vendor hashes to differ from tools/verify-manifest.json
#                              (archive structure and the locally built shim are still checked)

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${BUILD_DIR:-$ROOT/build}"
NATIVE_BIN="${NATIVE_BIN_DIR:-$ROOT/native/bin}"
VENDOR="${VENDOR_DIR:-$ROOT/vendor}"

if [ -z "${BUILD_TOOLS:-}" ] && [ -n "${ANDROID_SDK_ROOT:-}" ]; then
    BUILD_TOOLS="$(find -L "$ANDROID_SDK_ROOT/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -n 1)"
fi
if [ -z "${ANDROID_JAR:-}" ] && [ -n "${ANDROID_SDK_ROOT:-}" ]; then
    ANDROID_JAR="$ANDROID_SDK_ROOT/platforms/android-35/android.jar"
fi

if [ -z "${BUILD_TOOLS:-}" ] || [ ! -x "$BUILD_TOOLS/aapt2" ]; then
    echo "ERROR: Set ANDROID_SDK_ROOT or BUILD_TOOLS (directory containing aapt2, d8, zipalign, apksigner)." >&2
    exit 1
fi
if [ -z "${ANDROID_JAR:-}" ] || [ ! -f "$ANDROID_JAR" ]; then
    echo "ERROR: Set ANDROID_SDK_ROOT or ANDROID_JAR (path to android-35/android.jar)." >&2
    exit 1
fi

required=(
    "$NATIVE_BIN/nearby-flag"
    "$NATIVE_BIN/query_declared"
    "$NATIVE_BIN/libmosey_local_binder.so"
    "$VENDOR/privileged-app.tar"
    "$VENDOR/daemon.tar"
    "$VENDOR/manifest_mosey.xml"
)
for item in "${required[@]}"; do
    if [ -L "$item" ] || [ ! -f "$item" ] || [ ! -s "$item" ]; then
        echo "ERROR: Missing, empty, or symlinked required input: $item" >&2
        echo "Run tools/build-native.sh and tools/extract_vendor.py first." >&2
        exit 1
    fi
done

STAGE_ASSETS="$BUILD/assets"
rm -rf "$STAGE_ASSETS" "$BUILD/classes" "$BUILD/dex" "$BUILD/base.apk" "$BUILD/aligned.apk"
mkdir -p "$STAGE_ASSETS" "$BUILD/classes" "$BUILD/dex"

cp "$ROOT/scripts/"*.sh "$ROOT/scripts/config.env" "$STAGE_ASSETS/"
cp "$NATIVE_BIN/nearby-flag" "$NATIVE_BIN/query_declared" "$STAGE_ASSETS/"
cp "$VENDOR/privileged-app.tar" "$VENDOR/daemon.tar" "$VENDOR/manifest_mosey.xml" "$STAGE_ASSETS/"
cp "$ROOT/native/third_party/zlib-LICENSE.txt" "$STAGE_ASSETS/"

python3 -B - "$ROOT/tools/verify-manifest.json" "$STAGE_ASSETS" "${ALLOW_UNVERIFIED_VENDOR:-0}" \
    "$NATIVE_BIN/libmosey_local_binder.so" <<'PY'
import hashlib, io, json, sys, tarfile
from pathlib import Path

manifest_path = Path(sys.argv[1])
sys.path.insert(0, str(manifest_path.parent))
from extract_vendor import add_bytes, add_dir

manifest = json.loads(manifest_path.read_text(encoding="utf-8"))["components"]
vendor = Path(sys.argv[2])
allow_unverified = sys.argv[3] == "1"
shim = Path(sys.argv[4]).read_bytes()
shim_member = "./lib64/libmosey_local_binder.so"
if (len(shim) < 64 or shim[:6] != bytes([127, 69, 76, 70, 2, 1])
        or int.from_bytes(shim[16:18], "little") != 3
        or int.from_bytes(shim[18:20], "little") != 183):
    raise SystemExit("ERROR: Build an AArch64 ELF shared library with tools/build-native.sh first.")
shim_hash = hashlib.sha256(shim).hexdigest()

def check_hash(label: str, data: bytes, expected: str, *, strict: bool = False):
    actual = hashlib.sha256(data).hexdigest()
    if actual != expected:
        if strict:
            raise SystemExit(f"ERROR: {label} differs from the locally built shim. Re-run tools/extract_vendor.py.")
        if allow_unverified:
            print(f"WARNING: {label} SHA-256 differs ({actual[:12]} != {expected[:12]})")
        else:
            raise SystemExit(
                f"ERROR: SHA-256 mismatch for {label} (expected {expected}, got {actual}). "
                "Re-run tools/extract_vendor.py or set ALLOW_UNVERIFIED_VENDOR=1."
            )

def check_tar(path: Path, allowed_dirs: set, required_files: dict):
    seen_dirs = set()
    files = {}
    with tarfile.open(path, "r:") as tar:
        for member in tar.getmembers():
            if member.type not in (tarfile.DIRTYPE, tarfile.REGTYPE, tarfile.AREGTYPE):
                raise SystemExit(f"ERROR: Disallowed tar member type in {path.name}: {member.name}")
            if member.pax_headers:
                raise SystemExit(f"ERROR: Disallowed extended headers in {path.name}: {member.name}")
            if member.name in seen_dirs or member.name in files:
                raise SystemExit(f"ERROR: Duplicate member in {path.name}: {member.name}")
            if member.name.startswith("/") or ".." in Path(member.name).parts:
                raise SystemExit(f"ERROR: Unsafe tar path in {path.name}: {member.name}")
            if member.isdir():
                if member.name not in allowed_dirs:
                    raise SystemExit(f"ERROR: Unexpected directory in {path.name}: {member.name}")
                seen_dirs.add(member.name)
            else:
                if member.name not in required_files:
                    raise SystemExit(f"ERROR: Unexpected file in {path.name}: {member.name}")
                fh = tar.extractfile(member)
                data = fh.read() if fh else b""
                if not data:
                    raise SystemExit(f"ERROR: Empty file member in {path.name}: {member.name}")
                check_hash(f"{path.name}:{member.name}", data, required_files[member.name],
                           strict=member.name == shim_member)
                files[member.name] = data
    missing = (allowed_dirs - seen_dirs) | (set(required_files) - files.keys())
    if missing:
        raise SystemExit(f"ERROR: Missing members in {path.name}: {sorted(missing)}")

    # Emit only the checked members, with explicit metadata for Android's tar reader.
    normalized = io.BytesIO()
    with tarfile.open(fileobj=normalized, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        for name in sorted(allowed_dirs):
            add_dir(tar, name)
        for name, data in files.items():
            mode = 0o755 if name in ("./bin/mosey_server", shim_member) else 0o644
            add_bytes(tar, name, data, mode)
    contents = normalized.getvalue()
    path.write_bytes(contents)
    return hashlib.sha256(contents).hexdigest()

priv_hash = check_tar(
    vendor / "privileged-app.tar",
    {"./priv-app", "./priv-app/MoseyApp", "./permissions"},
    {
        "./priv-app/MoseyApp/MoseyApp.apk": manifest["MoseyApp.apk"]["sha256"],
        "./permissions/privapp-permissions-com.google.android.mosey.xml": manifest[
            "privapp-permissions-com.google.android.mosey.xml"
        ]["sha256"],
    },
)
daemon_hash = check_tar(
    vendor / "daemon.tar",
    {"./bin", "./lib64"},
    {
        "./bin/mosey_server": manifest["mosey_server"]["sha256"],
        "./lib64/libmosey_daemon_ffi.so": manifest["libmosey_daemon_ffi.so"]["sha256"],
        shim_member: shim_hash,
    },
)
check_hash(
    "manifest_mosey.xml",
    (vendor / "manifest_mosey.xml").read_bytes(),
    manifest["manifest_mosey.xml"]["sha256"],
)
with (vendor / "config.env").open("a", encoding="utf-8") as config:
    config.write(f"\nMOSEY_PRIV_TAR_SHA256='{priv_hash}'\n"
                 f"MOSEY_DAEMON_TAR_SHA256='{daemon_hash}'\n"
                 f"MOSEY_SHIM_SHA256='{shim_hash}'\n")
print("Vendor archive whitelist & integrity check passed.")
PY

if [ ! -f "$BUILD/signing.p12" ]; then
    umask 077
    openssl rand -hex 24 > "$BUILD/signing.pass"
    keytool -genkeypair -keystore "$BUILD/signing.p12" -storetype PKCS12 \
        -storepass:file "$BUILD/signing.pass" -alias quickshare \
        -dname 'CN=Quick Share Restore for PMA110' -keyalg RSA -keysize 3072 -validity 10000
fi

javac --release 8 -Xlint:-options -encoding UTF-8 -classpath "$ANDROID_JAR" -d "$BUILD/classes" \
    "$ROOT/app/src/org/george/quicksharerestore/MainActivity.java"
"$BUILD_TOOLS/d8" --min-api 30 --lib "$ANDROID_JAR" --output "$BUILD/dex" \
    "$BUILD/classes/org/george/quicksharerestore/"*.class
"$BUILD_TOOLS/aapt2" link --manifest "$ROOT/app/AndroidManifest.xml" \
    -I "$ANDROID_JAR" -A "$STAGE_ASSETS" -o "$BUILD/base.apk"
zip -q -j "$BUILD/base.apk" "$BUILD/dex/classes.dex"
"$BUILD_TOOLS/zipalign" -f -v 4 "$BUILD/base.apk" "$BUILD/aligned.apk" >"$BUILD/zipalign.log"
"$BUILD_TOOLS/apksigner" sign --ks "$BUILD/signing.p12" --ks-pass "file:$BUILD/signing.pass" \
    --out "$BUILD/QuickShare-PMA110.apk" "$BUILD/aligned.apk"
"$BUILD_TOOLS/apksigner" verify --verbose --print-certs "$BUILD/QuickShare-PMA110.apk"
echo "Built APK: $BUILD/QuickShare-PMA110.apk"
