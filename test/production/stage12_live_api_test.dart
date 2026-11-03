import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/api_client.dart';
import 'package:program/data/sync/operation_gateway.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:program/data/sync/operation_store.dart';
import 'package:program/data/sync/sync_engine.dart';
import 'package:uuid/uuid.dart';

const _baseUrl = String.fromEnvironment('NN_STAGE12_API_URL');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'two real Flutter clients converge through FastAPI and PostgreSQL',
    () async {
      final id = const Uuid().v4().replaceAll('-', '');
      final apiA = ApiClient(baseUri: Uri.parse(_baseUrl));
      final apiB = ApiClient(baseUri: Uri.parse(_baseUrl));
      final dbA = NotesDatabase(NativeDatabase.memory());
      final dbB = NotesDatabase(NativeDatabase.memory());
      final storeA = OperationStore(dbA);
      final storeB = OperationStore(dbB);
      SyncEngine? engineA;
      SyncEngine? engineB;

      Future<void> applyObject(
        NotesDatabase db,
        OperationEnvelope operation,
      ) async {
        final objectId = operation.objectId;
        if (objectId == null) {
          return;
        }
        switch (operation.kind) {
          case OperationKind.objectCreate:
            await db.customStatement(
              'INSERT OR IGNORE INTO stage12_objects VALUES (?, ?)',
              [objectId, 'committed'],
            );
            break;
          case OperationKind.objectDelete:
            await db.customStatement(
              'DELETE FROM stage12_objects WHERE id = ?',
              [objectId],
            );
            break;
          default:
            break;
        }
      }

      Future<List<String>> objects(NotesDatabase db) async {
        final rows = await db
            .customSelect('SELECT id FROM stage12_objects ORDER BY id')
            .get();
        return rows.map((row) => row.read<String>('id')).toList();
      }

      try {
        await dbA.customStatement(
          'CREATE TABLE stage12_objects '
          '(id TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)',
        );
        await dbB.customStatement(
          'CREATE TABLE stage12_objects '
          '(id TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)',
        );

        final registration = await apiA.postJson(
          '/v1/auth/register',
          {'username': 's12_${id.substring(0, 20)}', 'password': 'stage12-test-only'},
          authenticated: false,
        );
        final account = Map<String, dynamic>.from(
          registration.decodeJson() as Map,
        );
        final token = account['accessToken'] as String;
        expect(token, isNotEmpty);
        apiA.setAccessToken(token);
        apiB.setAccessToken(token);

        final document = 'stage12-$id';
        const page = 'stage12-page';
        engineA = SyncEngine(
          store: storeA,
          gateway: HttpOperationGateway(apiA),
          actorId: 'stage12-linux-a',
          checkpointScope: 'stage12-$id-a',
          enableRealtime: true,
          apiClient: apiA,
          applyRemote: (operation, _) => applyObject(dbA, operation),
        );
        engineB = SyncEngine(
          store: storeB,
          gateway: HttpOperationGateway(apiB),
          actorId: 'stage12-linux-b',
          checkpointScope: 'stage12-$id-b',
          enableRealtime: true,
          apiClient: apiB,
          applyRemote: (operation, _) => applyObject(dbB, operation),
        );

        await engineA.writeLocal(
          documentId: document,
          kind: OperationKind.documentCreate,
          payload: const {
            'value': {'title': 'Stage 12'},
          },
          apply: (_) async {},
        );
        await engineA.writeLocal(
          documentId: document,
          kind: OperationKind.pageCreate,
          objectId: page,
          payload: const {
            'value': {'title': 'Page'},
          },
          apply: (_) async {},
        );
        final first = await engineA.writeLocal(
          documentId: document,
          pageId: page,
          objectId: 'stroke-a',
          kind: OperationKind.objectCreate,
          payload: const {
            'value': {'points': [1, 2]},
          },
          apply: (operation) => applyObject(dbA, operation),
        );
        expect(await storeA.isPending(first.operationId), isTrue);
        await engineA.start();
        expect(await storeA.pending(), isEmpty);

        await engineB.start();
        expect(await objects(dbB), ['stroke-a']);

        final second = await engineB.writeLocal(
          documentId: document,
          pageId: page,
          objectId: 'stroke-b',
          kind: OperationKind.objectCreate,
          payload: const {
            'value': {'points': [3, 4]},
          },
          apply: (operation) => applyObject(dbB, operation),
        );
        await engineB.syncNow();
        await engineA.syncNow();
        expect(await objects(dbA), ['stroke-a', 'stroke-b']);
        expect(await objects(dbB), ['stroke-a', 'stroke-b']);
        expect(await storeB.isPending(second.operationId), isFalse);

        await engineA.writeLocal(
          documentId: document,
          pageId: page,
          objectId: 'stroke-a',
          kind: OperationKind.objectDelete,
          payload: const {},
          apply: (operation) => applyObject(dbA, operation),
        );
        await engineA.syncNow();
        await engineB.syncNow();
        expect(await objects(dbA), ['stroke-b']);
        expect(await objects(dbB), ['stroke-b']);

        final apiSnapshot = await apiA.get(
          '/v2/documents/$document/snapshot',
        );
        final snapshot = Map<String, dynamic>.from(
          apiSnapshot.decodeJson() as Map,
        );
        final state = Map<String, dynamic>.from(snapshot['state'] as Map);
        final pages = Map<String, dynamic>.from(state['pages'] as Map);
        final pageState = Map<String, dynamic>.from(pages[page] as Map);
        final savedObjects = Map<String, dynamic>.from(
          pageState['objects'] as Map,
        );
        expect(savedObjects.keys.toList(), ['stroke-b']);
        expect(await storeA.pending(), isEmpty);
        expect(await storeB.pending(), isEmpty);
      } finally {
        await engineA?.stop();
        await engineB?.stop();
        engineA?.dispose();
        engineB?.dispose();
        apiA.close();
        apiB.close();
        await dbA.close();
        await dbB.close();
      }
    },
    skip: _baseUrl.isEmpty,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
