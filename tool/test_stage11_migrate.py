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

    def test_symlinked_assets_are_refused(self):
        (self.data / 'images' / 'link').symlink_to(self.data / 'notes.sqlite')
        with self.assertRaises(MigrationError):
            stage_migration(self.data)


if __name__ == '__main__':
    unittest.main()
