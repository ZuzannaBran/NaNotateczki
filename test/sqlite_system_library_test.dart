import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('native SQLite supports transactions, JSON and text search', () {
    final database = sqlite3.openInMemory();
    addTearDown(database.close);

    database.execute('PRAGMA foreign_keys = ON');
    database.execute(
      'CREATE TABLE items (id INTEGER PRIMARY KEY, '
      'payload TEXT NOT NULL)',
    );
    database.execute('INSERT INTO items (payload) VALUES (?)', [
      '{"title":"persisted"}',
    ]);
    final json = database.select(
      "SELECT json_extract(payload, '\$.title') AS title FROM items",
    );
    expect(json.single['title'], 'persisted');

    database.execute('CREATE VIRTUAL TABLE search USING fts5(content)');
    database.execute('INSERT INTO search (content) VALUES (?)', [
      'offline notebook',
    ]);
    expect(
      database
          .select("SELECT content FROM search WHERE search MATCH 'offline'")
          .single['content'],
      'offline notebook',
    );

    database.execute('BEGIN IMMEDIATE');
    database.execute('INSERT INTO items (payload) VALUES (?)', [
      '{"title":"temporary"}',
    ]);
    database.execute('ROLLBACK');
    expect(
      database.select('SELECT count(*) AS count FROM items').single['count'],
      1,
    );
    expect(database.select('PRAGMA foreign_keys').single.values.single, 1);
  });

  test('WAL journal survives reopen without overwriting IDs', () async {
    final directory = await Directory.systemTemp.createTemp('nn-sqlite-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File(directory.path + '/operations.sqlite');
    final first = sqlite3.open(file.path);
    try {
      first.execute('PRAGMA journal_mode = WAL');
      first.execute(
        'CREATE TABLE operations '
        '(operation_id TEXT PRIMARY KEY, payload TEXT NOT NULL)',
      );
      first.execute('INSERT INTO operations VALUES (?, ?)', [
        'operation-1',
        '{"kind":"text.insert"}',
      ]);
    } finally {
      first.close();
    }

    final reopened = sqlite3.open(file.path);
    try {
      expect(
        reopened.select(
          'SELECT payload FROM operations WHERE operation_id = ?',
          ['operation-1'],
        ).single['payload'],
        '{"kind":"text.insert"}',
      );
      reopened.execute('INSERT OR IGNORE INTO operations VALUES (?, ?)', [
        'operation-1',
        '{"kind":"text.delete"}',
      ]);
      final count = reopened
          .select('SELECT count(*) AS total FROM operations')
          .single['total'];
      expect(count, 1);
      expect(
        reopened.select(
          'SELECT payload FROM operations WHERE operation_id = ?',
          ['operation-1'],
        ).single['payload'],
        '{"kind":"text.insert"}',
      );
    } finally {
      reopened.close();
    }
  });
}
