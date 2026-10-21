import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_box_transform/flutter_box_transform.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:program/core/input/app_preferences_controller.dart';
import 'package:program/core/theme/app_colors.dart';
import 'package:program/core/theme/app_theme.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/features/editor/presentation/editor_commands.dart';
import 'package:program/features/editor/presentation/interaction/object_transform_engine.dart';
import 'package:program/features/editor/presentation/widgets/object_transform_hud.dart';
import 'package:program/features/editor/presentation/widgets/page_overlay.dart';
import 'package:program/features/editor/presentation/widgets/text_edit_toolbar.dart';
import 'package:program/features/editor/presentation/widgets/text_hud_block.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/image_block.dart';
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';
import 'package:program/features/notebook/domain/text_block.dart';

import 'support/native_test_documents.dart';

void main() {
  useIsolatedNativeTestDocuments();
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


  testWidgets('font size menu is attached, compact and scrollable', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

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

    final button = find.byKey(
      const ValueKey('text-font-size-menu-button'),
    );
    final popupButton = tester.widget<PopupMenuButton<int>>(button);
    final sizes = popupButton
        .itemBuilder(tester.element(button))
        .map((item) => (item as PopupMenuItem<int>).value)
        .toList();
    expect(sizes, containsAll([8, 9, 10, 11, 96, 112, 128, 192]));

    await tester.tap(button);
    await tester.pumpAndSettle();

    final menu = find.ancestor(
      of: find.text('8').last,
      matching: find.byType(Material),
    ).first;
    final menuRect = tester.getRect(menu);
    final toolbarRect = tester.getRect(
      find.byKey(const ValueKey('text-toolbar-panel')),
    );
    expect(menuRect.top, closeTo(toolbarRect.bottom, 1));
    expect(menuRect.height, lessThanOrEqualTo(280));
    expect(menuRect.width, 72);

    final shape = tester.widget<Material>(menu).shape;
    expect(shape, isA<RoundedRectangleBorder>());
    expect(
      (shape! as RoundedRectangleBorder).borderRadius,
      const BorderRadius.only(
        bottomLeft: Radius.circular(12),
        bottomRight: Radius.circular(12),
      ),
    );

    final scrollable = find.descendant(
      of: menu,
      matching: find.byType(Scrollable),
    );
    expect(scrollable, findsOneWidget);

    await tester.tap(find.text('8').last);
    await tester.pumpAndSettle();
    expect(controller.pages.single.textBlocks.single.fontSize, 8);

    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('192').last,
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('192').last);
    await tester.pumpAndSettle();
    expect(controller.pages.single.textBlocks.single.fontSize, 192);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await database.close();
  });

  testWidgets('text color picker updates the chosen block after focus loss', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final database = NotesDatabase(NativeDatabase.memory());
    final preferences = AppPreferencesController();
    final notebook = _notebook();
    const initialColor = Color(0xFF1E1E1E);
    const selectedColor = Color(0xFFB02857);
    final block = TextBlock(
      id: 'colored-text',
      text: 'Selected text',
      position: const Offset(40, 150),
      width: 260,
      fontSize: 22,
      color: initialColor,
    );
    final controller = EditorController(
      repository: NotebookRepository(database),
      notebook: notebook.copyWith(
        pages: [
          notebook.pages.single.copyWith(textBlocks: [block]),
        ],
      ),
    );
    controller.setTool(DrawingTool.text);
    controller.setActiveTextBlock(block.id, null);

    await tester.pumpWidget(
      MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<AppPreferencesController>.value(
              value: preferences,
            ),
            ChangeNotifierProvider<EditorController>.value(value: controller),
          ],
          child: Scaffold(
            body: Stack(
              children: [
                Positioned.fill(
                  child: Consumer<EditorController>(
                    builder: (context, value, _) =>
                        PageOverlay(controller: value, renderBackground: false),
                  ),
                ),
                Consumer<EditorController>(
                  builder: (context, value, _) {
                    final selectedId = value.activeTextBlockId;
                    if (selectedId == null) {
                      return const SizedBox.shrink();
                    }
                    final selected = value.findTextBlockById(selectedId);
                    if (selected == null) {
                      return const SizedBox.shrink();
                    }
                    return TextEditToolbar(
                      editorController: value,
                      block: selected,
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(TextHudBlock), findsOneWidget);
    expect(
      tester.widget<EditableText>(find.byType(EditableText).first).style.color,
      initialColor,
    );

    await tester.tap(find.byTooltip('Text color'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '#B02857');
    await tester.pump();

    // A picker must target the block that opened it, even if focus changes.
    controller.clearActiveTextBlock();
    await tester.pump();
    expect(controller.activeTextBlockId, isNull);

    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();

    final updated = controller.findTextBlockById(block.id)!;
    expect(updated.color, selectedColor);
    expect(updated.deltaJson!.toLowerCase(), contains('#b02857'));

    controller.setActiveTextBlock(block.id, null);
    await tester.pump();
    expect(
      tester.widget<EditableText>(find.byType(EditableText).first).style.color,
      selectedColor,
    );

    controller.undo();
    await tester.pump();
    expect(controller.findTextBlockById(block.id)!.color, initialColor);
    controller.redo();
    await tester.pump();
    expect(controller.findTextBlockById(block.id)!.color, selectedColor);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    preferences.dispose();
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

    final inactiveEditor = find.byType(EditableText);
    expect(inactiveEditor, findsOneWidget);
    expect(tester.widget<EditableText>(inactiveEditor).readOnly, isTrue);
    final textPosition = tester.getCenter(inactiveEditor);
    await tester.tapAt(textPosition);
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 1));

    expect(controller.activeTextBlockId, isNotNull);
    expect(controller.activeTextController, isNull);
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

  testWidgets('ink tools pass through text and image hit areas', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final database = NotesDatabase(NativeDatabase.memory());
    final notebook = _notebook();
    final textBlock = TextBlock(
      id: 'existing-text',
      text: 'Text under ink',
      position: const Offset(40, 60),
      fontSize: 20,
      color: Colors.black,
      width: 200,
    );
    final imageBlock = ImageBlock(
      id: 'existing-image',
      path: '',
      ocrText: '',
      position: const Offset(250, 200),
      width: 180,
      height: 140,
    );
    final controller = EditorController(
      repository: NotebookRepository(database),
      notebook: notebook.copyWith(
        pages: [
          notebook.pages.single.copyWith(
            textBlocks: [textBlock],
            imageBlocks: [imageBlock],
          ),
        ],
      ),
    );
    var canvasPointerDowns = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: ChangeNotifierProvider<EditorController>.value(
          value: controller,
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 600,
                height: 500,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: (_) => canvasPointerDowns++,
                        child: const SizedBox.expand(),
                      ),
                    ),
                    Consumer<EditorController>(
                      builder: (context, editor, _) =>
                          PageOverlay(controller: editor),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final textEditors = find.byType(EditableText);
    expect(textEditors, findsWidgets);
    final textPosition = tester.getCenter(textEditors.first);
    final imageTarget = find.byKey(
      const ValueKey('page-image-hit-target-existing-image'),
    );
    expect(imageTarget, findsOneWidget);
    final imagePosition = tester.getCenter(imageTarget);
    for (final tool in [
      DrawingTool.pen,
      DrawingTool.highlighter,
      DrawingTool.eraserBrush,
      DrawingTool.rectangle,
    ]) {
      controller.setTool(tool);
      await tester.pump();
      for (final position in [textPosition, imagePosition]) {
        final previousDowns = canvasPointerDowns;
        await tester.tapAt(position);
        await tester.pump();
        expect(
          canvasPointerDowns,
          previousDowns + 1,
          reason: '$tool must pass the pointer to the ink canvas',
        );
        expect(controller.activeTextBlockId, isNull);
        expect(controller.activeImageBlockId, isNull);
        expect(controller.tool, tool);
      }
    }

    controller.setTool(DrawingTool.pen);
    await tester.pump();
    final previousDowns = canvasPointerDowns;
    await tester.tapAt(textPosition);
    await tester.pump(kDoubleTapMinTime);
    await tester.tapAt(textPosition);
    await tester.pump(kDoubleTapTimeout);
    expect(canvasPointerDowns, previousDowns + 2);
    expect(controller.tool, DrawingTool.pen);
    expect(controller.activeTextBlockId, isNull);

    controller.setTool(DrawingTool.edit);
    await tester.pump();
    await tester.tap(imageTarget);
    await tester.pump(kDoubleTapTimeout);
    expect(controller.activeImageBlockId, imageBlock.id);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await database.close();
  });

  testWidgets('legacy rich text inverts without changing its saved delta', (
    tester,
  ) async {
    final database = NotesDatabase(NativeDatabase.memory());
    final preferences = AppPreferencesController();
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
      themeAnimationDuration: Duration.zero,
      home: MultiProvider(
        providers: [
          ChangeNotifierProvider<AppPreferencesController>.value(
            value: preferences,
          ),
          ChangeNotifierProvider<EditorController>.value(value: controller),
        ],
        child: Scaffold(
          body: SizedBox(
            width: 600,
            height: 360,
            child: Consumer<EditorController>(
              builder: (context, value, _) =>
                  PageOverlay(controller: value, renderBackground: false),
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

    String hex(Color color) =>
        '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';

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
    preferences.dispose();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await database.close();
  });


  testWidgets('text wrapping and glyph positions remain fixed', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1100, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final database = NotesDatabase(NativeDatabase.memory());
    final preferences = AppPreferencesController();
    final notebook = _notebook();
    const content =
        'The creativity is required from the author. The motivation is '
        'needed. Next the idea has to be created. The product has to be '
        'published. Then the attention has to be given by the audience. '
        'The feedback has to be given by users. The thing has to be '
        'unique enough to make audience stay for the moment.';
    final block = TextBlock(
      id: 'stable-text-layout',
      text: content,
      position: const Offset(60, 90),
      fontSize: 22,
      color: const Color(0xFF243B54),
      width: 600,
      deltaJson: jsonEncode([
        {
          'insert': content.substring(0, 65),
          'attributes': {'size': '22', 'color': '#243B54'},
        },
        {
          'insert': content.substring(65),
          'attributes': {'size': '22', 'color': '#243B54'},
        },
        {'insert': '\n'},
      ]),
    );
    final controller = EditorController(
      repository: NotebookRepository(database),
      notebook: notebook.copyWith(
        pages: [notebook.pages.single.copyWith(textBlocks: [block])],
      ),
    );
    const characterOffsets = [0, 35, 60, 90, 120, 150, 180, 210, 240];

    for (final theme in [AppTheme.light(), AppTheme.dark()]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: MultiProvider(
            providers: [
              ChangeNotifierProvider<AppPreferencesController>.value(
                value: preferences,
              ),
              ChangeNotifierProvider<EditorController>.value(
                value: controller,
              ),
            ],
            child: Scaffold(
              body: SizedBox(
                width: 650,
                height: 620,
                child: Consumer<EditorController>(
                  builder: (context, editor, _) => PageOverlay(
                    controller: editor,
                    renderBackground: false,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      controller.setTool(DrawingTool.edit);
      controller.clearActiveTextBlock();
      await tester.pump();
      await tester.pump();

      final previewFinder = find.byType(EditableText);
      expect(find.byType(quill.QuillEditor), findsNothing);
      expect(previewFinder, findsOneWidget);
      final preview = tester.widget<EditableText>(previewFinder);
      expect(preview.readOnly, isTrue);
      final previewRect = tester.getRect(previewFinder);
      final previewRender =
          tester.state<EditableTextState>(previewFinder).renderEditable;
      final expectedCarets = characterOffsets
          .map(
            (offset) => previewRender.getLocalRectForCaret(
              TextPosition(offset: offset),
            ),
          )
          .toList();

      for (var iteration = 0; iteration < 2; iteration++) {
        controller.setTool(DrawingTool.text);
        controller.setActiveTextBlock(block.id, null);
        await tester.pump();
        await tester.pump();

        final editFinder = find.byType(EditableText);
        expect(editFinder, findsOneWidget);
        final edit = tester.widget<EditableText>(editFinder);
        expect(edit.readOnly, isFalse);
        expect(edit.style, preview.style);
        final activeRect = tester.getRect(editFinder);
        expect(activeRect.left, closeTo(previewRect.left, 0.1));
        expect(activeRect.top, closeTo(previewRect.top, 0.1));
        expect(activeRect.width, closeTo(previewRect.width, 0.1));
        expect(activeRect.height, closeTo(previewRect.height, 0.1));
        final editRender =
            tester.state<EditableTextState>(editFinder).renderEditable;
        for (var i = 0; i < characterOffsets.length; i++) {
          final caret = editRender.getLocalRectForCaret(
            TextPosition(offset: characterOffsets[i]),
          );
          expect(
            caret.top,
            closeTo(expectedCarets[i].top, 0.1),
            reason: 'line changed at offset ${characterOffsets[i]}',
          );
          expect(
            caret.left,
            closeTo(expectedCarets[i].left, 0.1),
            reason: 'glyph moved at offset ${characterOffsets[i]}',
          );
        }
        expect(
          controller.findTextBlockById(block.id)!.position,
          block.position,
        );
        expect(
          controller.findTextBlockById(block.id)!.fontSize,
          block.fontSize,
        );

        controller.setTool(DrawingTool.edit);
        controller.clearActiveTextBlock();
        await tester.pump();
        await tester.pump();
        expect(find.byType(quill.QuillEditor), findsNothing);
        final restoredFinder = find.byType(EditableText);
        final restoredRect = tester.getRect(restoredFinder);
        expect(restoredRect.left, closeTo(previewRect.left, 0.1));
        expect(restoredRect.top, closeTo(previewRect.top, 0.1));
        expect(restoredRect.width, closeTo(previewRect.width, 0.1));
        expect(restoredRect.height, closeTo(previewRect.height, 0.1));
        final restoredRender =
            tester.state<EditableTextState>(restoredFinder).renderEditable;
        for (var i = 0; i < characterOffsets.length; i++) {
          final caret = restoredRender.getLocalRectForCaret(
            TextPosition(offset: characterOffsets[i]),
          );
          expect(caret.top, closeTo(expectedCarets[i].top, 0.1));
          expect(caret.left, closeTo(expectedCarets[i].left, 0.1));
        }
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    preferences.dispose();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await database.close();
  });

  testWidgets('Delete edits text to the right and removes only empty blocks', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final database = NotesDatabase(NativeDatabase.memory());
    final preferences = AppPreferencesController();
    final notebook = _notebook();
    final block = TextBlock(
      id: 'delete-shortcut-text',
      text: 'AB',
      position: const Offset(40, 80),
      width: 260,
      fontSize: 22,
      color: const Color(0xFF1E1E1E),
    );
    final controller = EditorController(
      repository: NotebookRepository(database),
      notebook: notebook.copyWith(
        pages: [notebook.pages.single.copyWith(textBlocks: [block])],
      ),
    );
    controller.setTool(DrawingTool.text);
    controller.setActiveTextBlock(block.id, null);

    await tester.pumpWidget(
      MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<AppPreferencesController>.value(
              value: preferences,
            ),
            ChangeNotifierProvider<EditorController>.value(value: controller),
          ],
          child: Builder(
            builder: (context) {
              final current = context.watch<EditorController>();
              return EditorCommandShortcuts(
                enabled: current.activeTextController == null,
                commands: EditorCommands(
                  context: context,
                  controller: current,
                  insertPosition: () => Offset.zero,
                  runBusy: <T>(Future<T> Function() action) => action(),
                ),
                child: Scaffold(
                  body: SizedBox(
                    width: 600,
                    height: 500,
                    child: PageOverlay(
                      controller: current,
                      renderBackground: false,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    EditableText editable() =>
        tester.widget<EditableText>(find.byType(EditableText));
    expect(editable().focusNode.hasFocus, isTrue);

    editable().controller.selection = const TextSelection.collapsed(offset: 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    expect(controller.pages.single.textBlocks.single.text, 'AB');

    editable().controller.selection = const TextSelection.collapsed(offset: 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    expect(controller.pages.single.textBlocks.single.text, 'B');

    editable().controller.selection = const TextSelection.collapsed(offset: 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(controller.pages.single.textBlocks.single.text, '');
    expect(controller.pages.single.textBlocks, hasLength(1));

    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    expect(controller.pages.single.textBlocks, isEmpty);
    expect(controller.activeTextBlockId, isNull);

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
