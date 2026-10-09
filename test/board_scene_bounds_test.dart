import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:program/core/input/app_preferences_controller.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/features/board/presentation/board_screen.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';

void main() {
  test('board coordinates do not rebase during object transforms', () {
    final resolver = BoardSceneBoundsResolver();
    const viewport = Size(900, 650);
    const initialContent = Rect.fromLTWH(80, 110, 200, 130);
    const expandedContent = Rect.fromLTWH(-1200, -800, 2200, 1900);

    Rect resolve(
      Rect content, {
      required bool freeze,
      Offset pan = Offset.zero,
    }) {
      return resolver.resolve(
        contentBounds: content,
        viewPan: pan,
        viewScale: 1,
        viewportSize: viewport,
        freeze: freeze,
      );
    }

    final initial = resolve(initialContent, freeze: false);

    expect(resolve(expandedContent, freeze: true), initial);
    expect(
      resolve(expandedContent, freeze: true, pan: const Offset(200, 200)),
      initial,
    );

    final updated = resolve(expandedContent, freeze: false);
    expect(updated, isNot(initial));
    expect(updated.left, -1900);
    expect(updated.top, -1500);

    expect(resolve(initialContent, freeze: true), updated);
    expect(resolve(initialContent, freeze: false), initial);
  });

  test('board bounds can freeze on the first render', () {
    final resolver = BoardSceneBoundsResolver();
    const content = Rect.fromLTWH(0, 0, 100, 100);

    Rect resolve(bool freeze, Rect contentBounds) {
      return resolver.resolve(
        contentBounds: contentBounds,
        viewPan: Offset.zero,
        viewScale: 2,
        viewportSize: const Size(800, 600),
        freeze: freeze,
      );
    }

    final first = resolve(true, content);
    expect(resolve(true, content.shift(const Offset(-2000, 0))), first);
    expect(resolve(false, content), first);
  });
  testWidgets('board toolbar floats above full-height canvas', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final database = NotesDatabase(NativeDatabase.memory());
    final preferences = AppPreferencesController();
    final now = DateTime(2026);
    final board = Notebook(
      uid: 'board-overlay-layout',
      title: 'Board overlay',
      kind: NotebookKind.board,
      folder: 'Tests',
      createdAt: now,
      updatedAt: now,
      pages: [
        NotePage(
          id: 'board-page',
          title: 'Board',
          textBlocks: const [],
          imageBlocks: const [],
          inkStrokes: const [],
          isBookmarked: false,
        ),
      ],
    );
    final controller = EditorController(
      repository: NotebookRepository(database),
      notebook: board,
    );

    Widget app({required bool showToolbar}) {
      return MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<AppPreferencesController>.value(
              value: preferences,
            ),
            ChangeNotifierProvider<EditorController>.value(value: controller),
          ],
          child: BoardScreen(showToolbar: showToolbar),
        ),
      );
    }

    await tester.pumpWidget(app(showToolbar: true));
    await tester.pump();

    final canvas = find.byKey(const ValueKey('board-canvas-area'));
    final toolbar = find.byKey(const ValueKey('editor-toolbar-panel'));
    final canvasRect = tester.getRect(canvas);
    final toolbarRect = tester.getRect(toolbar);
    final appBar = tester.widget<AppBar>(find.byType(AppBar));

    expect(
      canvasRect.top,
      closeTo(tester.getBottomLeft(find.byType(AppBar)).dy, 0.01),
    );
    expect(canvasRect.bottom, closeTo(800, 0.01));
    expect(toolbarRect.top, greaterThanOrEqualTo(canvasRect.top));
    expect(toolbarRect.bottom, lessThan(canvasRect.bottom));
    expect(appBar.scrolledUnderElevation, 0);
    expect(appBar.surfaceTintColor, Colors.transparent);

    await tester.tap(find.byTooltip('Highlighter'));
    await tester.pump();
    expect(controller.tool, DrawingTool.highlighter);

    await tester.pumpWidget(app(showToolbar: false));
    await tester.pump();
    expect(toolbar, findsNothing);
    expect(tester.getRect(canvas), canvasRect);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    preferences.dispose();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await database.close();
  });

}
