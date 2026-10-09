import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:program/core/theme/app_colors.dart';
import 'package:program/data/export/notebook_export_service.dart';
import 'package:program/features/editor/state/page_background.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';
import 'package:program/features/notebook/domain/note_page.dart';
import 'package:program/features/notebook/domain/notebook.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';
import 'package:program/features/notebook/domain/text_block.dart';

const _pageSize = Size(80, 60);

NotePage _page(String id, {bool draw = false, bool text = false}) {
  return NotePage(
    id: id,
    title: id,
    textBlocks: text
        ? [
            TextBlock(
              id: '$id-text',
              text: 'Visible export',
              position: const Offset(3, 4),
              fontSize: 12,
              color: const Color(0xFF161616),
              width: 72,
            ),
          ]
        : const [],
    imageBlocks: const [],
    inkStrokes: draw
        ? [
            InkStroke(
              id: '$id-stroke',
              points: const [
                InkPoint(dx: 3, dy: 40, pressure: 0.5),
                InkPoint(dx: 65, dy: 40, pressure: 0.5),
              ],
              color: const Color(0xFF121212),
              width: 4,
              tool: DrawingTool.pen,
            ),
          ]
        : const [],
    isBookmarked: false,
  );
}

Notebook _notebook(List<NotePage> pages) => Notebook(
  uid: 'export-fixture',
  title: 'Export fixture',
  kind: NotebookKind.notebook,
  folder: 'Tests',
  createdAt: DateTime.utc(2026, 1, 1),
  updatedAt: DateTime.utc(2026, 1, 1),
  pages: pages,
);

void _verifyPng(Uint8List bytes) {
  expect(bytes.take(8).toList(), [137, 80, 78, 71, 13, 10, 26, 10]);
  expect(bytes.length, greaterThan(70));
  final header = ByteData.sublistView(bytes);
  expect(header.getUint32(16), 160);
  expect(header.getUint32(20), 120);
}

Future<Color> _pixel(Uint8List png, int x, int y) async {
  final codec = await instantiateImageCodec(png);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final data = await image.toByteData(format: ImageByteFormat.rawRgba);
  if (data == null) {
    throw StateError('Cannot decode PNG pixels.');
  }
  final offset = (y * image.width + x) * 4;
  final color = Color.fromARGB(
    data.getUint8(offset + 3),
    data.getUint8(offset),
    data.getUint8(offset + 1),
    data.getUint8(offset + 2),
  );
  image.dispose();
  codec.dispose();
  return color;
}

