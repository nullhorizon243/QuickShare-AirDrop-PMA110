# Quick Share ↔ AirDrop Restore for OPPO Find X9 Ultra (CN / PMA110)

[简体中文](README.md) | English

An unofficial tool for the Mainland China **OPPO Find X9 Ultra (`PMA110`)**. Under a KernelSU Root environment, it dynamically loads the stock Mosey components through temporary in-memory overlays and local configuration adjustments to enable **Google Quick Share ↔ Apple AirDrop** interoperability, without modifying physical system partitions.

**v1.0 release.** This release is based on v1.0.7, which the author tested on a Mainland China `PMA110`. On-device testing covered the phone workflow, and earlier tests confirmed two-way small-file transfers with a Mac. The v1.0 APK was built on macOS using a real firmware image and passed signature verification. See the baseline below for the exact firmware and Google Play services versions.

**How to Obtain.** This repository provides source code and build scripts only. Extract the stock vendor components from a matching official OTA yourself and [build locally](#4-building-from-source). The built APK and `vendor/*.tar` contain proprietary Google/OPPO components; the MIT license covers only the original code in this repository. Do **not** upload built APKs, `vendor/*.tar`, firmware images, or signing keys to public repositories or GitHub Releases.

> **AI-Assisted Development & Disclaimer**: Code implementation, security review, and documentation for this project were created with AI assistance. Because this tool performs Root operations, dynamic mounts, framework soft reboots, and local GMS config edits, please read the [Disclaimer](#7-ai-assisted-development--disclaimer) carefully and back up your data first. Use entirely at your own risk.

---

## Quick Start

1. Check the [baseline environment](#1-baseline-environment--compatibility). Your phone needs KernelSU Root, and its primary user must be able to open Google Quick Share.
2. Download the [matching Indonesian OTA](#2-extract-and-verify-stock-components), export `system_ext.img` on your computer, and follow the [build steps](#4-building-from-source) to extract the five components and build the APK.
3. Follow [on-device usage](#5-on-device-usage) to install the APK, grant Root, and tap **Load**. If prompted, perform a soft reboot, tap **Load** again, and use **Status** to confirm activation.

## 1. Baseline Environment & Compatibility

### 1. Verified Author Baseline
- **Device**: OPPO Find X9 Ultra, Mainland China (`ro.product.model = PMA110`)
- **Firmware**: `PMA110_17.0.0.105(CN01)`
- **Google Play services (GMS)**: `26.45.31` (`versionCode = 264531035`)
- **Root Manager**: KernelSU (baseline: `ksud 3.3.1 (uapi: 5)` and KernelSU BusyBox). Temporary Root also works, provided Root remains available after running soft reboot through this tool.
- **Stock Mosey Component Source**: Global sibling model `CPH2841` (`MoseyApp 1.0.927074190`)

### 2. Prerequisites
Unlock the phone and wait for the home screen to finish loading before running the tool. User 0 (primary user) must be able to open Google Quick Share normally, and the main Google Play services process must be running. The script expects a single matching Nearby config file under GMS's `app_phenotype_shared` directory; if the tool still reports a missing config after opening Quick Share, verify this prerequisite first.

The author's baseline uses Coogle to lift Mainland China GMS restrictions. Whether the Quick Share entry itself is available must be verified separately on your device. Any existing GMS unlock method is fine as long as its mount points do not conflict with the checks below. [Coogle Upstream README](https://github.com/zopulus/coogle#readme)

### 3. Pre-Load Checks

| Check | Default Policy | Details |
| :--- | :--- | :--- |
| **Device & Firmware** (`PMA110` / `PMA110_17.0.0.105(CN01)`) | **Strictly enforced by default** (configurable for self-testing) | Different firmware builds may change the wireless driver (`wonder0`), system layout, or SELinux policy. Updating `TARGET_BUILD` in [scripts/config.env](scripts/config.env) allows self-testing newer OTAs on the same device, with no guarantee of compatibility. |
| **KernelSU Tools & Root-Only State Dir** | **Hard requirement** | Requires `/data/adb/ksud` and `/data/adb/ksu/bin/busybox`. All sessions, locks, and rollback states are stored in Root-only `/data/adb/quickshare-pma110/` (`0700 root:root`), never trusting shell-writable `/data/local/tmp`. Magisk and APatch are not supported. |
| **Mount Points & Pending OTA** | **Hard requirement** | Checks for mount conflicts on `/system/priv-app` and `/system/etc/permissions` when preparing the privileged extension, and on the VINTF manifest directory and APEX list when starting the service. Aborts if pending OTA lookup fails or a staged update is ready. |
| **Google Play services (GMS) Version** | **Prompt & pin exact `versionCode`** | Before making changes, any non-baseline GMS version triggers a confirmation dialog pinned to the exact `versionCode`. If the version changes again before modifications start, the tool prompts again. Canceling leaves mounts, permissions, and GMS config untouched. If a version change is detected after tearing down an old session, the tool stops and asks you to check status. GMS UID is resolved dynamically for User 0. |
| **Quick Share Extension (`com.google.android.mosey`)** | **Verify User 0 install state** | If not installed for User 0, the tool attempts to stage the privileged overlay and soft reboot. If already installed, its APK path and SHA-256 are verified. Package manager query failures, mismatched versions, or split-APK updates abort execution. |
| **KernelSU `ksud` Version** | **Capability check** | Probes `ksud soft-reboot --help`. Non-baseline versions print a notice; actual soft-reboot behavior depends on your KernelSU fork. |
| **Google Play Store** | **No version requirement** | Play Store version is neither required nor checked. |

### 4. Transfer Speed Measurements

The author recorded one run in each direction between a Mainland China PMA110 and a Mac. The CSVs contain one sample per second. The directions are relative to the Mac. Android → Mac uses its receive rate (`RX_MB/s`) and Mac → Android uses its transmit rate (`TX_MB/s`). The active-window mean covers the continuous interval with a rate of at least **1 MB/s** in the measured direction. The peak is the highest one-second sample.

| Direction | Active samples | Active-window mean | One-second peak |
| :--- | ---: | ---: | ---: |
| Android → Mac | 107 | 10.70 MB/s | 11.79 MB/s |
| Mac → Android | 334 | 3.42 MB/s | 3.76 MB/s |

The CSVs record RX and TX rates. File sizes and transfer completion events were unavailable, so end-to-end file throughput could not be calculated. In each sanitized CSV, the first sample is set to second 0. [Android → Mac CSV](docs/benchmarks/android-to-mac.csv) · [Mac → Android CSV](docs/benchmarks/mac-to-android.csv)

---

## 2. How It Works

1. **Leaf-Directory Read-Only Overlay + KernelSU Soft Reboot** (`scripts/prepare-privileged.sh`)
   - Inside PID 1's mount namespace, overlays only the two leaf directories `/system/priv-app` and `/system/etc/permissions` with the unpacked, whitelist-checked, symlink-free, SHA-256-verified stock `MoseyApp.apk` and privapp permissions XML, keeping stock `SystemUI` and `liboplus_network_servers.so` intact.
   - Starts a timeout/boot-loop watchdog and invokes `ksud soft-reboot` (restarting the Android framework without rebooting the kernel) so `com.google.android.mosey` receives the `PRIVILEGED` flag and privileged permissions.
2. **Live VINTF Manifest Injection & Cache Refresh** (`scripts/live-vintf.sh`, `native/query_declared.c`)
   - Mounts the SHA-256-verified stock `manifest_mosey.xml` read-only onto `/system_ext/etc/vintf/manifest`.
   - Temporarily bind-mounts a copy of `/apex/apex-info-list.xml` with an updated `mtime` and calls `AServiceManager_isDeclared` to trigger `servicemanager` to reload its VINTF cache, then immediately unmounts and restores the original path.
3. **Lossless GMS Nearby External-Provider Flag Toggle** (`native/nearby-flag.c`, `scripts/cache-test.sh`)
   - Resolves User 0's GMS UID via shared `resolve_package_uid_u0` and verifies config ownership. Uses `nearby-flag` with byte-for-byte lossless round-trip verification to enable only Flag `45704091`, retains a hard-link backup of the original file in the same directory, temporarily grants required location permissions, and gracefully restarts the main GMS process.
   - Every lock acquisition, unmount, and verification step in rollback explicitly checks for errors; any failure preserves `armed` / `cache-armed` markers for subsequent recovery.
4. **Private Mount Namespace for `mosey_server` & Bounded Self-Recovery** (`scripts/probe-native.sh`, `native/mosey_lazy_hold.c`)
   - Uses `unshare -m --propagation private` to isolate a private mount namespace and overlays verified `mosey_server`, `libmosey_daemon_ffi.so`, and `libmosey_local_binder.so` without affecting global `/system_ext/bin` or `/system_ext/lib64`.
   - `libmosey_local_binder.so` keeps the lazy Binder service persistent. The supervisor logs exit codes and timestamps. If the daemon exits unexpectedly while the session is still valid, the tool first tries to restart it in that session. After the recovered daemon runs for at least 10 minutes, a subsequent failure is eligible for recovery again. See [Known Limitations](#6-known-limitations) for session rebuild conditions.

---

## 3. Repository Layout

```text
.
├── app/                      # Standalone Android management APK (plain Java, minSdk 30, no Gradle)
├── scripts/                  # On-device shell runtime scripts packaged into APK assets
│   ├── config.env            # Target device/build/baseline versions and stock SHA-256 digests
│   ├── common.sh             # Root-only state validation, staged OTA check, User 0 UID lookup
│   ├── restore.sh            # Main dispatcher (load / status / soft-reboot / rollback / logs)
│   ├── prepare-privileged.sh # Leaf priv-app overlay, unpack verification, soft-reboot watchdog
│   ├── live-vintf.sh         # VINTF manifest injection, APEX mtime cache refresh, explicit rollback
│   ├── cache-test.sh         # GMS Phenotype flag toggle, backup, and explicit rollback
│   ├── probe.sh              # Bridge script
│   └── probe-native.sh       # Private-namespace mosey_server launcher, digest check & recovery monitor
├── native/                   # 3 original ARM64 C utilities
│   ├── nearby-flag.c         # Phenotype snapshot codec and --status read-only inspector
│   ├── query_declared.c      # Calls libbinder_ndk.so to query live VINTF declaration
│   ├── mosey_lazy_hold.c     # LD_PRELOAD persistence shim for mosey_server
│   └── third_party/
│       └── zlib-LICENSE.txt  # License notice when statically linking zlib
├── docs/
│   └── benchmarks/           # Anonymized transfer rate CSVs for both directions
├── tools/
│   ├── inspect_ota.py        # Local / remote HTTP Range scanner for EROFS paths in official OTAs
│   ├── extract_vendor.py     # Rejects symlinks, verifies SHA-256, and packages components into vendor/
│   ├── build-native.sh       # Builds the 3 ARM64 native binaries (Android NDK or Zig)
│   ├── build-apk.sh          # Verifies vendor archive whitelist & hashes, compiles and signs the APK
│   └── verify-manifest.json  # Verified CPH2841 stock component image paths and SHA-256 digests
└── vendor/                   # User-extracted proprietary component output (ignored by .gitignore)
```

---

## 4. Building from Source

### 0. Build Prerequisites

Run all commands from the repository root. Once built and installed on your phone, daily loading and rollback run completely standalone on-device.

- **Base Tools**: Bash, JDK supporting `javac --release 8` (including `keytool`), Android SDK Build Tools (`aapt2`, `d8`, `zipalign`, `apksigner`) with `platforms/android-35/android.jar`, Python 3, `zip`, `openssl`.
- **Native Toolchain (choose one)**:
  - Android NDK (the script probes ARM64 API 35, 34, and 29 clang, or set `NDK_CLANG` explicitly); or
  - Zig (tested with `0.15.2`) + `zlib` source directory + Android `libc.so` / `libdl.so`.
- **OTA Extraction Tools**: Use an open-source tool such as `payload-dumper-go` to extract `system_ext.img` from a full official OTA ZIP; extracting files directly from `system_ext.img` (EROFS) requires `erofs-utils` (`dump.erofs`).

### 1. Build Native Helper Binaries
```bash
# Option A: Android NDK
ANDROID_NDK_HOME=/path/to/android-ndk ./tools/build-native.sh

# Option B: Zig (if redistributing static builds privately, comply with musl and zlib licenses)
ZIG=/path/to/zig ZLIB_DIR=/path/to/zlib-src BIONIC_LIB_DIR=/path/to/bionic-libs ./tools/build-native.sh
```

Build outputs are placed in `native/bin/` (ignored by `.gitignore`).

### 2. Extract and Verify Stock Components
The verified download is the **full OTA for the global `CPH2841_17.0.0.101(EX01)`, Indonesia (`ID`)**, with a size of `10,508,029,704` bytes (about 9.79 GiB). Search for the full version in the catalog, select the `ID` entry, and click **获取链接** (Get link) to download from OPPO's CDN. Return to the catalog for a fresh link if it expires. Use this OTA on your computer as the input for component extraction. [MyFyFy firmware catalog](https://myfyfy.top/)

Use [payload-dumper-go](https://github.com/ssut/payload-dumper-go/releases/tag/2.1.0) to extract `system_ext.img` from the downloaded ZIP. The command below was verified with version 2.1.0.

```bash
payload-dumper-go -p system_ext -o /path/to/extracted-ota /path/to/official-ota.zip
```

The verified image has build increment `1792250571287` and SHA-256 `5fad6016df612752ebe2785c053f5838f412ac9c855b0f2aa22c26ccf527dc63`. Regional packages can share the same OTA version name. Use the five SHA-256 checks in the following step to confirm the required components match.

After building the native binaries, run `tools/extract_vendor.py`. It checks paths and SHA-256 digests against [tools/verify-manifest.json](tools/verify-manifest.json) and packages the verified components together with the locally built shim into `vendor/`. If a hash mismatch occurs, verify your OTA source first. To inspect EROFS paths inside an OTA beforehand, run `python3 tools/inspect_ota.py --zip /path/to/official-ota.zip system_ext`.

```bash
# Option A: Extract directly from system_ext.img (requires dump.erofs)
python3 tools/extract_vendor.py --system-ext-img /path/to/extracted-ota/system_ext.img

# Option B: Package from an already-extracted regular-file directory
python3 tools/extract_vendor.py --components-dir /path/to/extracted-components
```

### 3. Build and Sign the APK

```bash
ANDROID_SDK_ROOT=/path/to/android-sdk ./tools/build-apk.sh
```

Or specify SDK tools explicitly:

```bash
BUILD_TOOLS=/path/to/android-sdk/build-tools/35.0.0 \
ANDROID_JAR=/path/to/android-sdk/platforms/android-35/android.jar \
./tools/build-apk.sh
```

During packaging, the script verifies that the shim inside `daemon.tar` matches the locally compiled `libmosey_local_binder.so`, repacks only verified members into canonical archives, and appends the SHA-256 digests of both archives and the shim into the APK's bundled `config.env`. On the phone, Root scripts verify each archive before unpacking and re-verify unpacked files before mounting.

**Signing Keys & In-Place Upgrades**:
- The first build generates a local random signing keystore under `build/` (`build/signing.p12` and `build/signing.pass`, ignored by `.gitignore`). Separate build directories generate different certificates and **cannot upgrade over each other** unless you uninstall first or reuse the same `build/signing.p12` + `build/signing.pass`.
- v1.0 has internal version code **14**. To upgrade in place from the v1.0.7 test build (version code 13), build v1.0 with the same signing key. The app selects its asset directory by the SHA-256 fingerprint of its bundled files and restores missing or damaged assets from the current APK.

---

## 5. On-Device Usage

> Note: The Android app UI and runtime messages are currently in Simplified Chinese: **「加载」** = Load, **「查看状态」** = Status, **「软重启」** = Soft Reboot, **「撤回」** = Rollback, **「查看日志」** = Logs.

1. Install `build/QuickShare-PMA110.apk` and grant superuser access to **Quick Share 恢复** in KernelSU.
2. Ensure KernelSU Root is active and User 0 has opened Google Quick Share at least once.
3. Open **Quick Share 恢复** and tap **「加载」 (Load)**:
   - If your Google Play services version differs from the baseline, a confirmation dialog will ask whether to proceed for that exact `versionCode`.
   - If prompted that the privileged extension is staged, tap **「软重启」 (Soft Reboot)** inside the app.
   - After returning to the launcher and unlocking the phone, open the app again and tap **「加载」 (Load)** to finish activation.
4. Keep Wi-Fi and Bluetooth enabled on both devices when transferring. To receive on Android, unlock the phone and open Quick Share's **Receive** screen. To receive on Apple devices, temporarily set AirDrop visibility to **Everyone** (**Everyone for 10 Minutes** on iPhone/iPad). [Google Quick Share Help](https://support.google.com/googleplay/answer/9286773) · [Apple AirDrop on Mac](https://support.apple.com/guide/mac-help/mh35868/mac)
5. Use **「查看状态」 (Status)** to inspect the privileged extension, native daemon, GMS binding, and Nearby flag. Tapping **「撤回」 (Rollback)** stops the daemon and reverts temporary config and permission changes made in the session. Active privileged extension mounts disappear on a full reboot.

### Fallback: If the Privileged Extension Does Not Activate After Soft Reboot on a Clean Device
You can start the normal setup on a phone without `com.google.android.mosey` installed. Use these steps if **Load** or **Status** reports an inactive extension overlay after the soft reboot.
1. Perform a **full device reboot** to clear the lingering overlay (the current **Rollback** button only unmounts staged pre-soft-reboot overlays, not post-soft-reboot mounts). Re-acquire Root first if using temporary Root.
2. Extract the stock `MoseyApp.apk` from the archive created during the build. Compare its SHA-256 with [tools/verify-manifest.json](tools/verify-manifest.json), then install it manually on the phone. Keep this exact version, since a Play Store update can replace it with a different version or split APK.

   ```bash
   tar -xOf vendor/privileged-app.tar ./priv-app/MoseyApp/MoseyApp.apk > MoseyApp.apk
   openssl dgst -sha256 MoseyApp.apk
   ```

3. Open the tool again and run **Load → Soft Reboot → Load**.

After loading again, open **Status** and check for **「特权扩展 已生效」 (Privileged extension active)** and **「Google Play 服务 已连接扩展」 (GMS connected to extension)**. If the installed APK is the same version, Android may retain a copy under `/data/app` after privileged mode is active.

---

## 6. Known Limitations

- **Apple device compatibility.** Other AirDrop-capable Apple devices may also work with the PMA110 in theory, with testing limited to Mac because it is the only Apple device available to the author. Compatibility with iPhone, iPad, and other models still needs testing.
- **Full Reboot**: Clears all in-memory mounts. Temporary Root users must re-root first, and both temporary and permanent Root users must run **Load → Soft Reboot → Load** again after a hard reboot. Leftover state from an abnormal exit is cleaned up on the next Load or Rollback.
- **Unexpected daemon exit**: The tool first attempts an in-session restart. If the session ends, it can rebuild the session when Root, Android framework stability, the approved GMS version, and the privileged extension are still available. After the recovered daemon runs for at least 10 minutes, a later failure is eligible for recovery again. Repeated failures within 10 minutes of automatic rebuilding limit further rebuilds. Rollback cancels automatic rebuilding. A full rebuild opens Quick Share and checks the daemon, GMS binding, and Nearby flag.
- **GMS Config Refresh**: Google Play services background sync may revert or remove the local Nearby flag. If the daemon is running but devices cannot see each other, check **Status**; if the flag is disabled or absent, tap **Load** to rebuild the session.
- **97%–99% Receive Stall**: Observed in `PMA110` baseline tests (the file is sometimes already written to storage). Keep phone Wi-Fi on, try temporarily disabling **Auto-join** for your current Wi-Fi router, and compare SHA-256 checksums on both devices when verifying large files.
- **Reporting Issues**: Include device model, firmware build, GMS and KernelSU versions, reproduction steps, and error messages. Redact account hashes, device names, MAC addresses, and signed OTA URLs before posting logs. The author can currently reproduce issues in the baseline environment listed above. Reports from other configurations are welcome, and diagnosis and fixes depend on the available logs and reproduction conditions.
- **Third-Party License**: `native/nearby-flag.c` depends on `zlib`; see [native/third_party/zlib-LICENSE.txt](native/third_party/zlib-LICENSE.txt).

---

## 7. AI-Assisted Development & Disclaimer

### AI-Assisted Development Notice
Parts of this project's source code, shell scripts, build tooling, security audits, and documentation were authored and reviewed with AI assistance. Although the repository has undergone host-side real-image extraction, signed APK builds, static checks, and simulated regression tests, edge cases and firmware-specific issues may still exist. Review the code and understand the risks before building or running it.

### Disclaimer
- This is an unofficial personal open-source research tool and is **not** affiliated with, endorsed by, or sponsored by **OPPO, Google, Apple, or KernelSU**.
- Running this tool requires **Root privileges** and performs in-memory system directory overlays, Android framework soft reboots, and modifications to local Google Play services configuration files. These operations carry inherent risks including boot loops, system or networking instability, data loss, voided warranty, or service/account issues.
- This software is provided **"AS IS"**, without warranty of any kind, express or implied. **Back up all important data before proceeding. You assume full responsibility and all risks arising from using, modifying, or distributing this tool; the author shall not be held liable for any direct or indirect damages.**

---

## License

Original source code in this repository is licensed under the [MIT License](LICENSE).
