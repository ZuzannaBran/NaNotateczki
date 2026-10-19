import 'dart:math' as math;

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:program/core/input/app_preferences_controller.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/features/board/presentation/board_screen.dart';
import 'package:program/features/editor/presentation/editor_screen.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/editor/state/input_mode.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';

import 'native_test_documents.dart';

class _Contact {
  _Contact(
    this.tester,
    this.pointer,
    this.kind, {
    this.radiusMajor = 1,
    this.radiusMinor = 1,
  });

  final WidgetTester tester;
  final int pointer;
  final PointerDeviceKind kind;
  final double radiusMajor;
  final double radiusMinor;
  Offset? _position;

  Future<void> down(Offset position) async {
    _position = position;
    await tester.sendEventToBinding(
      PointerDownEvent(
        pointer: pointer,
        kind: kind,
        position: position,
        buttons: kPrimaryButton,
        radiusMajor: radiusMajor,
        radiusMinor: radiusMinor,
      ),
    );
    await tester.pump();
  }

  Future<void> move(Offset position) async {
    final previous = _position!;
    _position = position;
    await tester.sendEventToBinding(
      PointerMoveEvent(
        pointer: pointer,
        kind: kind,
        position: position,
        delta: position - previous,
        buttons: kPrimaryButton,
        radiusMajor: radiusMajor,
        radiusMinor: radiusMinor,
      ),
    );
    await tester.pump();
  }

  Future<void> up() async {
    await tester.sendEventToBinding(
      PointerUpEvent(
        pointer: pointer,
        kind: kind,
        position: _position!,
        radiusMajor: radiusMajor,
        radiusMinor: radiusMinor,
      ),
    );
    await tester.pump();
  }

  Future<void> cancel() async {
    await tester.sendEventToBinding(
      PointerCancelEvent(pointer: pointer, kind: kind, position: _position!),
    );
    await tester.pump();
  }
}

Future<void> _stroke(_Contact contact, Offset start) async {
  await contact.down(start);
  await contact.move(start + const Offset(20, 7));
  await contact.move(start + const Offset(45, 18));
  await contact.up();
}

void _expectLocalInk(InkStroke stroke, double scale) {
  final xs = stroke.points.map((point) => point.dx).toList();
  final ys = stroke.points.map((point) => point.dy).toList();
  expect(xs.length, greaterThan(1));
  expect((xs.reduce(math.max) - xs.reduce(math.min)) * scale, lessThan(75));
  expect((ys.reduce(math.max) - ys.reduce(math.min)) * scale, lessThan(55));
  for (var i = 1; i < stroke.points.length; i++) {
    final previous = stroke.points[i - 1].toOffset();
    final current = stroke.points[i].toOffset();
    expect(
      (current - previous).distance * scale,
      lessThan(75),
      reason: 'Palm input must not teleport the active pen cursor',
    );
  }
}

class _CanvasFixture {
  _CanvasFixture({
    required this.tester,
    required this.kind,
    required this.database,
    required this.repository,
    required this.preferences,
    required this.controller,
    required this.inkStart,
    required this.nearPalm,
    required this.farPalm,
  });

  final WidgetTester tester;
  final NotebookKind kind;
  final NotesDatabase database;
  final NotebookRepository repository;
  final AppPreferencesController preferences;
  final EditorController controller;
  final Offset inkStart;
  final Offset nearPalm;
  final Offset farPalm;

