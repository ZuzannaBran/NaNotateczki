import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart'
    as mlkit;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../notebook/data/notebook_repository.dart';
import '../../notebook/domain/drawing_tool.dart';
import '../../notebook/domain/image_block.dart';
import '../../notebook/domain/notebook.dart';
import '../../notebook/domain/note_page.dart';
import '../../notebook/domain/shape.dart';
import '../../notebook/domain/stroke.dart';
import '../../notebook/domain/stroke_point.dart';
import '../../notebook/domain/text_block.dart';
import 'editor_actions.dart';

class EditorController extends ChangeNotifier {
  EditorController({required this.repository, required this.notebook}) {
    pages = notebook.pages;
    currentPageIndex = 0;
  }

  final NotebookRepository repository;
  final Notebook notebook;
  final Uuid _uuid = const Uuid();
  final ImagePicker _imagePicker = ImagePicker();

  late List<NotePage> pages;
  int currentPageIndex = 0;
  DrawingTool tool = DrawingTool.pen;
  Color inkColor = const Color(0xFF1E1E1E);
  double strokeWidth = 3.0;

  Stroke? _inProgress;
  Shape? _inProgressShape;
  List<Offset> _shapePoints = <Offset>[];
  List<Offset> _lassoPoints = <Offset>[];
  Set<String> _selectedStrokeIds = <String>{};
  bool _isSelecting = false;
  bool _isDraggingSelection = false;
  Offset? _lastDragPoint;
  List<Stroke>? _dragStartSnapshot;

  final List<EditorAction> _undoActions = <EditorAction>[];
  final List<EditorAction> _redoActions = <EditorAction>[];

  NotePage get currentPage => pages[currentPageIndex];
  Stroke? get inProgressStroke => _inProgress;
  Shape? get inProgressShape => _inProgressShape;
  List<Offset> get lassoPoints => _lassoPoints;
  Set<String> get selectedStrokeIds => _selectedStrokeIds;
  bool get isSelecting => _isSelecting;
  bool get hasSelection => _selectedStrokeIds.isNotEmpty;

  Rect? get selectionBounds {
    if (!hasSelection) {
      return null;
    }
    final points = <Offset>[];
    for (final stroke in currentPage.strokes) {
      if (!_selectedStrokeIds.contains(stroke.id)) {
        continue;
      }
      for (final point in stroke.points) {
        points.add(Offset(point.dx, point.dy));
      }
    }
    if (points.isEmpty) {
      return null;
    }
    final first = points.first;
    var minX = first.dx;
    var maxX = first.dx;
    var minY = first.dy;
    var maxY = first.dy;
    for (final point in points.skip(1)) {
      minX = point.dx < minX ? point.dx : minX;
      maxX = point.dx > maxX ? point.dx : maxX;
      minY = point.dy < minY ? point.dy : minY;
      maxY = point.dy > maxY ? point.dy : maxY;
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY).inflate(6);
  }

  bool get canUndo => _undoActions.isNotEmpty;
  bool get canRedo => _redoActions.isNotEmpty;

  void setTool(DrawingTool newTool) {
    tool = newTool;
    notifyListeners();
  }

  void setColor(Color newColor) {
    inkColor = newColor;
    tool = DrawingTool.pen;
    notifyListeners();
  }

  void setStrokeWidth(double value) {
    strokeWidth = value;
    notifyListeners();
  }

  void handlePointerDown(Offset point, double pressure) {
    if (tool == DrawingTool.shape) {
      _startShape(point);
      return;
    }
    if (tool == DrawingTool.lasso) {
      if (_hitSelection(point)) {
        _isDraggingSelection = true;
        _lastDragPoint = point;
        _dragStartSnapshot = _cloneStrokes(currentPage.strokes);
        notifyListeners();
        return;
      }
      _clearSelection();
      _isSelecting = true;
      _lassoPoints = <Offset>[point];
      notifyListeners();
      return;
    }

    startStroke(point, pressure);
  }

