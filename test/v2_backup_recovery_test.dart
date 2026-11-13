import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:program/core/storage/active_storage_namespace.dart';
import 'package:program/core/storage/storage_namespace_manager.dart';
import 'package:program/core/storage/text_storage.dart';
import 'package:program/data/backup/v2_backup_recovery_service.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/account_session_controller.dart';
import 'package:program/data/sync/api_client.dart';
import 'package:program/data/sync/editor_v2_account_runtime.dart';
import 'package:program/data/sync/operation_protocol.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';

const accountId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const backupId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const deviceId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

OperationEnvelope event(
  int seq,
  OperationKind kind, {
  Map<String, dynamic>? payload,
  String documentId = 'notebook-1',
  String? objectId,
  String? pageId,
}) {
  return OperationEnvelope(
    operationId: '11111111-1111-4111-8111-${seq.toString().padLeft(12, '0')}',
    actorId: 'actor-1',
    actorSeq: seq,
    documentId: documentId,
    kind: kind,
    objectId: objectId,
    pageId: pageId,
    logicalClock: seq,
    dependencies: [
      if (seq > 1)
        '11111111-1111-4111-8111-${(seq - 1).toString().padLeft(12, '0')}',
    ],
    payload: payload ?? {},
  );
}

final createDocument = event(
  1,
  OperationKind.documentCreate,
  payload: {
    'value': {
      'title': 'History',
      'folder': 'Notes',
      'kindIndex': 0,
      'createdAt': '2026-11-12T10:00:00Z',
    },
  },
);

final createPage = event(
  2,
  OperationKind.pageCreate,
  objectId: 'page-one',
  payload: {
    'value': {'title': 'Page', 'isBookmarked': false},
  },
);

class _Server {
  final history = <OperationEnvelope>[createDocument, createPage];
  Uint8List? verified;
  Uint8List? pending;
  bool rejectUpload = false;
  Future<void> Function()? beforeCheckpoint;
  final paths = <String>[];

  Future<http.Response> respond(http.Request request) async {
    final path = request.url.path;
    paths.add('${request.method} $path');
    if (path.startsWith('/v2/assets/')) {
      return http.Response.bytes([9, 9, 9], 200);
    }
    if (path == '/v2/sync/checkpoint') {
      await beforeCheckpoint?.call();
      return http.Response(jsonEncode({'cursor': history.length}), 200);
    }
    if (path == '/v2/operations') {
      final after = int.parse(request.url.queryParameters['after']!);
      return http.Response(
        jsonEncode({
          'cursor': history.length,
          'hasMore': false,
          'operations': [
            for (var i = after; i < history.length; i++)
              {'cursor': i + 1, 'operation': history[i].toJson()},
          ],
        }),
        200,
      );
    }
    if (request.method == 'POST' && path == '/v2/backups') {
      final create = jsonDecode(request.body) as Map;
      expect(create['formatVersion'], 3);
      return http.Response(jsonEncode({'backupId': backupId}), 201);
    }
    if (request.method == 'PUT' && path.endsWith('/content')) {
      if (rejectUpload) {
        return http.Response('Insufficient storage', 507);
      }
      pending = request.bodyBytes;
      return http.Response('', 204);
    }
    if (request.method == 'POST' && path.endsWith('/finalize')) {
      verified = pending;
      return http.Response(
        jsonEncode({
          'status': 'verified',
          'sha256': sha256.convert(verified!).toString(),
          'verifiedAt': '2026-11-12T12:00:00Z',
        }),
        200,
      );
    }
    if (request.method == 'GET' && path == '/v2/backups') {
      return http.Response(
        jsonEncode({
          'backups': [
            if (verified != null)
              {
                'backupId': backupId,
                'deviceId': deviceId,
                'sha256': sha256.convert(verified!).toString(),
                'sizeBytes': verified!.length,
              },
          ],
        }),
        200,
      );
    }
    if (request.method == 'GET' && path.endsWith('/download')) {
      return verified == null
          ? http.Response('missing', 404)
          : http.Response.bytes(verified!, 200);
    }
    throw StateError('Unexpected v2 request: ${request.method} $path');
  }
}