  static Future<_CanvasFixture> create(
    WidgetTester tester,
    NotebookKind kind, {
    Size? surfaceSize,
  }) async {
    if (surfaceSize != null) {
      await tester.binding.setSurfaceSize(surfaceSize);
      addTearDown(() => tester.binding.setSurfaceSize(null));
    }
    final db = NotesDatabase(NativeDatabase.memory());
    final repository = NotebookRepository(db);
    final preferences = AppPreferencesController();
    final now = DateTime(2026);
    final notebook = Notebook(
      uid: 'pointer-matrix-${kind.name}',
      title: 'Pointer input matrix',
      kind: kind,
      folder: 'Tests',
      createdAt: now,
      updatedAt: now,
      pages: [
        NotePage(
          id: 'page-1',
          title: 'Page 1',
          textBlocks: const [],
          imageBlocks: const [],
          inkStrokes: const [],
          isBookmarked: false,
        ),
      ],
    );
    final controller = EditorController(
      repository: repository,
      notebook: notebook,
    );
    controller.setTool(DrawingTool.pen);
    controller.setPointerInputMode(PointerInputMode.off);
    await tester.pumpWidget(
      MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<EditorController>.value(value: controller),
            ChangeNotifierProvider<AppPreferencesController>.value(
              value: preferences,
            ),
          ],
          child: kind == NotebookKind.board
              ? const BoardScreen(showToolbar: false)
              : const EditorScreen(showToolbar: false),
        ),
      ),
    );
    await tester.pump();

    final finder = kind == NotebookKind.board
        ? find.byKey(const ValueKey('board-canvas-area'))
        : find.byKey(const ValueKey('notebook-page-viewport'));
    final rect = tester.getRect(finder);
    // The notebook's document viewport can extend below the real window.
    // Native desktop tests must send both contacts inside the visible screen.
    final visibleRect = rect.intersect(
      tester.getRect(find.byType(Scaffold).first),
    );
    expect(visibleRect.width, greaterThan(80));
    expect(visibleRect.height, greaterThan(220));
    final start = Offset(
      visibleRect.left + visibleRect.width * 0.24,
      visibleRect.top + math.min(170.0, visibleRect.height * 0.32),
    );
    return _CanvasFixture(
      tester: tester,
      kind: kind,
      database: db,
      repository: repository,
      preferences: preferences,
      controller: controller,
      inkStart: start,
      nearPalm: start + const Offset(60, 70),
      farPalm: Offset(
        visibleRect.right - math.max(18.0, visibleRect.width * 0.09),
        visibleRect.top + visibleRect.height * 0.77,
      ),
    );
  }

  Future<void> close() async {
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    preferences.dispose();
    await repository.waitForPendingSaves();
    await database.close();
  }

  Offset get navigationOffset {
    if (kind == NotebookKind.board) {
      return controller.viewPan;
    }
    final transform = tester
        .widget<Transform>(
          find.byKey(const ValueKey('notebook-document-transform')),
        )
        .transform;
    final scroll = tester.widget<SingleChildScrollView>(
      find.byKey(const ValueKey('notebook-document-scroll')),
    );
    final scrollOffset = scroll.controller!.offset;
    return Offset(transform.entry(0, 3), transform.entry(1, 3) - scrollOffset);
  }

  void expectStrokeCount(int count) {
    expect(
      controller.currentPage.inkStrokes,
      hasLength(count),
      reason: 'Only deliberate drawing contacts may persist as ink',
    );
  }

  void expectLastStrokeLocal() {
    final scale = kind == NotebookKind.board
        ? controller.viewScale
        : tester
              .widget<Transform>(
                find.byKey(const ValueKey('notebook-document-transform')),
              )
              .transform
              .entry(0, 0);
    expect(scale, greaterThan(0));
    _expectLocalInk(controller.currentPage.inkStrokes.last, scale);
  }
}

