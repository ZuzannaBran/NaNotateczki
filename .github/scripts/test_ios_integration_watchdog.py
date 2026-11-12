#!/usr/bin/env python3
"""Exercise simulator discovery recovery with fake subprocesses, no Xcode."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

WATCHDOG = Path(__file__).with_name("ios_integration_watchdog.py")


class IOSWatchdogTests(unittest.TestCase):
    def setUp(self):
        self.sandbox = tempfile.TemporaryDirectory()
        self.addCleanup(self.sandbox.cleanup)
        self.folder = Path(self.sandbox.name)
        flutter = self.folder / "flutter"
        flutter.write_text(
            "#!/usr/bin/env python3\n"
            "import os, pathlib, sys, time\n"
            "p = pathlib.Path(os.environ['TEST_ATTEMPT_FILE'])\n"
            "n = int(p.read_text()) + 1 if p.exists() else 1\n"
            "p.write_text(str(n))\n"
            "mode = os.environ['TEST_MODE']\n"
            "print('Xcode build done. 123.4s', flush=True)\n"
            "if mode == 'stall' or (mode == 'stall_once' and n == 1):\n"
            "    time.sleep(10)\n"
            "elif mode == 'assertion':\n"
            "    print('00:00 +0: platform bootstrap expected true, got false', flush=True)\n"
            "    sys.exit(17)\n"
            "elif mode == 'compile':\n"
            "    print('Compilation failed', flush=True)\n"
            "    sys.exit(18)\n"
            "else:\n"
            "    print('00:00 +0: platform bootstrap real platform bootstrap opens the library', flush=True)\n"
            "    print('All tests passed!', flush=True)\n"
        )
        flutter.chmod(0o755)
        xcrun = self.folder / "xcrun"
        xcrun.write_text(
            "#!/usr/bin/env python3\n"
            "import os, pathlib, sys\n"
            "p = pathlib.Path(os.environ['TEST_SIMCTL_LOG'])\n"
            "with p.open('a') as f: f.write(' '.join(sys.argv[1:]) + '\\n')\n"
        )
        xcrun.chmod(0o755)
        self.env = {
            **os.environ,
            "PATH": f"{self.folder}{os.pathsep}{os.environ['PATH']}",
            "IOS_VM_DISCOVERY_TIMEOUT_SECONDS": "0.3",
            "TEST_ATTEMPT_FILE": str(self.folder / "attempts"),
            "TEST_SIMCTL_LOG": str(self.folder / "simctl"),
            "TEST_MODE": "success",
        }

    def invoke(self, *args):
        return subprocess.run(
            [sys.executable, str(WATCHDOG), *args],
            env=self.env,
            capture_output=True,
            text=True,
            timeout=12,
            check=False,
        )

    def attempts(self):
        return int((self.folder / "attempts").read_text())

    def test_invalid_device_does_not_run_flutter(self):
        self.assertEqual(self.invoke().returncode, 2)
        self.assertFalse((self.folder / "attempts").exists())

    def test_successful_suite_is_run_once(self):
        result = self.invoke("mock-udid")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.attempts(), 1)
        self.assertFalse((self.folder / "simctl").exists())

    def test_assertion_failure_is_not_retried(self):
        self.env["TEST_MODE"] = "assertion"
        result = self.invoke("mock-udid")
        self.assertEqual(result.returncode, 17)
        self.assertEqual(self.attempts(), 1)
        self.assertFalse((self.folder / "simctl").exists())

    def test_compile_failure_is_not_retried(self):
        self.env["TEST_MODE"] = "compile"
        result = self.invoke("mock-udid")
        self.assertEqual(result.returncode, 18)
        self.assertEqual(self.attempts(), 1)

    def test_vm_service_stall_restarts_simulator_once(self):
        self.env["TEST_MODE"] = "stall_once"
        result = self.invoke("mock-udid")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.attempts(), 2)
        self.assertIn("VM-service discovery stall", result.stderr)
        self.assertEqual(
            (self.folder / "simctl").read_text().splitlines(),
            [
                "simctl shutdown mock-udid",
                "simctl boot mock-udid",
                "simctl bootstatus mock-udid -b",
            ],
        )

    def test_persistent_vm_stall_fails_ci(self):
        self.env["TEST_MODE"] = "stall"
        result = self.invoke("mock-udid")
        self.assertEqual(result.returncode, 124)
        self.assertEqual(self.attempts(), 2)
        self.assertIn("stalled twice", result.stderr)


if __name__ == "__main__":
    unittest.main()
