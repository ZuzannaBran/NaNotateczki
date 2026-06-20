import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/drift/notes_database_connection.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/note_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'saveNotebook updates existing notebook without breaking foreign keys',
    () async {
      final database = NotesDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final repository = NotebookRepository(database);

      final notebook = await repository.createNotebook();
      final renamed = notebook.copyWith(title: 'Renamed notebook');

      await repository.saveNotebook(renamed);

      final saved = await repository.getNotebook(notebook.uid);
      expect(saved?.title, 'Renamed notebook');
      expect(saved?.pages, hasLength(1));
    },
  );

  test(
    'database open retries transient failures without resetting data',
    () async {
      var attempts = 0;
      final delays = <Duration>[];

      final result = await NotesDatabase.open(
        connectionOpener: (_) async {
          attempts++;
          if (attempts < 3) {
            throw StateError('temporary open failure');
          }
          return NotesDatabaseConnection(
            executor: NativeDatabase.memory(),
            freshFile: false,
          );
        },
        retryDelay: (duration) async => delays.add(duration),
        errorRecorder: (_, _, _) {},
      );
      addTearDown(result.database.close);

      expect(attempts, 3);
      expect(delays, hasLength(2));
      expect(result.wasReset, isFalse);
      expect(result.freshFile, isFalse);
    },
  );

  test('database open fails closed after retries', () async {
    var attempts = 0;

    await expectLater(
      NotesDatabase.open(
        connectionOpener: (_) async {
          attempts++;
          throw StateError('persistent open failure');
        },
        retryDelay: (_) async {},
        errorRecorder: (_, _, _) {},
      ),
      throwsA(
        isA<DatabaseOpenException>()
            .having(
              (error) => error.stage,
              'stage',
              DatabaseOpenStage.connection,
            )
            .having((error) => error.attempts, 'attempts', 3)
            .having(
              (error) => error.cause,
              'cause',
              isA<StateError>().having(
                (cause) => cause.message,
                'message',
                'persistent open failure',
              ),
            ),
      ),
    );

    expect(attempts, 3);
  });

  test('older snapshot cannot replace newer notebook data', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final notebook = await repository.createNotebook();
    final newer = notebook.copyWith(
      title: 'Newer title',
      updatedAt: notebook.updatedAt.add(const Duration(minutes: 2)),
      pages: [
        ...notebook.pages,
        NotePage(
          id: 'newer-page',
          title: 'Newer page',
          textBlocks: const [],
          imageBlocks: const [],
          inkStrokes: const [],
          isBookmarked: false,
          indexTabs: const [],
        ),
      ],
    );
    final older = notebook.copyWith(
      title: 'Older title',
      updatedAt: notebook.updatedAt.add(const Duration(minutes: 1)),
    );

    expect(await repository.saveNotebook(newer), isTrue);
    expect(await repository.saveNotebook(older), isFalse);

    final saved = await repository.getNotebook(notebook.uid);
    expect(saved?.title, 'Newer title');
    expect(saved?.pages, hasLength(2));
  });

  test('later equal-timestamp snapshot wins in save order', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final notebook = await repository.createNotebook();
    final first = notebook.copyWith(title: 'First');
    final second = notebook.copyWith(title: 'Second');

    await Future.wait([
      repository.saveNotebook(first),
      repository.saveNotebook(second),
    ]);

    final saved = await repository.getNotebook(notebook.uid);
    expect(saved?.title, 'Second');
  });

  test('empty snapshot cannot erase notebook pages', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final notebook = await repository.createNotebook();

    await expectLater(
      repository.saveNotebook(notebook.copyWith(pages: const [])),
      throwsArgumentError,
    );

    final saved = await repository.getNotebook(notebook.uid);
    expect(saved?.pages, hasLength(1));
  });

  test(
    'top-level fetch failure is reported instead of returning empty',
    () async {
      final database = NotesDatabase(NativeDatabase.memory());
      final repository = NotebookRepository(database);
      await repository.createNotebook();
      await database.close();

      await expectLater(repository.fetchNotebooks(), throwsA(anything));
    },
  );

  test(
    'metadata update preserves pages and blocks an older snapshot',
    () async {
      final database = NotesDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final repository = NotebookRepository(database);
      final notebook = await repository.createNotebook();

      final updated = await repository.updateNotebookMetadata(
        notebook.uid,
        title: 'Metadata-only rename',
      );

      expect(updated?.title, 'Metadata-only rename');
      expect(updated?.pages, hasLength(1));
      expect(await repository.saveNotebook(notebook), isFalse);
      final saved = await repository.getNotebook(notebook.uid);
      expect(saved?.title, 'Metadata-only rename');
      expect(saved?.pages, hasLength(1));
    },
  );

  test('corrupt stroke does not hide its notebook or page', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final readErrors = <Object>[];
    final repository = NotebookRepository(
      database,
      readErrorHandler: (error, _, _) => readErrors.add(error),
    );
    final notebook = await repository.createNotebook();
    await database
        .into(database.inkStrokeRows)
        .insert(
          InkStrokeRowsCompanion.insert(
            uid: 'corrupt-stroke',
            pageUid: notebook.pages.single.id,
            colorValue: 0xFF000000,
            width: 2,
            toolIndex: 0,
            pointsJson: '{not valid json',
            sortIndex: 0,
          ),
        );

    final fetched = await repository.fetchNotebooks();

    expect(fetched, hasLength(1));
    expect(fetched.single.uid, notebook.uid);
    expect(fetched.single.pages, hasLength(1));
    expect(fetched.single.pages.single.inkStrokes, isEmpty);
    expect(repository.lastFetchSkippedCorruptRows, isTrue);
    expect(repository.lastCorruptNotebookIds, [notebook.uid]);
    expect(readErrors, hasLength(1));

    final partialUpdate = fetched.single.copyWith(
      updatedAt: DateTime.now().add(const Duration(minutes: 1)),
    );
    expect(await repository.saveNotebook(partialUpdate), isFalse);
    final corruptRows = await (database.select(
      database.inkStrokeRows,
    )..where((row) => row.uid.equals('corrupt-stroke'))).get();
    expect(corruptRows, hasLength(1));
  });
}
