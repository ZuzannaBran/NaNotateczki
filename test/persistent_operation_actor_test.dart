import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/core/storage/text_storage.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:program/data/sync/operation_store.dart';
import 'package:program/data/sync/persistent_operation_actor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const key = 'account_v2_actor_id.json';
  late Map<String, String> files;

  setUp(() {
    files = {};
    textStorageReadOverride = (key) async => files[key];
    textStorageWriteOverride = (key, value) async => files[key] = value;
  });

  tearDown(() {
    textStorageReadOverride = null;
    textStorageWriteOverride = null;
  });

  test('restart retains actor and continues durable actor sequence', () async {
    final directory = await Directory.systemTemp.createTemp('nn-actor-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/notes.sqlite');
    final firstDb = NotesDatabase(NativeDatabase(file));
    final firstStore = OperationStore(firstDb);
    final actor = await loadPersistentOperationActor(firstStore);
    final first = await firstStore.writeLocal(
      actorId: actor,
      documentId: 'actor-document',
      kind: OperationKind.documentCreate,
      payload: const {'value': {}},
      apply: (_) async {},
    );
    await firstDb.close();

    final reopenedDb = NotesDatabase(NativeDatabase(file));
    addTearDown(reopenedDb.close);
    final reopened = OperationStore(reopenedDb);
    expect(await loadPersistentOperationActor(reopened), actor);
    final next = await reopened.writeLocal(
      actorId: await loadPersistentOperationActor(reopened),
      documentId: 'actor-document',
      kind: OperationKind.documentSet,
      payload: const {
        'properties': {'title': 'After restart'},
      },
      apply: (_) async {},
    );
    expect(first.actorSeq, 1);
    expect(next.actorSeq, 2);
    expect(next.dependencies, contains(first.operationId));
    expect(await reopened.pending(includeDeferred: true), hasLength(2));
  });

  for (final stored in ['{broken', '{}', '{"version":1,"actorId":"bad"}']) {
    test('malformed actor is preserved for recovery: $stored', () async {
      final database = NotesDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      files[key] = stored;
      await expectLater(
        loadPersistentOperationActor(OperationStore(database)),
        throwsFormatException,
      );
      expect(files[key], stored);
    });
  }

  for (final blocked in [false, true]) {
    test('missing actor refuses pending edits, blocked=$blocked', () async {
      final database = NotesDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final store = OperationStore(database);
      final actor = await loadPersistentOperationActor(store);
      await store.writeLocal(
        actorId: actor,
        documentId: 'pending-document',
        kind: OperationKind.documentCreate,
        payload: const {'value': {}},
        apply: (_) async {},
      );
      if (blocked) {
        await database.customStatement(
          "UPDATE operation_outbox SET status = 'blocked'",
        );
      }
      files.remove(key);
      await expectLater(loadPersistentOperationActor(store), throwsStateError);
      expect(files.containsKey(key), isFalse);
      expect(await store.pending(includeDeferred: true), hasLength(1));
    });
  }

  test('actor is not returned if persistence fails', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    textStorageWriteOverride = (_, _) async => throw StateError('Disk full');
    await expectLater(
      loadPersistentOperationActor(OperationStore(database)),
      throwsStateError,
    );
    expect(files, isEmpty);
  });

  test('new actor is persisted before use and reused', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final store = OperationStore(database);
    final actor = await loadPersistentOperationActor(store);
    expect(jsonDecode(files[key]!)['actorId'], actor);
    expect(await loadPersistentOperationActor(store), actor);
  });
}
