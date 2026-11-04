import 'dart:convert';
import 'dart:ui';

import '../../features/notebook/domain/drawing_tool.dart';
import '../../features/notebook/domain/ink_stroke.dart';
import '../../features/notebook/domain/note_page.dart';
import 'operation_protocol.dart';

/// A completed ink change; never a pointer preview or a document snapshot.
///
/// The caller must commit each intent through SyncEngine.writeLocal with a
/// transactional SQLite projection callback before acknowledging local save.
class ShareInkIntent {
  const ShareInkIntent({
    required this.kind,
    required this.pageId,
    required this.objectId,
    required this.payload,
  });

  final OperationKind kind;
  final String pageId;
  final String objectId;
  final Map<String, dynamic> payload;
}

/// Converts committed stroke changes into object-level Share v2 operations.
///
/// Move, style and z-order are independent properties. This preserves an
/// unrelated change to the same stroke when operations are rebased.
class ShareInkEditAdapter {
  static const maxPayloadBytes = 512 * 1024;
  static const maxPointsPerStroke = 10000;

  List<ShareInkIntent> plan({
    required NotePage before,
    required NotePage after,
  }) {
    if (before.id.isEmpty || before.id != after.id) {
      throw ArgumentError('Ink edits require the same stable page ID.');
    }
    final previous = _indexed(before.inkStrokes);
    final current = _indexed(after.inkStrokes);
    final previousOrder = <String, int>{
      for (var i = 0; i < before.inkStrokes.length; i++)
        before.inkStrokes[i].id: i,
    };
    final intents = <ShareInkIntent>[];

    for (final old in before.inkStrokes) {
      if (!current.containsKey(old.id)) {
        intents.add(
          _intent(OperationKind.objectDelete, before.id, old.id, const {}),
        );
      }
    }
    for (var index = 0; index < after.inkStrokes.length; index++) {
      final stroke = after.inkStrokes[index];
      final older = previous[stroke.id];
      final fields = _fields(stroke, index);
      if (older == null) {
        intents.add(
          _intent(OperationKind.strokeCreate, after.id, stroke.id, {
            'value': fields,
          }),
        );
        continue;
      }
      final original = _fields(older, previousOrder[stroke.id]!);
      if (!_equalPoints(original['points'] as List, fields['points'] as List)) {
        intents.add(
          _intent(OperationKind.objectTransform, after.id, stroke.id, {
            'properties': {'points': fields['points']},
          }),
        );
      }
      final style = <String, dynamic>{};
      for (final key in ['colorValue', 'width', 'toolIndex']) {
        if (original[key] != fields[key]) {
          style[key] = fields[key];
        }
      }
      if (style.isNotEmpty) {
        intents.add(
          _intent(OperationKind.objectSet, after.id, stroke.id, {
            'properties': style,
          }),
        );
      }
      if (previousOrder[stroke.id] != index) {
        intents.add(
          _intent(OperationKind.objectReorder, after.id, stroke.id, {
            'properties': {'sortIndex': index},
          }),
        );
      }
    }
    return intents;
  }

  /// Reconstructs only the touched stroke for an editor patch.
  ///
  /// Its operation must be persisted before calling the editor's
  /// applyConfirmedShareObjectPatch. Invalid remote strokes fail closed.
  InkStroke decode(String objectId, Map<String, dynamic> node) {
    if (node['type'] != OperationKind.strokeCreate.wireName ||
        node['properties'] is! Map) {
      throw const FormatException('Not a projected ink stroke.');
    }
    final fields = Map<String, dynamic>.from(node['properties'] as Map);
    final color = fields['colorValue'];
    final width = fields['width'];
    final toolIndex = fields['toolIndex'];
    final rawPoints = fields['points'];
    if (objectId.isEmpty ||
        color is! int ||
        color < 0 ||
        color > 0xFFFFFFFF ||
        width is! num ||
        !width.toDouble().isFinite ||
        width <= 0 ||
        toolIndex is! int ||
        toolIndex < 0 ||
        toolIndex >= DrawingTool.values.length ||
        rawPoints is! List ||
        rawPoints.isEmpty ||
        rawPoints.length > maxPointsPerStroke) {
      throw const FormatException('Invalid projected ink properties.');
    }
    final tool = DrawingTool.values[toolIndex];
    if (!_isPersistedInk(tool)) {
      throw const FormatException('Ink tool cannot be persisted.');
    }
    final points = <InkPoint>[];
    for (final raw in rawPoints) {
      if (raw is! List ||
          raw.length != 3 ||
          raw.any((value) => value is! num || !value.toDouble().isFinite)) {
        throw const FormatException('Invalid projected ink point.');
      }
      points.add(
        InkPoint(
          dx: (raw[0] as num).toDouble(),
          dy: (raw[1] as num).toDouble(),
          pressure: (raw[2] as num).toDouble(),
        ),
      );
    }
    return InkStroke(
      id: objectId,
      points: points,
      color: Color(color),
      width: width.toDouble(),
      tool: tool,
    );
  }

  static Map<String, InkStroke> _indexed(List<InkStroke> strokes) {
    final result = <String, InkStroke>{};
    for (final stroke in strokes) {
      if (stroke.id.isEmpty || result.containsKey(stroke.id)) {
        throw StateError('Duplicate or missing ink object ID.');
      }
      result[stroke.id] = stroke;
    }
    return result;
  }

  static Map<String, dynamic> _fields(InkStroke stroke, int index) {
    if (!_isPersistedInk(stroke.tool) ||
        !stroke.width.isFinite ||
        stroke.width <= 0 ||
        stroke.points.isEmpty ||
        stroke.points.length > maxPointsPerStroke ||
        stroke.points.any(
          (point) =>
              !point.dx.isFinite ||
              !point.dy.isFinite ||
              !point.pressure.isFinite,
        )) {
      throw StateError('Invalid committed ink stroke.');
    }
    return {
      'objectType': 'stroke',
      'colorValue': stroke.color.toARGB32(),
      'width': stroke.width,
      'toolIndex': stroke.tool.index,
      'sortIndex': index,
      'points': [
        for (final point in stroke.points) [point.dx, point.dy, point.pressure],
      ],
    };
  }

  static bool _isPersistedInk(DrawingTool tool) =>
      tool == DrawingTool.pen ||
      tool == DrawingTool.highlighter ||
      tool.isShape;

  static bool _equalPoints(List old, List current) {
    if (old.length != current.length) {
      return false;
    }
    for (var index = 0; index < old.length; index++) {
      final a = old[index] as List;
      final b = current[index] as List;
      if (a.length != b.length) {
        return false;
      }
      for (var coordinate = 0; coordinate < a.length; coordinate++) {
        if (a[coordinate] != b[coordinate]) {
          return false;
        }
      }
    }
    return true;
  }

  static ShareInkIntent _intent(
    OperationKind kind,
    String pageId,
    String objectId,
    Map<String, dynamic> payload,
  ) {
    if (utf8.encode(jsonEncode(payload)).length > maxPayloadBytes) {
      throw StateError('Ink change exceeds the safe operation size.');
    }
    OperationEnvelope.validateV2Payload(
      kind: kind,
      payload: payload,
      documentId: 'share-ink',
      objectId: objectId,
    );
    return ShareInkIntent(
      kind: kind,
      pageId: pageId,
      objectId: objectId,
      payload: payload,
    );
  }
}
