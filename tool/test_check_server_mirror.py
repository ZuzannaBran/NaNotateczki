"""Exercise mirror drift checks without reading or writing a real checkout."""
import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "server_mirror", Path(__file__).with_name("check_server_mirror.py")
)
MIRROR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MIRROR)


class ServerMirrorTest(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.source = Path(self.work.name) / "canonical"
        self.mirror = Path(self.work.name) / "mirror"
        for root in (self.source, self.mirror):
            self.write(root, "api/app/main.py", "# same backend\n")

    def write(self, root, relative, value):
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value)

    def run_check(self, *options):
        with (
            patch.object(MIRROR, "MIRROR", self.mirror),
            patch("sys.argv", ["check_server_mirror", str(self.source), *options]),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            return MIRROR.main()

    def test_caches_and_known_app_contract_do_not_mask_unknown_source(self):
        self.write(self.source, "api/.pytest_cache/v/cache/nodeids", "cache")
        self.write(self.mirror, "api/__pycache__/main.pyc", "cache")
        app_contract = "api/tests/test_dart_python_operation_contract.py"
        self.write(self.mirror, app_contract, "# app-specific contract\n")
        self.assertEqual(self.run_check(), 0)
        self.write(self.mirror, "api/app/unexpected.py", "# unknown extra\n")
        self.assertEqual(self.run_check(), 1)
        self.assertEqual(self.run_check("--sync"), 1)
        self.assertTrue((self.mirror / app_contract).is_file())
        self.assertTrue((self.mirror / "api/app/unexpected.py").is_file())

    def test_missing_real_stack_compose_is_detected_and_synced(self):
        self.write(self.source, "compose.stage12.yaml", "services: {}\n")
        self.assertEqual(self.run_check(), 1)
        self.assertEqual(self.run_check("--sync"), 0)
        self.assertEqual(
            (self.mirror / "compose.stage12.yaml").read_text(), "services: {}\n"
        )
        self.assertEqual(self.run_check(), 0)

    def test_stale_backend_is_reported_and_replaced_from_canonical(self):
        path = "api/app/operation_projection.py"
        self.write(self.source, path, "# canonical\n")
        self.write(self.mirror, path, "# older projection\n")
        self.assertEqual(self.run_check(), 1)
        self.assertEqual(self.run_check("--sync"), 0)
        self.assertEqual((self.mirror / path).read_text(), "# canonical\n")
        self.assertEqual(self.run_check(), 0)


if __name__ == "__main__":
    unittest.main()
