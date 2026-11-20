#!/usr/bin/env python3
"""Exercise catalog, gallery, PBW, HTTPS checks, and watch protocol logic offline."""

import json
import os
import pathlib
import struct
import subprocess
import tempfile
import uuid
import zipfile
import zlib


def crc(data):
    value = 0xFFFFFFFF
    for offset in range(0, len(data), 4):
        word = data[offset:offset + 4]
        value ^= int.from_bytes(word, "little" if len(word) == 4 else "big")
        for _ in range(32):
            value = ((value << 1) ^ (0x04C11DB7 if value & 0x80000000 else 0)) & 0xFFFFFFFF
    return value


def png(depth, kind, rows, palette=None, alpha=None):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))

    result = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 3, 2, depth, kind, 0, 0, 0))
    if palette is not None:
        result += chunk(b'PLTE', palette)
    if alpha is not None:
        result += chunk(b'tRNS', alpha)
    return result + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')


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
    subprocess.run([os.environ.get("FPC", "fpc"), "-B", "-gl", "-Cr", "-Co", "-Ci", "-Sa", "-gh", f"-Fu{root}/ui", f"-FU{temp}", f"-o{temp}/test_gallery", str(root / "tests/test_ripple_gallery.pas")], check=True, cwd=temp)
    subprocess.run([f"{temp}/test_gallery"], check=True, cwd=temp, env=env)
    colors = bytes([255, 0, 0, 0, 255, 0, 0, 0, 255])
    fixtures = {
        'mono': png(1, 0, bytes([0, 0x40, 0, 0xA0])),
        'gray': png(4, 0, bytes([0, 0x08, 0xF0, 0, 0xF8, 0])),
        'palette': png(2, 3, bytes([0, 0x18, 0, 0x90]), colors),
        'palette-alpha': png(2, 3, bytes([0, 0x18, 0, 0x90]), colors, bytes([255, 128, 0])),
        'rgb': png(8, 2, b'\0' + colors + b'\0' + colors),
        'rgba': png(8, 6, bytes([0, 255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 0]) * 2),
    }
    for name, data in fixtures.items():
        pathlib.Path(temp, f'{name}.png').write_bytes(data)
    pathlib.Path(temp, 'truncated.png').write_bytes(fixtures['mono'][:24])
    fpc = os.environ.get('FPC', 'fpc')
    arch = '-'.join(subprocess.check_output([fpc, flag], text=True).strip() for flag in ['-iTP', '-iTO'])
    candidates = [pathlib.Path(os.environ['LAZARUS'])] if os.environ.get('LAZARUS') else (
        sorted(pathlib.Path('/usr/lib/lazarus').glob('*')) + [pathlib.Path('/usr/share/lazarus')])
    lazarus = next((path for path in candidates if (path / 'lcl/units' / arch / 'graphics.ppu').is_file()), None)
    if lazarus is None:
        raise RuntimeError('Lazarus LCL units not found; set LAZARUS to the Lazarus directory')
    subprocess.run([fpc, '-B', '-gl', '-Cr', '-Co', '-Ci', '-Sa', '-gh', f'-Fu{root}/ui',
                    f'-Fu{lazarus}/lcl/units/{arch}', f'-Fu{lazarus}/components/lazutils/lib/{arch}',
                    f'-FU{temp}', f'-o{temp}/test_preview', str(root / 'tests/test_ripple_preview.pas')],
                   check=True, cwd=temp)
    subprocess.run([f'{temp}/test_preview', temp], check=True, cwd=temp, env=env)
