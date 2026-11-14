import 'dart:io';
import 'dart:ui' show Color;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/api_client.dart';
import 'package:program/data/sync/editor_v2_account_runtime.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';

const _role = String.fromEnvironment('NN_STAGE12_PROCESS_ROLE');
const _directory = String.fromEnvironment('NN_STAGE12_PROCESS_DIRECTORY');
const _baseUrl = String.fromEnvironment('NN_STAGE12_API_URL');
const _token = String.fromEnvironment('NN_STAGE12_ACCESS_TOKEN');
const _inkId = 'two-process-ink';

class _LoopbackTestBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

File _file(String name) => File('$_directory/$name');

Future<void> _publish(String name, [String text = 'ready']) async {
  final temporary = _file('$name.tmp');
  await temporary.writeAsString(text, flush: true);
  await temporary.rename(_file(name).path);
}

Future<String> _awaitPeer(String name) async {
  final file = _file(name);
  final deadline = DateTime.now().add(const Duration(minutes: 2));
  while (!await file.exists()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Timed out waiting for independent client: $name');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return file.readAsString();
}

void main() {
  if (_role.isNotEmpty) {
    _LoopbackTestBinding();
  }
  test(
    'independent Flutter process $_role converges after offline edits',
    () async {
      final endpoint = Uri.parse(_baseUrl);
      expect(endpoint.scheme, 'http');
      expect(endpoint.host, anyOf('127.0.0.1', 'localhost', '::1'));
      expect(_directory, isNotEmpty);
      expect(_role, anyOf('a', 'b'));
      final api = ApiClient(baseUri: endpoint)..setAccessToken(_token);
      addTearDown(api.close);
      final profile = (await api.get('/v2/auth/me')).decodeJson() as Map;
      final account = profile['userId'] as String;
      final databaseFile = _file('$_role.sqlite');

      final database = NotesDatabase(NativeDatabase(databaseFile));
      final repository = NotebookRepository(database);
      final runtime = EditorV2AccountRuntime(
        repository: repository,
        apiClient: api,
        accountId: account,
        actorId: 'stage12-independent-$_role',
        enableRealtime: false,
      );
      var closed = false;
      Future<void> close() async {
        if (closed) return;
        closed = true;
        await runtime.stop();
        runtime.dispose();
        await database.close();
      }

      addTearDown(close);
      await repository.enableAccountOperations(runtime.writer);
      late final String uid;
      if (_role == 'a') {
        final note = await repository.createNotebook(title: 'Two processes');
        uid = note.uid;
        final first = note.pages.single;
        final second = first.copyWith(id: 'destination-page');
        await runtime.writer.writeNotebookChange(
          before: note,
          after: note.copyWith(
            pages: [
              first.copyWith(
                inkStrokes: [
                  InkStroke(
                    id: _inkId,
                    points: const [InkPoint(dx: 1, dy: 2, pressure: .5)],
                    color: const Color(0xff000000),
                    width: 2,
                    tool: DrawingTool.pen,
                  ),
                ],
              ),
              second,
            ],
          ),
        );
        await runtime.start();
        expect(runtime.engine.lastError, isNull);
        expect(await runtime.store.pending(), isEmpty);
        await _publish('document', uid);
      } else {
        uid = await _awaitPeer('document');
        await runtime.start();
        expect(runtime.engine.lastError, isNull);
      }
      await runtime.stop();
      final before = (await repository.getNotebook(uid))!;
      final first = before.pages.first;
      final second = before.pages.last;
      final ink = first.inkStrokes.single;
      final operations = await runtime.writer.writeNotebookChange(
        before: before,
        after: before.copyWith(
          pages: _role == 'a'
              ? [
                  first.copyWith(inkStrokes: []),
                  second.copyWith(inkStrokes: [ink]),
                ]
              : [
                  first.copyWith(inkStrokes: [ink.copyWith(width: 9)]),
                  second,
                ],
        ),
      );
      expect(operations, hasLength(1));
      expect(await runtime.store.pending(), hasLength(1));
      await _publish('offline-$_role');
      await _awaitPeer('offline-${_role == 'a' ? 'b' : 'a'}');
      // Client B delivers an edit that still names the original page. Client
      // A must accept it over its unsent move, then send the original envelope.
      if (_role == 'a') await _awaitPeer('sent-b');
      await runtime.start();
      expect(runtime.engine.lastError, isNull);
      expect(await runtime.store.pending(), isEmpty);
      await _publish('sent-$_role');
      await _awaitPeer('sent-${_role == 'a' ? 'b' : 'a'}');
      await close();

      final restarted = NotesDatabase(NativeDatabase(databaseFile));
      final restartedRepo = NotebookRepository(restarted);
      final restartedRuntime = EditorV2AccountRuntime(
        repository: restartedRepo,
        apiClient: api,
        accountId: account,
        actorId: 'stage12-independent-$_role',
        enableRealtime: false,
      );
      addTearDown(() async {
        await restartedRuntime.stop();
        restartedRuntime.dispose();
        await restarted.close();
      });
      expect(
        await restartedRuntime.startForCurrentAccount(isCurrent: () => true),
        isTrue,
      );
      expect(restartedRuntime.engine.lastError, isNull);
      final after = (await restartedRepo.getNotebook(uid))!;
      expect(after.pages.first.inkStrokes, isEmpty);
      expect(after.pages.last.id, 'destination-page');
      expect(after.pages.last.inkStrokes.single.id, _inkId);
      expect(after.pages.last.inkStrokes.single.width, 9);
      final op = operations.single;
      final preserved = await restartedRuntime.store.operation(op.operationId);
      expect(preserved?.toJson(), op.toJson());
      expect(await restartedRuntime.store.pending(), isEmpty);
    },
    skip: _role.isEmpty,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
