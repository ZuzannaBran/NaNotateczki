import 'dart:io';
import 'dart:ui';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/backup/local_backup_service.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';

void main() {
  test('unchanged notebook reuses its incremental backup', () async {
    final directory = await Directory.systemTemp.createTemp('backup-test-');
    addTearDown(() => directory.delete(recursive: true));
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final service = LocalBackupService(
      NotebookRepository(database),
      documentsDirectory: () async => directory,
    );
    final notebook = _notebook();

    final first = await service.snapshot([notebook]);
    final second = await service.snapshot([notebook]);

    expect(first.changedCount, 1);
    expect(second.changedCount, 0);
    expect(second.unchangedCount, 1);
    expect(second.notebookReports.single.flattenMs, 0);
    expect(second.notebookReports.single.encodeMs, 0);
    expect(second.notebookReports.single.jsonMs, 0);
  });

  test('snapshot stops when ink becomes active', () async {
    final directory = await Directory.systemTemp.createTemp('backup-test-');
    addTearDown(() => directory.delete(recursive: true));
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final service = LocalBackupService(
      NotebookRepository(database),
      documentsDirectory: () async => directory,
    );

    await expectLater(
      service.snapshot([_notebook()], shouldInterrupt: () => true),
      throwsA(isA<BackupSnapshotInterrupted>()),
    );
  });

  test('snapshot interrupts an active backup worker', () async {
    final directory = await Directory.systemTemp.createTemp('backup-test-');
    addTearDown(() => directory.delete(recursive: true));
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final service = LocalBackupService(
      NotebookRepository(database),
      documentsDirectory: () async => directory,
    );
    final snapshotStates = <bool>[];
    service.snapshotInProgress.addListener(
      () => snapshotStates.add(service.snapshotInProgress.value),
    );
    var interruptChecks = 0;

    await expectLater(
      service.snapshot([
        _largeNotebook(),
      ], shouldInterrupt: () => ++interruptChecks >= 3),
      throwsA(isA<BackupSnapshotInterrupted>()),
    );

    expect(interruptChecks, greaterThanOrEqualTo(3));
    expect(service.snapshotInProgress.value, isFalse);
    expect(snapshotStates, containsAllInOrder([true, false]));
  });
}

Notebook _notebook() {
  final timestamp = DateTime.utc(2026, 1, 2, 3, 4, 5);
  return Notebook(
    uid: 'notebook',
    title: 'Notebook',
    kind: NotebookKind.notebook,
    folder: 'Notes',
    createdAt: timestamp,
    updatedAt: timestamp,
    pages: [
      NotePage(
        id: 'page',
        title: 'Page',
        textBlocks: const [],
        imageBlocks: const [],
        inkStrokes: [
          InkStroke(
            id: 'stroke',
            points: const [
              InkPoint(dx: 0, dy: 0, pressure: 0.5),
              InkPoint(dx: 10, dy: 10, pressure: 0.5),
            ],
            color: Color(0xFF000000),
            width: 2,
            tool: DrawingTool.pen,
          ),
        ],
        isBookmarked: false,
        indexTabs: const [],
      ),
    ],
  );
}

Notebook _largeNotebook() {
  final notebook = _notebook();
  final strokes =
      List<InkStroke>.generate(
        1200,
        (strokeIndex) => InkStroke(
          id: 'stroke-$strokeIndex',
          points: List<InkPoint>.generate(
            40,
            (pointIndex) => InkPoint(
              dx: pointIndex.toDouble(),
              dy: strokeIndex.toDouble(),
              pressure: 0.5,
            ),
          ),
          color: const Color(0xFF000000),
          width: 2,
          tool: DrawingTool.pen,
        ),
      )..add(
        InkStroke(
          id: 'eraser',
          points: List<InkPoint>.generate(
            200,
            (index) => InkPoint(dx: index / 5, dy: index * 6, pressure: 0.5),
          ),
          color: const Color(0xFF000000),
          width: 8,
          tool: DrawingTool.eraserBrush,
        ),
      );
  return notebook.copyWith(
    pages: [notebook.pages.single.copyWith(inkStrokes: strokes)],
  );
}