class _Client {
  _Client(this.server) {
    db = NotesDatabase(NativeDatabase.memory());
    repo = NotebookRepository(db);
    api = ApiClient(
      baseUri: Uri.parse('https://api.example.com'),
      httpClient: MockClient(server.respond),
    )..setAccessToken('token');
    session = AccountSessionController(api)
      ..mode = AccountDataMode.account
      ..userId = accountId;
    runtime = EditorV2AccountRuntime(
      repository: repo,
      apiClient: api,
      accountId: accountId,
      actorId: 'device-test',
      enableRealtime: false,
    );
    backup = V2BackupRecoveryService(
      runtime: runtime,
      repository: repo,
      apiClient: api,
      session: session,
    );
  }

  final _Server server;
  late final NotesDatabase db;
  late final NotebookRepository repo;
  late final ApiClient api;
  late final AccountSessionController session;
  late final EditorV2AccountRuntime runtime;
  late final V2BackupRecoveryService backup;

  Future<void> seed() async {
    for (var i = 0; i < server.history.length; i++) {
      final operation = server.history[i];
      await runtime.store.applyRemote(
        operation,
        checkpointScope: 'account:$accountId',
        serverSequence: i + 1,
        coveredCursor: i,
        apply: () => runtime.projector.apply(operation),
      );
    }
  }