  void handlePointerMove(Offset point, double pressure) {
    if (tool == DrawingTool.shape) {
      _updateShapePreview(point);
      return;
    }
    if (tool == DrawingTool.lasso) {
      if (_isSelecting) {
        _lassoPoints = [..._lassoPoints, point];
        notifyListeners();
        return;
      }
      if (_isDraggingSelection) {
        _moveSelection(point);
        return;
      }
      return;
    }

    appendPoint(point, pressure);
  }

  void handlePointerUp() {
    if (tool == DrawingTool.shape) {
      _finalizeShape();
      return;
    }
    if (tool == DrawingTool.lasso) {
      if (_isSelecting) {
        _finalizeSelection();
      }
      if (_isDraggingSelection) {
        _isDraggingSelection = false;
        _lastDragPoint = null;
        _commitMoveSelection();
      }
      notifyListeners();
      return;
    }

    endStroke();
  }

  Future<String?> handleTap(Offset point) async {
    if (tool == DrawingTool.text) {
      addTextBlock(point);
      return null;
    }
    if (tool == DrawingTool.image) {
      return addImageBlock(point);
    }
    return null;
  }

  void startStroke(Offset point, double pressure) {
    if (!_canDraw(tool)) {
      return;
    }
    final strokeColor = tool == DrawingTool.highlighter
        ? inkColor.withValues(alpha: 0.35)
        : inkColor;
    _inProgress = Stroke(
      id: _uuid.v4(),
      points: <StrokePoint>[
        StrokePoint(dx: point.dx, dy: point.dy, pressure: pressure),
      ],
      color: strokeColor,
      width: strokeWidth,
      tool: tool,
    );
    notifyListeners();
  }

  void appendPoint(Offset point, double pressure) {
    if (_inProgress == null) {
      return;
    }
    _inProgress!.points.add(
      StrokePoint(dx: point.dx, dy: point.dy, pressure: pressure),
    );
    notifyListeners();
  }

  void endStroke() {
    if (_inProgress == null) {
      return;
    }
    _applyAction(AddStrokeAction(_inProgress!));
    _inProgress = null;
    _save();
  }

  void undo() {
    if (_undoActions.isEmpty) {
      return;
    }
    final action = _undoActions.removeLast();
    final updated = action.revert(currentPage);
    _redoActions.add(action);
    _updatePage(updated);
    _save();
  }

  void redo() {
    if (_redoActions.isEmpty) {
      return;
    }
    final action = _redoActions.removeLast();
    final updated = action.apply(currentPage);
    _undoActions.add(action);
    _updatePage(updated);
    _save();
  }

  void addPage() {
    final nextIndex = pages.length + 1;
    final page = NotePage(
      id: _uuid.v4(),
      title: 'Page $nextIndex',
      strokes: <Stroke>[],
      shapes: <Shape>[],
      textBlocks: <TextBlock>[],
      imageBlocks: <ImageBlock>[],
      redoStack: <Stroke>[],
      isBookmarked: false,
    );
    pages = [...pages, page];
    currentPageIndex = pages.length - 1;
    _save();
    notifyListeners();
  }

  void setCurrentPage(int index) {
    if (index < 0 || index >= pages.length) {
      return;
    }
    currentPageIndex = index;
    _clearSelection();
    notifyListeners();
  }

  void toggleBookmark() {
    final page = currentPage.copyWith(isBookmarked: !currentPage.isBookmarked);
    _updatePage(page);
    _save();
  }

  void addTextBlock(Offset position) {
    final block = TextBlock(
      id: _uuid.v4(),
      text: 'Text',
      position: position,
      fontSize: 18,
      color: inkColor,
      width: 240,
    );
    _applyAction(AddTextAction(block));
    _save();
  }

