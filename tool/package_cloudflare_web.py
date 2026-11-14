"""Validate the complete web build and create a ZIP for Cloudflare upload."""

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import shutil
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "build/web"
BUILD = ROOT / "build/cloudflare-worker"


def include_runtime_asset(relative, builds):
    name = relative.name
    if name == "drift_worker.dart" or name.endswith((".symbols", ".js.map", ".js.deps")):
        return False
    renderers = {build.get("renderer") for build in builds} - {None}
    if renderers == {"canvaskit"} and relative.parts[0] == "canvaskit":
        return not name.startswith(("skwasm", "wimp"))
    return name != "nanotateczki-release.json"


def validate_asset_limits(files):
    # Keep the artifact compatible with the dashboard's smaller upload limit.
    if len(files) > 1000:
        raise ValueError("Dashboard upload exceeds 1,000 files; use Wrangler")
    for path in files:
        if path.stat().st_size > 25 * 1024 * 1024:
            raise ValueError(f"Asset exceeds Cloudflare's 25 MiB limit: {path}")


def prepare_runtime_directory():
    bootstrap = (SOURCE / "flutter_bootstrap.js").read_text()
    match = re.search(r"_flutter\.buildConfig\s*=\s*(\{.*?\});", bootstrap, re.S)
    if match is None:
        raise ValueError("Missing generated Flutter build configuration")
    builds = json.loads(match.group(1))["builds"]
    selected = {
        path.relative_to(SOURCE)
        for path in SOURCE.rglob("*")
        if path.is_file() and include_runtime_asset(path.relative_to(SOURCE), builds)
    }
    BUILD.mkdir(parents=True, exist_ok=True)
    for existing in BUILD.rglob("*"):
        if existing.is_file() and existing.relative_to(BUILD) not in selected:
            existing.unlink()
    for relative in selected:
        target = BUILD / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(SOURCE / relative, target)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_vendor(directory, checksums, flat=False):
    for name, expected in checksums.items():
        path = directory / "files" / Path(name).name if flat else directory / name
        if digest(path) != expected:
            raise ValueError(f"Incomplete or changed runtime asset: {path}")


def flatten_font_paths(directory, checksums):
    target = directory / "files"
    target.mkdir(exist_ok=True)
    for name, expected in checksums.items():
        source = directory / name
        destination = target / Path(name).name
        if destination.exists() and digest(destination) != expected:
            raise ValueError(f"Colliding fallback font names: {name}")
        source.replace(destination)
    for child in sorted(directory.rglob("*"), key=lambda path: len(path.parts), reverse=True):
        if child.is_dir() and not any(child.iterdir()):
            child.rmdir()


def verify_ui_fonts(directory):
    font_manifest = json.loads((directory / "FontManifest.json").read_text())
    families = {family["family"] for family in font_manifest if family["fonts"]}
    for required in ("MaterialIcons", "Gelasio"):
        if required not in families:
            raise ValueError(f"Missing UI font family: {required}")
    for family in font_manifest:
        for font in family["fonts"]:
            asset = directory / font["asset"]
            if not asset.is_file() or asset.stat().st_size == 0:
                raise ValueError(f"Missing UI font: {font['asset']}")


def main():
    prepare_runtime_directory()
    index = (BUILD / "index.html").read_text()
    bootstrap = (BUILD / "flutter_bootstrap.js").read_text()
    if "cdn.jsdelivr.net" in index or "$FLUTTER_BASE_HREF" in index:
        raise ValueError("index.html is not the current compiled application")
    for setting in ("canvasKitBaseUrl:", "fontFallbackBaseUrl:"):
        if setting not in bootstrap:
            raise ValueError(f"Missing local runtime setting: {setting}")
    if "/share/* / 200" not in (BUILD / "_redirects").read_text():
        raise ValueError("The upload does not include share routing")
    for name in ("_headers", "main.dart.js", "drift_worker.dart.js", "sqlite3.wasm"):
        if (BUILD / name).stat().st_size == 0:
            raise ValueError(f"Empty runtime file: {name}")
    for variant in ("", "chromium/", "webparagraph/"):
        for extension in ("js", "wasm"):
            path = BUILD / f"canvaskit/{variant}canvaskit.{extension}"
            if path.stat().st_size == 0:
                raise ValueError(f"Missing CanvasKit variant: {path}")
    pdf = BUILD / "vendor/pdfjs/4.6.82"
    verify_vendor(pdf, json.loads((pdf / "SHA256SUMS.json").read_text()))
    fonts = BUILD / "vendor/flutter-fonts"
    manifest = json.loads((fonts / "manifest.json").read_text())
    if manifest["engine_revision"] not in bootstrap:
        raise ValueError("Fallback font table does not match the built Flutter engine")
    flatten_font_paths(fonts, manifest["files"])
    verify_vendor(fonts, manifest["files"], flat=True)
    with (BUILD / "_redirects").open("a") as stream:
        stream.write(
            "/vendor/flutter-fonts/:family/:version/:font "
            "/vendor/flutter-fonts/files/:font 200\n"
        )
    verify_ui_fonts(BUILD / "assets")
    hashes = {
        str(path.relative_to(BUILD)): digest(path)
        for path in sorted(BUILD.rglob("*"))
        if path.is_file() and path.name != "nanotateczki-release.json"
    }
    release_id = hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()[:16]
    release = {
        "release_id": release_id,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "flutter_version": manifest["flutter_version"],
        "fallback_fonts": len(manifest["files"]),
        "sha256": hashes,
    }
    (BUILD / "nanotateczki-release.json").write_text(json.dumps(release, indent=2) + "\n")
    destination = ROOT / f"build/nanotateczki-cloudflare-{release_id}.zip"
    files = sorted(path for path in BUILD.rglob("*") if path.is_file())
    validate_asset_limits(files)
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in files:
            archive.write(path, path.relative_to(BUILD))
    print(f"Release: {release_id}; files: {len(files)}")
    size = sum(path.stat().st_size for path in files)
    largest = max(path.stat().st_size for path in files)
    print(f"Assets: {size / 1024 / 1024:.1f} MiB; largest: {largest / 1024 / 1024:.2f} MiB")
    print(f"Upload directory: {BUILD}")
    print(f"Upload ZIP: {destination} ({destination.stat().st_size / 1024 / 1024:.1f} MiB)")


if __name__ == "__main__":
    main()
