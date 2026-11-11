import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/sync/share_ink_preview_codec.dart';
import 'package:program/features/notebook/domain/drawing_tool.dart';
import 'package:program/features/notebook/domain/ink_stroke.dart';

void main() {
  const sender = 'e5b63a5e-82f3-4a2a-9c57-16255f4e4431';
  final stroke = InkStroke(
    id: 'local-preview',
    points: [
      const InkPoint(dx: 1.5, dy: 4, pressure: 0.5),
      const InkPoint(dx: 3, dy: 8.5, pressure: 0.8),
    ],
    color: const Color(0xff123456),
    width: 2.5,
    tool: DrawingTool.pen,
  );
  test('preview uses a bounded non-operational wire representation', () {
    final encoded = ShareInkPreviewCodec.encode(
      shareId: 'share',
      documentUid: 'doc',
      pageId: 'page',
      senderId: sender,
      stroke: stroke,
    );
    expect(encoded.containsKey('operationId'), isFalse);
    expect(encoded['type'], 'share_preview');
    final decoded = ShareInkPreviewCodec.decode(encoded)!;
    expect(decoded.senderId, sender);
    expect(decoded.stroke!.points[1].dy, 8.5);
    expect(decoded.stroke!.color.toARGB32(), 0xff123456);
  });

  test('clear preview does not create a durable operation', () {
    final clear = ShareInkPreviewCodec.encode(
      shareId: 'share',
      documentUid: 'doc',
      pageId: 'page',
      senderId: sender,
    );
    expect(clear['stroke'], isNull);
    expect(ShareInkPreviewCodec.decode(clear)!.stroke, isNull);
  });

  test('overlarge and malicious coordinates are rejected', () {
    final encoded = ShareInkPreviewCodec.encode(
      shareId: 'share',
      documentUid: 'doc',
      pageId: 'page',
      senderId: sender,
      stroke: stroke,
    );
    final invalid = {...encoded, 'senderId': 'not-a-uuid'};
    expect(ShareInkPreviewCodec.decode(invalid), isNull);
    final broken = {
      ...encoded,
      'stroke': {
        ...encoded['stroke'] as Map<String, dynamic>,
        'points': [
          [double.infinity, 0, 1],
        ],
      },
    };
    expect(ShareInkPreviewCodec.decode(broken), isNull);
  });
}