  Future<void> close() async {
    await runtime.stop();
    runtime.dispose();
    api.close();
    session.dispose();
    await db.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, String> files;
  setUp(() {
    files = {
      'study_planner.json': jsonEncode({
        'sessions': [
          {'id': 'session-1', 'name': 'Study'},
        ],
      }),
      'app_prefs.json': '{"darkMode":true}',
      'library_folders.json': '{"folders":["Notes"]}',
    };
    ActiveStorageNamespace.activate(StorageNamespace.account(accountId));
    textStorageReadOverride = (key) async => files[key];
    textStorageWriteOverride = (key, value) async => files[key] = value;
  });
  tearDown(() {
    textStorageReadOverride = null;
    textStorageWriteOverride = null;
    ActiveStorageNamespace.activate(StorageNamespace.local());
  });

  test(
    'captures committed journal without serializing notebook snapshots',
    () async {
      final server = _Server();
      final client = _Client(server);
      addTearDown(client.close);
      await client.seed();
      final receipt = await client.backup.uploadVerifiedSnapshot(
        deviceId: deviceId,
      );
      expect(receipt.backupId, backupId);
      final envelope = jsonDecode(utf8.decode(server.verified!)) as Map;
      final payload = envelope['payload'] as Map;
      expect(envelope['version'], 3);
      expect(
        envelope['operationCheckpoint'],
        containsPair('account:$accountId', 2),
      );
      expect(payload['notebooks'], isEmpty);
      expect(payload['operationHistory'], hasLength(2));
      expect(payload['assetBlobs'], isEmpty);
      expect(payload['studyPlannerState']['sessions'], hasLength(1));
      expect(payload['appPreferences']['darkMode'], true);
      expect(server.paths.where((p) => p.contains('/v1/')), isEmpty);
    },
  );

  test(
    'a missing SQLite database restores and replays original envelopes',
    () async {
      final server = _Server();
      final first = _Client(server);
      addTearDown(first.close);
      await first.seed();
      await first.backup.uploadVerifiedSnapshot(deviceId: deviceId);
      final missing = _Client(server);
      addTearDown(missing.close);
      files.remove('app_prefs.json');
      final restored = await missing.backup.recoverVerifiedArchive(
        databaseWasReset: true,
      );
      expect(restored, true);
      expect(await missing.runtime.store.checkpoint('account:$accountId'), 2);
      expect((await missing.repo.fetchNotebooks()).single.title, 'History');
      expect(files['app_prefs.json'], '{"darkMode":true}');
      expect(await missing.backup.hasInterruptedRecovery(accountId), true);
      await missing.backup.completeRecovery();
      expect(await missing.backup.hasInterruptedRecovery(accountId), false);
      expect(
        (await missing.db.customSelect('SELECT * FROM operation_outbox').get()),
        isEmpty,
      );
    },
  );

  test(
    'post-snapshot remote deletion is replayed, never resurrected',
    () async {
      final server = _Server();
      final source = _Client(server);
      addTearDown(source.close);
      await source.seed();
      await source.backup.uploadVerifiedSnapshot(deviceId: deviceId);
      server.history.add(event(3, OperationKind.documentDelete));
      final target = _Client(server);
      addTearDown(target.close);
      expect(
        await target.backup.recoverVerifiedArchive(databaseWasReset: true),
        true,
      );
      expect((await target.repo.fetchNotebooks()), hasLength(1));
      expect(
        await target.runtime.startForCurrentAccount(isCurrent: () => true),
        true,
      );
      expect(await target.runtime.store.checkpoint('account:$accountId'), 3);
      expect(await target.repo.fetchNotebooks(), isEmpty);
      expect(
        await target.runtime.store.isTombstoned(
          'notebook-1',
          'document',
          'notebook-1',
        ),
        isTrue,
      );
    },
  );

  test(
    'restart mid-restore is idempotent with durable pending marker',
    () async {
      final server = _Server();
      server.history.add(
        event(
          3,
          OperationKind.pageSet,
          objectId: 'page-one',
          payload: {
            'properties': {'title': 'Renamed'},
          },
        ),
      );
      final source = _Client(server);
      addTearDown(source.close);
      await source.seed();
      await source.backup.uploadVerifiedSnapshot(deviceId: deviceId);
      final target = _Client(server);
      addTearDown(target.close);
      target.backup.afterRecoveryOperation = (index) async {
        if (index == 2) {
          throw StateError('Simulated crash after two SQLite commits');
        }
      };
      await expectLater(
        target.backup.recoverVerifiedArchive(databaseWasReset: true),
        throwsStateError,
      );
      expect(await target.backup.hasInterruptedRecovery(accountId), true);
      expect(await target.runtime.store.checkpoint('account:$accountId'), 2);
      target.backup.afterRecoveryOperation = null;
      expect(
        await target.backup.recoverVerifiedArchive(databaseWasReset: false),
        true,
      );
      expect(await target.runtime.store.checkpoint('account:$accountId'), 3);
      expect(
        (await target.db.customSelect('SELECT * FROM operations').get()),
        hasLength(3),
      );
    },
  );

  test('restart after catch-up but before marker completion is safe', () async {
    final server = _Server();
    final source = _Client(server);
    addTearDown(source.close);
    await source.seed();
    await source.backup.uploadVerifiedSnapshot(deviceId: deviceId);
    server.history.add(event(3, OperationKind.documentDelete));
    final target = _Client(server);
    addTearDown(target.close);
    await target.backup.recoverVerifiedArchive(databaseWasReset: true);
    await target.runtime.startForCurrentAccount(isCurrent: () => true);
    await target.runtime.stop();
    expect(await target.runtime.store.checkpoint('account:$accountId'), 3);
    expect(await target.backup.hasInterruptedRecovery(accountId), true);

    expect(
      await target.backup.recoverVerifiedArchive(databaseWasReset: false),
      true,
    );
    expect(await target.runtime.store.checkpoint('account:$accountId'), 3);
    expect(await target.repo.fetchNotebooks(), isEmpty);
    await target.backup.completeRecovery();
    expect(await target.backup.hasInterruptedRecovery(accountId), false);
  });

  test('corrupt archived media is rejected before SQLite writes', () async {
    final server = _Server();
    final source = _Client(server);
    addTearDown(source.close);
    await source.seed();
    await source.backup.uploadVerifiedSnapshot(deviceId: deviceId);
    final envelope = jsonDecode(utf8.decode(server.verified!)) as Map;
    final payload = envelope['payload'] as Map;
    payload['assetBlobs'] = {
      sha256.convert([1, 2, 3]).toString(): {
        'sizeBytes': 3,
        'mediaType': 'application/pdf',
        'bytesBase64': base64Encode([7, 8, 9]),
      },
    };
    envelope['checksum'] = sha256
        .convert(utf8.encode(jsonEncode(payload)))
        .toString();
    server.verified = Uint8List.fromList(utf8.encode(jsonEncode(envelope)));
    final target = _Client(server);
    addTearDown(target.close);
    await expectLater(
      target.backup.recoverVerifiedArchive(databaseWasReset: true),
      throwsFormatException,
    );
    expect(
      (await target.db.customSelect('SELECT * FROM operations').get()),
      isEmpty,
    );
  });

  test('corrupt content-addressed server asset blocks replay', () async {
    final server = _Server();
    final source = _Client(server);
    addTearDown(source.close);
    await source.seed();
    await source.backup.uploadVerifiedSnapshot(deviceId: deviceId);
    final envelope = jsonDecode(utf8.decode(server.verified!)) as Map;
    final payload = envelope['payload'] as Map;
    final history = payload['operationHistory'] as List;
    final sha = sha256.convert([1, 2, 3]).toString();
    final attach = event(
      3,
      OperationKind.assetAttach,
      objectId: 'object-one',
      pageId: 'page-one',
      payload: {
        'assetId': 'a1',
        'sha256': sha,
        'sizeBytes': 3,
        'mediaType': 'application/pdf',
      },
    );
    history.add({'cursor': 3, 'operation': attach.toJson()});
    (envelope['operationCheckpoint'] as Map)['account:$accountId'] = 3;
    payload['assetBlobs'] = {
      sha: {
        'sizeBytes': 3,
        'mediaType': 'application/pdf',
        'storage': 'verified-v2',
      },
    };
    envelope['checksum'] = sha256
        .convert(utf8.encode(jsonEncode(payload)))
        .toString();
    server.verified = Uint8List.fromList(utf8.encode(jsonEncode(envelope)));
    final target = _Client(server);
    addTearDown(target.close);
    await expectLater(
      target.backup.recoverVerifiedArchive(databaseWasReset: true),
      throwsFormatException,
    );
    expect(
      (await target.db.customSelect('SELECT * FROM operations').get()),
      isEmpty,
    );
  });

  test(
    'interrupted upload and no-space failure retain previous verified copy',
    () async {
      final server = _Server();
      final client = _Client(server);
      addTearDown(client.close);
      await client.seed();
      await client.backup.uploadVerifiedSnapshot(deviceId: deviceId);
      final oldHash = sha256.convert(server.verified!).toString();
      server.rejectUpload = true;
      await expectLater(
        client.backup.uploadVerifiedSnapshot(deviceId: deviceId),
        throwsA(isA<ApiException>()),
      );
      expect(sha256.convert(server.verified!).toString(), oldHash);
      expect(
        (await client.db.customSelect('SELECT * FROM operation_outbox').get()),
        isEmpty,
      );
    },
  );

  test('older archive cannot roll back a surviving newer checkpoint', () async {
    final server = _Server();
    final source = _Client(server);
    addTearDown(source.close);
    await source.seed();
    await source.backup.uploadVerifiedSnapshot(deviceId: deviceId);
    final target = _Client(server);
    addTearDown(target.close);
    await target.runtime.store.advanceCheckpoint('account:$accountId', 3);
    await expectLater(
      target.backup.recoverVerifiedArchive(databaseWasReset: false),
      throwsStateError,
    );
    expect(await target.runtime.store.checkpoint('account:$accountId'), 3);
  });

  test('account switch during checkpoint read blocks old backup', () async {
    final server = _Server();
    final client = _Client(server);
    addTearDown(client.close);
    await client.seed();
    server.beforeCheckpoint = () async {
      ActiveStorageNamespace.activate(StorageNamespace.local());
    };
    await expectLater(
      client.backup.uploadVerifiedSnapshot(deviceId: deviceId),
      throwsStateError,
    );
    expect(server.paths.where((p) => p == 'POST /v2/backups'), isEmpty);
  });

  test(
    'offline outbox prevents uploading a misleading confirmed checkpoint',
    () async {
      final server = _Server();
      final client = _Client(server);
      addTearDown(client.close);
      await client.seed();
      await client.db.customStatement(
        'INSERT INTO operation_outbox (operation_id, queued_at) VALUES (?, ?)',
        [createDocument.operationId, 0],
      );
      await expectLater(
        client.backup.uploadVerifiedSnapshot(deviceId: deviceId),
        throwsStateError,
      );
      expect(server.paths.where((p) => p == 'POST /v2/backups'), isEmpty);
      expect(
        (await client.db.customSelect('SELECT * FROM operation_outbox').get()),
        hasLength(1),
      );
    },
  );
}
