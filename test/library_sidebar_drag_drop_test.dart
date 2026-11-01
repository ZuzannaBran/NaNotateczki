import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:program/data/backup/local_backup_service.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/cloud_sync_service.dart';
import 'package:program/features/library/presentation/library_controller.dart';
import 'package:program/features/library/presentation/library_screen.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';

import 'support/native_test_documents.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useIsolatedNativeTestDocuments();
  useInMemoryTestTextStorage();

  test('move keeps selection and persists notebooks and boards', () async {
    final database = NotesDatabase(NativeDatabase.memory());
    final repository = NotebookRepository(database);
    final note = await repository.createNotebook(
      title: 'Source notebook',
      folder: 'Source',
    );
    final board = await repository.createBoard(
      title: 'Source board',
      folder: 'Source',
    );
    await repository.createNotebook(folder: 'Destination');
    final controller = LibraryController(
      repository,
      CloudSyncService(repository),
      LocalBackupService(repository),
    );
    await controller.loadItems();
    await controller.selectItem(note.uid);

    expect(await controller.moveItemToFolder(note.uid, 'Missing'), isFalse);
    expect(await controller.moveItemToFolder(note.uid, 'Source'), isFalse);
    expect(
      await controller.moveItemToFolder('missing-id', 'Destination'),
      isFalse,
    );
    expect(await controller.moveItemToFolder(note.uid, 'Destination'), isTrue);
    expect(controller.selectedItemId, note.uid);
    expect(controller.selectedFolder, 'Destination');
    expect(controller.selectedItem()?.folder, 'Destination');

    expect(await controller.moveItemToFolder(board.uid, 'Destination'), isTrue);
    expect(
      controller.items.singleWhere((item) => item.uid == board.uid).folder,
      'Destination',
    );
    expect((await repository.getNotebook(note.uid))?.folder, 'Destination');
    expect((await repository.getNotebook(board.uid))?.folder, 'Destination');

    await controller.loadItems();
    expect(controller.items.where((item) => item.folder == 'Source'), isEmpty);
    expect(controller.selectedItemId, note.uid);
    controller.dispose();
    await database.close();
  });

  test(
    'folder move relocates its tree, covers and selected document',
    () async {
      final database = NotesDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final repository = NotebookRepository(database);
      LibraryController newController() => LibraryController(
        repository,
        CloudSyncService(repository),
        LocalBackupService(repository),
      );
      final controller = newController();
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.createFolder('Source');
      await controller.createFolder('Child', parent: 'Source');
      await controller.createFolder('Destination');
      await controller.createFolder('Blocked');
      await controller.createFolder('Source', parent: 'Blocked');
      await controller.updateFolderCover(
        'Source/Child',
        const FolderCoverStyle(iconColor: Colors.blue),
      );
      final note = await repository.createNotebook(
        title: 'Nested note',
        folder: 'Source',
      );
      final board = await repository.createBoard(
        title: 'Nested board',
        folder: 'Source/Child',
      );
      await controller.loadItems();
      await controller.selectItem(board.uid);

      expect(
        controller.canMoveFolderToFolder('Source', 'Source/Child'),
        isFalse,
      );
      expect(controller.canMoveFolderToFolder('Source', 'Blocked'), isFalse);
      expect(await controller.moveFolderToFolder('Source', 'Blocked'), isNull);

      expect(
        await controller.moveFolderToFolder('Source', 'Destination'),
        'Destination/Source',
      );
      expect(controller.folderNames, isNot(contains('Source')));
      expect(
        controller.folderNames,
        containsAll(['Destination/Source', 'Destination/Source/Child']),
      );
      expect(
        controller.folderCoverFor('Destination/Source/Child').iconColor,
        Colors.blue,
      );
      expect(controller.selectedItemId, board.uid);
      expect(controller.selectedFolder, 'Destination/Source/Child');
      expect(controller.selectedItem()?.folder, 'Destination/Source/Child');
      expect(
        controller.items.singleWhere((item) => item.uid == note.uid).folder,
        'Destination/Source',
      );
      expect(
        controller.items.singleWhere((item) => item.uid == board.uid).folder,
        'Destination/Source/Child',
      );
      expect(
        controller.canMoveFolderToFolder('Destination', 'Destination/Source'),
        isFalse,
      );

      final restored = newController();
      addTearDown(restored.dispose);
      await restored.initialize();
      expect(restored.folderNames, contains('Destination/Source/Child'));
      expect(
        (await repository.getNotebook(board.uid))?.folder,
        'Destination/Source/Child',
      );
    },
  );

  testWidgets('long press drops notebook and board onto collapsed folder', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final database = NotesDatabase(NativeDatabase.memory());
    final repository = NotebookRepository(database);
    final note = await repository.createNotebook(
      title: 'Dragged notebook',
      folder: 'Source',
    );
    final board = await repository.createBoard(
      title: 'Dragged board',
      folder: 'Source',
    );
    await repository.createNotebook(
      title: 'Destination seed',
      folder: 'Destination',
    );
    final controller = LibraryController(
      repository,
      CloudSyncService(repository),
      LocalBackupService(repository),
    );
    await controller.loadItems();

    await tester.pumpWidget(
      MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<LibraryController>.value(value: controller),
            Provider<NotebookRepository>.value(value: repository),
          ],
          child: const LibraryScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Collapse Destination'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Expand Destination'), findsOneWidget);

    Future<void> dragToDestination(String uid) async {
      final source = find.byKey(ValueKey('library-tree-item:$uid'));
      final destination = find.byKey(
        const ValueKey('library-folder-drop:Destination'),
      );
      final draggable = find.ancestor(
        of: source,
        matching: find.byType(LongPressDraggable<String>),
      );
      expect(
        tester.widget<LongPressDraggable<String>>(draggable).axis,
        Axis.vertical,
      );
      final originalSize = tester.getSize(source);
      final gesture = await tester.startGesture(tester.getCenter(source));
      await tester.pump(const Duration(milliseconds: 700));

      final feedback = find.byKey(ValueKey('library-tree-drag-feedback:$uid'));
      expect(feedback, findsOneWidget);
      expect(tester.getSize(feedback), originalSize);
      expect(
        find.descendant(
          of: feedback,
          matching: find.text(uid == note.uid ? note.title : board.title),
        ),
        findsOneWidget,
      );

      final colors = Theme.of(tester.element(source)).colorScheme;
      final highlightedMaterial = tester.widget<Material>(
        find.descendant(of: feedback, matching: find.byType(Material)).first,
      );
      expect(
        highlightedMaterial.color,
        Color.alphaBlend(
          colors.onSurface.withValues(alpha: 0.10),
          colors.surfaceContainerHighest,
        ),
      );

      final initialFeedbackLeft = tester.getTopLeft(feedback).dx;
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump();
      expect(tester.getTopLeft(feedback).dx, closeTo(initialFeedbackLeft, 0.5));
      await gesture.moveTo(tester.getCenter(destination));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pumpAndSettle();
    }

    await dragToDestination(note.uid);
    expect((await repository.getNotebook(note.uid))?.folder, 'Destination');
    expect(find.byTooltip('Collapse Destination'), findsOneWidget);
    expect(
      find.byKey(ValueKey('library-tree-item:${note.uid}')),
      findsOneWidget,
    );

    await dragToDestination(board.uid);
    expect((await repository.getNotebook(board.uid))?.folder, 'Destination');
    expect(
      find.byKey(ValueKey('library-tree-item:${board.uid}')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await database.close();
  });

  testWidgets('dragged folder closes and moves its entire tree', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    late NotesDatabase database;
    late NotebookRepository repository;
    late LibraryController controller;
    late String noteId;
    await tester.runAsync(() async {
      database = NotesDatabase(NativeDatabase.memory());
      repository = NotebookRepository(database);
      controller = LibraryController(
        repository,
        CloudSyncService(repository),
        LocalBackupService(repository),
      );
      await controller.initialize();
      await controller.createFolder('Source');
      await controller.createFolder('Child', parent: 'Source');
      await controller.createFolder('Destination');
      final note = await repository.createNotebook(
        title: 'Moved with folder',
        folder: 'Source/Child',
      );
      noteId = note.uid;
      await controller.loadItems();
    });
    addTearDown(database.close);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<LibraryController>.value(value: controller),
            Provider<NotebookRepository>.value(value: repository),
          ],
          child: const LibraryScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final source = find.byKey(const ValueKey('library-folder-row:Source'));
    final child = find.byKey(const ValueKey('library-folder-row:Source/Child'));
    final destination = find.byKey(
      const ValueKey('library-folder-drop:Destination'),
    );
    expect(source, findsOneWidget);
    expect(child, findsOneWidget);

    final draggable = find.ancestor(
      of: source,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is LongPressDraggable && widget.axis == Axis.vertical,
      ),
    );
    expect(draggable, findsOneWidget);
    final originalSize = tester.getSize(source);
    final gesture = await tester.startGesture(tester.getCenter(source));
    await tester.pump(const Duration(milliseconds: 700));

    final feedback = find.byKey(
      const ValueKey('library-folder-drag-feedback:Source'),
    );
    expect(feedback, findsOneWidget);
    expect(tester.getSize(feedback), originalSize);
    expect(child, findsNothing);
    expect(
      find.descendant(of: feedback, matching: find.text('Source')),
      findsOneWidget,
    );
    for (final icon in [
      Icons.folder_outlined,
      Icons.folder_open_outlined,
    ]) {
      expect(
        find.descendant(of: feedback, matching: find.byIcon(icon)),
        findsNothing,
      );
    }
    expect(
      find.descendant(
        of: feedback,
        matching: find.byTooltip('Expand Source'),
      ),
      findsOneWidget,
    );

    final initialFeedbackLeft = tester.getTopLeft(feedback).dx;
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    expect(tester.getTopLeft(feedback).dx, closeTo(initialFeedbackLeft, 0.5));
    await gesture.moveTo(tester.getCenter(destination));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('library-folder-row:Source')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('library-folder-row:Destination/Source')),
      findsOneWidget,
    );
    expect(find.byTooltip('Collapse Destination'), findsOneWidget);
    expect(find.byTooltip('Expand Destination/Source'), findsOneWidget);
    expect(
      (await repository.getNotebook(noteId))?.folder,
      'Destination/Source/Child',
    );

    await tester.tap(find.byTooltip('Expand Destination/Source'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('library-folder-row:Destination/Source/Child')),
      findsOneWidget,
    );
    expect(find.byKey(ValueKey('library-tree-item:$noteId')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
