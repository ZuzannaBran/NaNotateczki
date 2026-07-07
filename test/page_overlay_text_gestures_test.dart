import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:program/core/input/app_preferences_controller.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/features/editor/presentation/widgets/page_overlay.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';

void main() {
  testWidgets('text tool inserts once, exits, and reopens on double tap', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(700, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final database = NotesDatabase(NativeDatabase.memory());
    final preferences = AppPreferencesController();
    final controller = EditorController(
      repository: NotebookRepository(database),
      notebook: _notebook(),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<AppPreferencesController>.value(
              value: preferences,
            ),
            ChangeNotifierProvider<EditorController>.value(value: controller),
          ],
          child: Align(
            alignment: Alignment.topLeft,
            child: Consumer<EditorController>(
              builder: (context, value, _) => SizedBox(
                width: 600,
                height: 800,
                child: PageOverlay(controller: value),
              ),
            ),
          ),
        ),
      ),
    );

    controller.setTool(DrawingTool.text);
    await tester.pump();
    final overlayTopLeft = tester.getTopLeft(find.byType(PageOverlay));
    const insertPosition = Offset(120, 160);
    await tester.tapAt(overlayTopLeft + insertPosition);
    await tester.pump();

    expect(controller.pages.single.textBlocks, hasLength(1));
    expect(controller.activeTextBlockId, isNotNull);
    expect(controller.tool, DrawingTool.text);

    await tester.tapAt(overlayTopLeft + const Offset(500, 700));
    await tester.pump();

    expect(controller.pages.single.textBlocks, hasLength(1));
    expect(controller.activeTextBlockId, isNull);
    expect(controller.tool, DrawingTool.pen);

    final textPosition = overlayTopLeft + insertPosition + const Offset(40, 20);
    await tester.tapAt(textPosition);
    await tester.pump(kDoubleTapMinTime);
    await tester.tapAt(textPosition);
    await tester.pump();

    expect(controller.activeTextBlockId, isNotNull);
    expect(controller.tool, DrawingTool.text);

    await tester.pump(kDoubleTapTimeout);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    preferences.dispose();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await database.close();
  });
}

Notebook _notebook() {
  final now = DateTime(2026);
  return Notebook(
    uid: 'text-gestures',
    title: 'Text gestures',
    kind: NotebookKind.board,
    folder: 'Tests',
    createdAt: now,
    updatedAt: now,
    pages: [
      NotePage(
        id: 'page-1',
        title: 'Canvas',
        textBlocks: const [],
        imageBlocks: const [],
        inkStrokes: const [],
        isBookmarked: false,
        indexTabs: const [],
      ),
    ],
  );
}