/// Runs the same synthetic pointer sequences on both production canvases.
///
/// These tests validate Flutter input routing and saved ink, not the native
/// digitizer's physical classification or operating-system palm rejection.
void registerPointerContactMatrix({Size? surfaceSize}) {
  useInMemoryTestTextStorage();

  for (final kind in [NotebookKind.notebook, NotebookKind.board]) {
    testWidgets('pointer matrix: finger acceptance and cancellation $kind', (
      tester,
    ) async {
      final f = await _CanvasFixture.create(
        tester,
        kind,
        surfaceSize: surfaceSize,
      );
      try {
        var count = 0;
        for (final radius in [0.5, 14.0, 34.0, 55.0]) {
          final finger = _Contact(
            tester,
            110 + count,
            PointerDeviceKind.touch,
            radiusMajor: radius,
            radiusMinor: radius * 0.75,
          );
          await _stroke(finger, f.inkStart + Offset(0, count * 34));
          f.expectStrokeCount(++count);
          f.expectLastStrokeLocal();
        }

        f.controller.setPointerInputMode(PointerInputMode.on);
        await tester.pump();
        final blocked = _Contact(
          tester,
          120,
          PointerDeviceKind.touch,
          radiusMajor: 34,
          radiusMinor: 25,
        );
        await _stroke(blocked, f.inkStart);
        f.expectStrokeCount(count);

        final stylus = _Contact(tester, 121, PointerDeviceKind.stylus);
        await _stroke(stylus, f.inkStart);
        f.expectStrokeCount(++count);
        f.expectLastStrokeLocal();

        f.controller.setPointerInputMode(PointerInputMode.off);
        await tester.pump();
        final tap = _Contact(
          tester,
          122,
          PointerDeviceKind.touch,
          radiusMajor: 34,
          radiusMinor: 25,
        );
        await tap.down(f.inkStart);
        await tap.up();
        f.expectStrokeCount(count);

        final first = _Contact(tester, 123, PointerDeviceKind.touch);
        final second = _Contact(tester, 124, PointerDeviceKind.touch);
        await first.down(f.nearPalm);
        await second.down(f.farPalm);
        await first.up();
        await second.up();
        f.expectStrokeCount(count);

        final recovered = _Contact(
          tester,
          125,
          PointerDeviceKind.touch,
          radiusMajor: 34,
        );
        await _stroke(recovered, f.inkStart);
        f.expectStrokeCount(++count);
      } finally {
        await f.close();
      }
    });

    testWidgets('pointer matrix: distant palm cannot steal pen $kind', (
      tester,
    ) async {
      final f = await _CanvasFixture.create(
        tester,
        kind,
        surfaceSize: surfaceSize,
      );
      try {
        var count = 0;
        for (final palmPosition in [f.nearPalm, f.farPalm]) {
          final pen = _Contact(
            tester,
            210 + count * 2,
            PointerDeviceKind.stylus,
          );
          final palm = _Contact(
            tester,
            211 + count * 2,
            PointerDeviceKind.touch,
            radiusMajor: 55,
            radiusMinor: 35,
          );
          await pen.down(f.inkStart);
          await pen.move(f.inkStart + const Offset(18, 7));
          await palm.down(palmPosition);
          await palm.move(palmPosition + const Offset(18, 6));
          await pen.move(f.inkStart + const Offset(44, 18));
          await pen.up();
          await palm.move(palmPosition + const Offset(21, 10));
          await palm.up();
          f.expectStrokeCount(++count);
          f.expectLastStrokeLocal();
        }

        final palmFirst = _Contact(
          tester,
          230,
          PointerDeviceKind.touch,
          radiusMajor: 55,
        );
        await palmFirst.down(f.farPalm);
        final penAfter = _Contact(tester, 231, PointerDeviceKind.stylus);
        await _stroke(penAfter, f.inkStart);
        await palmFirst.up();
        f.expectStrokeCount(++count);
        f.expectLastStrokeLocal();

        final fingerOne = _Contact(tester, 232, PointerDeviceKind.touch);
        final fingerTwo = _Contact(tester, 233, PointerDeviceKind.touch);
        await fingerOne.down(f.nearPalm);
        await fingerTwo.down(f.farPalm);
        final pen = _Contact(tester, 234, PointerDeviceKind.stylus);
        await _stroke(pen, f.inkStart);
        await fingerOne.up();
        await fingerTwo.up();
        f.expectStrokeCount(++count);
        f.expectLastStrokeLocal();
      } finally {
        await f.close();
      }
    });

    testWidgets('pointer matrix: two fingers navigate without ink $kind', (
      tester,
    ) async {
      final f = await _CanvasFixture.create(
        tester,
        kind,
        surfaceSize: surfaceSize,
      );
      try {
        final previousPan = f.navigationOffset;
        final first = _Contact(tester, 250, PointerDeviceKind.touch);
        final second = _Contact(tester, 251, PointerDeviceKind.touch);
        await first.down(f.nearPalm);
        await second.down(f.farPalm);
        await first.move(f.nearPalm + const Offset(0, -45));
        await second.move(f.farPalm + const Offset(0, -45));
        f.expectStrokeCount(0);
        expect(
          (f.navigationOffset - previousPan).distance,
          greaterThan(1),
          reason: 'Two fingers must navigate rather than create ink',
        );
        await first.up();
        await second.up();
        f.expectStrokeCount(0);

        final pen = _Contact(tester, 252, PointerDeviceKind.stylus);
        await _stroke(pen, f.inkStart);
        f.expectStrokeCount(1);
        f.expectLastStrokeLocal();
      } finally {
        await f.close();
      }
    });

    testWidgets('pointer matrix: drawing touch yields to second finger $kind', (
      tester,
    ) async {
      final f = await _CanvasFixture.create(
        tester,
        kind,
        surfaceSize: surfaceSize,
      );
      try {
        final previousPan = f.navigationOffset;
        final first = _Contact(tester, 260, PointerDeviceKind.touch);
        final second = _Contact(tester, 261, PointerDeviceKind.touch);
        await first.down(f.nearPalm);
        await first.move(f.nearPalm + const Offset(24, 7));
        await second.down(f.farPalm);
        await first.move(f.nearPalm + const Offset(24, -43));
        await second.move(f.farPalm + const Offset(0, -50));
        f.expectStrokeCount(0);
        expect(
          (f.navigationOffset - previousPan).distance,
          greaterThan(1),
          reason: 'A second finger must take over after a touch began drawing',
        );
        await first.up();
        await second.up();
        f.expectStrokeCount(0);

        final recovered = _Contact(tester, 262, PointerDeviceKind.touch);
        await _stroke(recovered, f.inkStart);
        f.expectStrokeCount(1);
        f.expectLastStrokeLocal();
      } finally {
        await f.close();
      }
    });

    testWidgets('pointer matrix: canceled contact never saves ink $kind', (
      tester,
    ) async {
      final f = await _CanvasFixture.create(
        tester,
        kind,
        surfaceSize: surfaceSize,
      );
      try {
        final pen = _Contact(tester, 310, PointerDeviceKind.stylus);
        await pen.down(f.inkStart);
        await pen.move(f.inkStart + const Offset(30, 12));
        await pen.cancel();
        f.expectStrokeCount(0);

        final touch = _Contact(
          tester,
          311,
          PointerDeviceKind.touch,
          radiusMajor: 34,
        );
        await touch.down(f.inkStart);
        await touch.move(f.inkStart + const Offset(30, 12));
        await touch.cancel();
        f.expectStrokeCount(0);

        final recoveredPen = _Contact(tester, 312, PointerDeviceKind.stylus);
        await _stroke(recoveredPen, f.inkStart);
        f.expectStrokeCount(1);
        f.expectLastStrokeLocal();

        final recoveredFinger = _Contact(
          tester,
          313,
          PointerDeviceKind.touch,
          radiusMajor: 34,
        );
        await _stroke(recoveredFinger, f.inkStart);
        f.expectStrokeCount(2);
        f.expectLastStrokeLocal();
      } finally {
        await f.close();
      }
    });
  }
}
