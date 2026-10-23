import 'dart:ui' show PointerDeviceKind;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/features/editor/presentation/widgets/drawing_canvas.dart';
import 'package:program/features/editor/presentation/widgets/object_transform_hud.dart';
import 'package:program/features/editor/presentation/widgets/page_overlay.dart';
import 'package:program/features/editor/presentation/widgets/shape_edit_overlay.dart';
import 'package:program/features/editor/state/editor_actions.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';

import 'support/native_test_documents.dart';

InkStroke _shape(DrawingTool tool, List<Offset> points) => InkStroke(
  id: 'shape',
  points: [for (final point in points) InkPoint.fromOffset(point, 1)],
  color: const Color(0xFF222222),
  width: 3,
  tool: tool,
);

NotePage _page(InkStroke stroke) => NotePage(
  id: 'page',
  title: 'Page',
  textBlocks: const [],
  imageBlocks: const [],
  inkStrokes: [stroke],
  isBookmarked: false,
);

void main() {
  useIsolatedNativeTestDocuments();
  useInMemoryTestTextStorage();

  test('line and arrow expose exactly two endpoint handles', () {
    final line = _shape(
      DrawingTool.line,
      const [Offset(10, 20), Offset(110, 60)],
    );
    expect(ShapeEditGeometry.handles(line), [
      const Offset(10, 20),
      const Offset(110, 60),
    ]);
    final changed = ShapeEditGeometry.resized(
      line, 1, const Offset(25, -10),
    );
    expect(changed.points.last.toOffset(), const Offset(135, 50));

    final arrow = _shape(DrawingTool.arrow, const [
      Offset(0, 0),
      Offset(100, 0),
      Offset(82, 10),
      Offset(100, 0),
      Offset(82, -10),
    ]);
    expect(ShapeEditGeometry.handles(arrow), hasLength(2));
    final resized = ShapeEditGeometry.resized(
      arrow, 1, const Offset(40, 20),
    );
    expect(resized.points, hasLength(5));
    expect(resized.points[1].toOffset(), const Offset(140, 20));
  });

  test('rectangle and square have four editable corners', () {
    final rectangle = _shape(DrawingTool.rectangle, const [
      Offset(0, 0), Offset(100, 0), Offset(100, 50),
      Offset(0, 50), Offset(0, 0),
    ]);
    expect(ShapeEditGeometry.handles(rectangle), hasLength(4));
    final resized = ShapeEditGeometry.resized(
      rectangle, 0, const Offset(-20, -10),
    );
    expect(ShapeEditGeometry.bounds(resized), const Rect.fromLTRB(
      -20, -10, 100, 50,
    ));
    expect(resized.points.first.toOffset(),
        resized.points.last.toOffset());

    final square = _shape(DrawingTool.square, const [
      Offset(0, 0), Offset(50, 0), Offset(50, 50),
      Offset(0, 50), Offset(0, 0),
    ]);
    final updated = ShapeEditGeometry.resized(
      square, 2, const Offset(35, 10),
    );
    final bounds = ShapeEditGeometry.bounds(updated);
    expect(bounds.width, bounds.height);
    expect(ShapeEditGeometry.handles(updated), hasLength(4));
  });

  test('triangle has three editable vertices and stays closed', () {
    final triangle = _shape(DrawingTool.triangle, const [
      Offset(0, 60), Offset(100, 60), Offset(50, 0), Offset(0, 60),
    ]);
    expect(ShapeEditGeometry.handles(triangle), hasLength(3));
    final updated = ShapeEditGeometry.resized(
      triangle, 2, const Offset(20, -20),
    );
    expect(updated.points[2].toOffset(), const Offset(70, -20));
    expect(updated.points.last.toOffset(),
        updated.points.first.toOffset());
  });

  test('ellipse and circle have four axis handles', () {
    final ellipse = _shape(DrawingTool.ellipse, const [
      Offset(100, 30), Offset(50, 60), Offset(0, 30),
      Offset(50, 0), Offset(100, 30),
    ]);
    expect(ShapeEditGeometry.handles(ellipse), hasLength(4));
    final wider = ShapeEditGeometry.resized(
      ellipse, 1, const Offset(30, 0),
    );
    expect(ShapeEditGeometry.bounds(wider).width, closeTo(130, 0.001));

    final circle = _shape(DrawingTool.circle, const [
      Offset(50, 0), Offset(100, 50), Offset(50, 100),
      Offset(0, 50), Offset(50, 0),
    ]);
    final bigger = ShapeEditGeometry.resized(
      circle, 1, const Offset(40, 0),
    );
    final bounds = ShapeEditGeometry.bounds(bigger);
    expect(bounds.width, closeTo(bounds.height, 0.001));
  });

  test('block arrow uses three controls and can change height', () {
    final arrow = _shape(DrawingTool.blockArrow, const [
      Offset(0, 0), Offset(70, 0), Offset(70, -30),
      Offset(100, 25), Offset(70, 80), Offset(70, 50),
      Offset(0, 50), Offset(0, 0),
    ]);
    expect(ShapeEditGeometry.handles(arrow), hasLength(3));
    final updated = ShapeEditGeometry.resized(
      arrow, 2, const Offset(0, 25),
    );
    expect(ShapeEditGeometry.bounds(updated).bottom,
        greaterThan(ShapeEditGeometry.bounds(arrow).bottom));
  });

  test('moving keeps points and styling, hit zone excludes empty area', () {
    final line = _shape(DrawingTool.line, const [
      Offset(20, 20), Offset(80, 20),
    ]);
    final moved = ShapeEditGeometry.moved(line, const Offset(40, 30));
    expect(moved.points.first.toOffset(), const Offset(60, 50));
    expect(moved.width, line.width);
    expect(moved.color, line.color);
    expect(moved.id, line.id);
    expect(ShapeEditGeometry.hitTest(moved, const Offset(80, 50)), isTrue);
    expect(ShapeEditGeometry.hitTest(moved, const Offset(200, 200)), isFalse);
  });

  test('shape transform is undoable without losing its ID', () {
    final before = _shape(
      DrawingTool.line,
      const [Offset(0, 0), Offset(100, 0)],
    );
    final after = ShapeEditGeometry.moved(before, const Offset(15, 25));
    final action = UpdateInkStrokeAction(before: before, after: after);
    final applied = action.apply(_page(before));
    expect(applied.inkStrokes.single.points.first.toOffset(),
        const Offset(15, 25));
    final restored = action.revert(applied);
    expect(restored.inkStrokes.single.id, before.id);
    expect(restored.inkStrokes.single.points.first.toOffset(),
        const Offset(0, 0));
  });

  for (final kind in [NotebookKind.notebook, NotebookKind.board]) {
    testWidgets('holding a drawn line does not enter Move and preserves '
        'highlighter styling in $kind', (tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final database = NotesDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final controller = EditorController(
        repository: NotebookRepository(database),
        notebook: Notebook(
          uid: 'held-line-${kind.name}',
          title: 'Held line',
          kind: kind,
          folder: 'Tests',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          pages: [
            NotePage(
              id: 'page',
              title: 'Page',
              textBlocks: const [],
              imageBlocks: const [],
              inkStrokes: const [],
              isBookmarked: false,
            ),
          ],
        ),
      );
      addTearDown(controller.dispose);
      controller.setTool(DrawingTool.highlighter);
      controller.setColor(const Color(0xFF7798C0));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChangeNotifierProvider<EditorController>.value(
              value: controller,
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 400,
                  height: 400,
                  child: Builder(builder: (context) {
                    context.watch<EditorController>();
                    return kind == NotebookKind.board
                        ? const DrawingCanvas(pageIndex: 0)
                        : DocumentDrawingCanvas(
                            pages: controller.pages,
                            pageSize: const Size(400, 400),
                            pageGap: 0,
                          );
                  }),
                ),
              ),
            ),
          ),
        ),
      );

      final gesture = await tester.startGesture(
        const Offset(60, 80),
        kind: PointerDeviceKind.stylus,
      );
      await gesture.moveTo(const Offset(170, 80));
      await tester.pump(const Duration(milliseconds: 1250));
      await gesture.up();
      await tester.pump();

      final stroke = controller.pageAt(0).inkStrokes.single;
      expect(stroke.tool, DrawingTool.line);
      expect(stroke.width, 20);
      expect(stroke.color.a, closeTo(0.5, 0.01));
      expect(stroke.usesHighlighterStrokeCap, isTrue);
      expect(controller.activeShapeStrokeId, isNull);
      expect(controller.tool, DrawingTool.highlighter);

      final resized = ShapeEditGeometry.resized(
        stroke, 1, const Offset(15, 0),
      );
      expect(resized.color, stroke.color);
      expect(resized.width, stroke.width);
      expect(resized.usesHighlighterStrokeCap, isTrue);
    });


    for (final inkTool in [DrawingTool.pen, DrawingTool.highlighter]) {
      for (final recognizedTool in [
        DrawingTool.rectangle,
        DrawingTool.ellipse,
      ]) {
        testWidgets(
          'held ${recognizedTool.name} keeps ${inkTool.name} tool '
          'in ${kind.name}',
          (tester) async {
            await tester.binding.setSurfaceSize(const Size(600, 600));
            addTearDown(() => tester.binding.setSurfaceSize(null));
            final database = NotesDatabase(NativeDatabase.memory());
            addTearDown(database.close);
            final controller = EditorController(
              repository: NotebookRepository(database),
              notebook: Notebook(
                uid: 'held-${recognizedTool.name}-${inkTool.name}-${kind.name}',
                title: 'Held shape',
                kind: kind,
                folder: 'Tests',
                createdAt: DateTime(2026),
                updatedAt: DateTime(2026),
                pages: [
                  NotePage(
                    id: 'page',
                    title: 'Page',
                    textBlocks: const [],
                    imageBlocks: const [],
                    inkStrokes: const [],
                    isBookmarked: false,
                  ),
                ],
              ),
            );
            addTearDown(controller.dispose);
            controller.setTool(inkTool);
            controller.setColor(const Color(0xFF7798C0));
            await tester.pumpWidget(
              MaterialApp(
                home: Scaffold(
                  body: ChangeNotifierProvider<EditorController>.value(
                    value: controller,
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: 400,
                        height: 400,
                        child: Builder(
                          builder: (context) {
                            context.watch<EditorController>();
                            return kind == NotebookKind.board
                                ? const DrawingCanvas(pageIndex: 0)
                                : DocumentDrawingCanvas(
                                    pages: controller.pages,
                                    pageSize: const Size(400, 400),
                                    pageGap: 0,
                                  );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );

            final path = recognizedTool == DrawingTool.rectangle
                ? const <Offset>[
                    Offset(70, 80),
                    Offset(180, 80),
                    Offset(180, 160),
                    Offset(70, 160),
                    Offset(70, 80),
                  ]
                : const <Offset>[
                    Offset(120, 80),
                    Offset(160, 90),
                    Offset(180, 120),
                    Offset(160, 150),
                    Offset(120, 160),
                    Offset(80, 150),
                    Offset(60, 120),
                    Offset(80, 90),
                    Offset(120, 80),
                  ];
            final gesture = await tester.startGesture(
              path.first,
              kind: PointerDeviceKind.stylus,
            );
            for (final point in path.skip(1)) {
              await gesture.moveTo(point);
            }
            await tester.pump(const Duration(milliseconds: 1250));
            await gesture.up();
            await tester.pump();

            final stroke = controller.pageAt(0).inkStrokes.single;
            expect(stroke.tool, recognizedTool);
            expect(controller.tool, inkTool);
            expect(controller.activeShapeStrokeId, isNull);
            expect(controller.activeShapePageIndex, isNull);
            if (inkTool == DrawingTool.highlighter) {
              expect(stroke.width, 20);
              expect(stroke.color.a, closeTo(0.5, 0.01));
              expect(stroke.usesHighlighterStrokeCap, isTrue);
            }
          },
        );
      }
    }

    testWidgets('shape overlay moves, resizes and exits on outside tap '
        'in $kind', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 650));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final database = NotesDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final repository = NotebookRepository(database);
      final page = _page(_shape(
        DrawingTool.rectangle,
        const [
          Offset(40, 50), Offset(180, 50), Offset(180, 130),
          Offset(40, 130), Offset(40, 50),
        ],
      ));
      final now = DateTime(2026);
      final controller = EditorController(
        repository: repository,
        notebook: Notebook(
          uid: 'overlay-${kind.name}',
          title: 'Shape canvas',
          kind: kind,
          folder: 'Tests',
          createdAt: now,
          updatedAt: now,
          pages: [page],
        ),
      );
      addTearDown(controller.dispose);
      controller.setTool(DrawingTool.rectangle);
      controller.startShapeEdit(0, 'shape');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChangeNotifierProvider<EditorController>.value(
              value: controller,
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 400,
                  height: 400,
                  child: Builder(
                    builder: (context) {
                      context.watch<EditorController>();
                      return PageOverlay(controller: controller);
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('shape-hud-shape')), findsOneWidget);

      await tester.dragFrom(
        const Offset(110, 90),
        const Offset(30, 20),
      );
      await tester.pump();
      expect(controller.shapeStrokeOnPage(0, 'shape')!.points.first.toOffset(),
          const Offset(70, 70));
      expect(controller.isObjectTransformActive, isFalse);
      controller.undo();
      expect(controller.shapeStrokeOnPage(0, 'shape')!.points.first.toOffset(),
          const Offset(40, 50));
      controller.redo();
      expect(controller.shapeStrokeOnPage(0, 'shape')!.points.first.toOffset(),
          const Offset(70, 70));

      await tester.dragFrom(
        const Offset(210, 150),
        const Offset(35, 20),
      );
      await tester.pump();
      final bounds = ShapeEditGeometry.bounds(
        controller.shapeStrokeOnPage(0, 'shape')!,
      );
      expect(bounds.width, closeTo(175, 0.001));
      expect(bounds.height, closeTo(100, 0.001));

      await tester.tapAt(const Offset(320, 320));
      await tester.pump();
      expect(controller.activeShapeStrokeId, isNull);
      expect(controller.tool, DrawingTool.rectangle);
    });

    test('shape selects Move and restores previous tool in $kind', () async {
      final database = NotesDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final repository = NotebookRepository(database);
      final page = _page(_shape(
        DrawingTool.rectangle,
        const [Offset(0, 0), Offset(90, 0), Offset(90, 60),
          Offset(0, 60), Offset(0, 0)],
      ));
      final now = DateTime(2026);
      final notebook = Notebook(
        uid: 'shape-${kind.name}',
        title: 'Shapes',
        kind: kind,
        folder: 'Tests',
        createdAt: now,
        updatedAt: now,
        pages: [page],
      );
      final controller = EditorController(
        repository: repository,
        notebook: notebook,
      );
      addTearDown(controller.dispose);
      controller.setTool(DrawingTool.rectangle);
      controller.startShapeEdit(0, 'shape');
      expect(controller.tool, DrawingTool.edit);
      expect(controller.activeShapeStrokeId, 'shape');
      expect(controller.activeShapePageIndex, 0);
      controller.finishShapeEdit();
      expect(controller.tool, DrawingTool.rectangle);
      expect(controller.activeShapeStrokeId, isNull);

      controller.setTool(DrawingTool.pen);
      controller.startShapeEdit(0, 'shape');
      expect(controller.tool, DrawingTool.edit);
      controller.setTool(DrawingTool.highlighter);
      expect(controller.activeShapeStrokeId, isNull);
      expect(controller.tool, DrawingTool.highlighter);
    });
  }

  testWidgets('disposing an active object HUD unlocks after the frame', (
    tester,
  ) async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final controller = EditorController(
      repository: NotebookRepository(database),
      notebook: Notebook(
        uid: 'object-hud-dispose',
        title: 'Object HUD',
        kind: NotebookKind.notebook,
        folder: 'Tests',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        pages: [
          _page(_shape(DrawingTool.line, const [
            Offset.zero,
            Offset(20, 0),
          ])),
        ],
      ),
    );
    addTearDown(controller.dispose);

    Widget buildEditor({required bool showHud}) => MaterialApp(
      home: ChangeNotifierProvider<EditorController>.value(
        value: controller,
        child: Builder(
          builder: (context) {
            context.watch<EditorController>();
            return Scaffold(
              body: AnimatedBuilder(
                animation: controller,
                builder: (context, _) => Stack(
                  children: [
                    if (showHud)
                      ObjectTransformHud<int>(
                        data: 1,
                        rect: const Rect.fromLTWH(100, 150, 200, 100),
                        rotation: 0,
                        onPreview: (_, _) {},
                        onCommit: (_, _) {},
                        onTransformStart: controller.beginObjectTransform,
                        onTransformEnd: controller.endObjectTransform,
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );

    await tester.pumpWidget(buildEditor(showHud: true));
    await tester.pump();
    final gesture = await tester.startGesture(
      tester.getCenter(
        find.byKey(const ValueKey('object-transform-move-hit-zone')),
      ),
    );
    await tester.pump();
    expect(controller.isObjectTransformActive, isTrue);
    controller.panBy(const Offset(20, 10));
    expect(controller.viewPan, Offset.zero);

    await tester.pumpWidget(buildEditor(showHud: false));
    expect(tester.takeException(), isNull);
    expect(controller.isObjectTransformActive, isFalse);
    await tester.pump();
    expect(tester.takeException(), isNull);
    controller.panBy(const Offset(20, 10));
    expect(controller.viewPan, const Offset(20, 10));
    await gesture.up();
  });

  testWidgets('disposing an active shape overlay does not notify in unmount', (
    tester,
  ) async {
    final database = NotesDatabase(NativeDatabase.memory());
    addTearDown(database.close);
    final controller = EditorController(
      repository: NotebookRepository(database),
      notebook: Notebook(
        uid: 'shape-hud-dispose',
        title: 'Shape HUD',
        kind: NotebookKind.notebook,
        folder: 'Tests',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        pages: [
          _page(_shape(DrawingTool.rectangle, const [
            Offset(40, 50),
            Offset(180, 50),
            Offset(180, 130),
            Offset(40, 130),
            Offset(40, 50),
          ])),
        ],
      ),
    );
    addTearDown(controller.dispose);
    controller.setTool(DrawingTool.rectangle);
    controller.startShapeEdit(0, 'shape');

    Widget buildEditor({required bool showOverlay}) => MaterialApp(
      home: ChangeNotifierProvider<EditorController>.value(
        value: controller,
        child: Builder(
          builder: (context) {
            context.watch<EditorController>();
            return Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 400,
                  height: 400,
                  child: showOverlay
                      ? PageOverlay(controller: controller)
                      : const SizedBox.shrink(),
                ),
              ),
            );
          },
        ),
      ),
    );

    await tester.pumpWidget(buildEditor(showOverlay: true));
    await tester.pump();
    final gesture = await tester.startGesture(const Offset(110, 90));
    await tester.pump();
    expect(controller.isObjectTransformActive, isTrue);

    await tester.pumpWidget(buildEditor(showOverlay: false));
    expect(tester.takeException(), isNull);
    expect(controller.isObjectTransformActive, isFalse);
    await tester.pump();
    expect(tester.takeException(), isNull);
    controller.panBy(const Offset(15, 0));
    expect(controller.viewPan, const Offset(15, 0));
    await gesture.up();
  });
}
