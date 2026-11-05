import 'package:uuid/uuid.dart';

import '../../features/editor/state/editor_controller.dart';
import '../../features/editor/state/editor_v2_operation_writer.dart';
import '../../features/editor/state/editor_v2_remote_patch_dispatcher.dart';
import '../../features/notebook/data/notebook_repository.dart';
import 'api_client.dart';
import 'editor_sqlite_projector.dart';
import 'operation_asset_gateway.dart';
import 'operation_gateway.dart';
import 'operation_protocol.dart';
import 'operation_store.dart';
import 'sync_engine.dart';
import 'verified_editor_asset_buffer.dart';

/// Owns the operational editor journal for one confirmed v2 account.
///
/// It is intentionally separate from the legacy account sync. The caller
/// must verify the account protocol and local namespace before constructing
/// this runtime; a v1 document must never be imported implicitly.
class EditorV2AccountRuntime {
  EditorV2AccountRuntime._({
    required this.repository,
    required this.writer,
    required this.engine,
    required this.projector,
    required this.store,
    required this.assetGateway,
    required this.onLibraryChanged,
  });

  factory EditorV2AccountRuntime({
    required NotebookRepository repository,
    required ApiClient apiClient,
    required String accountId,
    Future<void> Function()? onLibraryChanged,
  }) {
    if (accountId.isEmpty) {
      throw ArgumentError('V2 account identity is required.');
    }
    final store = OperationStore(repository.database);
    final buffer = VerifiedEditorAssetBuffer();
    final projector = EditorSqliteProjector(
      repository.database,
      verifiedAssetBuffer: buffer,
    );
    final assetGateway = OperationAssetGateway(apiClient);
    late EditorV2AccountRuntime runtime;
    final engine = SyncEngine(
      store: store,
      gateway: HttpOperationGateway(apiClient),
      actorId: const Uuid().v4(),
      checkpointScope: 'account:$accountId',
      apiClient: apiClient,
      applyRemote: (operation, pendingLocal) async {
        // A conflict must not be flattened to a snapshot or silently
        // overwrite an optimistic local gesture. The engine pushes the
        // durable local outbox and retries this remote cursor afterwards.
        if (pendingLocal.isNotEmpty) {
          throw StateError('Remote v2 operation awaits local outbox ACK.');
        }
        await projector.apply(operation);
      },
      prepareRemoteOperation: (operation) =>
          projector.prepareRemoteMedia(operation, assetGateway),
      onRemoteCommitted: (operation) =>
          runtime._onRemoteCommitted(operation),
    );
    runtime = EditorV2AccountRuntime._(
      repository: repository,
      writer: EditorV2OperationWriter(
        syncEngine: engine,
        projector: projector,
        assetGateway: assetGateway,
        onCommitted: repository.reportOperationCommit,
      ),
      engine: engine,
      projector: projector,
      store: store,
      assetGateway: assetGateway,
      onLibraryChanged: onLibraryChanged,
    );
    return runtime;
  }

  final NotebookRepository repository;
  final EditorV2OperationWriter writer;
  final SyncEngine engine;
  final EditorSqliteProjector projector;
  final OperationStore store;
  final OperationAssetGateway assetGateway;
  final Future<void> Function()? onLibraryChanged;

  EditorController? _activeEditor;

  /// Only the currently mounted operational editor receives object patches.
  void attachEditor(EditorController editor) {
    if (!identical(editor.repository, repository) ||
        !identical(editor.operationWriter, writer) ||
        (_activeEditor != null && !identical(_activeEditor, editor))) {
      throw StateError('V2 editor ownership or SQLite namespace mismatch.');
    }
    _activeEditor = editor;
  }

  void detachEditor(EditorController editor) {
    if (identical(_activeEditor, editor)) {
      _activeEditor = null;
    }
  }

  Future<void> _onRemoteCommitted(OperationEnvelope operation) async {
    final editor = _activeEditor;
    if (editor != null) {
      await EditorV2RemotePatchDispatcher(
        editor: editor,
        repository: repository,
      ).onRemoteCommitted(operation);
    }
    repository.reportOperationCommit(operation.documentId, [operation]);
    if (editor == null ||
        operation.kind.target == OperationTarget.document) {
      await onLibraryChanged?.call();
    }
  }

  Future<void> start() => engine.start();

  Future<void> stop() => engine.stop();

  void dispose() {
    _activeEditor = null;
    engine.dispose();
  }
}
