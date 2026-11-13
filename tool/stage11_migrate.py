#!/usr/bin/env python3
"""Non-destructive offline staging of NaNotateczki legacy native data.

This is NOT a v1-to-v2 protocol cutover. Close the application first.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import sys
from urllib.parse import quote

MANIFEST = '.stage11_manifest.json'
INCOMPLETE = '.stage11_incomplete'
MAX_SUPPORTED_SCHEMA = 8
SQLITE_FILES = ('notes.sqlite', 'notes.sqlite-wal', 'notes.sqlite-shm',
                'notes.sqlite-journal')
BASE_FILES = SQLITE_FILES + (
    'notes.sqlite.recovery_pending',
    'account_profile.json',
    'storage_layout.json',
    'app_prefs.json',
    'editor_prefs.json',
    'shared_recent_colors.json',
    'library_folders.json',
    'study_planner.json',
    'cloud_sync.json',
)
ACCOUNT_FILES = (
    'server_device',
    'server_sync_state',
    'server_backup_preferences',
    'account_settings_cursor',
    'account_preimport',
)
BASE_DIRS = ('images', 'local_backup', 'deleted_notebooks',
             'data_integrity_incidents')


class MigrationError(RuntimeError):
    pass


def digest(path: Path) -> str:
    hash_ = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            hash_.update(block)
    return hash_.hexdigest()


def _regular_file(path: Path) -> bool:
    if path.is_symlink():
        raise MigrationError(f'Symlink forbidden: {path}')
    return path.is_file()


def source_files(root: Path, suffix: str | None) -> list[Path]:
    names = list(BASE_FILES)
    names += [f'{stem}_{suffix}.json' for stem in ACCOUNT_FILES if suffix]
    names += [f'{name}.{ext}' for name in list(names)
              if name.endswith('.json') for ext in ('previous', 'tmp')]
    paths = []
    for name in names:
        entry = root / name
        if entry.exists() and not _regular_file(entry):
            raise MigrationError(f'Expected a regular file: {entry}')
        if _regular_file(entry):
            paths.append(entry)
    for folder in BASE_DIRS:
        directory = root / folder
        if directory.is_symlink():
            raise MigrationError(f'Symlink forbidden: {directory}')
        if not directory.exists():
            continue
        if not directory.is_dir():
            raise MigrationError(f'Expected a directory: {directory}')
        for base, dirs, files in os.walk(directory, followlinks=False):
            for name in dirs:
                if (Path(base) / name).is_symlink():
                    raise MigrationError('Symlink in asset directory')
            for name in files:
                path = Path(base) / name
                if not _regular_file(path):
                    raise MigrationError(f'Non-file asset: {path}')
                paths.append(path)
    return sorted(paths)


def _profile_identity(root: Path, account_id: str | None) -> tuple[str, str | None]:
    profile = root / 'account_profile.json'
    bound = None
    if profile.exists() and not _regular_file(profile):
        raise MigrationError('Invalid account profile entry')
    if _regular_file(profile):
        try:
            data = json.loads(profile.read_text(encoding='utf-8'))
            if not isinstance(data, dict) or data.get('version') != 1:
                raise ValueError('Unsupported profile version')
            bound = data.get('boundUserId')
            if bound is not None and (not isinstance(bound, str) or
                                      not bound.strip() or bound != bound.strip() or
                                      len(bound) > 512):
                raise ValueError('Invalid boundUserId')
        except (ValueError, UnicodeError) as exc:
            raise MigrationError(f'Invalid account profile: {exc}') from exc
    if account_id is not None and account_id != bound:
        raise MigrationError('Account identity does not match legacy binding. '
                             'Local-to-account import is a separate operation.')
    if bound:
        key = hashlib.sha256(bound.encode('utf-8')).hexdigest()
        return f'accounts/{key[:40]}', key[:16]
    return 'local', None


def _inspect_database(path: Path) -> tuple[int, dict[str, int]]:
    try:
        uri = 'file:' + quote(str(path.resolve()), safe='/') + '?mode=ro'
        db = sqlite3.connect(uri, uri=True)
        try:
            if db.execute('PRAGMA quick_check').fetchone() != ('ok',):
                raise MigrationError('SQLite quick_check failed')
            if db.execute('PRAGMA foreign_key_check').fetchall():
                raise MigrationError('SQLite foreign_key_check failed')
            version = int(db.execute('PRAGMA user_version').fetchone()[0])
            if not 1 <= version <= MAX_SUPPORTED_SCHEMA:
                raise MigrationError(f'Unknown legacy SQLite schema: {version}')
            existing = {row[0] for row in db.execute(
                "SELECT name FROM sqlite_master WHERE type='table'")}
            required = {'notebook_rows', 'page_rows', 'image_block_rows'}
            if not required.issubset(existing):
                raise MigrationError('Missing required document tables')
            counts = {}
            for table in sorted(existing):
                if table.startswith('sqlite_'):
                    continue
                escaped = table.replace('"', '""')
                counts[table] = db.execute(
                    f'SELECT COUNT(*) FROM "{escaped}"'
                ).fetchone()[0]
            return version, counts
        finally:
            db.close()
    except sqlite3.DatabaseError as exc:
        raise MigrationError(f'Cannot read SQLite: {exc}') from exc


def _rewrite_and_check_images(database: Path, old_images: Path,
                              new_images: Path, staged_images: Path) -> None:
    db = sqlite3.connect(str(database))
    try:
        db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
        db.execute('PRAGMA journal_mode=DELETE')
        rows = db.execute('SELECT uid, path, bytes FROM image_block_rows').fetchall()
        with db:
            for uid, raw_path, bytes_ in rows:
                path = raw_path or ''
                if not path and bytes_ is not None:
                    continue
                if not path:
                    raise MigrationError(f'Image without path or bytes: {uid}')
                old_prefix = str(old_images.resolve()) + os.sep
                if path.startswith(old_prefix):
                    relative = path[len(old_prefix):]
                    parts = Path(relative).parts
                    if not parts or any(part in ('', '.', '..') for part in parts):
                        raise MigrationError(f'Unsafe image path: {uid}')
                    destination = new_images / relative
                    if not (staged_images / relative).is_file() and bytes_ is None:
                        raise MigrationError(f'Missing image asset: {uid}')
                    db.execute('UPDATE image_block_rows SET path=? WHERE uid=?',
                               (str(destination), uid))
                else:
                    raise MigrationError(f'External image path requires manual '
                                         f'import: {uid}')
    finally:
        db.close()


def _copy_verified(source: Path, target: Path, expected: str) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    with source.open('rb') as inp, target.open('xb') as out:
        shutil.copyfileobj(inp, out, 1024 * 1024)
        out.flush()
        os.fsync(out.fileno())
    if digest(target) != expected:
        raise MigrationError(f'Copy checksum mismatch: {source}')


def _verify_existing(target: Path, namespace: str) -> dict:
    marker = target / MANIFEST
    if not _regular_file(marker):
        raise MigrationError('Existing namespace has no verified migration marker')
    try:
        manifest = json.loads(marker.read_text(encoding='utf-8'))
        if (manifest.get('version') != 1 or
                manifest.get('namespace') != namespace or
                manifest.get('status') != 'staged-not-activated'):
            raise MigrationError('Namespace marker mismatch')
        target_files = manifest['targetFiles']
        if not isinstance(target_files, dict):
            raise MigrationError('Invalid target file inventory')
        actual = {str(file.relative_to(target)) for file in target.rglob('*')
                  if file.is_file() or file.is_symlink()}
        actual.discard(MANIFEST)
        if actual != set(target_files):
            raise MigrationError('Staged file inventory changed')
        for relative, sha in target_files.items():
            parts = Path(relative).parts
            if Path(relative).is_absolute() or '..' in parts:
                raise MigrationError('Unsafe path in migration manifest')
            entry = target / relative
            if not _regular_file(entry) or digest(entry) != sha:
                raise MigrationError(f'Migrated file changed: {relative}')
        version, counts = _inspect_database(target / 'notes.sqlite')
        recorded = manifest['rowCounts']
        if (version != manifest['schemaVersion'] or
                not isinstance(recorded, dict) or
                any(counts.get(name) != count for name, count in
                    recorded.items())):
            raise MigrationError('Migrated database metadata changed')
        return manifest
    except (ValueError, KeyError, TypeError, UnicodeError) as exc:
        raise MigrationError(f'Invalid migration manifest: {exc}') from exc


def _verify_source_unchanged(root: Path, suffix: str | None,
                             manifest: dict) -> None:
    """Reject an old verified copy if the live legacy database has advanced."""
    original = manifest.get('sourceFiles')
    if not isinstance(original, dict):
        raise MigrationError('Migration manifest lacks source checksums')
    files = source_files(root, suffix)
    current = {str(file.relative_to(root)): digest(file) for file in files}
    if current != original:
        raise MigrationError(
            'Legacy source changed after staging; the candidate is stale. '
            'Preserve both copies and repeat migration after a safe review.'
        )


def stage_migration(data: Path, account_id: str | None = None) -> dict:
    """Prepare a verified candidate; never mutate or delete the legacy source."""
    if data.is_symlink():
        raise MigrationError('Invalid symlinked data directory')
    data = data.resolve(strict=True)
    if not data.is_dir():
        raise MigrationError('Invalid app data directory')
    namespace, suffix = _profile_identity(data, account_id)
    target = data / namespace
    if target.is_symlink() or target.parent.is_symlink():
        raise MigrationError('Symlinked namespace is forbidden')
    if target.exists():
        verified = _verify_existing(target, namespace)
        _verify_source_unchanged(data, suffix, verified)
        return verified
    database = data / 'notes.sqlite'
    if not _regular_file(database):
        raise MigrationError('Legacy notes.sqlite not found')
    version, counts = _inspect_database(database)
    files = source_files(data, suffix)
    original = {str(path.relative_to(data)): digest(path) for path in files}
    # Preserve the original SQLite bytes in addition to the rewritten copy.
    needed = sum(path.stat().st_size for path in files)
    needed += sum(path.stat().st_size for path in files
                  if path.name in SQLITE_FILES)
    if shutil.disk_usage(data).free < int(needed * 1.2) + 1024 * 1024:
        raise MigrationError('Insufficient free space to stage a verified copy')
    staging = target.with_name(target.name + '.stage11-incomplete')
    if staging.is_symlink():
        raise MigrationError('Staging path is a symlink')
    if staging.exists():
        incomplete = staging / INCOMPLETE
        if (not _regular_file(incomplete) or
                incomplete.read_bytes() != b'stage11\n'):
            raise MigrationError('Unrecognized staging directory; refuse deletion')
        shutil.rmtree(staging)
    target.parent.mkdir(parents=True, exist_ok=True)
    staging.mkdir(parents=False)
    (staging / INCOMPLETE).write_text('stage11\n', encoding='ascii')
    try:
        for path in files:
            rel = path.relative_to(data)
            _copy_verified(path, staging / rel, original[str(rel)])
            if path.name in SQLITE_FILES:
                _copy_verified(path, staging / 'legacy_sqlite' / path.name,
                               original[str(rel)])
        if source_files(data, suffix) != files or any(
            digest(data / rel) != sha for rel, sha in original.items()
        ):
            raise MigrationError('Legacy source changed during migration')
        _rewrite_and_check_images(staging / 'notes.sqlite', data / 'images',
                                  target / 'images', staging / 'images')
        staged_version, staged_counts = _inspect_database(staging / 'notes.sqlite')
        if staged_version != version or staged_counts != counts:
            raise MigrationError('Document/object counts changed during migration')
        if (source_files(data, suffix) != files or
                any(digest(data / rel) != sha
                    for rel, sha in original.items())):
            raise MigrationError('Legacy source changed during validation')
        targets = {str(path.relative_to(staging)): digest(path)
                   for path in staging.rglob('*')
                   if path.is_file() and path.name != INCOMPLETE}
        manifest = {'version': 1, 'status': 'staged-not-activated',
                    'namespace': namespace, 'schemaVersion': version,
                    'rowCounts': counts, 'sourceFiles': original,
                    'targetFiles': targets}
        marker = staging / MANIFEST
        marker.write_text(json.dumps(manifest, sort_keys=True, indent=2) + '\n',
                          encoding='utf-8')
        with marker.open('rb') as stream:
            os.fsync(stream.fileno())
        (staging / INCOMPLETE).unlink()
        if (source_files(data, suffix) != files or
                any(digest(data / rel) != sha
                    for rel, sha in original.items())):
            raise MigrationError('Legacy source changed before publication')
        staging.rename(target)
        return _verify_existing(target, namespace)
    except BaseException:
        if staging.exists():
            shutil.rmtree(staging)
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data', required=True, type=Path,
                        help='Path to existing Application Support/data directory')
    parser.add_argument('--account-id', help='Expected existing bound account UUID')
    args = parser.parse_args()
    try:
        result = stage_migration(args.data, args.account_id)
    except (MigrationError, OSError) as exc:
        print(f'Migration refused: {exc}', file=sys.stderr)
        return 1
    print(json.dumps({'namespace': result['namespace'], 'status': result['status'],
                      'schemaVersion': result['schemaVersion'],
                      'rowCounts': result['rowCounts']}, indent=2))
    print('Not activated. Do not remove legacy data or enable v2 writers.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
