import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_box_transform/flutter_box_transform.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:program/core/input/app_preferences_controller.dart';
import 'package:program/core/theme/app_colors.dart';
import 'package:program/core/theme/app_theme.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/features/editor/presentation/interaction/object_transform_engine.dart';
import 'package:program/features/editor/presentation/widgets/object_transform_hud.dart';
import 'package:program/features/editor/presentation/widgets/page_overlay.dart';
import 'package:program/features/editor/presentation/widgets/text_edit_toolbar.dart';
import 'package:program/features/editor/presentation/widgets/text_hud_block.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';
import 'package:program/features/notebook/domain/text_block.dart';

void main() {
  test('transform handle hit area scales with frame size', () {
    const style = ObjectTransformHudStyle();

    final small = style.handleHitSizeForRect(const Rect.fromLTWH(0, 0, 80, 40));
    final medium = style.handleHitSizeForRect(
      const Rect.fromLTWH(0, 0, 320, 120),
    );
    final large = style.handleHitSizeForRect(
      const Rect.fromLTWH(0, 0, 900, 700),
    );

    expect(small, 32);
    expect(medium, greaterThan(small));
    expect(large, greaterThan(medium));
    expect(large, 80);
  });

  testWidgets('top resize and move hit areas meet halfway for every size', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1150));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    for (final size in [
      const Size(24, 24),
      const Size(80, 40),
      const Size(320, 120),
      const Size(900, 700),
    ]) {
      ObjectTransformKind? lastKind;
      final rect = Rect.fromLTWH(140, 200, size.width, size.height);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                ObjectTransformHud<int>(
                  data: 1,
                  rect: rect,
                  rotation: 0,
                  onPreview: (_, preview) => lastKind = preview.kind,
                  onCommit: (_, _) {},
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      final topHandle = tester.getRect(
        find.byKey(const ValueKey('object-transform-top-hit-zone')),
      );
      final moveHandle = tester.getRect(
        find.byKey(const ValueKey('object-transform-move-hit-zone')),
      );
      final topLeft = tester.getRect(
        find.byKey(const ValueKey('object-transform-topLeft-hit-zone')),
      );
      final topRight = tester.getRect(
        find.byKey(const ValueKey('object-transform-topRight-hit-zone')),
      );
      final midpoint =
          rect.top - const ObjectTransformHudStyle().moveHandleOffset / 2;
      expect(moveHandle.bottom, closeTo(midpoint, 0.01));
      expect(topHandle.top, closeTo(midpoint, 0.01));
      expect(topLeft.top, closeTo(midpoint, 0.01));
      expect(topRight.top, closeTo(midpoint, 0.01));
      expect(moveHandle.bottom, lessThanOrEqualTo(topHandle.top));

      final grab = await tester.startGesture(
        Offset(rect.center.dx, midpoint - 2),
      );
      await grab.moveBy(const Offset(4, 0));
      await tester.pump();
      expect(lastKind, ObjectTransformKind.move);
      await grab.up();
      await tester.pump();

      final resize = await tester.startGesture(
        Offset(rect.center.dx, midpoint + 2),
      );
      await resize.moveBy(const Offset(0, -4));
      await tester.pump();
      expect(lastKind, ObjectTransformKind.resize);
      await resize.up();
      await tester.pump();
    }

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('block text toolbar applies only supported formatting', (
    tester,
  ) async {
    final database = NotesDatabase(NativeDatabase.memory());
    final controller = EditorController(
      repository: NotebookRepository(database),
      notebook: _notebook(),
    );

    controller.addTextBlock(const Offset(40, 50));
    controller.setTool(DrawingTool.text);
    final block = controller.pages.single.textBlocks.single;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextEditToolbar(editorController: controller, block: block),
        ),
      ),
    );

    expect(find.byIcon(Icons.format_bold), findsOneWidget);
    expect(find.byIcon(Icons.format_list_bulleted), findsNothing);

    await tester.tap(find.byIcon(Icons.format_bold));
    await tester.pump();

    final formatted = controller.pages.single.textBlocks.single;
    expect(formatted.deltaJson, contains('"bold":true'));
    expect(controller.activeTextBlockId, block.id);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await database.close();
  });

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
    expect(controller.isObjectTransformActive, isTrue);

    final viewPanBeforeResize = controller.viewPan;
    final viewScaleBeforeResize = controller.viewScale;
    controller.panBy(const Offset(100, 50));
    controller.zoomBy(1.5, focalPoint: const Offset(200, 200));
    expect(controller.viewPan, viewPanBeforeResize);
    expect(controller.viewScale, viewScaleBeforeResize);

    await gesture.moveBy(const Offset(4, 0));
    await tester.pump();

    final liveResizeBlock = controller.pages.single.textBlocks.single;
    expect(liveResizeBlock.width, greaterThan(widthBeforeResize));

    await gesture.up();
    await tester.pump();
    expect(controller.isObjectTransformActive, isFalse);

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

  testWidgets('legacy rich text inverts without changing its saved delta', (
    tester,
  ) async {
    final database = NotesDatabase(NativeDatabase.memory());
    const firstColor = Color(0xFFBBDCFB);
    const secondColor = Color(0xFF203E85);
    final deltaJson = jsonEncode([
      {
        'insert': 'Pale blue ',
        'attributes': {'color': '#BBDCFB', 'bold': true},
      },
      {
        'insert': 'Deep blue',
        'attributes': {'color': '#203E85'},
      },
      {'insert': '\n'},
    ]);
    final block = TextBlock(
      id: 'legacy-colored-text',
      text: 'Pale blue Deep blue',
      position: const Offset(30, 40),
      fontSize: 18,
      color: firstColor,
      width: 260,
      deltaJson: deltaJson,
    );
    final notebook = _notebook();
    final controller = EditorController(
      repository: NotebookRepository(database),
      notebook: notebook.copyWith(
        pages: [
          notebook.pages.single.copyWith(textBlocks: [block]),
        ],
      ),
    );

    Widget screen(bool darkMode) => MaterialApp(
      theme: darkMode ? AppTheme.dark() : AppTheme.light(),
      home: ChangeNotifierProvider<EditorController>.value(
        value: controller,
        child: Scaffold(
          body: SizedBox(
            width: 600,
            height: 360,
            child: PageOverlay(
              controller: controller,
              renderBackground: false,
            ),
          ),
        ),
      ),
    );

    String displayedColor(int index) {
      final editor = tester.widget<quill.QuillEditor>(
        find.byType(quill.QuillEditor).first,
      );
      final operation = editor.controller.document.toDelta().toJson()[index];
      final attributes = operation['attributes'] as Map;
      return attributes['color'] as String;
    }

    String hex(Color color) => '#${color.toARGB32().toRadixString(16)
        .padLeft(8, '0').substring(2)}';

    await tester.pumpWidget(screen(false));
    await tester.pump();
    expect(displayedColor(0).toLowerCase(), '#bbdcfb');
    expect(displayedColor(1).toLowerCase(), '#203e85');

    await tester.pumpWidget(screen(true));
    await tester.pump();
    expect(
      displayedColor(0),
      hex(AppColors.displayInkColor(firstColor, darkMode: true)),
    );
    expect(
      displayedColor(1),
      hex(AppColors.displayInkColor(secondColor, darkMode: true)),
    );
    expect(controller.pages.single.textBlocks.single.deltaJson, deltaJson);

    await tester.pumpWidget(screen(false));
    await tester.pump();
    expect(displayedColor(0).toLowerCase(), '#bbdcfb');
    expect(displayedColor(1).toLowerCase(), '#203e85');
    expect(controller.pages.single.textBlocks.single.deltaJson, deltaJson);

    await tester.pumpWidget(screen(true));
    await tester.pump();
    controller.setTool(DrawingTool.text);
    controller.setActiveTextBlock(block.id, null);
    await tester.pump();
    expect(find.byType(TextHudBlock), findsOneWidget);
    final activeText = tester.widget<EditableText>(
      find.byType(EditableText).first,
    );
    expect(
      activeText.style.color,
      AppColors.displayInkColor(firstColor, darkMode: true),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
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
