import 'stroke.dart';

class NotePage {
  NotePage({required this.id, required this.title, List<Stroke>? strokes})
    : strokes = strokes ?? <Stroke>[],
      redoStack = <Stroke>[];

  final String id;
  final String title;
  final List<Stroke> strokes;
  final List<Stroke> redoStack;
}
