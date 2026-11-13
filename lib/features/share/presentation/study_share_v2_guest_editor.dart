import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../data/drift/notes_database.dart';
import '../../../data/sync/api_client.dart';
import '../../../data/sync/editor_sqlite_projector.dart';
import '../../../data/sync/operation_asset_gateway.dart';
import '../../../data/sync/operation_gateway.dart';
import '../../../data/sync/operation_protocol.dart';
import '../../../data/sync/operation_store.dart';
import '../../../data/sync/persistent_share_actor.dart';
import '../../../data/sync/share_ink_preview_codec.dart';
import '../../../data/sync/study_share_service.dart';
import '../../../data/sync/sync_engine.dart';
import '../../../data/sync/v2_delete_conflict_archive.dart';
import '../../../data/sync/verified_editor_asset_buffer.dart';
import '../../board/presentation/board_screen.dart';
import '../../editor/state/editor_controller.dart';
import '../../editor/state/editor_v2_operation_writer.dart';
import '../../editor/state/editor_v2_remote_patch_dispatcher.dart';
import '../../editor/state/page_background.dart';
import '../../notebook/data/notebook_repository.dart';
import '../../notebook/domain/notebook_kind.dart';
import '../../notebook/presentation/notebook_screen.dart';
import 'study_share_memory_db_stub.dart'
    if (dart.library.js_interop) 'study_share_memory_db_web.dart'
    as guest_db;

/// A committed-operation editor with invitation-scoped persistent outbox.
///
/// Legacy v1 invitations never mount this widget or write in its namespace.
class StudyShareV2GuestEditor extends StatefulWidget {
  const StudyShareV2GuestEditor({
    required this.shareId,
    required this.documentUid,
    required this.ticket,
    required this.updateRevision,
    required this.onEnded,
    required this.onRejoin,
    this.onHostDarkMode,
    super.key,
  });

  final String shareId;
  final String documentUid;
  final String ticket;
  final int updateRevision;
  final VoidCallback onEnded;
  final VoidCallback onRejoin;
  final ValueChanged<bool>? onHostDarkMode;

  @override
  State<StudyShareV2GuestEditor> createState() =>
      _StudyShareV2GuestEditorState();
}

class _StudyShareV2GuestEditorState extends State<StudyShareV2GuestEditor> {
  static const guestNamespace = 'browser-guest';
  static Future<void> _previousClose = Future<void>.value();

  late final Future<void> _startup;
  Future<void>? _releasing;

  NotesDatabase? _database;
  NotebookRepository? _repository;
  EditorController? _editor;
  SyncEngine? _engine;
  ApiClient? _api;
  bool _closed = false;
  bool _starting = false;
  String? _error;
  bool _needsRejoin = false;
  bool _hasRecovery = false;
  int _appearanceRequest = 0;

  @override
  void initState() {
    super.initState();
    _startup = _initialize();
    unawaited(_startup);
  }

