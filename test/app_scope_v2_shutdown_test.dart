import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:program/app/app_scope.dart';
import 'package:program/core/error/app_error_log.dart';
import 'package:program/core/storage/active_storage_namespace.dart';
import 'package:program/core/storage/storage_namespace_manager.dart';
import 'package:program/core/storage/text_storage.dart';
import 'package:program/data/backup/remote_backup_scheduler.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/account_session_controller.dart';
import 'package:program/data/sync/api_client.dart';
import 'package:program/data/sync/editor_v2_account_runtime.dart';
import 'package:program/features/library/presentation/library_screen.dart';
import 'package:provider/provider.dart';

import 'support/native_test_documents.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useIsolatedNativeTestDocuments();
  useInMemoryTestTextStorage();

  testWidgets('v2 exit drains writers and logout verifies backup', (
    tester,
  ) async {
    const owner = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    const backup = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    final baseUri = Uri.parse('https://api.example.com');
    final calls = <String>[];
    final database = NotesDatabase(NativeDatabase.memory());
    late EditorV2AccountRuntime runtime;
    bool? runningAtExit;
    String? archiveHash;
    String? uploadedHash;
    http.Response json(Object value, [int status = 200]) =>
        http.Response(jsonEncode(value), status);
    final api = ApiClient(
      baseUri: baseUri,
      httpClient: MockClient((request) async {
        final path = request.url.path;
        calls.add('${request.method} $path');
        switch (path) {
          case '/v1/auth/refresh':
            return json({
              'accessToken': 'access',
              'refreshToken': 'refresh',
              'expiresIn': 3600,
              'userId': owner,
              'username': 'test_user',
            });
          case '/v1/time':
            return http.Response('', 404);
          case '/v1/auth/protocol':
            return json({'protocol': 'v2'});
          case '/v2/activation/readiness':
            return json({'protocol': 'v2', 'writeEnabled': true, 'version': 1});
          case '/v2/operations':
            return json({'operations': [], 'cursor': 0, 'hasMore': false});
          case '/v2/sync/checkpoint':
            return json({'cursor': 0});
          case '/v2/account-settings':
            return json({'settings': {}});
          case '/v2/planner/entries':
            return json({'entries': [], 'next': null});
          case '/v2/backups':
            archiveHash = (jsonDecode(request.body) as Map)['sha256'] as String;
            return json({'backupId': backup}, 201);
          case '/v2/backups/$backup/content':
            uploadedHash = sha256.convert(request.bodyBytes).toString();
            return http.Response('', 204);
          case '/v2/backups/$backup/finalize':
            return json({
              'status': 'verified',
              'sha256': archiveHash,
              'verifiedAt': '2026-11-13T07:00:00Z',
            });
          case '/v1/auth/logout':
            return http.Response('', 204);
          default:
            return http.Response('', 404);
        }
      }),
    );
    await writeStoredText(
      AccountSessionController.profileStorageKey,
      jsonEncode({
        'version': 1,
        'preferredMode': 'account',
        'onboardingComplete': true,
        'boundUserId': owner,
        'lastAccountUsername': 'test_user',
      }),
    );
    FlutterSecureStorage.setMockInitialValues({
      'nanotateczki_account_refresh_v1': jsonEncode({
        'version': 1,
        'backend': baseUri.toString(),
        'userId': owner,
        'username': 'test_user',
        'refreshToken': 'refresh',
      }),
    });
    addTearDown(() {
      ActiveStorageNamespace.activate(StorageNamespace.local());
      FlutterSecureStorage.setMockInitialValues({});
    });

    await tester.pumpWidget(
      AppScope.forTesting(
        apiClient: api,
        exit: () async {
          runningAtExit = runtime.engine.isStarted;
          return ui.AppExitResponse.cancel;
        },
        openDatabase: () async => DatabaseOpenResult(
          database: database,
          wasReset: false,
          freshFile: true,
        ),
      ),
    );
    for (
      var frame = 0;
      frame < 50 && find.byType(LibraryScreen).evaluate().isEmpty;
      frame++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    final library = find.byType(LibraryScreen);
    expect(library, findsOneWidget, reason: calls.join(', '));
    final session = tester.element(library).read<AccountSessionController>();
    expect(session.isSignedIn, isTrue);
    runtime = tester.element(library).read<EditorV2AccountRuntime?>()!;
    final backupScheduler = tester
        .element(library)
        .read<RemoteBackupScheduler>();
    final scope = tester.state(find.byType(AppScope)) as WidgetsBindingObserver;
    expect(await scope.didRequestAppExit(), ui.AppExitResponse.cancel);
    for (
      var frame = 0;
      frame < 100 && (runningAtExit == null || !backupScheduler.isEnabled);
      frame++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(
      runningAtExit,
      isFalse,
      reason: AppErrorLog.instance.entries
          .map((entry) => entry.error)
          .join(' | '),
    );
    expect(runtime.engine.isStarted, isTrue, reason: 'OS cancelled exit');
    expect(backupScheduler.isEnabled, isTrue);
    calls.clear();

    var done = false;
    final logout = session.logout().whenComplete(() => done = true);
    unawaited(logout.catchError((Object _) {}));
    for (var frame = 0; frame < 100 && !done; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(done, isTrue, reason: calls.join(', '));
    await logout;
    expect(session.isSignedIn, isFalse);
    expect(archiveHash, isNotNull);
    expect(uploadedHash, archiveHash);
    expect(
      calls,
      containsAllInOrder([
        'POST /v2/backups/$backup/finalize',
        'POST /v1/auth/logout',
      ]),
    );
    expect(calls.where((call) => call.contains('/v1/backups')), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