Future<T> _render<T>(WidgetTester tester, Future<T> Function() render) async {
  final result = await tester.runAsync(render);
  if (result == null) {
    throw TestFailure('Production export rendering failed.');
  }
  return result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('exported PNGs have valid signatures and expected dimensions', (
    tester,
  ) async {
    final pngs = await _render(
      tester,
      () => NotebookExportService.renderPngPagesForTest(
        _notebook([_page('first'), _page('second', draw: true)]),
        pageSize: _pageSize,
      ),
    );
    expect(pngs, hasLength(2));
    for (final png in pngs) {
      _verifyPng(png);
    }
    expect(pngs[0], isNot(equals(pngs[1])));
  });

  testWidgets('ink and formatted text are not lost during rendering', (
    tester,
  ) async {
    final rendered = await _render(tester, () async {
      final blank = (await NotebookExportService.renderPngPagesForTest(
        _notebook([_page('baseline')]),
        pageSize: _pageSize,
      )).single;
      final ink = (await NotebookExportService.renderPngPagesForTest(
        _notebook([_page('ink', draw: true)]),
        pageSize: _pageSize,
      )).single;
      final withText = (await NotebookExportService.renderPngPagesForTest(
        _notebook([_page('ink-text', draw: true, text: true)]),
        pageSize: _pageSize,
      )).single;
      return [blank, ink, withText];
    });

    expect(rendered[1], isNot(equals(rendered[0])));
    expect(rendered[2], isNot(equals(rendered[1])));
  });

  testWidgets('PDF export contains a valid document with two pages', (
    tester,
  ) async {
    final pdf = await _render(
      tester,
      () => NotebookExportService.renderPdfBytesForTest(
        _notebook([_page('first', draw: true), _page('second', text: true)]),
        pageSize: _pageSize,
        background: const PageBackgroundSettings(
          style: PageBackgroundStyle.grid,
          spacing: 20,
        ),
      ),
    );

    expect(latin1.decode(pdf.take(5).toList()), '%PDF-');
    expect(latin1.decode(pdf.skip(pdf.length - 7).toList()), contains('%%EOF'));
    expect(pdf.length, greaterThan(600));
  });

  testWidgets('multi-page PNG export preserves page count', (tester) async {
    final pages = [
      for (var i = 0; i < 12; i++)
        _page('page-$i', draw: i.isEven, text: i.isOdd),
    ];
    final images = await _render(
      tester,
      () => NotebookExportService.renderPngPagesForTest(
        _notebook(pages),
        pageSize: const Size(320, 420),
      ),
    );
    expect(images, hasLength(12));
    for (final image in images) {
      final data = ByteData.sublistView(image);
      expect(data.getUint32(16), 640);
      expect(data.getUint32(20), 840);
    }
  });

  testWidgets('board can render PNG and PDF', (tester) async {
    final board = _notebook([
      _page('board', draw: true, text: true),
    ]).copyWith(kind: NotebookKind.board);
    final results = await _render(tester, () async {
      final png = (await NotebookExportService.renderPngPagesForTest(
        board,
        pageSize: _pageSize,
      )).single;
      final pdf = await NotebookExportService.renderPdfBytesForTest(
        board,
        pageSize: _pageSize,
      );
      return (png: png, pdf: pdf);
    });

    expect(results.png.length, greaterThan(70));
    expect(latin1.decode(results.pdf.take(5).toList()), '%PDF-');
  });

  testWidgets('legacy erase masks are flattened before rendering', (
    tester,
  ) async {
    final legacy = _page('legacy', draw: true);
    final erase = InkStroke(
      id: 'legacy-eraser',
      points: const [
        InkPoint(dx: 35, dy: 25, pressure: 1),
        InkPoint(dx: 35, dy: 55, pressure: 1),
      ],
      color: const Color(0xFFFFFFFF),
      width: 12,
      tool: DrawingTool.eraserBrush,
    );
    final original = legacy.copyWith(inkStrokes: [...legacy.inkStrokes, erase]);
    final pages = await _render(
      tester,
      () => NotebookExportService.renderPngPagesForTest(
        _notebook([original]),
        pageSize: _pageSize,
      ),
    );

    expect(pages, hasLength(1));
    _verifyPng(pages.single);
  });

  testWidgets('saved ink and paper match the export theme', (tester) async {
    const black = Color(0xFF101010);
    const paleBlue = Color(0xFFBBDCFB);
    const deepPink = Color(0xFF8F214D);
    final page = _page('previously-saved').copyWith(
      inkStrokes: [
        for (final (i, color) in [
          black,
          paleBlue,
          deepPink,
        ].indexed)
          InkStroke(
            id: 'saved-color-$i',
            points: [
              InkPoint(dx: 5, dy: 15.0 + 15 * i, pressure: 1),
              InkPoint(dx: 65, dy: 15.0 + 15 * i, pressure: 1),
            ],
            color: color,
            width: 4,
            tool: DrawingTool.pen,
          ),
      ],
    );
    final notebook = _notebook([page]);
    final rendered = await _render(tester, () async {
      final light = (await NotebookExportService.renderPngPagesForTest(
        notebook,
        pageSize: _pageSize,
        darkMode: false,
      )).single;
      final dark = (await NotebookExportService.renderPngPagesForTest(
        notebook,
        pageSize: _pageSize,
        darkMode: true,
      )).single;
      final pdfLight = await NotebookExportService.renderPdfBytesForTest(
        notebook,
        pageSize: _pageSize,
        darkMode: false,
      );
      final pdfDark = await NotebookExportService.renderPdfBytesForTest(
        notebook,
        pageSize: _pageSize,
        darkMode: true,
      );
      return (
        lightBackground: await _pixel(light, 148, 8),
        darkBackground: await _pixel(dark, 148, 8),
        lightInk: [
          for (final y in [15, 30, 45])
            await _pixel(light, 60, y * 2),
        ],
        darkInk: [
          for (final y in [15, 30, 45])
            await _pixel(dark, 60, y * 2),
        ],
        lightPng: light,
        darkPng: dark,
        pdfLight: pdfLight,
        pdfDark: pdfDark,
      );
    });

    expect(rendered.lightBackground, AppColors.paper);
    expect(rendered.darkBackground, AppColors.darkCanvas);
    final colors = [black, paleBlue, deepPink];
    for (var i = 0; i < colors.length; i++) {
      expect(rendered.lightInk[i], colors[i]);
      expect(
        rendered.darkInk[i],
        AppColors.displayInkColor(colors[i], darkMode: true),
      );
    }
    expect(rendered.darkPng, isNot(equals(rendered.lightPng)));
    expect(latin1.decode(rendered.pdfLight.take(5).toList()), '%PDF-');
    expect(latin1.decode(rendered.pdfDark.take(5).toList()), '%PDF-');
    expect(rendered.pdfDark, isNot(equals(rendered.pdfLight)));
    expect(notebook.pages.first.inkStrokes.map((stroke) => stroke.color), colors);
  });
}
