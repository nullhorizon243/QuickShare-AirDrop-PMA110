#!/usr/bin/env python3
"""Verify user-supplied stock CPH2841 Mosey components and package them into
vendor/privileged-app.tar, vendor/daemon.tar, and vendor/manifest_mosey.xml.

This repository does not ship any proprietary Google/OPPO binaries.
Users extract the components from their own official OTA image first.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parent.parent
MANIFEST_PATH = Path(__file__).resolve().parent / "verify-manifest.json"
DEFAULT_SHIM = ROOT / "native" / "bin" / "libmosey_local_binder.so"
VENDOR_DIR = ROOT / "vendor"


def read_regular_file(path: Path) -> bytes:
    """Open and read a regular file without following symlinks on the final component."""
    if path.is_symlink():
        raise ValueError(f"Refusing symlink input: {path}")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(str(path), flags)
    except OSError as exc:
        raise ValueError(f"Cannot safely open regular file {path}: {exc}") from exc
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise ValueError(f"Input is not a regular file: {path}")
        with os.fdopen(fd, "rb") as handle:
            fd = -1
            return handle.read()
    finally:
        if fd != -1:
            os.close(fd)


def extract_from_erofs(image: Path, manifest: dict, out_dir: Path, dump_erofs: str) -> None:
    if image.is_symlink() or not image.is_file():
        raise ValueError(f"EROFS image must be an existing regular file: {image}")
    for filename, info in manifest["components"].items():
        rel_path = info["system_ext_path"]
        dest = out_dir / filename
        cmd = [dump_erofs, "--cat", f"--path=/{rel_path}", str(image)]
        proc = subprocess.run(cmd, capture_output=True)
        if proc.returncode != 0 or not proc.stdout:
            raise RuntimeError(
                f"Failed to extract /{rel_path} from {image} using {dump_erofs}:\n"
                f"{proc.stderr.decode(errors='replace').strip()}"
            )
        dest.write_bytes(proc.stdout)


def add_bytes(tar: tarfile.TarFile, arcname: str, data: bytes, mode: int) -> None:
    info = tarfile.TarInfo(name=arcname)
    info.type = tarfile.REGTYPE
    info.size = len(data)
    info.mode = mode
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    info.mtime = 0
    tar.addfile(info, io.BytesIO(data))


def add_dir(tar: tarfile.TarFile, arcname: str) -> None:
    info = tarfile.TarInfo(name=arcname)
    info.type = tarfile.DIRTYPE
    info.mode = 0o755
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    info.mtime = 0
    tar.addfile(info)


def verify_archive(tar_path: Path, expected_dirs: set, expected_files: dict) -> None:
    """Inspect every member of a produced tar archive for strict whitelist, type, and SHA-256."""
    seen_dirs = set()
    seen_files = {}
    with tarfile.open(tar_path, "r") as tar:
        for member in tar.getmembers():
            if member.issym() or member.islnk() or not (member.isdir() or member.isfile()):
                raise ValueError(f"Disallowed non-regular tar member in {tar_path.name}: {member.name}")
            if member.name.startswith("/") or ".." in Path(member.name).parts:
                raise ValueError(f"Unsafe tar member path in {tar_path.name}: {member.name}")
            if member.isdir():
                if member.name not in expected_dirs:
                    raise ValueError(f"Unexpected directory member in {tar_path.name}: {member.name}")
                seen_dirs.add(member.name)
            elif member.isfile():
                if member.name not in expected_files:
                    raise ValueError(f"Unexpected file member in {tar_path.name}: {member.name}")
                extracted = tar.extractfile(member)
                if extracted is None:
                    raise ValueError(f"Unable to read tar member {member.name}")
                actual_hash = hashlib.sha256(extracted.read()).hexdigest()
                if actual_hash != expected_files[member.name]:
                    raise ValueError(f"Archive member digest mismatch for {member.name}")
                seen_files[member.name] = actual_hash
    if seen_dirs != expected_dirs or set(seen_files) != set(expected_files):
        raise ValueError(f"Archive {tar_path.name} missing required entries")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify stock Mosey components and build vendor tarballs for APK packaging."
    )
    src = parser.add_mutually_exclusive_group(required=True)
    src.add_argument(
        "--components-dir", type=Path,
        help="Directory containing extracted MoseyApp.apk, privapp-permissions-com.google.android.mosey.xml, "
             "manifest_mosey.xml, mosey_server, and libmosey_daemon_ffi.so",
    )
    src.add_argument(
        "--system-ext-img", type=Path,
        help="Path to extracted CPH2841 system_ext.img (EROFS); requires dump.erofs in PATH",
    )
    parser.add_argument(
        "--dump-erofs", default="dump.erofs",
        help="Path to dump.erofs binary when using --system-ext-img (default: dump.erofs)",
    )
    parser.add_argument(
        "--shim", type=Path, default=DEFAULT_SHIM,
        help="Path to compiled libmosey_local_binder.so (default: native/bin/libmosey_local_binder.so)",
    )
    parser.add_argument(
        "--output-dir", type=Path, default=VENDOR_DIR,
        help="Output directory (default: vendor/)",
    )
    parser.add_argument(
        "--allow-unverified", action="store_true",
        help="Skip SHA-256 verification against verify-manifest.json (for testing newer firmware builds)",
    )
    args = parser.parse_args()

    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    try:
        shim_bytes = read_regular_file(args.shim)
    except ValueError as exc:
        print(
            f"{exc}\n"
            "Run tools/build-native.sh first to compile native/bin/libmosey_local_binder.so.",
            file=sys.stderr,
        )
        return 1
    if not shim_bytes:
        print(f"Compiled shim is empty: {args.shim}", file=sys.stderr)
        return 1
    shim_hash = hashlib.sha256(shim_bytes).hexdigest()

    with tempfile.TemporaryDirectory(prefix="mosey-vendor-") as tmp:
        if args.system_ext_img:
            comp_dir = Path(tmp)
            try:
                extract_from_erofs(args.system_ext_img, manifest, comp_dir, args.dump_erofs)
            except (ValueError, RuntimeError) as exc:
                print(exc, file=sys.stderr)
                return 1
        else:
            comp_dir = args.components_dir

        payloads = {}
        digests = {}
        for filename, info in manifest["components"].items():
            candidate = comp_dir / filename
            if not candidate.exists() and not candidate.is_symlink():
                alt = comp_dir / info["system_ext_path"]
                if alt.exists() or alt.is_symlink():
                    candidate = alt
                else:
                    print(f"Missing required component: {filename}", file=sys.stderr)
                    return 1
            try:
                raw = read_regular_file(candidate)
            except ValueError as exc:
                print(exc, file=sys.stderr)
                return 1
            if not raw:
                print(f"Component is empty: {candidate}", file=sys.stderr)
                return 1
            actual = hashlib.sha256(raw).hexdigest()
            expected = info["sha256"]
            if actual != expected:
                if args.allow_unverified:
                    print(f"WARNING: {filename} SHA-256 differs ({actual[:12]} != {expected[:12]})")
                else:
                    print(
                        f"SHA-256 mismatch for {filename}:\n"
                        f"  expected: {expected}\n"
                        f"  actual:   {actual}\n"
                        "Pass --allow-unverified only if you intentionally use a different firmware build.",
                        file=sys.stderr,
                    )
                    return 1
            payloads[filename] = raw
            digests[filename] = actual

        args.output_dir.mkdir(parents=True, exist_ok=True)

        priv_tar = args.output_dir / "privileged-app.tar"
        with tarfile.open(priv_tar, "w") as tar:
            add_dir(tar, "./priv-app")
            add_dir(tar, "./priv-app/MoseyApp")
            add_dir(tar, "./permissions")
            add_bytes(tar, "./priv-app/MoseyApp/MoseyApp.apk", payloads["MoseyApp.apk"], 0o644)
            add_bytes(
                tar,
                "./permissions/privapp-permissions-com.google.android.mosey.xml",
                payloads["privapp-permissions-com.google.android.mosey.xml"],
                0o644,
            )
        verify_archive(
            priv_tar,
            {"./priv-app", "./priv-app/MoseyApp", "./permissions"},
            {
                "./priv-app/MoseyApp/MoseyApp.apk": digests["MoseyApp.apk"],
                "./permissions/privapp-permissions-com.google.android.mosey.xml": digests[
                    "privapp-permissions-com.google.android.mosey.xml"
                ],
            },
        )

        daemon_tar = args.output_dir / "daemon.tar"
        with tarfile.open(daemon_tar, "w") as tar:
            add_dir(tar, "./bin")
            add_dir(tar, "./lib64")
            add_bytes(tar, "./bin/mosey_server", payloads["mosey_server"], 0o755)
            add_bytes(tar, "./lib64/libmosey_daemon_ffi.so", payloads["libmosey_daemon_ffi.so"], 0o644)
            add_bytes(tar, "./lib64/libmosey_local_binder.so", shim_bytes, 0o755)
        verify_archive(
            daemon_tar,
            {"./bin", "./lib64"},
            {
                "./bin/mosey_server": digests["mosey_server"],
                "./lib64/libmosey_daemon_ffi.so": digests["libmosey_daemon_ffi.so"],
                "./lib64/libmosey_local_binder.so": shim_hash,
            },
        )

        manifest_out = args.output_dir / "manifest_mosey.xml"
        manifest_out.write_bytes(payloads["manifest_mosey.xml"])
        if hashlib.sha256(manifest_out.read_bytes()).hexdigest() != digests["manifest_mosey.xml"]:
            raise RuntimeError("manifest_mosey.xml verification failed after write")

    print(f"Packaged and verified vendor assets into {args.output_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