  Future<void> _initialize() async {
    if (_closed || _starting || _editor != null) {
      return;
    }
    _starting = true;
    try {
      await _previousClose;
      if (_closed || !mounted) {
        return;
      }
      final database = await guest_db.openSharedGuestOperationDatabase(
        widget.shareId,
        guestActorId: guestNamespace,
      );
      if (_closed || !mounted) {
        await database.close();
        return;
      }
      _database = database;
      final repository = NotebookRepository(database);
      _repository = repository;
      final store = OperationStore(
        database,
        checkpointScope: 'share:${widget.shareId}',
      );
      final actorId = await loadPersistentShareActor(
        store,
        shareId: widget.shareId,
        guestActorId: guestNamespace,
      );
      if (_closed || !mounted) {
        return;
      }
      final api = ApiClient();
      _api = api;
      final verified = VerifiedEditorAssetBuffer();
      final projector = EditorSqliteProjector(
        database,
        verifiedAssetBuffer: verified,
      );
      final assets = OperationAssetGateway(
        api,
        shareId: widget.shareId,
        guestTicket: widget.ticket,
      );
      final engine = SyncEngine(
        store: store,
        gateway: HttpOperationGateway(
          api,
          shareId: widget.shareId,
          guestTicket: widget.ticket,
        ),
        actorId: actorId,
        checkpointScope: 'share:${widget.shareId}',
        apiClient: api,
        shareId: widget.shareId,
        guestTicket: widget.ticket,
        applyRemoteAtCursor: (operation, pendingLocal, cursor) async {
          if (operation.documentId != widget.documentUid) {
            throw StateError('Guest operation escaped the invitation scope.');
          }
          await V2DeleteConflictArchive.applyRemote(
            operation,
            pendingLocal,
            cursor,
            repository: repository,
            projector: projector,
          );
        },
        prepareRemoteOperation: (operation) =>
            projector.prepareRemoteMedia(operation, assets),
        prepareLocalOperations: (operations) => assets.uploadPendingAssets(
          operations,
          projector.verifiedUploadBytes,
        ),
        onRemoteCommitted: _onRemoteCommitted,
        onShareEnded: widget.onEnded,
      );
      _engine = engine;
      engine.onSharePreview = _onSharePreview;
      engine.addListener(_onEngineChanged);
      final writer = EditorV2OperationWriter(
        syncEngine: engine,
        projector: projector,
        assetGateway: assets,
        onCommitted: repository.reportOperationCommit,
      );
      // Prevent legacy snapshots from changing this operational SQLite.
      await repository.enableAccountOperations(writer);
      if (_closed || !mounted) {
        return;
      }
      await engine.start();
      if (_closed || !mounted) {
        return;
      }
      if (engine.lastError != null) {
        throw StateError(engine.lastError!);
      }
      final notebook = await repository.getNotebook(widget.documentUid);
      if (notebook == null) {
        throw StateError('Shared document is absent from the v2 journal.');
      }
      if (notebook.kind == NotebookKind.planner) {
        throw StateError('Planner cannot be edited through Study Share.');
      }
      final editor = EditorController(
        repository: repository,
        notebook: notebook,
        operationWriter: writer,
        saveDebounce: const Duration(milliseconds: 20),
      );
      _editor = editor;
      editor.sendShareInkPreview = (pageId, stroke) {
        engine.publishSharePreview(
          ShareInkPreviewCodec.encode(
            shareId: widget.shareId,
            documentUid: widget.documentUid,
            pageId: pageId,
            senderId: engine.actorId,
            stroke: stroke,
          ),
        );
      };
      await editor.historyReady;
      final archived = await V2DeleteConflictArchive.read(repository);
      if (_closed || !mounted) {
        return;
      }
      setState(() {
        _error = null;
        _needsRejoin = false;
        _hasRecovery = archived.isNotEmpty;
      });
      engine.requestSync();
      unawaited(_refreshAppearance());
    } catch (error) {
      if (!_closed && mounted) {
        setState(() => _error = 'Cannot open v2 study share: $error');
      }
      await _release();
    } finally {
      _starting = false;
    }
  }

  Future<void> _onRemoteCommitted(OperationEnvelope operation) async {
    if (operation.documentId != widget.documentUid) {
      throw StateError('Guest operation escaped the invitation scope.');
    }
    final repository = _repository;
    if (repository == null) {
      return;
    }
    repository.reportOperationCommit(operation.documentId, [operation]);
    final editor = _editor;
    if (editor != null) {
      // The SQLite transaction has completed; update only touched objects.
      await EditorV2RemotePatchDispatcher(
        editor: editor,
        repository: repository,
      ).onRemoteCommitted(operation);
    }
    if (operation.kind == OperationKind.pageDelete && !_hasRecovery) {
      final archived = await V2DeleteConflictArchive.read(repository);
      if (archived.isNotEmpty && mounted && !_closed) {
        setState(() => _hasRecovery = true);
      }
    }
  }

  Future<void> _copyRecovery() async {
    final repository = _repository;
    if (repository == null) return;
    final archived = await V2DeleteConflictArchive.read(repository);
    if (archived.isEmpty || _closed || !mounted) return;
    await Clipboard.setData(
      ClipboardData(
        text: jsonEncode({'version': 1, 'concurrentDeletes': archived}),
      ),
    );
  }

  void _onSharePreview(Map<String, dynamic> message) {
    final preview = ShareInkPreviewCodec.decode(message);
    if (preview == null ||
        preview.shareId != widget.shareId ||
        preview.documentUid != widget.documentUid ||
        preview.senderId == _engine?.actorId) {
      return;
    }
    _editor?.applyRemoteShareInkPreview(
      senderId: preview.senderId,
      pageId: preview.pageId,
      stroke: preview.stroke,
    );
  }

