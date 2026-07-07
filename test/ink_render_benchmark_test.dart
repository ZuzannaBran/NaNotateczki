import 'dart:ui';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:program/data/drift/notes_database.dart';
import 'package:program/features/editor/presentation/widgets/drawing_canvas.dart';
import 'package:program/features/editor/state/editor_controller.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';

const _pageSize = Size(600, 800);
const _pageGap = 26.0;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('ink render benchmark', (tester) async {
    await tester.binding.setSurfaceSize(const Size(700, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final previousDebugPrint = debugPrint;
    final inkLogs = <String>[];
    debugPrint = (message, {wrapWidth}) {
      if (message != null && message.startsWith('[ink] nb ')) {
        inkLogs.add(message);
      }
      previousDebugPrint(message, wrapWidth: wrapWidth);
    };
    addTearDown(() => debugPrint = previousDebugPrint);

    const scenarios = <_BenchmarkScenario>[
      _BenchmarkScenario(
        name: 'warmup',
        pageCount: 1,
        strokesPerPage: 20,
        pointsPerStroke: 8,
      ),
      _BenchmarkScenario(
        name: 'small',
        pageCount: 1,
        strokesPerPage: 100,
        pointsPerStroke: 12,
      ),
      _BenchmarkScenario(
        name: 'medium',
        pageCount: 5,
        strokesPerPage: 200,
        pointsPerStroke: 16,
        effectiveScale: 0.6,
      ),
      _BenchmarkScenario(
        name: 'large',
        pageCount: 20,
        strokesPerPage: 250,
        pointsPerStroke: 24,
        effectiveScale: 0.3,
      ),
    ];

    for (final scenario in scenarios) {
      inkLogs.clear();
      final database = NotesDatabase(NativeDatabase.memory());
      final repository = NotebookRepository(database);
      final notebook = _notebookFor(scenario);
      final controller = EditorController(
        repository: repository,
        notebook: notebook,
      );

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<EditorController>.value(
            value: controller,
            child: Consumer<EditorController>(
              builder: (context, value, _) {
                return SizedBox(
                  width: _pageSize.width,
                  height: _pageSize.height,
                  child: DocumentDrawingCanvas(
                    effectiveScale: scenario.effectiveScale,
                    pages: value.pages,
                    pageSize: _pageSize,
                    pageGap: _pageGap,
                    firstPageIndex: 0,
                    lastPageIndex: scenario.pageCount.clamp(0, 4),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();

      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.stylus,
      );
      await gesture.down(const Offset(120, 120));
      await tester.pump(const Duration(milliseconds: 16));
      for (var i = 1; i <= 12; i++) {
        await gesture.moveTo(Offset(120 + i * 8, 120 + i * 3));
        await tester.pump(const Duration(milliseconds: 8));
      }
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 16));

      expect(
        controller.pages.first.inkStrokes,
        hasLength(scenario.strokesPerPage + 1),
      );
      expect(inkLogs, isNotEmpty);
      final result = inkLogs.last;
      expect(result, contains('renderPages=${scenario.renderedPages}'));
      expect(result, contains('staticPaintUsLast='));
      expect(result, contains('activePaintUsAvg='));
      expect(result, contains('inputToPaintUsAvg='));
      expect(result, contains('inputToPaintUsMax='));
      expect(
        _metric(result, 'frameUsAvg'),
        lessThanOrEqualTo(_metric(result, 'frameUsMax')),
      );
      if (scenario.name != 'warmup') {
        debugPrint(
          'INK_BENCHMARK scenario=${scenario.name} '
          'totalStrokes=${scenario.totalStrokes} '
          'pointsPerStroke=${scenario.pointsPerStroke} $result',
        );
      }

      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await database.close();
    }
    debugPrint = previousDebugPrint;
  });
}

int _metric(String log, String name) {
  final match = RegExp('$name=(\\d+)').firstMatch(log);
  return int.parse(match!.group(1)!);
}

Notebook _notebookFor(_BenchmarkScenario scenario) {
  final now = DateTime(2026);
  return Notebook(
    uid: 'benchmark-${scenario.name}',
    title: 'Ink benchmark ${scenario.name}',
    kind: NotebookKind.notebook,
    folder: 'Benchmarks',
    createdAt: now,
    updatedAt: now,
    pages: List<NotePage>.generate(
      scenario.pageCount,
      (pageIndex) => NotePage(
        id: 'page-$pageIndex',
        title: 'Page ${pageIndex + 1}',
        textBlocks: const [],
        imageBlocks: const [],
        inkStrokes: List<InkStroke>.generate(
          scenario.strokesPerPage,
          (strokeIndex) =>
              _strokeFor(pageIndex, strokeIndex, scenario.pointsPerStroke),
        ),
        isBookmarked: false,
        indexTabs: const [],
      ),
    ),
  );
}

InkStroke _strokeFor(int pageIndex, int strokeIndex, int pointCount) {
  final row = strokeIndex % 40;
  final column = strokeIndex ~/ 40;
  final startX = 18.0 + column * 22.0;
  final startY = 18.0 + row * 18.0;
  return InkStroke(
    id: 'stroke-$pageIndex-$strokeIndex',
    points: List<InkPoint>.generate(
      pointCount,
      (pointIndex) => InkPoint(
        dx: startX + pointIndex * 2.0,
        dy: startY + (pointIndex.isEven ? 0.0 : 3.0),
        pressure: 0.65,
      ),
    ),
    color: const Color(0xFF1E1E1E),
    width: 2.5,
    tool: DrawingTool.pen,
  );
}

class _BenchmarkScenario {
  const _BenchmarkScenario({
    required this.name,
    required this.pageCount,
    required this.strokesPerPage,
    required this.pointsPerStroke,
    this.effectiveScale = 1.0,
  });

  final String name;
  final int pageCount;
  final int strokesPerPage;
  final int pointsPerStroke;
  final double effectiveScale;

  int get totalStrokes => pageCount * strokesPerPage;

  int get renderedPages => pageCount.clamp(0, 4);
}
