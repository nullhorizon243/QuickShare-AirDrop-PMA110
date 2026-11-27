#!/usr/bin/env python3
"""Inspect an official Android full OTA ZIP (local file or HTTP range URL)
for Mosey / AWDL / Quick Share files inside EROFS partitions.
"""
import argparse
import bz2
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from functools import lru_cache
import hashlib
import io
import lzma
from pathlib import Path
import re
import struct
import subprocess
import sys
import zipfile


SEARCH_LOCATIONS = (
    "", "app", "priv-app", "bin", "bin/hw", "etc/init", "etc/permissions",
    "etc/default-permissions", "etc/sysconfig", "etc/vintf",
    "etc/vintf/manifest", "lib64", "lib64/hw", "lib/modules",
)
PATTERN = re.compile(r"mosey|awdl|wonder|quick.?share", re.IGNORECASE)


class RemoteSource:
    def __init__(self, url: str):
        self.url = url
        head = subprocess.run(
            ["curl", "-fsSI", "--max-time", "20", url],
            capture_output=True, text=True, check=True,
        )
        lengths = re.findall(r"(?im)^content-length:\s*(\d+)\s*$", head.stdout)
        if not lengths:
            raise ValueError("Server did not return Content-Length for OTA URL")
        self.size = int(lengths[-1])

    @lru_cache(maxsize=64)
    def read_at(self, offset: int, size: int) -> bytes:
        if not size:
            return b""
        response = subprocess.run(
            ["curl", "-fsS", "--max-time", "20", "--max-filesize",
             str(size), "-r", f"{offset}-{offset + size - 1}", self.url],
            capture_output=True, check=True,
        )
        if len(response.stdout) != size:
            raise ValueError(f"Unexpected HTTP range length at {offset}: {len(response.stdout)}")
        return response.stdout


class LocalSource:
    def __init__(self, path: Path):
        self.path = path
        self.size = path.stat().st_size

    def read_at(self, offset: int, size: int) -> bytes:
        if not size:
            return b""
        with self.path.open("rb") as handle:
            handle.seek(offset)
            data = handle.read(size)
        if len(data) != size:
            raise ValueError(f"Short read at {offset}: {len(data)} != {size}")
        return data


class SeekableReader(io.RawIOBase):
    def __init__(self, source):
        self.source = source
        self.position = 0

    def tell(self):
        return self.position

    def seek(self, offset, whence=io.SEEK_SET):
        base = {io.SEEK_SET: 0, io.SEEK_CUR: self.position, io.SEEK_END: self.source.size}
        self.position = base[whence] + offset
        return self.position

    def read(self, size=-1):
        remainder = self.source.size - self.position
        size = min(remainder, size) if size >= 0 else remainder
        result = self.source.read_at(self.position, size)
        self.position += len(result)
        return result


def varint(data, cursor):
    value = 0
    for shift in range(0, 70, 7):
        byte = data[cursor]
        cursor += 1
        value |= (byte & 127) << shift
        if not byte & 128:
            return value, cursor
    raise ValueError("Invalid protobuf varint")


def fields(data):
    result = defaultdict(list)
    cursor = 0
    while cursor < len(data):
        tag, cursor = varint(data, cursor)
        number, wire = tag >> 3, tag & 7
        if wire == 0:
            value, cursor = varint(data, cursor)
        elif wire in (1, 5):
            size = 8 if wire == 1 else 4
            value = data[cursor:cursor + size]
            cursor += size
        elif wire == 2:
            size, cursor = varint(data, cursor)
            value = data[cursor:cursor + size]
            cursor += size
        else:
            raise ValueError(f"Unsupported protobuf wire type {wire}")
        result[number].append(value)
    return result


def read_manifest(source):
    with zipfile.ZipFile(SeekableReader(source)) as archive:
        entry = archive.getinfo("payload.bin")
        if entry.compress_type != zipfile.ZIP_STORED:
            raise ValueError("payload.bin is compressed by ZIP")
        header = source.read_at(entry.header_offset, 30)
        path_size, extra_size = struct.unpack_from("<HH", header, 26)
        payload_start = entry.header_offset + len(header) + path_size + extra_size
        header = source.read_at(payload_start, 24)
        magic, version, size, signature_size = struct.unpack(">4sQQI", header)
        if magic != b"CrAU" or version != 2:
            raise ValueError("Unknown Android OTA payload format")
        manifest = fields(source.read_at(payload_start + len(header), size))
        data_start = payload_start + len(header) + size + signature_size
    return manifest, data_start


class Image:
    def __init__(self, source, partition, data_start, block_size):
        self.source = source
        self.size = fields(partition[7][0])[1][0]
        self.data_start = data_start
        self.extents = []
        self.operations = [fields(entry) for entry in partition[8]]
        for index, op in enumerate(self.operations):
            op_offset = 0
            for raw_extent in op[6]:
                extent = fields(raw_extent)
                start = extent[1][0] * block_size
                size = extent[2][0] * block_size
                self.extents.append((start, start + size, index, op_offset))
                op_offset += size
        self.extents.sort()

    @lru_cache(maxsize=64)
    def operation_data(self, index):
        op = self.operations[index]
        kind = op[1][0]
        if kind in (6, 7):
            return None
        blob = self.source.read_at(self.data_start + op[2][0], op[3][0])
        if op[8] and hashlib.sha256(blob).digest() != op[8][0]:
            raise ValueError(f"Invalid OTA operation checksum {index}")
        if kind == 0:
            return blob
        if kind == 1:
            return bz2.decompress(blob)
        if kind == 8:
            return lzma.decompress(blob)
        raise ValueError(f"Unsupported full OTA operation {kind}")

    def read(self, start, size):
        blocks = []
        end = start + size
        for first, last, index, shift in self.extents:
            if last <= start:
                continue
            if first >= end:
                break
            if first > start:
                blocks.append(bytes(first - start))
                start = first
            count = min(last, end) - start
            data = self.operation_data(index)
            offset = shift + start - first
            blocks.append(data[offset:offset + count] if data is not None else bytes(count))
            start += count
        if start < end:
            blocks.append(bytes(end - start))
        return b"".join(blocks)