  void updateTextBlockText(TextBlock before, String text) {
    final after = before.copyWith(text: text);
    _applyAction(UpdateTextAction(before: before, after: after));
    _save();
  }

  void updateTextBlockPosition(String id, Offset position) {
    final updated = currentPage.textBlocks
        .map((item) => item.id == id ? item.copyWith(position: position) : item)
        .toList();
    _updatePage(currentPage.copyWith(textBlocks: updated));
  }

  void commitTextMove(String id, Offset start, Offset end) {
    if (start == end) {
      return;
    }
    _applyAction(
      MoveTextAction(
        id: id,
        from: OffsetPosition.fromOffset(start),
        to: OffsetPosition.fromOffset(end),
      ),
    );
    _save();
  }

  Future<String?> addImageBlock(Offset position) async {
    final picked = await _imagePicker.pickImage(source: ImageSource.gallery);
    if (picked == null) {
      return null;
    }
    final file = await _persistImage(picked);
    final size = await _imageSize(file);
    final targetWidth = 240.0;
    final ratio = size.width == 0 ? 1.0 : size.height / size.width;
    final targetHeight = targetWidth * ratio;
    final block = ImageBlock(
      id: _uuid.v4(),
      path: file.path,
      ocrText: '',
      position: position,
      width: targetWidth,
      height: targetHeight.clamp(80, 320).toDouble(),
    );
    _applyAction(AddImageAction(block));
    _save();

    final ocrText = await _runOcr(file);
    if (ocrText == null) {
      return 'OCR is not supported on this platform.';
    }
    if (ocrText.trim().isNotEmpty) {
      updateImageBlockOcrText(block.id, ocrText.trim());
    }
    return null;
  }

  Future<String?> runOcrForImage(ImageBlock block) async {
    final file = File(block.path);
    if (!await file.exists()) {
      return 'Image file not found.';
    }
    final ocrText = await _runOcr(file);
    if (ocrText == null) {
      return 'OCR is not supported on this platform.';
    }
    updateImageBlockOcrText(block.id, ocrText.trim());
    return null;
  }

  void updateImageBlockPosition(String id, Offset position) {
    final updated = currentPage.imageBlocks
        .map((item) => item.id == id ? item.copyWith(position: position) : item)
        .toList();
    _updatePage(currentPage.copyWith(imageBlocks: updated));
  }

  void updateImageBlockOcrText(String id, String text) {
    final before = currentPage.imageBlocks.map((item) => item).toList();
    final updated = currentPage.imageBlocks
        .map((item) => item.id == id ? item.copyWith(ocrText: text) : item)
        .toList();
    _applyAction(UpdateImageOcrAction(id: id, ocrText: text, before: before));
    _updatePage(currentPage.copyWith(imageBlocks: updated));
    _save();
  }

  void commitImageMove(String id, Offset start, Offset end) {
    if (start == end) {
      return;
    }
    _applyAction(
      MoveImageAction(
        id: id,
        from: OffsetPosition.fromOffset(start),
        to: OffsetPosition.fromOffset(end),
      ),
    );
    _save();
  }

  Future<File> _persistImage(XFile picked) async {
    final dir = await getApplicationDocumentsDirectory();
    final imagesDir = Directory('${dir.path}/images');
    if (!await imagesDir.exists()) {
      await imagesDir.create(recursive: true);
    }
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final extension = picked.path.split('.').last;
    final target = File('${imagesDir.path}/img_$timestamp.$extension');
    return File(picked.path).copy(target.path);
  }

  Future<Size> _imageSize(File file) async {
    final bytes = await file.readAsBytes();
    final codec = await instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    return Size(image.width.toDouble(), image.height.toDouble());
  }

  Future<String?> _runOcr(File file) async {
    if (!_isOcrSupported()) {
      return null;
    }
    final input = mlkit.InputImage.fromFilePath(file.path);
    final recognizer = mlkit.TextRecognizer(
      script: mlkit.TextRecognitionScript.latin,
    );
    try {
      final result = await recognizer.processImage(input);
      return result.text;
    } finally {
      await recognizer.close();
    }
  }

