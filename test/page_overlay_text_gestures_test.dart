import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_box_transform/flutter_box_transform.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:program/core/input/app_preferences_controller.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/features/editor/presentation/widgets/page_overlay.dart';
import 'package:program/features/editor/presentation/widgets/text_hud_block.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';

void main() {
  testWidgets('inserted text starts selected in edit mode and reopens', (
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

    controller.setTool(DrawingTool.edit);
    controller.setActiveImageBlock('background-image');
    expect(controller.activeImageBlockId, 'background-image');

    controller.setTool(DrawingTool.text);
    expect(controller.activeImageBlockId, isNull);
    await tester.pump();
    final overlayTopLeft = tester.getTopLeft(find.byType(PageOverlay));
    const insertPosition = Offset(120, 160);
    await tester.tapAt(overlayTopLeft + insertPosition);
    await tester.pump();

    expect(controller.pages.single.textBlocks, hasLength(1));
    expect(controller.activeTextBlockId, isNotNull);
    expect(controller.activeImageBlockId, isNull);
    expect(controller.tool, DrawingTool.edit);
    expect(controller.pages.single.textBlocks.single.position, insertPosition);
    expect(find.byType(TextHudBlock), findsOneWidget);

    await tester.tapAt(overlayTopLeft + const Offset(500, 700));
    await tester.pump();

    expect(controller.pages.single.textBlocks, hasLength(1));
    expect(controller.activeTextBlockId, isNull);
    expect(controller.tool, DrawingTool.edit);
    expect(find.byType(TextHudBlock), findsNothing);

    final inactiveEditor = find.byType(quill.QuillEditor);
    expect(inactiveEditor, findsOneWidget);
    final textPosition = tester.getCenter(inactiveEditor);
    await tester.tapAt(textPosition);
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 1));

    expect(controller.activeTextBlockId, isNotNull);
    expect(controller.tool, DrawingTool.edit);
    expect(find.byType(TextHudBlock), findsOneWidget);

    await tester.tapAt(textPosition);
    await tester.pump(kDoubleTapMinTime);
    await tester.tapAt(textPosition);
    await tester.pump();

    expect(controller.activeTextBlockId, isNotNull);
    expect(controller.tool, DrawingTool.text);
    expect(find.byType(EditableText), findsOneWidget);
    expect(find.byType(DefaultCornerHandle), findsNWidgets(4));
    expect(find.byType(DefaultSideHandle), findsOneWidget);
    expect(
      find.byKey(const ValueKey('object-transform-move-handle')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.rotate_right), findsNothing);

    await tester.enterText(find.byType(EditableText), 'Edited text');
    await tester.pump();
    expect(controller.pages.single.textBlocks.single.text, 'Edited text');

    final positionBeforeMove =
        controller.pages.single.textBlocks.single.position;
    await tester.drag(
      find.byKey(const ValueKey('object-transform-move-handle')),
      const Offset(36, 24),
    );
    await tester.pump();

    final movedBlock = controller.pages.single.textBlocks.single;
    expect(movedBlock.text, 'Edited text');
    expect(movedBlock.position.dx, greaterThan(positionBeforeMove.dx));
    expect(movedBlock.position.dy, greaterThan(positionBeforeMove.dy));
    expect(controller.tool, DrawingTool.text);
    expect(find.byType(EditableText), findsOneWidget);

    final widthBeforeResize = movedBlock.width;
    final sideHandle = find.byType(DefaultSideHandle);
    final gesture = await tester.startGesture(tester.getCenter(sideHandle));
    await gesture.moveBy(const Offset(4, 0));
    await tester.pump();

    final liveResizeBlock = controller.pages.single.textBlocks.single;
    expect(liveResizeBlock.width, greaterThan(widthBeforeResize));

    await gesture.up();
    await tester.pump();

    final resizedBlock = controller.pages.single.textBlocks.single;
    expect(resizedBlock.text, 'Edited text');
    expect(resizedBlock.width, greaterThan(widthBeforeResize));

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
      ),
    ],
  );
}
