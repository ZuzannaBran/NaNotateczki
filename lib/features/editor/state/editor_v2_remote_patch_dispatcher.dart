import '../../../data/sync/operation_protocol.dart';
import '../../notebook/data/notebook_repository.dart';
import '../../notebook/domain/note_page.dart';
import 'editor_controller.dart';

/// Delivers a committed v2 operation without replaying a whole notebook.
///
/// The SyncEngine.onRemoteCommitted callback calls this only after its
/// SQLite transaction. A busy editor throws, leaving the feed cursor at
/// its previous value so the same delivery can be retried safely.
class EditorV2RemotePatchDispatcher {
  EditorV2RemotePatchDispatcher({
    required this.editor,
    required this.repository,
  }) {
    if (editor.operationWriter == null ||
        !identical(editor.repository, repository)) {
      throw ArgumentError('The dispatcher requires the migrated v2 editor.');
    }
  }

  final EditorController editor;
  final NotebookRepository repository;

  Future<void> onRemoteCommitted(OperationEnvelope operation) async {
    if (operation.documentId != editor.notebook.uid) {
      return;
    }
    if (operation.kind.target != OperationTarget.object &&
        operation.kind.target != OperationTarget.page) {
      throw UnsupportedError(
        'Unsupported v2 editor notification: ${operation.kind.wireName}.',
      );
    }
    if (!editor.canApplyConfirmedRemoteNotebook) {
      throw StateError('Editor is busy; retry the committed remote patch.');
    }
    final notebook = await repository.getNotebook(operation.documentId);
    if (notebook == null) {
      throw StateError('Committed v2 notebook projection is unreadable.');
    }

    if (operation.kind.target == OperationTarget.page) {
      final id = operation.objectId!;
      final index = notebook.pages.indexWhere((page) => page.id == id);
      final page = index < 0 ? null : notebook.pages[index];
      final applied = editor.applyConfirmedV2PagePatch(
        pageId: id,
        page: page,
        pageIndex: index < 0 ? null : index,
      );
      if (!applied) {
        throw StateError('Committed page patch was deferred.');
      }
      return;
    }

    final sourceId = operation.pageId!;
    if (operation.kind == OperationKind.objectMove) {
      final destinationId = operation.payload['toPageId'] as String;
      final destination = _page(notebook.pages, destinationId);
      final sourceExists = editor.pageById(sourceId) != null;
      if (sourceExists) {
        final removed = editor.applyConfirmedShareObjectPatch(
          pageId: sourceId,
          objectId: operation.objectId!,
          deleted: true,
        );
        if (!removed) {
          throw StateError('The move source patch was deferred.');
        }
      }
      if (destination == null) {
        throw StateError('Moved destination is absent from SQLite.');
      }
      _applyObject(destination, operation.objectId!);
      return;
    }

    final source = _page(notebook.pages, sourceId);
    if (source == null) {
      // A previously delivered page deletion may have erased the entire
      // target. No old operation may resurrect it.
      if (editor.pageById(sourceId) != null) {
        throw StateError('The editor has a stale deleted page.');
      }
      return;
    }
    _applyObject(source, operation.objectId!);
  }

  void _applyObject(NotePage page, String objectId) {
    final ink = [
      for (var i = 0; i < page.inkStrokes.length; i++)
        if (page.inkStrokes[i].id == objectId)
          (stroke: page.inkStrokes[i], index: i),
    ];
    final text = [
      for (final entry in page.textBlocks)
        if (entry.id == objectId) entry,
    ];
    final images = [
      for (final entry in page.imageBlocks)
        if (entry.id == objectId) entry,
    ];
    if (ink.length + text.length + images.length > 1) {
      throw StateError('Ambiguous object identity in the SQLite projection.');
    }
    final supplied = ink.isNotEmpty || text.isNotEmpty || images.isNotEmpty;
    final applied = editor.applyConfirmedShareObjectPatch(
      pageId: page.id,
      objectId: objectId,
      stroke: ink.isEmpty ? null : ink.single.stroke,
      text: text.isEmpty ? null : text.single,
      image: images.isEmpty ? null : images.single,
      deleted: !supplied,
      sortIndex: ink.isEmpty ? null : ink.single.index,
    );
    if (!applied) {
      throw StateError('Committed object patch was deferred.');
    }
  }

  static NotePage? _page(List<NotePage> pages, String id) {
    for (final page in pages) {
      if (page.id == id) {
        return page;
      }
    }
    return null;
  }
}