  void _onEngineChanged() {
    if (!mounted || _closed) {
      return;
    }
    final error = _engine?.lastError;
    if (error == null && _error == null) {
      return;
    }
    setState(() {
      _error = error;
      _needsRejoin =
          error != null &&
          (error.contains('401') || error.contains('Unauthorized'));
    });
  }

  Future<void> _retrySync() async {
    final engine = _engine;
    if (engine == null || !engine.isStarted) {
      await _release();
      await _initialize();
      return;
    }
    engine.requestSync();
    await engine.syncNow();
    _onEngineChanged();
  }

  Future<void> _refreshAppearance() async {
    final api = _api;
    final editor = _editor;
    if (api == null || editor == null || _closed) {
      return;
    }
    final request = ++_appearanceRequest;
    try {
      final appearance = await StudyShareGuestClient(
        apiClient: api,
      ).appearance(widget.shareId, widget.ticket);
      if (!mounted ||
          _closed ||
          request != _appearanceRequest ||
          !identical(editor, _editor) ||
          appearance == null) {
        return;
      }
      final dark = appearance['darkMode'];
      final style = appearance['backgroundStyle'];
      final spacing = appearance['backgroundSpacing'];
      if (dark is bool) {
        widget.onHostDarkMode?.call(dark);
      }
      if (style is int &&
          style >= 0 &&
          style < PageBackgroundStyle.values.length &&
          spacing is num &&
          spacing.isFinite &&
          spacing > 0) {
        editor.applySharedBackgroundSettings(
          PageBackgroundSettings(
            style: PageBackgroundStyle.values[style],
            spacing: spacing.toDouble(),
          ),
        );
      }
    } catch (_) {
      // Appearance is independent of persisted editing and will retry on events.
    }
  }

  @override
  void didUpdateWidget(covariant StudyShareV2GuestEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.updateRevision != oldWidget.updateRevision) {
      _engine?.requestSync();
      unawaited(_refreshAppearance());
    }
  }

  Future<void> _release() {
    final current = _releasing;
    if (current != null) {
      return current;
    }
    final release = _releaseResources();
    _releasing = release;
    return release.whenComplete(() {
      if (identical(_releasing, release)) {
        _releasing = null;
      }
    });
  }

  Future<void> _releaseResources() async {
    final editor = _editor;
    final engine = _engine;
    final database = _database;
    final api = _api;
    _editor = null;
    _engine = null;
    _repository = null;
    _database = null;
    _api = null;
    if (editor != null) {
      editor.sendShareInkPreview = null;
      try {
        await editor.flushPendingSaves();
      } catch (_) {
        // Previously committed operations stay recoverable in the outbox.
      }
    }
    if (engine != null) {
      engine.removeListener(_onEngineChanged);
      try {
        await engine.stop();
      } finally {
        engine.dispose();
      }
    }
    editor?.dispose();
    await database?.close();
    api?.close();
  }

  Future<void> _shutdown() async {
    try {
      await _startup;
    } finally {
      await _release();
    }
  }

  @override
  void dispose() {
    _closed = true;
    final closing = _shutdown();
    _previousClose = closing;
    unawaited(closing);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editor = _editor;
    return Column(
      children: [
        if (_hasRecovery)
          TextButton(
            onPressed: () async {
              try {
                await _copyRecovery();
              } catch (_) {
                if (mounted && !_closed) {
                  setState(() => _error = 'Cannot copy the saved edits.');
                }
              }
            },
            child: const Text('Copy saved edits from a deleted page'),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                if (_needsRejoin)
                  TextButton(
                    onPressed: widget.onRejoin,
                    child: const Text('Rejoin with password'),
                  )
                else
                  TextButton(
                    onPressed: () => unawaited(_retrySync()),
                    child: const Text('Retry synchronization'),
                  ),
              ],
            ),
          ),
        Expanded(
          child: editor == null
              ? const Center(child: CircularProgressIndicator())
              : ChangeNotifierProvider<EditorController>.value(
                  value: editor,
                  child: editor.notebook.kind == NotebookKind.board
                      ? BoardScreen(title: editor.notebook.title)
                      : NotebookScreen(title: editor.notebook.title),
                ),
        ),
      ],
    );
  }
}
