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
  testWidgets('library locks wide layout below editor margin breakpoint', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1038, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final database = NotesDatabase(NativeDatabase.memory());
    final repository = NotebookRepository(database);
    final controller = LibraryController(
      repository,
      CloudSyncService(repository),
      LocalBackupService(repository),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<LibraryController>.value(
          value: controller,
          child: const LibraryScreen(),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Pick an item'), findsOneWidget);

    await tester.binding.setSurfaceSize(const Size(1037, 700));
    await tester.pump();

    expect(find.text('Pick an item'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await database.close();
  });
}
