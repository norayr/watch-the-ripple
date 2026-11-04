#!/usr/bin/env python3
"""Compile and run notification tests in an isolated temporary directory."""

import pathlib
import os
import subprocess
import tempfile


root = pathlib.Path(__file__).resolve().parent.parent
temp_root = "/tmp/opencode" if pathlib.Path("/tmp/opencode").is_dir() else None
with tempfile.TemporaryDirectory(prefix="maebble-tests-", dir=temp_root) as temp:
    for name, fixture in [
        ("test_notifications", f"{temp}/events.db"),
        ("test_mail_cache", f"{temp}/mail"),
        ("test_pebble_protocol", f"{temp}/unused"),
    ]:
        subprocess.run(
            [
                os.environ.get("FPC", "fpc"), "-B", "-gl", "-Cr", "-Co", "-Ci", "-Sa", f"-Fu{root}",
                f"-FU{temp}", f"-o{temp}/{name}",
                str(root / f"tests/{name}.pas"),
            ],
            check=True,
            cwd=temp,
        )
        subprocess.run([f"{temp}/{name}", fixture], check=True)
