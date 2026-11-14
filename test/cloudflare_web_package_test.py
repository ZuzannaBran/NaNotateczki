import importlib.util
import hashlib
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "package_cloudflare_web", ROOT / "tool/package_cloudflare_web.py"
)
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class CloudflareWebPackageTest(unittest.TestCase):
    def test_ui_fonts_require_icons_and_bundled_serif_with_nonempty_assets(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = []
            for family in ("MaterialIcons", "Gelasio"):
                (root / f"{family}.ttf").write_bytes(b"font")
                manifest.append({"family": family, "fonts": [
                    {"asset": f"{family}.ttf"}
                ]})
            path = root / "FontManifest.json"
            path.write_text(json.dumps(manifest))
            package.verify_ui_fonts(root)
            for omitted in ("MaterialIcons", "Gelasio"):
                path.write_text(json.dumps([
                    item for item in manifest if item["family"] != omitted
                ]))
                with self.assertRaisesRegex(ValueError, omitted):
                    package.verify_ui_fonts(root)
            path.write_text(json.dumps(manifest))
            (root / "MaterialIcons.ttf").write_bytes(b"")
            with self.assertRaisesRegex(ValueError, "Missing UI font"):
                package.verify_ui_fonts(root)

    def test_font_flattening_keeps_every_font_byte_and_removes_empty_folders(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            files = {}
            for name in ["noto/v1/first.woff2", "emoji/v2/second.woff2"]:
                path = root / name
                path.parent.mkdir(parents=True)
                path.write_bytes(name.encode())
                files[name] = hashlib.sha256(path.read_bytes()).hexdigest()
            package.flatten_font_paths(root, files)
            package.verify_vendor(root, files, flat=True)
            self.assertEqual(len(list(root.rglob("*.woff2"))), 2)
            self.assertEqual([path.name for path in root.iterdir()], ["files"])

    def test_js_build_omits_only_unused_renderer_and_diagnostics(self):
        builds = [{"renderer": "canvaskit"}, {}]
        for name in ["index.html", "main.dart.js", "canvaskit/canvaskit.wasm",
                     "canvaskit/chromium/canvaskit.wasm",
                     "vendor/flutter-fonts/example.woff2"]:
            self.assertTrue(package.include_runtime_asset(Path(name), builds))
        for name in ["canvaskit/skwasm.wasm", "canvaskit/wimp.js",
                     "canvaskit/canvaskit.js.symbols", "drift_worker.dart.js.map",
                     "drift_worker.dart.js.deps", "drift_worker.dart"]:
            self.assertFalse(package.include_runtime_asset(Path(name), builds))

    def test_wasm_build_retains_its_engine(self):
        builds = [{"renderer": "skwasm"}, {"renderer": "canvaskit"}]
        self.assertTrue(package.include_runtime_asset(Path("canvaskit/skwasm.wasm"), builds))

    def test_dashboard_file_count_is_checked_before_upload(self):
        with self.assertRaisesRegex(ValueError, "1,000"):
            package.validate_asset_limits([Path("unused")] * 1001)

    def test_size_limit_is_per_file_and_not_total_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            files = []
            for name in ["one.wasm", "two.wasm"]:
                path = Path(directory) / name
                with path.open("wb") as stream:
                    stream.truncate(13 * 1024 * 1024)
                files.append(path)
            package.validate_asset_limits(files)

    def test_oversized_asset_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "large.wasm"
            with path.open("wb") as stream:
                stream.truncate(25 * 1024 * 1024 + 1)
            with self.assertRaisesRegex(ValueError, "25 MiB"):
                package.validate_asset_limits([path])

    def test_worker_serves_flutter_as_static_assets(self):
        config = json.loads((ROOT / "wrangler.jsonc").read_text())
        self.assertNotIn("main", config)
        self.assertEqual(config["assets"]["directory"], "./build/cloudflare-worker")
        self.assertEqual(config["assets"]["not_found_handling"], "single-page-application")


if __name__ == "__main__":
    unittest.main()
