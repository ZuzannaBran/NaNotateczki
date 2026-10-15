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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
}
