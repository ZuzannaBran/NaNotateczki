import 'package:flutter/material.dart';

import '../constants.dart';
import '../models/drawing_tool.dart';
import '../models/note_page.dart';
import '../models/stroke.dart';

class NoteEditorController extends ChangeNotifier {
  NoteEditorController() {
    pages = <NotePage>[NotePage(id: 'page-1', title: 'Page 1')];
  }

  late List<NotePage> pages;
  int currentPageIndex = 0;
  DrawingTool tool = DrawingTool.pen;
  Color inkColor = inkBlack;
  double strokeWidth = defaultStrokeWidth;

  Stroke? _inProgress;

  NotePage get currentPage => pages[currentPageIndex];
  Stroke? get inProgressStroke => _inProgress;

  bool get canUndo => currentPage.strokes.isNotEmpty;
  bool get canRedo => currentPage.redoStack.isNotEmpty;

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

  void startStroke(Offset point) {
    final strokeColor = tool == DrawingTool.eraser ? paperColor : inkColor;
    _inProgress = Stroke(
      points: <Offset>[point],
      color: strokeColor,
      width: strokeWidth,
      tool: tool,
    );
    notifyListeners();
  }

  void appendPoint(Offset point) {
    if (_inProgress == null) {
      return;
    }
    _inProgress!.points.add(point);
    notifyListeners();
  }

  void endStroke() {
    if (_inProgress == null) {
      return;
    }
    currentPage.strokes.add(_inProgress!);
    currentPage.redoStack.clear();
    _inProgress = null;
    notifyListeners();
  }

  void undo() {
    if (currentPage.strokes.isEmpty) {
      return;
    }
    currentPage.redoStack.add(currentPage.strokes.removeLast());
    notifyListeners();
  }

  void redo() {
    if (currentPage.redoStack.isEmpty) {
      return;
    }
    currentPage.strokes.add(currentPage.redoStack.removeLast());
    notifyListeners();
  }

  void addPage() {
    final nextIndex = pages.length + 1;
    pages.add(NotePage(id: 'page-$nextIndex', title: 'Page $nextIndex'));
    currentPageIndex = pages.length - 1;
    notifyListeners();
  }

  void setCurrentPage(int index) {
    if (index < 0 || index >= pages.length) {
      return;
    }
    currentPageIndex = index;
    notifyListeners();
  }
}
