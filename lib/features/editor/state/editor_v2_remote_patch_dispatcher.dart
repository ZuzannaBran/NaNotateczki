import '../../../data/sync/operation_protocol.dart';
import '../../../data/sync/operation_store.dart';
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
    this.onDocumentCommitted,
  }) {
    if (editor.operationWriter == null ||
        !identical(editor.repository, repository)) {
      throw ArgumentError('The dispatcher requires the migrated v2 editor.');
    }
  }

  final EditorController editor;
  final NotebookRepository repository;

  /// Refreshes the owning library after document metadata or deletion.
  final Future<void> Function(OperationEnvelope)? onDocumentCommitted;

  Future<void> onRemoteCommitted(OperationEnvelope operation) async {
    final updatesActiveEditor =
        operation.documentId == editor.notebook.uid &&
        operation.kind != OperationKind.documentCreate;
    if (updatesActiveEditor) {
      editor.noteV2RemoteCommit();
    }
    await _dispatchRemoteCommitted(operation);
    if (updatesActiveEditor) {
      editor.completeV2RemotePatch();
    }
  }

  Future<void> _dispatchRemoteCommitted(OperationEnvelope operation) async {
    if (operation.documentId != editor.notebook.uid) {
      if (operation.kind.target == OperationTarget.document) {
        await onDocumentCommitted?.call(operation);
      }
      return;
    }
    if (operation.kind.target == OperationTarget.document) {
      if (operation.kind == OperationKind.documentDelete) {
        if (!editor.applyConfirmedV2DocumentDeletion()) {
          throw StateError('Committed document deletion was deferred.');
        }
      } else {
        if (editor.isV2DocumentDeleted) {
          return;
        }
        if (operation.kind == OperationKind.documentSet) {
          final notebook = await repository.getNotebook(operation.documentId);
          if (notebook == null ||
              !editor.applyConfirmedV2DocumentMetadata(
                title: notebook.title,
                folder: notebook.folder,
              )) {
            throw StateError('Committed document metadata was deferred.');
          }
        } else if (operation.kind != OperationKind.documentCreate) {
          throw UnsupportedError(
            'Unknown document operation: ${operation.kind.wireName}.',
          );
        }
      }
      await onDocumentCommitted?.call(operation);
      return;
    }
    if (editor.isV2DocumentDeleted) {
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
    // Image creation announces only metadata. Its verified bytes become
    // renderable at asset.attach, not at object.create.
    if (operation.kind == OperationKind.objectCreate &&
        operation.payload['value'] is Map &&
        (operation.payload['value'] as Map)['objectType'] == 'image') {
      return;
    }
    if (operation.kind == OperationKind.objectMove) {
      final movedId = operation.objectId!;
      final owners = [
        for (final page in notebook.pages)
          if (_ownsObject(page, movedId)) page,
      ];
      if (owners.isEmpty) {
        final store = OperationStore(repository.database);
        final deleted =
            await store.wasObjectDeleted(
              documentId: operation.documentId,
              objectId: movedId,
            ) ||
            await store.isTombstoned(operation.documentId, 'page', sourceId);
        if (deleted) {
          // The operation store accepted a stale move as a no-op. Do not
          // advance the UI cursor if an earlier deletion was not rendered.
          if (editor.pages.any((page) => _ownsObject(page, movedId))) {
            throw StateError('The editor still displays a deleted object.');
          }
          return;
        }
      }
      if (owners.length != 1) {
        throw StateError('Committed move has no unique SQLite target.');
      }
      final visibleOwners = [
        for (final page in editor.pages)
          if (_ownsObject(page, movedId)) page.id,
      ];
      if (visibleOwners.length > 1) {
        throw StateError('Committed move has no unique visible source.');
      }
      // Concurrent moves may share the original envelope page. Remove the
      // object from its last rendered location, including an intermediate
      // losing destination, before displaying the durable winner.
      final source = _page(
        notebook.pages,
        visibleOwners.isEmpty ? sourceId : visibleOwners.single,
      );
      if (source == null) {
        throw StateError('Committed move has no readable source page.');
      }
      // A concurrent operation with a lower rank may have committed as a
      // no-op. Use the durable winning location, not its stale toPageId.
      final destination = owners.single;
      if (destination.id == source.id) {
        _applyObject(source, movedId);
        return;
      }
      if (!editor.applyConfirmedV2PageMovePatch(
        source: source,
        destination: destination,
      )) {
        throw StateError('Committed move patch was deferred.');
      }
      return;
    }

    final objectId = operation.objectId!;
    final owners = [
      for (final page in notebook.pages)
        if (_ownsObject(page, objectId)) page,
    ];
    if (owners.length > 1) {
      throw StateError('Committed object has ambiguous SQLite identity.');
    }
    final visibleOwners = [
      for (final page in editor.pages)
        if (_ownsObject(page, objectId)) page.id,
    ];
    if (visibleOwners.length > 1) {
      throw StateError('Committed object has ambiguous visible identity.');
    }
    if (owners.isNotEmpty) {
      final destination = owners.single;
      if (visibleOwners.isNotEmpty && visibleOwners.single != destination.id) {
        final source = _page(notebook.pages, visibleOwners.single);
        if (source == null ||
            !editor.applyConfirmedV2PageMovePatch(
              source: source,
              destination: destination,
            )) {
          throw StateError('Committed relocated object patch was deferred.');
        }
      } else {
        _applyObject(destination, objectId);
      }
      return;
    }
    // An object deleted on its old page may already be displayed elsewhere.
    for (final id in visibleOwners) {
      final page = _page(notebook.pages, id);
      if (page == null) {
        throw StateError('Committed deletion awaits a page patch.');
      }
      _applyObject(page, objectId);
    }
    if (visibleOwners.isEmpty) {
      final source = _page(notebook.pages, sourceId);
      if (source == null && editor.pageById(sourceId) != null) {
        throw StateError('The editor has a stale deleted page.');
      }
    }
  }

  void _applyObject(NotePage page, String objectId) {
    final ink = [
      for (var i = 0; i < page.inkStrokes.length; i++)
        if (page.inkStrokes[i].id == objectId)
          (stroke: page.inkStrokes[i], index: i),
    ];
    final text = [
      for (var i = 0; i < page.textBlocks.length; i++)
        if (page.textBlocks[i].id == objectId)
          (block: page.textBlocks[i], index: i),
    ];
    final images = [
      for (var i = 0; i < page.imageBlocks.length; i++)
        if (page.imageBlocks[i].id == objectId)
          (block: page.imageBlocks[i], index: i),
    ];
    if (ink.length + text.length + images.length > 1) {
      throw StateError('Ambiguous object identity in the SQLite projection.');
    }
    final supplied = ink.isNotEmpty || text.isNotEmpty || images.isNotEmpty;
    final applied = editor.applyConfirmedShareObjectPatch(
      pageId: page.id,
      objectId: objectId,
      stroke: ink.isEmpty ? null : ink.single.stroke,
      text: text.isEmpty ? null : text.single.block,
      image: images.isEmpty ? null : images.single.block,
      deleted: !supplied,
      sortIndex: ink.isNotEmpty
          ? ink.single.index
          : text.isNotEmpty
          ? text.single.index
          : images.isNotEmpty
          ? images.single.index
          : null,
    );
    if (!applied) {
      throw StateError('Committed object patch was deferred.');
    }
  }

  static bool _ownsObject(NotePage page, String id) =>
      page.inkStrokes.any((stroke) => stroke.id == id) ||
      page.textBlocks.any((text) => text.id == id) ||
      page.imageBlocks.any((image) => image.id == id);

  static NotePage? _page(List<NotePage> pages, String id) {
    for (final page in pages) {
      if (page.id == id) {
        return page;
      }
    }
    return null;
  }
}
