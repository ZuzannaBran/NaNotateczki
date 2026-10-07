import '../../features/notebook/domain/ink_eraser_engine.dart';
import '../../features/notebook/domain/note_page.dart';
import '../../features/notebook/domain/notebook.dart';

Notebook flattenErasersForBackup(Notebook notebook) {
  return notebook.copyWith(
    pages: notebook.pages.map(flattenPageErasersForBackup).toList(),
  );
}

NotePage flattenPageErasersForBackup(NotePage page) {
  final result = InkEraserEngine.flattenLegacyErasers(page.inkStrokes);
  if (!result.changed) {
    return page;
  }
  return page.copyWith(inkStrokes: result.strokes);
}
