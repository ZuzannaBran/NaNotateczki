"""Validate the complete web build and create a ZIP for Cloudflare upload."""

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import zipfile


ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build/web"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_vendor(directory, checksums):
    for name, expected in checksums.items():
        path = directory / name
        if digest(path) != expected:
            raise ValueError(f"Incomplete or changed runtime asset: {path}")


def main():
    index = (BUILD / "index.html").read_text()
    bootstrap = (BUILD / "flutter_bootstrap.js").read_text()
    if "cdn.jsdelivr.net" in index or "$FLUTTER_BASE_HREF" in index:
        raise ValueError("index.html is not the current compiled application")
    for setting in ("canvasKitBaseUrl:", "fontFallbackBaseUrl:"):
        if setting not in bootstrap:
            raise ValueError(f"Missing local runtime setting: {setting}")
    if "/share/* /index.html 200" not in (BUILD / "_redirects").read_text():
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
    verify_vendor(fonts, manifest["files"])
    font_manifest = json.loads((BUILD / "assets/FontManifest.json").read_text())
    for family in font_manifest:
        for font in family["fonts"]:
            if (BUILD / "assets" / font["asset"]).stat().st_size == 0:
                raise ValueError(f"Missing UI font: {font['asset']}")
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
    for path in files:
        if path.stat().st_size > 25 * 1024 * 1024:
            raise ValueError(f"Asset exceeds Cloudflare's 25 MiB limit: {path}")
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in files:
            archive.write(path, path.relative_to(BUILD))
    print(f"Release: {release_id}; files: {len(files)}")
    print(f"Upload directory: {BUILD}")
    print(f"Upload ZIP: {destination} ({destination.stat().st_size / 1024 / 1024:.1f} MiB)")


if __name__ == "__main__":
    main()