class ErofsDirectoryReader:
    def __init__(self, image):
        self.image = image
        superblock = image.read(1024, 128)
        if superblock[:4] != bytes.fromhex("e2e1f5e0"):
            raise ValueError("Partition is not EROFS")
        self.block_size = 1 << superblock[12]
        self.root_nid = struct.unpack_from("<H", superblock, 14)[0]
        self.metadata_start = struct.unpack_from("<I", superblock, 40)[0] * self.block_size

    def inode_location(self, nid):
        return self.metadata_start + nid * 32

    @lru_cache(maxsize=512)
    def inode_data(self, nid):
        start = self.inode_location(nid)
        inode = self.image.read(start, 64)
        format_, xattr_count = struct.unpack_from("<HH", inode, 0)
        extended = bool(format_ & 1)
        layout = (format_ >> 1) & 7
        size = struct.unpack_from("<Q" if extended else "<I", inode, 8)[0]
        block = struct.unpack_from("<I", inode, 16)[0]
        if size > 4 * 1024 * 1024:
            raise ValueError(f"Unexpected directory size {size}")
        if layout == 0:
            return self.image.read(block * self.block_size, size)
        if layout == 2:
            inline_start = start + (64 if extended else 32)
            inline_start += 12 + (xattr_count - 1) * 4 if xattr_count else 0
            main_size, tail_size = divmod(size, self.block_size)
            main = self.image.read(block * self.block_size, main_size * self.block_size)
            return main + self.image.read(inline_start, tail_size)
        raise ValueError(f"Unsupported directory layout {layout} (inode {nid})")

    @lru_cache(maxsize=512)
    def directory(self, nid):
        result = {}
        data = self.inode_data(nid)
        for offset in range(0, len(data), self.block_size):
            block = data[offset:offset + self.block_size]
            name_start = struct.unpack_from("<H", block, 8)[0]
            if name_start == 0 or name_start % 12 or name_start > len(block):
                raise ValueError(f"Invalid EROFS directory entries at inode {nid}")
            entries = list(struct.iter_unpack("<QHBB", block[:name_start]))
            for index, (child, address, kind, _) in enumerate(entries):
                end = entries[index + 1][1] if index + 1 < len(entries) else len(block)
                name = block[address:end].split(b"\0", 1)[0].decode(errors="replace")
                if name not in (".", ".."):
                    result[name] = (child, kind)
        return result

    def resolve_directory(self, path):
        node = self.root_nid
        for part in path.split("/") if path else ():
            entry = self.directory(node).get(part)
            if entry is None or entry[1] != 2:
                return {}
            node = entry[0]
        return self.directory(node)


def inspect_partition(args):
    source, name, partition, data_start, block_size = args
    image = Image(source, partition, data_start, block_size)
    try:
        reader = ErofsDirectoryReader(image)
    except (ValueError, subprocess.CalledProcessError) as exc:
        return name, [], [str(exc)]
    matches = []
    errors = []
    for path in SEARCH_LOCATIONS:
        try:
            for filename, (nid, entry_type) in reader.resolve_directory(path).items():
                if not PATTERN.search(filename):
                    continue
                relative = f"{path}/{filename}".strip("/")
                matches.append(relative)
                if entry_type == 2:
                    matches.extend(f"{relative}/{child}" for child in reader.directory(nid))
        except (ValueError, subprocess.CalledProcessError) as exc:
            errors.append(f"{path}: {exc.__class__.__name__}")
    return name, matches, errors


def main():
    parser = argparse.ArgumentParser(
        description="Inspect EROFS partitions inside an official Android OTA ZIP for Mosey/Quick Share files."
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--zip", type=Path, help="Path to local full OTA zip containing payload.bin")
    group.add_argument("--url", help="HTTP/HTTPS URL supporting range requests to a full OTA zip")
    parser.add_argument("partitions", nargs="+", help="Partition names to scan (e.g. system_ext product vendor)")
    args = parser.parse_args()

    source = LocalSource(args.zip) if args.zip else RemoteSource(args.url)
    manifest, data_start = read_manifest(source)
    block_size = manifest[3][0] if manifest[3] else 4096
    wanted = list(dict.fromkeys(args.partitions))
    available = {}
    for record in manifest[13]:
        partition = fields(record)
        name = partition[1][0].decode()
        available[name] = partition
    missing = [name for name in wanted if name not in available]
    if missing:
        print(f"Missing requested partition(s) in OTA manifest: {', '.join(missing)}", file=sys.stderr)
        return 1
    work_items = [(source, name, available[name], data_start, block_size) for name in wanted]
    with ThreadPoolExecutor(max_workers=min(5, len(work_items))) as pool:
        for name, matches, errors in pool.map(inspect_partition, work_items):
            print(f"{name}: {len(matches)} matching paths", flush=True)
            for path in matches:
                print(f"  /{name}/{path}", flush=True)
            for error in errors:
                print(f"  Incomplete: {error}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
