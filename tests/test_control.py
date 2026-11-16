#!/usr/bin/env python3
"""Exercise user controls with an isolated daemon and home directory."""

import concurrent.futures
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parent.parent
TEMP_ROOT = "/tmp/opencode" if pathlib.Path("/tmp/opencode").is_dir() else None


@unittest.skipIf(os.geteuid() == 0, "user-session lifecycle tests require an unprivileged account")
class ControlTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="ripple-control-build-", dir=TEMP_ROOT)
        cls.binary = pathlib.Path(cls.build.name) / "wtrd"
        subprocess.run(
            [os.environ.get("FPC", "fpc"), f"-FU{cls.build.name}", f"-o{cls.binary}",
             str(ROOT / "tests/control_daemon.pas")], check=True, cwd=cls.build.name,
        )

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ripple-control-", dir=TEMP_ROOT)
        self.root = pathlib.Path(self.temp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.prefix = self.root / "usr"
        (self.prefix / "bin").mkdir(parents=True)
        (self.prefix / "share/ripple").mkdir(parents=True)
        shutil.copyfile(ROOT / "scripts/wtr", self.prefix / "bin/wtr")
        (self.prefix / "bin/wtr").chmod(0o755)
        shutil.copyfile(self.binary, self.prefix / "bin/wtrd")
        (self.prefix / "bin/wtrd").chmod(0o755)
        shutil.copyfile(ROOT / "wtr.conf", self.prefix / "share/ripple/wtr.conf")
        self.env = dict(os.environ, HOME=str(self.home), XDG_CONFIG_HOME="",
                        XDG_CACHE_HOME="", XDG_RUNTIME_DIR="")
        self.config = self.home / ".config/wtr/wtr.conf"
        self.pidfile = self.home / ".cache/ripple/wtrd.pid"

    def control(self, command, expected=0):
        result = subprocess.run([str(self.prefix / "bin/wtr"), command],
                                env=self.env, cwd=self.root, text=True,
                                capture_output=True, timeout=15)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def configure(self):
        self.control("init")
        self.config.write_text(self.config.read_text().replace(
            "address =", "address = AA:BB:CC:DD:EE:FF", 1))

    def tearDown(self):
        try:
            self.control("stop")
        finally:
            self.temp.cleanup()

    def test_init_and_validation(self):
        self.control("autostart")
        self.assertFalse((self.home / ".cache/ripple").exists())
        self.control("init")
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)
        original = self.config.read_bytes()
        self.control("init")
        self.assertEqual(self.config.read_bytes(), original)
        self.control("start", expected=1)
        self.control("enable", expected=1)
        self.assertFalse(self.pidfile.exists())

    def test_legacy_migration(self):
        legacy = self.home / ".config/maebble/maebble.cfg"
        legacy.parent.mkdir(parents=True)
        legacy.write_text("[btservice]\naddress=AA:BB:CC:DD:EE:FF\n")
        self.control("init")
        self.assertEqual(self.config.read_bytes(), legacy.read_bytes())
        self.control("start")
        self.control("status")

    def test_lifecycle_and_opt_in(self):
        self.configure()
        self.control("status", expected=3)
        self.control("enable")
        self.control("autostart")
        first_pid = self.pidfile.read_text()
        self.control("start")
        self.assertEqual(self.pidfile.read_text(), first_pid)
        self.control("disable")
        self.control("status")
        self.control("stop")
        self.control("autostart")
        self.control("status", expected=3)
        self.control("restart")
        self.control("status")
        self.control("log")
        self.assertTrue((self.home / ".cache/ripple/wtrd.log.previous").exists())

    def test_concurrent_starts(self):
        self.configure()
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: self.control("start"), range(2)))
        self.assertEqual(sum("already running" in result.stdout for result in results), 1)
        self.control("status")

    def test_stale_pid_does_not_target_unrelated_process(self):
        self.configure()
        self.pidfile.parent.mkdir(parents=True)
        self.pidfile.write_text(f"{os.getpid()}\n")
        self.control("status", expected=3)
        self.control("stop")
        self.assertFalse(self.pidfile.exists())

    def test_xdg_directories(self):
        self.env.update(XDG_CONFIG_HOME=str(self.home / "config"),
                        XDG_CACHE_HOME=str(self.home / "cache"),
                        XDG_RUNTIME_DIR=str(self.home / "runtime"))
        self.config = self.home / "config/wtr/wtr.conf"
        self.pidfile = self.home / "runtime/ripple/wtrd.pid"
        self.configure()
        self.control("start")
        self.assertTrue(self.pidfile.exists())
        self.assertTrue((self.home / "cache/ripple/wtrd.log").exists())


@unittest.skipUnless(os.geteuid() == 0, "root refusal test requires root")
class RootControlTests(unittest.TestCase):
    def test_refuses_root(self):
        result = subprocess.run(["/bin/sh", str(ROOT / "scripts/wtr"), "init"],
                                text=True, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertIn("without sudo", result.stderr)


if __name__ == "__main__":
    unittest.main()
