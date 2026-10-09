import '../../features/notebook/domain/ink_eraser_engine.dart';
import '../../features/notebook/domain/note_page.dart';
import '../../features/notebook/domain/notebook.dart';

Notebook flattenErasersForBackup(Notebook notebook) {
  return InkEraserEngine.normalizeNotebook(notebook);
}

NotePage flattenPageErasersForBackup(NotePage page) {
  return InkEraserEngine.normalizePage(page);
}
