import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:program/data/sync/operation_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    '1000 additions and deletions survive SQLite restart without replay',
    () async {
      final directory = await Directory.systemTemp.createTemp('stage12-');
      final file = File('${directory.path}/notes.sqlite');
      var database = NotesDatabase(NativeDatabase(file));
      var store = OperationStore(database);
      final created = <String>[];
      final deleted = <String>[];

      try {
        await database.customStatement(
          'CREATE TABLE stage12_objects '
          '(id TEXT NOT NULL PRIMARY KEY, content TEXT NOT NULL)',
        );

        for (var index = 0; index < 1000; index++) {
          final id = 'object-$index';
          final operation = await store.writeLocal(
            actorId: 'stage12-actor',
            documentId: 'stage12-document',
            pageId: 'stage12-page',
            objectId: id,
            kind: OperationKind.objectCreate,
            payload: {
              'value': {'content': id},
            },
            apply: (_) => database.customStatement(
              'INSERT INTO stage12_objects (id, content) VALUES (?, ?)',
              [id, id],
            ),
          );
          created.add(operation.operationId);
        }

        for (var index = 0; index < 1000; index++) {
          final id = 'object-$index';
          final operation = await store.writeLocal(
            actorId: 'stage12-actor',
            documentId: 'stage12-document',
            pageId: 'stage12-page',
            objectId: id,
            kind: OperationKind.objectDelete,
            payload: const {},
            apply: (_) => database.customStatement(
              'DELETE FROM stage12_objects WHERE id = ?',
              [id],
            ),
          );
          deleted.add(operation.operationId);
        }

        expect(
          (await database
                  .customSelect('SELECT COUNT(*) AS total FROM stage12_objects')
                  .getSingle())
              .read<int>('total'),
          0,
        );
        await database.close();

        database = NotesDatabase(NativeDatabase(file));
        store = OperationStore(database);

        final journal = await database
            .customSelect('SELECT COUNT(*) AS total FROM operations')
            .getSingle();
        final outbox = await database
            .customSelect('SELECT COUNT(*) AS total FROM operation_outbox')
            .getSingle();
        final tombstones = await database
            .customSelect('SELECT COUNT(*) AS total FROM object_tombstones')
            .getSingle();
        expect(journal.read<int>('total'), 2000);
        expect(outbox.read<int>('total'), 2000);
        expect(tombstones.read<int>('total'), 1000);
        expect(await store.isPending(created.first), isTrue);
        expect(await store.isPending(deleted.last), isTrue);
        expect(
          (await database
                  .customSelect('SELECT COUNT(*) AS total FROM stage12_objects')
                  .getSingle())
              .read<int>('total'),
          0,
        );
        expect(
          await store.isTombstoned(
            'stage12-document',
            'object',
            'object-999',
            pageId: 'stage12-page',
          ),
          isTrue,
        );

        await store.acknowledge(created.first, serverSequence: 1);
        await store.acknowledge(created.first, serverSequence: 1);
        expect(await store.isPending(created.first), isFalse);
        expect(await store.isPending(deleted.last), isTrue);

        await expectLater(
          store.writeLocal(
            actorId: 'stage12-actor',
            documentId: 'stage12-document',
            pageId: 'stage12-page',
            objectId: 'incomplete',
            kind: OperationKind.objectCreate,
            payload: const {
              'value': {'content': 'uncommitted'},
            },
            apply: (_) async {
              await database.customStatement(
                'INSERT INTO stage12_objects (id, content) VALUES (?, ?)',
                ['incomplete', 'uncommitted'],
              );
              throw StateError('Simulated interruption');
            },
          ),
          throwsStateError,
        );
        expect(
          (await database
                  .customSelect('SELECT COUNT(*) AS total FROM operations')
                  .getSingle())
              .read<int>('total'),
          2000,
        );
        final next = await store.writeLocal(
          actorId: 'stage12-actor',
          documentId: 'stage12-document',
          pageId: 'stage12-page',
          objectId: 'after-retry',
          kind: OperationKind.objectCreate,
          payload: const {
            'value': {'content': 'retained'},
          },
          apply: (_) => database.customStatement(
            'INSERT INTO stage12_objects VALUES (?, ?)',
            ['after-retry', 'retained'],
          ),
        );
        expect(next.actorSeq, 2001);
      } finally {
        await database.close();
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
