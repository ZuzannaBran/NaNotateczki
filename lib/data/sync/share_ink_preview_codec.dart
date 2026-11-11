import 'dart:math' as math;
import 'dart:ui';

import '../../features/notebook/domain/drawing_tool.dart';
import '../../features/notebook/domain/ink_stroke.dart';

/// Non-durable, bounded hint. Never convert a preview to an OperationEnvelope.
class ShareInkPreview {
  const ShareInkPreview({
    required this.shareId,
    required this.documentUid,
    required this.pageId,
    required this.senderId,
    required this.stroke,
  });

  final String shareId;
  final String documentUid;
  final String pageId;
  final String senderId;
  final InkStroke? stroke;
}

class ShareInkPreviewCodec {
  static const maximumPoints = 96;
  static final _actor = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  static int _sampleIndex(int index, int count, int total) =>
      count < 2 ? 0 : (index * (total - 1) / (count - 1)).round();

  static bool supported(DrawingTool tool) =>
      tool == DrawingTool.pen ||
      tool == DrawingTool.highlighter ||
      tool.isShape;

  static Map<String, dynamic> encode({
    required String shareId,
    required String documentUid,
    required String pageId,
    required String senderId,
    InkStroke? stroke,
  }) {
    if (!_actor.hasMatch(senderId) ||
        shareId.isEmpty ||
        documentUid.isEmpty ||
        pageId.isEmpty ||
        (stroke != null && !supported(stroke.tool))) {
      throw ArgumentError('Invalid ephemeral share ink preview.');
    }
    final points = stroke?.points ?? const <InkPoint>[];
    final count = math.min(maximumPoints, points.length);
    return {
      'type': 'share_preview',
      'shareId': shareId,
      'documentUid': documentUid,
      'pageId': pageId,
      'senderId': senderId,
      'stroke': stroke == null || points.isEmpty
          ? null
          : {
              'tool': stroke.tool.index,
              'color': stroke.color.toARGB32(),
              'width': stroke.width,
              'points': [
                for (var index = 0; index < count; index++)
                  [
                    points[_sampleIndex(index, count, points.length)].dx,
                    points[_sampleIndex(index, count, points.length)].dy,
                    points[_sampleIndex(index, count, points.length)].pressure,
                  ],
              ],
            },
    };
  }

  static ShareInkPreview? decode(Object? data) {
    if (data is! Map<String, dynamic> || data['type'] != 'share_preview') {
      return null;
    }
    final shareId = data['shareId'];
    final documentUid = data['documentUid'];
    final pageId = data['pageId'];
    final senderId = data['senderId'];
    if (shareId is! String ||
        shareId.isEmpty ||
        documentUid is! String ||
        documentUid.isEmpty ||
        pageId is! String ||
        pageId.isEmpty ||
        senderId is! String ||
        !_actor.hasMatch(senderId)) {
      return null;
    }
    InkStroke? stroke;
    final raw = data['stroke'];
    if (raw != null) {
      if (raw is! Map ||
          raw['tool'] is! int ||
          raw['color'] is! int ||
          raw['width'] is! num ||
          raw['points'] is! List) {
        return null;
      }
      final index = raw['tool'] as int;
      final colorValue = raw['color'] as int;
      final width = (raw['width'] as num).toDouble();
      final rawPoints = raw['points'] as List;
      if (index < 0 ||
          index >= DrawingTool.values.length ||
          !supported(DrawingTool.values[index]) ||
          colorValue < 0 ||
          colorValue > 0xffffffff ||
          !width.isFinite ||
          width <= 0 ||
          width > 100 ||
          rawPoints.isEmpty ||
          rawPoints.length > maximumPoints) {
        return null;
      }
      final points = <InkPoint>[];
      for (final item in rawPoints) {
        if (item is! List || item.length != 3 || item.any((v) => v is! num)) {
          return null;
        }
        final dx = (item[0] as num).toDouble();
        final dy = (item[1] as num).toDouble();
        final pressure = (item[2] as num).toDouble();
        if (!dx.isFinite ||
            !dy.isFinite ||
            !pressure.isFinite ||
            dx.abs() > 1000000 ||
            dy.abs() > 1000000 ||
            pressure < 0 ||
            pressure > 2) {
          return null;
        }
        points.add(InkPoint(dx: dx, dy: dy, pressure: pressure));
      }
      stroke = InkStroke(
        id: 'share-preview-$senderId',
        points: points,
        color: Color(colorValue),
        width: width,
        tool: DrawingTool.values[index],
      );
    }
    return ShareInkPreview(
      shareId: shareId,
      documentUid: documentUid,
      pageId: pageId,
      senderId: senderId,
      stroke: stroke,
    );
  }
}
