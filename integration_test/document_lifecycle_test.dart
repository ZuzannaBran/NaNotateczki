import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:program/app/notes_app.dart';
import 'package:program/features/library/presentation/library_controller.dart';
import 'package:program/features/library/presentation/library_screen.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';

const _isolated = bool.fromEnvironment('NANOTATECZKI_ISOLATED_CI');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'isolated platform DB creates, persists, renames and deletes a board',
    (tester) async {
      await tester.pumpWidget(const NotesApp());

      for (var attempt = 0; attempt < 70; attempt++) {
        await tester.pump(const Duration(milliseconds: 200));
        if (find.byType(LibraryScreen).evaluate().isNotEmpty) {
          break;
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 75)),
        );
      }
      expect(find.byType(LibraryScreen), findsOneWidget);

      final context = tester.element(find.byType(LibraryScreen));
      final repository = Provider.of<NotebookRepository>(
        context,
        listen: false,
      );
      final library = Provider.of<LibraryController>(context, listen: false);

      final created = await library.createBoard();
      try {
        expect(created.kind, NotebookKind.board);
        final read = await repository.getNotebook(created.uid);
        expect(read?.uid, created.uid);
        expect(read?.pages, hasLength(1));

        final renamed = await repository.updateNotebookMetadata(
          created.uid,
          title: 'QA persisted board',
        );
        expect(renamed?.title, 'QA persisted board');

        await library.loadItems();
        final reloaded = await repository.getNotebook(created.uid);
        expect(reloaded?.title, 'QA persisted board');
        expect(library.items.any((item) => item.uid == created.uid), isTrue);
      } finally {
        await repository.deleteNotebook(created.uid);
        await library.loadItems();
      }

      expect(await repository.getNotebook(created.uid), isNull);
    },
    skip: !_isolated,
  );
}
