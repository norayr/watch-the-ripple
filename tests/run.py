#!/usr/bin/env python3
"""Compile and run notification tests in an isolated temporary directory."""

import pathlib
import os
import subprocess
import tempfile


root = pathlib.Path(__file__).resolve().parent.parent
temp_root = "/tmp/opencode" if pathlib.Path("/tmp/opencode").is_dir() else None
with tempfile.TemporaryDirectory(prefix="maebble-tests-", dir=temp_root) as temp:
    subprocess.run(
        [
            os.environ.get("FPC", "fpc"), "-B", "-gl", "-Cr", "-Co", "-Ci", "-Sa", f"-Fu{root}",
            f"-FU{temp}", f"-o{temp}/test_notifications",
            str(root / "tests/test_notifications.pas"),
        ],
        check=True,
        cwd=temp,
    )
    subprocess.run([f"{temp}/test_notifications", f"{temp}/events.db"], check=True)
