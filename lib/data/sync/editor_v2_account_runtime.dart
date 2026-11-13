import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../features/editor/state/editor_controller.dart';
import '../../features/editor/state/editor_v2_operation_writer.dart';
import '../../features/editor/state/editor_v2_remote_patch_dispatcher.dart';
import '../../features/notebook/data/notebook_repository.dart';
import '../../features/notebook/domain/note_page.dart';
import '../../features/notebook/domain/notebook.dart';
import 'api_client.dart';
import 'editor_sqlite_projector.dart';
import 'operation_asset_gateway.dart';
import 'operation_gateway.dart';
import 'library_v2_operation_service.dart';
import 'operation_protocol.dart';
import 'operation_store.dart';
import 'share_ink_preview_codec.dart';
import 'sync_engine.dart';
import 'verified_editor_asset_buffer.dart';
import 'v2_outbox_conflict_policy.dart';

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
    required this.libraryOperations,
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
    final store = OperationStore(
      repository.database,
      checkpointScope: 'account:$accountId',
    );
    final buffer = VerifiedEditorAssetBuffer();
    final projector = EditorSqliteProjector(
      repository.database,
      verifiedAssetBuffer: buffer,
    );
    final assetGateway = OperationAssetGateway(apiClient);
    late EditorV2AccountRuntime runtime;
    late LibraryV2OperationService libraryOperations;
    final engine = SyncEngine(
      store: store,
      gateway: HttpOperationGateway(apiClient),
      actorId: actorId,
      checkpointScope: 'account:$accountId',
      apiClient: apiClient,
      enableRealtime: enableRealtime,
      applyRemote: (operation, pendingLocal) async {
        if (operation.documentId == OperationEnvelope.libraryDocumentId) {
          await libraryOperations.apply(operation);
          return;
        }
        // Editor mutations never use the library projection.
        if (!V2OutboxConflictPolicy.canApply(operation, pendingLocal)) {
          final canArchiveDeletion =
              operation.kind == OperationKind.documentDelete ||
              (operation.kind == OperationKind.objectDelete &&
                  V2OutboxConflictPolicy.canArchiveObjectDelete(
                    operation,
                    pendingLocal,
                  ));
          if (!canArchiveDeletion) {
            throw StateError('Remote v2 operation awaits local outbox ACK.');
          }
          await runtime._archiveDeleteConflict(operation, pendingLocal);
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
    libraryOperations = LibraryV2OperationService(
      engine: engine,
      accountId: accountId,
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
      libraryOperations: libraryOperations,
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
  final LibraryV2OperationService libraryOperations;
  final Future<void> Function()? onLibraryChanged;

  EditorController? _activeEditor;
  String? _sharePreviewId;

  /// Configure live, memory-only previews for the mounted v2 editor.
  void configureSharePreview(EditorController editor, {String? shareId}) {
    if (!identical(_activeEditor, editor)) {
      throw StateError('Only the owning v2 editor can publish previews.');
    }
    engine.onSharePreview = null;
    editor.sendShareInkPreview = null;
    _sharePreviewId = shareId;
    if (shareId == null) {
      return;
    }
    final documentUid = editor.notebook.uid;
    engine.onSharePreview = (message) {
      final preview = ShareInkPreviewCodec.decode(message);
      if (preview == null ||
          _sharePreviewId != shareId ||
          preview.shareId != shareId ||
          preview.documentUid != documentUid ||
          preview.senderId == engine.actorId) {
        return;
      }
      editor.applyRemoteShareInkPreview(
        senderId: preview.senderId,
        pageId: preview.pageId,
        stroke: preview.stroke,
      );
    };
    editor.sendShareInkPreview = (pageId, stroke) {
      if (_sharePreviewId != shareId) {
        return;
      }
      engine.publishSharePreview(
        ShareInkPreviewCodec.encode(
          shareId: shareId,
          documentUid: documentUid,
          pageId: pageId,
          senderId: engine.actorId,
          stroke: stroke,
        ),
      );
    };
  }

  void clearSharePreview(EditorController editor) {
    if (!identical(_activeEditor, editor)) {
      return;
    }
    _sharePreviewId = null;
    engine.onSharePreview = null;
    editor.sendShareInkPreview = null;
  }

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
      clearSharePreview(editor);
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
    if (operation.documentId == OperationEnvelope.libraryDocumentId) {
      await libraryOperations.refreshReadModel();
      await onLibraryChanged?.call();
      return;
    }
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

  /// Reattempts an explicitly resolved conflict without losing the
  /// original local intent, operation ID or actor sequence.
  Future<void> retryBlockedOperation(String operationId) =>
      engine.retryBlockedOperation(operationId);

  Future<void> _archiveDeleteConflict(
    OperationEnvelope operation,
    List<OperationEnvelope> pending,
  ) async {
    final notebook = await repository.getNotebook(operation.documentId);
    if (notebook == null ||
        repository.lastCorruptNotebookIds.contains(operation.documentId)) {
      throw StateError(
        'Cannot archive a delete conflict with an unreadable notebook.',
      );
    }
    final database = repository.database;
    await database.customStatement(
      'CREATE TABLE IF NOT EXISTS v2_delete_conflicts ('
      'operation_id TEXT PRIMARY KEY, document_id TEXT NOT NULL, '
      'remote_json TEXT NOT NULL, local_json TEXT NOT NULL, notebook_json TEXT)',
    );
    await database.customStatement(
      'INSERT INTO v2_delete_conflicts '
      '(operation_id, document_id, remote_json, local_json, notebook_json) '
      'VALUES (?, ?, ?, ?, ?)',
      [
        operation.operationId,
        operation.documentId,
        jsonEncode(operation.toJson()),
        jsonEncode([for (final item in pending) item.toJson()]),
        jsonEncode(await _recoveryNotebookSnapshot(notebook)),
      ],
    );
  }

  Future<Map<String, dynamic>> _recoveryNotebookSnapshot(
    Notebook source,
  ) async {
    final pages = <NotePage>[];
    for (final page in source.pages) {
      final blocks = [...page.textBlocks];
      for (var i = 0; i < blocks.length; i++) {
        final text = blocks[i];
        if (text.deltaJson == null) {
          continue;
        }
        final delta = jsonDecode(text.deltaJson!) as List<dynamic>;
        for (final entry in delta) {
          final insert = (entry as Map)['insert'];
          if (insert is! Map) {
            continue;
          }
          final assetId = OperationEnvelope.embedAssetId(insert);
          final receipt = await projector.localAssetReceipt(
            documentId: source.uid,
            assetId: assetId,
          );
          if (receipt == null) {
            throw StateError('Cannot archive an unverified Quill attachment.');
          }
          final bytes = await projector.verifiedUploadBytes(receipt);
          final mediaType = receipt['mediaType'];
          entry['insert'] = {
            insert.keys.single: 'data:$mediaType;base64,${base64Encode(bytes)}',
          };
        }
        blocks[i] = text.copyWith(deltaJson: jsonEncode(delta));
      }
      pages.add(page.copyWith(textBlocks: blocks));
    }
    return repository.encodeSelfContainedBackup([
      source.copyWith(pages: pages),
    ]).single;
  }

  /// Keeps an archived edit as a new document only on explicit user action.
  /// Original document IDs and tombstones never change.
  Future<void> restoreRecoveryCopies({
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) {
      return;
    }
    final raw = await recoveryReport();
    if (raw == null) {
      return;
    }
    final report = jsonDecode(raw) as Map<String, dynamic>;
    for (final entry in report['concurrentDeletes'] as List) {
      final row = entry as Map;
      await _restoreRecoveryCopy(
        'delete:${row['operation_id']}',
        row['notebook_json'] as String,
        isCurrent,
      );
    }
    for (final entry in report['legacyConflicts'] as List) {
      final row = entry as Map;
      final rawLocal = row['local_json'];
      if (rawLocal is String &&
          row['uid'] != OperationEnvelope.libraryDocumentId) {
        await _restoreRecoveryCopy('legacy:${row['uid']}', rawLocal, isCurrent);
      }
    }
  }

  Future<void> _restoreRecoveryCopy(
    String key,
    String raw,
    bool Function() isCurrent,
  ) async {
    if (!isCurrent()) {
      return;
    }
    final source = repository.decodeBackupStrict([jsonDecode(raw)]).single;
    String id(String value) => const Uuid().v5(
      Namespace.url.value,
      jsonEncode(['sync-recovery-v2', engine.checkpointScope, key, value]),
    );
    final uid = id('document');
    final existing = await repository.getNotebook(uid);
    if (existing != null || await store.isTombstoned(uid, 'document', uid)) {
      return;
    }
    final pages = <NotePage>[];
    for (final page in source.pages) {
      final blocks = [...page.textBlocks];
      for (var i = 0; i < blocks.length; i++) {
        final text = blocks[i];
        final rawDelta = text.deltaJson;
        if (rawDelta == null) {
          blocks[i] = text.copyWith(id: id('text:${text.id}'));
          continue;
        }
        final delta = jsonDecode(rawDelta) as List<dynamic>;
        for (final entry in delta) {
          final insert = (entry as Map)['insert'];
          if (insert is! Map) {
            continue;
          }
          final type = insert.keys.single as String;
          final data = insert.values.single;
          if (data is! String ||
              !data.startsWith('data:') ||
              !data.contains(';base64,')) {
            throw const FormatException(
              'Recovery copy is missing embedded bytes.',
            );
          }
          final bytes = base64Decode(data.split(';base64,').last);
          final asset = writer.stageQuillAsset(
            documentId: uid,
            bytes: bytes,
            embedType: type,
          );
          entry['insert'] = {type: 'asset:${asset.assetId}'};
        }
        blocks[i] = text.copyWith(
          id: id('text:${text.id}'),
          deltaJson: jsonEncode(delta),
        );
      }
      pages.add(
        page.copyWith(
          id: id('page:${page.id}'),
          textBlocks: blocks,
          inkStrokes: [
            for (final ink in page.inkStrokes)
              ink.copyWith(id: id('ink:${ink.id}')),
          ],
          imageBlocks: [
            for (final image in page.imageBlocks)
              image.copyWith(id: id('image:${image.id}')),
          ],
        ),
      );
    }
    if (!isCurrent()) {
      return;
    }
    await writer.writeCreateNotebook(
      onCommittedInTransaction: (_) async {
        if (!isCurrent()) {
          throw StateError('The account changed during notebook recovery.');
        }
      },
      notebook: source.copyWith(
        uid: uid,
        title: '${source.title} (Recovered)',
        pages: pages,
      ),
    );
    if (isCurrent()) {
      await onLibraryChanged?.call();
    }
  }

  /// A portable account-scoped record of edits which need manual recovery.
  Future<String?> recoveryReport() async {
    final database = repository.database;
    final table = await database
        .customSelect(
          "SELECT name FROM sqlite_master WHERE name = 'legacy_v1_cutover_intents'",
        )
        .getSingleOrNull();
    final legacy = table == null
        ? []
        : await database
              .customSelect(
                "SELECT uid, base_json, local_json, reason FROM legacy_v1_cutover_intents "
                "WHERE state = 'conflict' ORDER BY uid",
              )
              .get();
    final blocked = await database
        .customSelect(
          "SELECT o.envelope_json, x.last_error FROM operation_outbox x "
          "JOIN operations o ON o.operation_id = x.operation_id "
          "WHERE x.status = 'blocked' ORDER BY o.actor_id, o.actor_seq",
        )
        .get();
    final archive = await database
        .customSelect(
          "SELECT name FROM sqlite_master WHERE name = 'v2_delete_conflicts'",
        )
        .getSingleOrNull();
    final deleted = archive == null
        ? []
        : await database
              .customSelect(
                'SELECT * FROM v2_delete_conflicts ORDER BY operation_id',
              )
              .get();
    if (legacy.isEmpty && blocked.isEmpty && deleted.isEmpty) {
      return null;
    }
    return jsonEncode({
      'version': 1,
      'legacyConflicts': [for (final row in legacy) row.data],
      'blockedOperations': [for (final row in blocked) row.data],
      'concurrentDeletes': [for (final row in deleted) row.data],
    });
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
    final editor = _activeEditor;
    if (editor != null) {
      clearSharePreview(editor);
    }
    _activeEditor = null;
    engine.dispose();
  }
}
