"""Mirror the exact fallback fonts referenced by the installed Flutter engine."""

import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import re
import shutil
import time
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
DESTINATION = ROOT / "web/vendor/flutter-fonts"
FONT_BASE = "https://fonts.gstatic.com/s/"
LICENSES = {
    "LICENSE-Noto.txt":
        "https://raw.githubusercontent.com/googlefonts/noto-fonts/main/LICENSE",
    "LICENSE-Emoji.txt":
        "https://raw.githubusercontent.com/googlefonts/noto-emoji/main/LICENSE",
    "LICENSE-Roboto.txt":
        "https://raw.githubusercontent.com/googlefonts/roboto/main/LICENSE",
}


def download(url):
    for attempt in range(3):
        try:
            with urllib.request.urlopen(url, timeout=30) as response:
                return response.read()
        except OSError:
            if attempt == 2:
                raise
            time.sleep(attempt + 1)


def mirror_font(relative):
    target = DESTINATION / relative
    data = target.read_bytes() if target.exists() else download(FONT_BASE + relative)
    if data[:4] != b"wOF2":
        raise ValueError(f"Invalid WOFF2 font: {relative}")
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.exists():
        temporary = target.with_suffix(".tmp")
        temporary.write_bytes(data)
        temporary.replace(target)
    return relative, hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--flutter-sdk", type=Path)
    args = parser.parse_args()
    executable = shutil.which("flutter")
    if args.flutter_sdk is None and executable is None:
        parser.error("Flutter is not on PATH; pass --flutter-sdk")
    sdk = args.flutter_sdk or Path(executable).resolve().parents[1]
    engine = sdk / "bin/cache/flutter_web_sdk/lib/_engine/engine"
    source = (engine / "font_fallback_data.dart").read_bytes()
    pattern = r"([a-z0-9]+/v[0-9]+/[A-Za-z0-9_.-]+\.woff2)"
    paths = set(re.findall(pattern, source.decode()))
    paths.update(re.findall(pattern, (engine / "canvaskit/fonts.dart").read_text()))
    if len(paths) < 100:
        raise ValueError("Unexpected Flutter font table; refusing an incomplete mirror")
    version = json.loads((sdk / "bin/cache/flutter.version.json").read_text())
    DESTINATION.mkdir(parents=True, exist_ok=True)
    files = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=12) as executor:
        futures = [executor.submit(mirror_font, path) for path in sorted(paths)]
        for future in concurrent.futures.as_completed(futures):
            relative, checksum = future.result()
            files[relative] = checksum
            if len(files) % 100 == 0:
                print(f"Fonts ready: {len(files)}/{len(paths)}", flush=True)
    for filename, url in LICENSES.items():
        target = DESTINATION / filename
        if not target.exists():
            target.write_bytes(download(url))
    manifest = {
        "flutter_version": version["frameworkVersion"],
        "engine_revision": version["engineRevision"],
        "font_table_sha256": hashlib.sha256(source).hexdigest(),
        "source": FONT_BASE,
        "files": dict(sorted(files.items())),
    }
    (DESTINATION / "manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )
    size = sum((DESTINATION / name).stat().st_size for name in files)
    print(f"Bundled {len(files)} fonts ({size / 1024 / 1024:.1f} MiB)")


if __name__ == "__main__":
    main()
