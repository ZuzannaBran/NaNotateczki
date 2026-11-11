import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/core/storage/storage_namespace_manager.dart';
import 'package:program/core/storage/text_storage.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:program/data/sync/operation_store.dart';
import 'package:program/data/sync/persistent_share_actor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const firstShare = 'e5b63a5e-82f3-4a2a-9c57-16255f4e4431';
  const secondShare = '99999999-9999-4999-8999-999999999999';
  const guest = 'browser-guest';
  late Map<String, String> storage;

  setUp(() {
    storage = {};
    textStorageReadOverride = (key) async => storage[key];
    textStorageWriteOverride = (key, value) async => storage[key] = value;
  });

  tearDown(() {
    textStorageReadOverride = null;
    textStorageWriteOverride = null;
  });

  test('guest actor persists and is scoped to the invitation', () async {
    final firstDb = NotesDatabase(NativeDatabase.memory());
    addTearDown(firstDb.close);
    final first = await loadPersistentShareActor(
      OperationStore(firstDb),
      shareId: firstShare,
      guestActorId: guest,
    );
    expect(
      await loadPersistentShareActor(
        OperationStore(firstDb),
        shareId: firstShare,
        guestActorId: guest,
      ),
      first,
    );
    final secondDb = NotesDatabase(NativeDatabase.memory());
    addTearDown(secondDb.close);
    final second = await loadPersistentShareActor(
      OperationStore(secondDb),
      shareId: secondShare,
      guestActorId: guest,
    );
    expect(second, isNot(first));
    expect(storage.length, 2);
  });

  test('missing actor never abandons durable guest outbox', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final store = OperationStore(database);
    final actor = await loadPersistentShareActor(
      store,
      shareId: firstShare,
      guestActorId: guest,
    );
    final operation = await store.writeLocal(
      actorId: actor,
      documentId: 'shared-document',
      kind: OperationKind.documentCreate,
      payload: const {'value': {}},
      apply: (_) async {},
    );
    final key = StorageNamespace.share(firstShare, guest).fileKey('actor.json');
    storage.remove(key);
    await expectLater(
      loadPersistentShareActor(store, shareId: firstShare, guestActorId: guest),
      throwsStateError,
    );
    expect(
      (await store.pending(includeDeferred: true)).single.operationId,
      operation.operationId,
    );
  });

  test('invalid identity is retained for recovery', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final key = StorageNamespace.share(firstShare, guest).fileKey('actor.json');
    storage[key] = '{"version":1,"actorId":"invalid"}';
    await expectLater(
      loadPersistentShareActor(
        OperationStore(database),
        shareId: firstShare,
        guestActorId: guest,
      ),
      throwsFormatException,
    );
    expect(jsonDecode(storage[key]!)['actorId'], 'invalid');
  });
}
