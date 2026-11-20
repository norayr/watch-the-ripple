#!/usr/bin/env python3
"""Check staged installation and Hildon launcher metadata."""

import base64
import configparser
import os
import pathlib
import shutil
import struct
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parent.parent
TEMP_ROOT = "/tmp/opencode" if pathlib.Path("/tmp/opencode").is_dir() else None


class InstallTests(unittest.TestCase):
    def test_hildon_install(self):
        with tempfile.TemporaryDirectory(prefix="ripple-install-", dir=TEMP_ROOT) as temp:
            workspace = pathlib.Path(temp) / "source"
            destination = pathlib.Path(temp) / "installed"
            files = ["Makefile", "pebble.png", "wtr.conf", "scripts/wtr",
                     "data/ripple.desktop", "data/90ripple"]
            for name in files:
                target = workspace / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / name, target)
            for name in ["wtrd", "ripple"]:
                binary = workspace / name
                binary.write_text("#!/bin/sh\nexit 0\n")
                binary.chmod(0o755)
            subprocess.run(
                ["make", "--no-print-directory", "--assume-old=wtrd", "--assume-old=ripple",
                 "install", f"DESTDIR={destination}", "PREFIX=/usr"],
                check=True, cwd=workspace,
            )
            for name in ["wtrd", "wtr", "ripple"]:
                binary = destination / "usr/bin" / name
                self.assertTrue(binary.is_file(), str(binary))
                self.assertTrue(os.access(binary, os.X_OK), str(binary))
            desktop = destination / "usr/share/applications/hildon/ripple.desktop"
            parser = configparser.ConfigParser(interpolation=None)
            parser.optionxform = str
            parser.read(desktop)
            entry = parser["Desktop Entry"]
            self.assertEqual(entry["Encoding"], "UTF-8")
            self.assertEqual(entry["Name"], "Ripple")
            self.assertEqual(entry["Exec"], "/usr/bin/ripple")
            self.assertEqual(entry["Icon"], "ripple")
            self.assertEqual(entry["Type"], "Application")
            self.assertEqual(entry["X-Osso-Type"], "application/x-executable")
            self.assertFalse(entry.getboolean("Terminal"))
            self.assertFalse(entry.getboolean("X-MultipleArgs"))
            icon = destination / "usr/share/pixmaps" / (entry["Icon"] + ".png")
            data = icon.read_bytes()
            self.assertEqual(data, (ROOT / "pebble.png").read_bytes())
            self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
            self.assertEqual(struct.unpack(">II", data[16:24]), (48, 48))
            control = (ROOT / "debian/control").read_text()
            encoded = control.split("XB-Maemo-Icon-26:\n", 1)[1]
            encoded = "".join(line.strip() for line in encoded.splitlines() if line.startswith(" "))
            self.assertEqual(base64.b64decode(encoded, validate=True), data)
            self.assertEqual((destination / "usr/share/ripple/wtr.conf").read_bytes(),
                             (ROOT / "wtr.conf").read_bytes())
            self.assertEqual((destination / "etc/X11/Xsession.d/90ripple").read_bytes(),
                             (ROOT / "data/90ripple").read_bytes())


if __name__ == "__main__":
    unittest.main()