  bool _isOcrSupported() {
    if (kIsWeb) {
      return false;
    }
    return Platform.isAndroid || Platform.isIOS;
  }

  void _finalizeSelection() {
    if (_lassoPoints.length < 2) {
      _clearSelection();
      _isSelecting = false;
      _lassoPoints = <Offset>[];
      return;
    }
    final bounds = _rectFromPoints(_lassoPoints);
    _selectedStrokeIds = {
      for (final stroke in currentPage.strokes)
        if (_strokeIntersectsRect(stroke, bounds)) stroke.id,
    };
    _isSelecting = false;
    _lassoPoints = <Offset>[];
  }

  void _moveSelection(Offset point) {
    if (_lastDragPoint == null || !hasSelection) {
      return;
    }
    final delta = point - _lastDragPoint!;
    _lastDragPoint = point;

    final updatedStrokes = currentPage.strokes.map((stroke) {
      if (!_selectedStrokeIds.contains(stroke.id)) {
        return stroke;
      }
      final movedPoints = stroke.points
          .map(
            (p) => StrokePoint(
              dx: p.dx + delta.dx,
              dy: p.dy + delta.dy,
              pressure: p.pressure,
            ),
          )
          .toList();
      return Stroke(
        id: stroke.id,
        points: movedPoints,
        color: stroke.color,
        width: stroke.width,
        tool: stroke.tool,
      );
    }).toList();

    _updatePage(currentPage.copyWith(strokes: updatedStrokes));
  }

  bool _hitSelection(Offset point) {
    final bounds = selectionBounds;
    if (bounds == null) {
      return false;
    }
    return bounds.contains(point);
  }

