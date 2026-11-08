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

/// Two scalar property edits of the same UID can merge by field.
bool _canMergeDifferentFields(
  OperationEnvelope remote,
  OperationEnvelope local,
) {
  if (remote.kind != OperationKind.objectSet ||
      local.kind != OperationKind.objectSet ||
      remote.pageId != local.pageId) {
    return false;
  }
  final remoteProperties = remote.payload['properties'];
  final localProperties = local.payload['properties'];
  if (remoteProperties is! Map ||
      localProperties is! Map ||
      remoteProperties.containsKey('assetId') ||
      localProperties.containsKey('assetId')) {
    return false;
  }
  final remoteKeys = remoteProperties.keys.toSet();
  final localKeys = localProperties.keys.toSet();
  return remoteKeys.intersection(localKeys).isEmpty;
}

String? _referencedAssetId(OperationEnvelope operation) {
  if (operation.kind == OperationKind.assetAttach ||
      operation.kind == OperationKind.assetDetach) {
    return operation.payload['assetId'] as String?;
  }
  if (operation.kind == OperationKind.objectSet) {
    final properties = operation.payload['properties'];
    if (properties is Map && properties['assetId'] is String) {
      return properties['assetId'] as String;
    }
  }
  return null;
}

/// Keeps local outbox immutable while applying independent remote changes.
bool _canProjectIndependentRemote(
  OperationEnvelope remote,
  List<OperationEnvelope> pendingLocal,
) {
  if (pendingLocal.isEmpty) {
    return true;
  }
  if (remote.kind.target != OperationTarget.object) {
    return false;
  }
  final remoteAssetId = _referencedAssetId(remote);
  return pendingLocal.every((local) {
    if (local.documentId != remote.documentId ||
        local.kind.target != OperationTarget.object) {
      return false;
    }
    if (local.objectId == remote.objectId) {
      return _canMergeDifferentFields(remote, local);
    }
    final localAssetId = _referencedAssetId(local);
    if (remoteAssetId == null || localAssetId == null) {
      return true;
    }
    return remoteAssetId != localAssetId;
  });
}

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
    required String actorId,
    Future<void> Function()? onLibraryChanged,
    bool enableRealtime = true,
  }) {
    if (accountId.isEmpty || actorId.isEmpty) {
      throw ArgumentError('V2 account and persistent actor IDs are required.');
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
      actorId: actorId,
      checkpointScope: 'account:$accountId',
      apiClient: apiClient,
      enableRealtime: enableRealtime,
      applyRemote: (operation, pendingLocal) async {
        // Disjoint objects and scalar fields merge without snapshots.
        // Shared fields, assets and containers require full rebase.
        if (!_canProjectIndependentRemote(operation, pendingLocal)) {
          throw StateError('Remote v2 operation awaits local outbox ACK.');
        }
        await projector.apply(operation);
      },
      prepareRemoteOperation: (operation) =>
          projector.prepareRemoteMedia(operation, assetGateway),
      prepareLocalOperations: (operations) => assetGateway.uploadPendingAssets(
        operations,
        projector.verifiedUploadBytes,
      ),
      onRemoteCommitted: (operation) => runtime._onRemoteCommitted(operation),
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

  /// Returns the mounted writer owner without registering another controller.
  EditorController? editorForDocument(String documentId) {
    final editor = _activeEditor;
    if (editor == null || editor.notebook.uid != documentId) {
      return null;
    }
    return editor;
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
    if (editor == null || operation.kind.target == OperationTarget.document) {
      await onLibraryChanged?.call();
    }
  }

  Future<void> start() => engine.start();

  /// The account owner must remain current across every startup await.
  /// Cancellation retains an established v2 write fence and stops transport.
  /// The caller decides whether to publish the ready runtime; no v1 fallback.
  Future<bool> startForCurrentAccount({
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) {
      await stop();
      return false;
    }
    try {
      await repository.enableAccountOperations(writer);
      if (!isCurrent()) {
        await stop();
        return false;
      }
      await engine.start(isCurrent: isCurrent);
      if (!isCurrent()) {
        await stop();
        return false;
      }
      return true;
    } catch (_) {
      await stop();
      rethrow;
    }
  }

  Future<void> stop() => engine.stop();

  void dispose() {
    _activeEditor = null;
    engine.dispose();
  }
}
