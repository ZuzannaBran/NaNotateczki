import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:program/data/backup/local_backup_service.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/cloud_sync_service.dart';
import 'package:program/features/library/presentation/library_catalog.dart';
import 'package:program/features/library/presentation/library_controller.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/notebook.dart';

import 'support/native_test_documents.dart';

void main() {
  useIsolatedNativeTestDocuments();
  useInMemoryTestTextStorage();

  test(
    'nested folders survive reload, rename and cascading deletion',
    () async {
      final database = NotesDatabase(NativeDatabase.memory());
      final repository = NotebookRepository(database);
      LibraryController newController() => LibraryController(
        repository,
        CloudSyncService(repository),
        LocalBackupService(repository),
      );
      final controller = newController();
      addTearDown(database.close);
      addTearDown(controller.dispose);
      await controller.initialize();

      expect(await controller.createFolder('Courses'), 'Courses');
      expect(
        await controller.createFolder('Math', parent: 'Courses'),
        'Courses/Math',
      );
      expect(
        await controller.createFolder('Lectures', parent: 'Courses/Math'),
        'Courses/Math/Lectures',
      );
      expect(await controller.createFolder('Art'), 'Art');
      expect(await controller.createFolder('Math', parent: 'Courses'), isNull);
      expect(await controller.createFolder('Invalid/Name'), isNull);
      expect(
        await controller.createFolder('Orphan', parent: 'Missing'),
        isNull,
      );
      expect(controller.childFoldersOf(null), ['Art', 'Courses']);
      expect(controller.childFoldersOf('Courses'), ['Courses/Math']);
      expect(controller.folderLabel('Courses/Math'), 'Math');

      await controller.updateFolderCover(
        'Courses/Math',
        const FolderCoverStyle(iconColor: Colors.blue),
      );
      final note = await repository.createNotebook(
        title: 'Lecture one',
        folder: 'Courses/Math/Lectures',
      );
      await controller.loadItems();
      await controller.selectItem(note.uid);
      expect(
        await controller.renameFolder('Courses/Math', 'Algebra'),
        'Courses/Algebra',
      );
      expect(controller.selectedFolder, 'Courses/Algebra/Lectures');
      expect(
        controller.folderCoverFor('Courses/Algebra').iconColor,
        Colors.blue,
      );
      expect(
        (await repository.getNotebook(note.uid))?.folder,
        'Courses/Algebra/Lectures',
      );

      final restored = newController();
      addTearDown(restored.dispose);
      await restored.initialize();
      expect(restored.folderNames, contains('Courses/Algebra/Lectures'));
      expect(restored.folderNames, isNot(contains('Courses/Math')));
      expect(
        restored.folderCoverFor('Courses/Algebra').iconColor?.toARGB32(),
        Colors.blue.toARGB32(),
      );
      await restored.deleteFolder('Courses/Algebra');
      expect(restored.childFoldersOf('Courses'), isEmpty);
      expect(restored.folderNames, containsAll(['Art', 'Courses']));
      expect(await repository.getNotebook(note.uid), isNull);
    },
  );

  testWidgets('catalog shows direct children and documents at each level', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late NotesDatabase database;
    late LibraryController controller;
    await tester.runAsync(() async {
      database = NotesDatabase(NativeDatabase.memory());
      final repository = NotebookRepository(database);
      controller = LibraryController(
        repository,
        CloudSyncService(repository),
        LocalBackupService(repository),
      );
      await controller.initialize();
      await controller.createFolder('Science');
      await controller.createFolder('Math', parent: 'Science');
      await repository.createNotebook(
        title: 'Science notebook',
        folder: 'Science',
      );
      await controller.loadItems();
    });
    addTearDown(database.close);
    addTearDown(controller.dispose);

    String? current;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, update) => LibraryCatalog(
            controller: controller,
            folder: current,
            onBack: () => update(() {
              current = current == null
                  ? null
                  : controller.parentFolderOf(current!);
            }),
            onFolderTap: (folder) => update(() => current = folder),
            onOpenItem: (Notebook item) {},
            onEditFolder: (_) {},
            onRenameFolder: (_) {},
            onDeleteFolder: (_) {},
            onRenameItem: (_) {},
            onDeleteItem: (_) {},
            onSettings: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('catalog-folder:Science')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('catalog-folder:Science/Math')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('catalog-folder:Science')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('catalog-folder:Science/Math')),
      findsOneWidget,
    );
    final nestedFolderCover = find.byKey(
      const ValueKey('catalog-folder-cover:Science/Math'),
    );
    final nestedFolderCoverSize = tester.getSize(nestedFolderCover);
    expect(nestedFolderCoverSize.width, nestedFolderCoverSize.height);
    expect(find.text('Math'), findsWidgets);
    expect(find.text('Science notebook'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('catalog-back')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('catalog-folder:Science')),
      findsOneWidget,
    );
  });

  testWidgets(
    'nested folder grid matches Projects independently of documents',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      late NotesDatabase database;
      late LibraryController controller;
      late Notebook note;
      await tester.runAsync(() async {
        database = NotesDatabase(NativeDatabase.memory());
        final repository = NotebookRepository(database);
        controller = LibraryController(
          repository,
          CloudSyncService(repository),
          LocalBackupService(repository),
        );
        await controller.initialize();
        await controller.createFolder('Root');
        for (var index = 1; index <= 7; index++) {
          await controller.createFolder('Child $index', parent: 'Root');
        }
        note = await repository.createNotebook(folder: 'Root');
        await repository.createBoard(folder: 'Root');
        await controller.loadItems();
      });
      addTearDown(database.close);
      addTearDown(controller.dispose);

      Widget catalog(String? folder) => MaterialApp(
        home: LibraryCatalog(
          controller: controller,
          folder: folder,
          onBack: () {},
          onFolderTap: (_) {},
          onOpenItem: (_) {},
          onEditFolder: (_) {},
          onRenameFolder: (_) {},
          onDeleteFolder: (_) {},
          onRenameItem: (_) {},
          onDeleteItem: (_) {},
          onSettings: () {},
        ),
      );

      await tester.pumpWidget(catalog(null));
      await tester.pumpAndSettle();
      final rootCover = tester.getSize(
        find.byKey(const ValueKey('catalog-folder-cover:Root')),
      );

      await tester.pumpWidget(catalog('Root'));
      await tester.pumpAndSettle();
      final folders = find.byKey(const ValueKey('catalog-folder-grid'));
      final documents = find.byKey(const ValueKey('catalog-document-grid'));
      final first = find.byKey(const ValueKey('catalog-folder:Root/Child 1'));
      final sixth = find.byKey(const ValueKey('catalog-folder:Root/Child 6'));
      final childCover = find.byKey(
        const ValueKey('catalog-folder-cover:Root/Child 1'),
      );
      expect(tester.getSize(childCover), rootCover);
      expect(tester.getSize(folders).width, 1230);
      expect(tester.getCenter(folders).dx, closeTo(800, 1));
      expect(tester.getSize(documents).width, 492);
      expect(tester.getCenter(documents).dx, closeTo(800, 1));
      expect(
        tester.getRect(sixth).top - tester.getRect(first).top,
        closeTo(292, 1),
      );
      expect(
        tester.getRect(documents).top,
        greaterThan(tester.getRect(sixth).bottom),
      );
      expect(
        find.byKey(ValueKey('catalog-document:${note.uid}')),
        findsOneWidget,
      );

      await tester.binding.setSurfaceSize(const Size(580, 900));
      await tester.pumpAndSettle();
      expect(tester.getSize(folders).width, 492);
      expect(tester.getSize(documents).width, 492);
      final third = find.byKey(
        const ValueKey('catalog-folder:Root/Child 3'),
      );
      expect(
        tester.getRect(third).top - tester.getRect(first).top,
        closeTo(292, 1),
      );
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
