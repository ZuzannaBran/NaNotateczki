#!/usr/bin/env python3
"""Verify or refresh NaNotateczki's mirror of the canonical server."""

import argparse
import filecmp
import shutil
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MIRROR = ROOT / "server"
APP_ONLY = {Path("api/tests/test_dart_python_operation_contract.py")}
SHARED = (
    ".env.example",
    ".gitignore",
    "Caddyfile",
    "README.md",
    "REPORTING.md",
    "SECURITY_DEPLOY.md",
    "SERVER.md",
    "TESTING.md",
    "docs/OPERATION_PROTOCOL_V1.md",
    "compose.yaml",
    "compose.local.yaml",
    "compose.stage12.yaml",
    "compose.public.yaml",
    "postgres-init/01-create-app-role.sh",
    "scripts/apply-migrations.sh",
    "scripts/backup-server.sh",
    "scripts/smoke-local-api.py",
    "scripts/run-stage12-real.sh",
    "scripts/stage13-activate-empty-canary.sh",
    "scripts/stage13-verify-restore.sh",
    "scripts/stage13_backup_check.py",
    "scripts/tests/test_stage13_backup_check.py",
    "scripts/tests/test_stage13_canary_activation.py",
    "scripts/tests/test_stage12_runner_guard.py",
)


def managed_files(root: Path) -> set[Path]:
    paths: set[Path] = set()
    for subdir in ("api", "migrations"):
        directory = root / subdir
        if directory.exists():
            paths.update(
                path.relative_to(root)
                for path in directory.rglob("*")
                if path.is_file()
                and not {"__pycache__", ".pytest_cache"}.intersection(path.parts)
                and path.suffix not in {".pyc", ".pyo"}
            )
    paths.update(
        Path(relative)
        for relative in SHARED
        if (root / relative).is_file()
    )
    return paths


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("canonical_checkout", type=Path)
    parser.add_argument(
        "--sync",
        action="store_true",
        help="Copy managed files from the canonical server checkout",
    )
    args = parser.parse_args()
    canonical = args.canonical_checkout.expanduser().resolve()
    if not (canonical / "api/app/main.py").is_file():
        parser.error("Pass the root of the NaNotateczki-serwer checkout")

    source_paths = managed_files(canonical)
    mirror_paths = managed_files(MIRROR)
    missing = []
    different = []
    for relative in sorted(source_paths):
        source = canonical / relative
        destination = MIRROR / relative
        if not destination.is_file():
            missing.append(str(relative))
        elif not filecmp.cmp(source, destination, shallow=False):
            different.append(str(relative))
        if args.sync and (str(relative) in missing or str(relative) in different):
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)

    # App-only pytest.ini and deployment notes intentionally remain outside
    # the managed source directories. Never delete files automatically.
    extras = sorted(str(path) for path in mirror_paths - source_paths - APP_ONLY)
    if missing or different or extras:
        print("Missing:", ", ".join(missing) or "none")
        print("Different:", ", ".join(different) or "none")
        print("Extra managed paths:", ", ".join(extras) or "none")
        if not args.sync or extras:
            return 1
    print("Backend mirror matches canonical source.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
