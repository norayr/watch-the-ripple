#!/usr/bin/env python3
"""Compile and run notification tests in an isolated temporary directory."""

import pathlib
import os
import subprocess
import tempfile


root = pathlib.Path(__file__).resolve().parent.parent
temp_root = "/tmp/opencode" if pathlib.Path("/tmp/opencode").is_dir() else None
with tempfile.TemporaryDirectory(prefix="wtr-tests-", dir=temp_root) as temp:
    for name, fixture in [
        ("test_notifications", f"{temp}/events.db"),
        ("test_mail_cache", f"{temp}/mail"),
        ("test_pebble_protocol", f"{temp}/unused"),
        ("test_wtr_config", f"{temp}/config"),
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
        env = os.environ.copy()
        if name == "test_wtr_config":
            env.update(HOME=f"{fixture}/home", XDG_CONFIG_HOME="")
        subprocess.run([f"{temp}/{name}", fixture], check=True, cwd=temp, env=env)
        if name == "test_wtr_config":
            env["XDG_CONFIG_HOME"] = f"{fixture}/xdg"
            subprocess.run([f"{temp}/{name}", fixture], check=True, cwd=temp, env=env)
