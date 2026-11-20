#!/usr/bin/env python3
"""Exercise catalog, PBW, HTTPS URL checks, and watch protocol logic offline."""

import json
import os
import pathlib
import struct
import subprocess
import tempfile
import uuid
import zipfile


def crc(data):
    value = 0xFFFFFFFF
    for offset in range(0, len(data), 4):
        word = data[offset:offset + 4]
        value ^= int.from_bytes(word, "little" if len(word) == 4 else "big")
        for _ in range(32):
            value = ((value << 1) ^ (0x04C11DB7 if value & 0x80000000 else 0)) & 0xFFFFFFFF
    return value


root = pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="ripple-ui-", dir="/tmp/opencode" if pathlib.Path("/tmp/opencode").is_dir() else None) as temp:
    firmware = struct.pack(
        ">I32s8sBBB", 1, b"v3.13.3-rbl", b"12345678", 0, 5, 1
    )
    pathlib.Path(temp, "version.bin").write_bytes(b"\x01" + firmware + firmware)
    binary = bytearray(129)
    binary[:8] = b"PBLAPP\0\0"
    binary[8:10] = bytes([0x10, 0])
    binary[10:14] = bytes([3, 0, 1, 2])
    binary[24:32] = b"Test app"
    struct.pack_into("<I", binary, 96, 9)
    binary[104:120] = uuid.UUID("00112233-4455-6677-8899-aabbccddeeff").bytes
    parts = {"application": ("pebble-app.bin", binary), "resources": ("app_resources.pbpack", b"abc" * 1400), "worker": ("pebble-worker.bin", b"worker!")}
    manifest = {key: {"name": name, "size": len(data), "crc": crc(data)} for key, (name, data) in parts.items()}
    for filename in ["test.pbw", "bad.pbw"]:
        if filename == "bad.pbw":
            manifest["application"]["crc"] ^= 1
        with zipfile.ZipFile(f"{temp}/{filename}", "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("basalt/manifest.json", json.dumps(manifest))
            for name, data in parts.values():
                archive.writestr(f"basalt/{name}", data)
    legacy = binary[:100] + bytearray(4) + binary[100:]
    legacy[8:10] = bytes([8, 1])
    legacy_manifest = {"application": {"name": "pebble-app.bin", "size": len(legacy), "crc": crc(legacy)}}
    with zipfile.ZipFile(f"{temp}/legacy.pbw", "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("manifest.json", json.dumps(legacy_manifest))
        archive.writestr("pebble-app.bin", legacy)
    control = pathlib.Path(temp) / "control"
    control.write_text('''#!/bin/sh
set -eu
base=$(dirname "$0")
printf '%s\\n' "$1" >> "$base/control.log"
case $1 in
    status) [ -f "$base/running" ] || exit 3 ;;
    stop) rm -f "$base/running" ;;
    start) touch "$base/running" ;;
    *) exit 1 ;;
esac
''')
    control.chmod(0o755)
    subprocess.run([os.environ.get("FPC", "fpc"), "-B", "-gl", "-Cr", "-Co", "-Ci", "-Sa", "-gh", f"-Fu{root}", f"-Fu{root}/ui", f"-Fu{root}/third_party/bluetoothlaz", f"-FU{temp}", f"-o{temp}/test_ui", str(root / "tests/test_ripple_ui.pas")], check=True, cwd=temp)
    env = os.environ.copy()
    env.update(HOME=f"{temp}/home", XDG_CONFIG_HOME=f"{temp}/config")
    subprocess.run([f"{temp}/test_ui", temp], check=True, cwd=temp, env=env)
