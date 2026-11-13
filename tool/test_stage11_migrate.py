import hashlib
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

from stage11_migrate import MigrationError, digest, stage_migration


class Stage11MigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.data = Path(self.temp.name) / 'data'
        self.data.mkdir()
        (self.data / 'images').mkdir()
        (self.data / 'images' / 'a.png').write_bytes(b'image-content')
        with sqlite3.connect(self.data / 'notes.sqlite') as db:
            db.executescript('''
                PRAGMA user_version = 5;
                CREATE TABLE notebook_rows (uid TEXT PRIMARY KEY);
                CREATE TABLE page_rows (uid TEXT PRIMARY KEY, notebook_uid TEXT);
                CREATE TABLE image_block_rows (uid TEXT PRIMARY KEY,
                    page_uid TEXT, path TEXT, bytes BLOB);
                CREATE TABLE operation_outbox (operation_id TEXT PRIMARY KEY);
                CREATE TABLE object_tombstones (id TEXT);
                INSERT INTO notebook_rows VALUES ('doc');
                INSERT INTO page_rows VALUES ('page', 'doc');
                INSERT INTO operation_outbox VALUES ('offline-1');
                INSERT INTO object_tombstones VALUES ('deleted-object');
            ''')
            db.execute('INSERT INTO image_block_rows VALUES (?, ?, ?, ?)',
                       ('img', 'page', str(self.data / 'images' / 'a.png'), None))
        (self.data / 'study_planner.json').write_text('{"sessions":[]}', encoding='utf8')

    def test_sqlite_v6_is_recognized_without_touching_source(self):
        with sqlite3.connect(self.data / 'notes.sqlite') as db:
            db.execute('PRAGMA user_version = 6')
        before = digest(self.data / 'notes.sqlite')
        report = stage_migration(self.data)
        self.assertEqual(report['rowCounts']['object_tombstones'], 1)
        self.assertEqual(digest(self.data / 'notes.sqlite'), before)
        with sqlite3.connect(self.data / 'local' / 'notes.sqlite') as db:
            self.assertEqual(db.execute(
                'PRAGMA user_version'
            ).fetchone()[0], 6)

    def test_recent_schemas_preserve_journal_tables_and_source(self):
        for version, table in ((7, 'operation_asset_bytes'),
                               (8, 'editor_history')):
            with self.subTest(version=version):
                data = Path(self.temp.name) / str(version)
                data.mkdir()
                database = data / 'notes.sqlite'
                with sqlite3.connect(database) as db:
                    db.executescript(f'''
                        PRAGMA user_version = {version};
                        CREATE TABLE notebook_rows (uid TEXT PRIMARY KEY);
                        CREATE TABLE page_rows (uid TEXT PRIMARY KEY);
                        CREATE TABLE image_block_rows (uid TEXT PRIMARY KEY,
                            path TEXT, bytes BLOB);
                        CREATE TABLE {table} (value BLOB NOT NULL);
                        INSERT INTO {table} VALUES (x'1aff');
                    ''')
                checksum = digest(database)
                report = stage_migration(data)
                self.assertEqual(report['status'], 'staged-not-activated')
                self.assertEqual(report['schemaVersion'], version)
                self.assertEqual(report['rowCounts'][table], 1)
                self.assertEqual(digest(database), checksum)
                self.assertEqual(report, stage_migration(data))
                with sqlite3.connect(data / 'local' / 'notes.sqlite') as db:
                    self.assertEqual(db.execute(
                        f'SELECT value FROM {table}'
                    ).fetchone(), (b'\x1a\xff',))

    def test_local_migration_preserves_source_and_outbox(self):
        before = digest(self.data / 'notes.sqlite')
        report = stage_migration(self.data)
        self.assertEqual(report['namespace'], 'local')
        self.assertEqual(report['rowCounts']['operation_outbox'], 1)
        self.assertEqual(report['rowCounts']['object_tombstones'], 1)
        self.assertEqual(before, digest(self.data / 'notes.sqlite'))
        with sqlite3.connect(self.data / 'local' / 'notes.sqlite') as db:
            image = db.execute('SELECT path FROM image_block_rows').fetchone()[0]
        self.assertEqual(image, str(self.data / 'local' / 'images' / 'a.png'))
        self.assertEqual(report, stage_migration(self.data))

    def test_bound_identity_cannot_be_copied_to_another_account(self):
        (self.data / 'account_profile.json').write_text(json.dumps({
            'version': 1, 'boundUserId': 'account-a'}), encoding='utf8')
        with self.assertRaises(MigrationError):
            stage_migration(self.data, 'account-b')
        self.assertFalse((self.data / 'local').exists())
        result = stage_migration(self.data, 'account-a')
        self.assertTrue(result['namespace'].startswith('accounts/'))
        self.assertFalse((self.data / 'local').exists())

    def test_bound_namespace_stages_and_reuses_verified_copy(self):
        (self.data / 'account_profile.json').write_text(json.dumps({
            'version': 1, 'boundUserId': 'account-a'}), encoding='utf8')
        suffix = hashlib.sha256(b'account-a').hexdigest()[:16]
        account_settings = self.data / f'account_settings_cursor_{suffix}.json'
        account_settings.write_text('{"version":1}', encoding='utf8')
        report = stage_migration(self.data, 'account-a')
        target = self.data / report['namespace']
        self.assertTrue(target.is_dir())
        self.assertEqual(digest(account_settings),
                         digest(target / account_settings.name))
        self.assertEqual(report, stage_migration(self.data, 'account-a'))
        self.assertEqual(digest(self.data / 'notes.sqlite'),
                         digest(target / 'legacy_sqlite' / 'notes.sqlite'))

    def test_modified_profile_invalidates_staging(self):
        profile = self.data / 'account_profile.json'
        profile.write_text(json.dumps({'version': 1,
                                       'boundUserId': 'account-a'}))
        stage_migration(self.data, 'account-a')
        profile.write_text(json.dumps({'version': 1,
                                       'boundUserId': 'account-a',
                                       'onboardingComplete': True}))
        with self.assertRaisesRegex(MigrationError, 'source changed'):
            stage_migration(self.data, 'account-a')

    def test_adding_legacy_file_invalidates_staging(self):
        stage_migration(self.data)
        (self.data / 'storage_layout.json').write_text('{}')
        with self.assertRaisesRegex(MigrationError, 'source changed'):
            stage_migration(self.data)

    def test_staged_extra_file_invalidates_manifest(self):
        report = stage_migration(self.data)
        target = self.data / report['namespace']
        (target / 'unexpected').write_text('unsafe')
        with self.assertRaisesRegex(MigrationError, 'inventory changed'):
            stage_migration(self.data)

    def test_bound_account_with_whitespace_is_refused(self):
        (self.data / 'account_profile.json').write_text(json.dumps({
            'version': 1, 'boundUserId': ' account-a '}))
        with self.assertRaises(MigrationError):
            stage_migration(self.data)
        self.assertFalse((self.data / 'accounts').exists())

    def test_corrupted_partial_staging_marker_does_not_delete_files(self):
        partial = self.data / 'local.stage11-incomplete'
        partial.mkdir()
        (partial / '.stage11_incomplete').write_bytes(bytes([255]) + b'invalid')
        (partial / 'private').write_text('keep')
        with self.assertRaises(MigrationError):
            stage_migration(self.data)
        self.assertEqual((partial / 'private').read_text(), 'keep')

    def test_directory_in_place_of_profile_is_refused(self):
        (self.data / 'account_profile.json').mkdir()
        with self.assertRaises(MigrationError):
            stage_migration(self.data)
        self.assertFalse((self.data / 'local').exists())

    def test_missing_asset_aborts_without_committing(self):
        (self.data / 'images' / 'a.png').unlink()
        with self.assertRaises(MigrationError):
            stage_migration(self.data)
        self.assertFalse((self.data / 'local').exists())
        self.assertTrue((self.data / 'notes.sqlite').exists())

    def test_partial_staging_is_retried_without_touching_source(self):
        partial = self.data / 'local.stage11-incomplete'
        partial.mkdir()
        (partial / '.stage11_incomplete').write_text('stage11\n')
        (partial / 'bad').write_bytes(b'incomplete')
        stage_migration(self.data)
        self.assertFalse(partial.exists())
        self.assertTrue((self.data / 'local' / 'notes.sqlite').exists())

    def test_unrecognized_staging_is_never_deleted(self):
        partial = self.data / 'local.stage11-incomplete'
        partial.mkdir()
        (partial / 'private').write_text('keep')
        with self.assertRaises(MigrationError):
            stage_migration(self.data)
        self.assertTrue((partial / 'private').exists())

    def test_existing_namespace_tampering_is_refused(self):
        stage_migration(self.data)
        (self.data / 'local' / 'study_planner.json').write_text('changed')
        with self.assertRaises(MigrationError):
            stage_migration(self.data)

    def test_symlinked_target_is_never_accepted(self):
        (self.data / 'local').symlink_to(self.data / 'images')
        with self.assertRaises(MigrationError):
            stage_migration(self.data)

    def test_migration_refuses_to_reuse_stale_source(self):
        stage_migration(self.data)
        (self.data / 'study_planner.json').write_text('{"sessions":[1]}')
        with self.assertRaisesRegex(MigrationError, 'source changed'):
            stage_migration(self.data)

    def test_recovery_sidecar_is_preserved(self):
        original = self.data / 'study_planner.json.previous'
        original.write_text('{"sessions":["recovered"]}')
        report = stage_migration(self.data)
        copy = self.data / 'local' / 'study_planner.json.previous'
        self.assertEqual(digest(original), digest(copy))
        self.assertIn('study_planner.json.previous', report['targetFiles'])

    def test_image_path_traversal_is_rejected(self):
        with sqlite3.connect(self.data / 'notes.sqlite') as db:
            db.execute('UPDATE image_block_rows SET path=?',
                       (str(self.data / 'images' / '..' / 'notes.sqlite'),))
        with self.assertRaisesRegex(MigrationError, 'Unsafe image path'):
            stage_migration(self.data)
        self.assertTrue((self.data / 'notes.sqlite').exists())
        self.assertFalse((self.data / 'local').exists())

    def test_external_image_path_with_inline_bytes_still_refused(self):
        with sqlite3.connect(self.data / 'notes.sqlite') as db:
            db.execute('UPDATE image_block_rows SET path=?, bytes=?',
                       ('/private/elsewhere/image.png', b'inline'))
        with self.assertRaisesRegex(MigrationError, 'External image path'):
            stage_migration(self.data)

    def test_symlinked_assets_are_refused(self):
        (self.data / 'images' / 'link').symlink_to(self.data / 'notes.sqlite')
        with self.assertRaises(MigrationError):
            stage_migration(self.data)


if __name__ == '__main__':
    unittest.main()
