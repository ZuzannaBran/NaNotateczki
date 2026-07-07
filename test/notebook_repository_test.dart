import 'dart:ui';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:program/core/diagnostics/data_integrity_log.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/drift/notes_database_connection.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';
import 'package:program/features/notebook/domain/notebook.dart';
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
    'saveNotebookPages updates one page and refreshes backup cache',
    () async {
      final database = NotesDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final repository = NotebookRepository(database);
      final notebook = await repository.createNotebook();
      final secondPage = NotePage(
        id: 'second-page',
        title: 'Second page',
        textBlocks: const [],
        imageBlocks: const [],
        inkStrokes: const [],
        isBookmarked: false,
        indexTabs: const [],
      );
      final twoPages = notebook.copyWith(
        pages: [...notebook.pages, secondPage],
        updatedAt: notebook.updatedAt.add(const Duration(seconds: 1)),
      );
      await repository.saveNotebook(twoPages);
      await repository.fetchNotebooks();

      final changedPage = twoPages.pages.first.copyWith(title: 'Changed page');
      final changed = twoPages.copyWith(
        pages: [changedPage, secondPage],
        updatedAt: twoPages.updatedAt.add(const Duration(seconds: 1)),
      );

      expect(
        await repository.saveNotebookPages(changed, {changedPage.id}),
        isTrue,
      );
      final saved = await repository.getNotebook(notebook.uid);
      expect(saved?.pages.map((page) => page.title), [
        'Changed page',
        'Second page',
      ]);
      expect(
        repository.cachedNotebooks?.single.pages.first.title,
        'Changed page',
      );
    },
  );

  test('saveNotebookPages rolls back when replacing a page fails', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final notebook = await repository.createNotebook();
    final duplicateStroke = InkStroke(
      id: 'duplicate-stroke',
      points: const [InkPoint(dx: 1, dy: 1, pressure: 0.5)],
      color: const Color(0xFF000000),
      width: 2,
      tool: DrawingTool.pen,
    );
    final brokenPage = notebook.pages.single.copyWith(
      title: 'Must roll back',
      inkStrokes: [duplicateStroke, duplicateStroke],
    );
    final broken = notebook.copyWith(
      pages: [brokenPage],
      updatedAt: notebook.updatedAt.add(const Duration(seconds: 1)),
    );

    await expectLater(
      repository.saveNotebookPages(broken, {brokenPage.id}),
      throwsA(anything),
    );

    final saved = await repository.getNotebook(notebook.uid);
    expect(saved?.pages.single.title, 'Page 1');
    expect(saved?.pages.single.inkStrokes, isEmpty);
  });

  test('local page save advances a future persisted timestamp', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(database);
    final notebook = await repository.createNotebook();
    final future = notebook.copyWith(
      updatedAt: notebook.updatedAt.add(const Duration(days: 1)),
    );
    expect(await repository.saveNotebook(future), isTrue);

    final changedPage = future.pages.single.copyWith(title: 'Clock safe');
    final clockWentBack = future.copyWith(
      pages: [changedPage],
      updatedAt: notebook.updatedAt,
    );
    expect(
      await repository.saveNotebookPages(clockWentBack, {changedPage.id}),
      isTrue,
    );

    final saved = await repository.getNotebook(notebook.uid);
    expect(saved?.pages.single.title, 'Clock safe');
    expect(saved!.updatedAt.isAfter(future.updatedAt), isTrue);
  });

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

  test('suspicious full save records before and attempted evidence', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final incidents = <DataIntegrityIncident>[];
    final beforeSnapshots = <Notebook>[];
    final attemptedSnapshots = <Notebook>[];
    final repository = NotebookRepository(
      database,
      dataIntegrityIncidentHandler: (incident, before, attempted) async {
        incidents.add(incident);
        beforeSnapshots.add(before);
        attemptedSnapshots.add(attempted);
      },
    );
    final notebook = await repository.createNotebook();
    final stroke = InkStroke(
      id: 'important-stroke',
      points: const [InkPoint(dx: 10, dy: 20, pressure: 0.7)],
      color: const Color(0xFF000000),
      width: 2,
      tool: DrawingTool.pen,
    );
    final withContent = notebook.copyWith(
      updatedAt: notebook.updatedAt.add(const Duration(seconds: 1)),
      pages: [
        notebook.pages.single.copyWith(inkStrokes: [stroke]),
      ],
    );
    expect(await repository.saveNotebook(withContent), isTrue);

    final emptied = withContent.copyWith(
      updatedAt: withContent.updatedAt.add(const Duration(seconds: 1)),
      pages: [withContent.pages.single.copyWith(inkStrokes: const [])],
    );
    expect(await repository.saveNotebook(emptied), isTrue);

    expect(incidents, hasLength(1));
    expect(incidents.single.operation, 'saveNotebook');
    expect(incidents.single.notebookUid, notebook.uid);
    expect(incidents.single.reasons, contains('all_content_removed'));
    expect(incidents.single.before['inkStrokes'], 1);
    expect(incidents.single.attempted['inkStrokes'], 0);
    expect(incidents.single.stackTrace, contains('saveNotebook'));
    expect(beforeSnapshots.single.pages.single.inkStrokes, hasLength(1));
    expect(attemptedSnapshots.single.pages.single.inkStrokes, isEmpty);
  });

  test('suspicious page save identifies the affected page', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final incidents = <DataIntegrityIncident>[];
    final repository = NotebookRepository(
      database,
      dataIntegrityIncidentHandler: (incident, _, _) async {
        incidents.add(incident);
      },
    );
    final notebook = await repository.createNotebook();
    final stroke = InkStroke(
      id: 'page-stroke',
      points: const [InkPoint(dx: 1, dy: 2, pressure: 0.5)],
      color: const Color(0xFF000000),
      width: 2,
      tool: DrawingTool.pen,
    );
    final pageWithContent = notebook.pages.single.copyWith(
      inkStrokes: [stroke],
    );
    final withContent = notebook.copyWith(
      updatedAt: notebook.updatedAt.add(const Duration(seconds: 1)),
      pages: [pageWithContent],
    );
    expect(await repository.saveNotebook(withContent), isTrue);

    final emptiedPage = pageWithContent.copyWith(inkStrokes: const []);
    final emptied = withContent.copyWith(
      updatedAt: withContent.updatedAt.add(const Duration(seconds: 1)),
      pages: [emptiedPage],
    );
    expect(
      await repository.saveNotebookPages(emptied, {emptiedPage.id}),
      isTrue,
    );

    expect(incidents, hasLength(1));
    expect(incidents.single.operation, 'saveNotebookPages');
    expect(incidents.single.affectedPageIds, [emptiedPage.id]);
    expect(
      incidents.single.reasons,
      contains('page:${emptiedPage.id}:all_content_removed'),
    );
  });

  test(
    'ordinary content update does not create an integrity incident',
    () async {
      final database = NotesDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final incidents = <DataIntegrityIncident>[];
      final repository = NotebookRepository(
        database,
        dataIntegrityIncidentHandler: (incident, _, _) async {
          incidents.add(incident);
        },
      );
      final notebook = await repository.createNotebook();
      final changed = notebook.copyWith(
        title: 'Ordinary rename',
        updatedAt: notebook.updatedAt.add(const Duration(seconds: 1)),
      );

      expect(await repository.saveNotebook(changed), isTrue);
      expect(incidents, isEmpty);
    },
  );

  test('failed evidence recording prevents a suspicious overwrite', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final repository = NotebookRepository(
      database,
      dataIntegrityIncidentHandler: (_, _, _) async {
        throw StateError('evidence storage unavailable');
      },
    );
    final notebook = await repository.createNotebook();
    final stroke = InkStroke(
      id: 'protected-stroke',
      points: const [InkPoint(dx: 4, dy: 5, pressure: 0.8)],
      color: const Color(0xFF000000),
      width: 2,
      tool: DrawingTool.pen,
    );
    final withContent = notebook.copyWith(
      updatedAt: notebook.updatedAt.add(const Duration(seconds: 1)),
      pages: [
        notebook.pages.single.copyWith(inkStrokes: [stroke]),
      ],
    );
    expect(await repository.saveNotebook(withContent), isTrue);
    final emptied = withContent.copyWith(
      updatedAt: withContent.updatedAt.add(const Duration(seconds: 1)),
      pages: [withContent.pages.single.copyWith(inkStrokes: const [])],
    );

    await expectLater(
      repository.saveNotebook(emptied),
      throwsA(isA<StateError>()),
    );
    final persisted = await repository.getNotebook(notebook.uid);
    expect(persisted?.pages.single.inkStrokes, hasLength(1));
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