  Rect _rectFromPoints(List<Offset> points) {
    final first = points.first;
    var minX = first.dx;
    var maxX = first.dx;
    var minY = first.dy;
    var maxY = first.dy;
    for (final point in points.skip(1)) {
      minX = point.dx < minX ? point.dx : minX;
      maxX = point.dx > maxX ? point.dx : maxX;
      minY = point.dy < minY ? point.dy : minY;
      maxY = point.dy > maxY ? point.dy : maxY;
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  bool _strokeIntersectsRect(Stroke stroke, Rect rect) {
    for (final point in stroke.points) {
      if (rect.contains(Offset(point.dx, point.dy))) {
        return true;
      }
    }
    return false;
  }

  void _clearSelection() {
    _selectedStrokeIds = <String>{};
    _lassoPoints = <Offset>[];
    _isSelecting = false;
    _isDraggingSelection = false;
    _lastDragPoint = null;
    _dragStartSnapshot = null;
  }

  void _updatePage(NotePage page) {
    pages = [
      for (var i = 0; i < pages.length; i++)
        if (i == currentPageIndex) page else pages[i],
    ];
    notifyListeners();
  }

  bool _canDraw(DrawingTool tool) {
    return tool == DrawingTool.pen ||
        tool == DrawingTool.pencil ||
        tool == DrawingTool.highlighter ||
        tool == DrawingTool.eraser;
  }

  void _startShape(Offset point) {
    _shapePoints = <Offset>[point];
    _inProgressShape = Shape(
      id: _uuid.v4(),
      type: ShapeType.rectangle,
      color: inkColor,
      width: strokeWidth,
      start: point,
      end: point,
    );
    notifyListeners();
  }

  void _updateShapePreview(Offset point) {
    if (_shapePoints.isEmpty || _inProgressShape == null) {
      return;
    }
    _shapePoints = [..._shapePoints, point];
    final type = _recognizeShape(_shapePoints, _shapePoints.first, point);
    final end = type == ShapeType.line
        ? _snapLineEnd(_shapePoints.first, point)
        : point;
    _inProgressShape = Shape(
      id: _inProgressShape!.id,
      type: type,
      color: inkColor,
      width: strokeWidth,
      start: _shapePoints.first,
      end: end,
    );
    notifyListeners();
  }

  void _finalizeShape() {
    if (_shapePoints.length < 2 || _inProgressShape == null) {
      _shapePoints = <Offset>[];
      _inProgressShape = null;
      notifyListeners();
      return;
    }
    final shape = _inProgressShape!;
    _applyAction(AddShapeAction(shape));
    _shapePoints = <Offset>[];
    _inProgressShape = null;
    _save();
  }

  ShapeType _recognizeShape(List<Offset> points, Offset start, Offset end) {
    if (points.length < 2) {
      return ShapeType.rectangle;
    }
    final lineDistance = _averageDistanceToLine(points, start, end);
    if (lineDistance <= 6) {
      return ShapeType.line;
    }
    final bounds = _rectFromPoints(points);
    final width = bounds.width.abs();
    final height = bounds.height.abs();
    if (width <= 0 || height <= 0) {
      return ShapeType.rectangle;
    }
    final ratio = width > height ? width / height : height / width;
    if (ratio <= 1.25) {
      return ShapeType.ellipse;
    }
    return ShapeType.rectangle;
  }

  Offset _snapLineEnd(Offset start, Offset end) {
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final distance = sqrt((dx * dx) + (dy * dy));
    if (distance == 0) {
      return end;
    }
    final angle = atan2(dy, dx);
    const snap = pi / 4;
    final snapped = (angle / snap).round() * snap;
    return Offset(
      start.dx + distance * cos(snapped),
      start.dy + distance * sin(snapped),
    );
  }

  double _averageDistanceToLine(List<Offset> points, Offset start, Offset end) {
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final length = sqrt((dx * dx) + (dy * dy));
    if (length == 0) {
      return double.infinity;
    }
    var total = 0.0;
    for (final point in points) {
      final distance =
          ((dy * point.dx) -
                  (dx * point.dy) +
                  (end.dx * start.dy) -
                  (end.dy * start.dx))
              .abs() /
          length;
      total += distance;
    }
    return total / points.length;
  }

  void _applyAction(EditorAction action) {
    final updated = action.apply(currentPage);
    _undoActions.add(action);
    _redoActions.clear();
    _updatePage(updated);
  }

  List<Stroke> _cloneStrokes(List<Stroke> strokes) {
    return strokes
        .map(
          (stroke) => Stroke(
            id: stroke.id,
            points: stroke.points
                .map(
                  (p) => StrokePoint(dx: p.dx, dy: p.dy, pressure: p.pressure),
                )
                .toList(),
            color: stroke.color,
            width: stroke.width,
            tool: stroke.tool,
          ),
        )
        .toList();
  }

  void _commitMoveSelection() {
    if (_dragStartSnapshot == null) {
      return;
    }
    final before = _dragStartSnapshot!;
    final after = _cloneStrokes(currentPage.strokes);
    if (_strokesChanged(before, after)) {
      _undoActions.add(MoveStrokesAction(before: before, after: after));
      _redoActions.clear();
    }
    _dragStartSnapshot = null;
    _save();
  }

  bool _strokesChanged(List<Stroke> before, List<Stroke> after) {
    if (before.length != after.length) {
      return true;
    }
    for (var i = 0; i < before.length; i++) {
      final a = before[i];
      final b = after[i];
      if (a.id != b.id || a.points.length != b.points.length) {
        return true;
      }
      for (var j = 0; j < a.points.length; j++) {
        final pa = a.points[j];
        final pb = b.points[j];
        if (pa.dx != pb.dx || pa.dy != pb.dy) {
          return true;
        }
      }
    }
    return false;
  }

  Future<void> _save() async {
    final updated = notebook.copyWith(pages: pages, updatedAt: DateTime.now());
    await repository.saveNotebook(updated);
  }
}
