import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/error/app_error_log.dart';
import '../../core/storage/app_save_coordinator.dart';
import '../../core/storage/text_storage.dart';
import '../../features/notebook/data/notebook_repository.dart';
import '../../features/notebook/domain/notebook.dart';
import '../sync/account_session_controller.dart';
import '../sync/api_client.dart';
import 'notebook_conflicts.dart';
import 'notebook_merge.dart';

enum InitialSyncPolicy { uploadLocal, downloadRemote, mergeSafely }

class LiveWebSyncService extends ChangeNotifier with WidgetsBindingObserver {
  LiveWebSyncService({
    required this.repository,
    required this.apiClient,
    required this.session,
    this.enableRealtime = kIsWeb,
  }) {
    WidgetsBinding.instance.addObserver(this);
  }

  final NotebookRepository repository;
  final ApiClient apiClient;
  final AccountSessionController session;
  final bool enableRealtime;
  final Map<String, int> _revisions = <String, int>{};
  final Map<String, Map<String, dynamic>> _bases = {};
  final Set<String> _pending = <String>{};

  Future<void> _offlineQueueTail = Future<void>.value();
  final Map<String, String> _idempotencyKeys = <String, String>{};
  final Set<String> _restorePending = <String>{};
  Timer? _drainTimer;
  Timer? _reconnectTimer;
  Timer? _fallbackTimer;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _socketSubscription;
  Future<void>? _activeSync;
  bool _syncRequestedWhileRunning = false;
  String? _sharedDocumentUid;
  Future<void>? _starting;
  bool _applyingRemote = false;
  bool _started = false;
  bool _disposed = false;
  int _cursor = 0;
  int _reconnectAttempt = 0;
  String? _activeUserId;
  String? lastError;
  DateTime? lastSuccessfulSync;
  Future<void> Function()? onRemoteApplied;
  Future<void> Function()? onPlannerChanged;

  void reportStartupFailure(Object error) {
    if (_disposed) {
      return;
    }
    lastError = error.toString();
    notifyListeners();
  }

  bool get isStarted => _started;
  bool get hasPendingChanges => _pending.isNotEmpty;
  int remoteApplyEpoch = 0;

  /// Only an active shared document bypasses the normal sync debounce.
  void setSharedDocumentUid(String? uid) {
    _sharedDocumentUid = uid;
  }

  Future<void> start(InitialSyncPolicy policy) {
    final running = _starting;
    if (running != null) {
      return running;
    }
    final future = _startInitial(policy);
    _starting = future;
    return future.whenComplete(() {
      if (identical(_starting, future)) {
        _starting = null;
      }
    });
  }

  Future<void> _startInitial(InitialSyncPolicy policy) async {
    final userId = session.userId;
    if (!session.isSignedIn || userId == null) {
      throw StateError('Live synchronization requires a signed-in account.');
    }
    if (_started && _activeUserId == userId) {
      return;
    }
    if (_activeUserId != null || _activeSync != null) {
      await stop();
    }
    _resetAccountState();
    _activeUserId = userId;
    await _offlineQueueTail;
    await _loadState(userId);
    final remote = <_RemoteNotebookRecord>[];
    String? after;
    int? initialCursor;
    do {
      final page = await _getJsonObject(
        '/v1/sync/bootstrap',
        query: after == null ? null : {'after': after},
      );
      final records = page['notebooks'];
      final cursor = page['cursor'];
      if (records is! List<dynamic> || cursor is! num || cursor < 0) {
        throw const FormatException('Malformed sync bootstrap response.');
      }
      initialCursor ??= cursor.toInt();
      if (_activeUserId != userId || !session.isSignedIn) {
        return;
      }
      final next = page['next'];
      if (next != null &&
          (next is! String ||
              next.isEmpty ||
              records.isEmpty ||
              (after != null && next.compareTo(after) <= 0))) {
        throw const FormatException('Invalid sync bootstrap cursor.');
      }
      remote.addAll(records.map(_decodeRemoteRecord));
      after = next as String?;
    } while (after != null);
    await _applyInitialPolicy(policy, remote);
    _cursor = initialCursor;
    _started = true;
    await _offlineQueueTail;
    await _saveState();
    await syncNow();
    if (enableRealtime) {
      unawaited(_connectRealtime());
    }
    notifyListeners();
  }

  void enqueue(Iterable<NotebookRepositoryChange> changes) {
    if (_applyingRemote || !session.isSignedIn) {
      return;
    }
    final incoming = changes.map((change) => change.uid).toSet();
    if (incoming.isEmpty) {
      return;
    }
    if (!_started) {
      final userId = session.userId;
      if (userId == null) {
        return;
      }
      if (_activeUserId == userId) {
        // An edit during bootstrap must survive the final state write.
        // The on-disk outbox alone may be overwritten by _saveState().
        for (final uid in incoming) {
          _pending.add(uid);
          _idempotencyKeys.putIfAbsent(uid, () => const Uuid().v4());
        }
      }
      unawaited(_persistPreStartChanges(userId, incoming));
      return;
    }
    var sharedChange = false;
    for (final change in changes) {
      _pending.add(change.uid);
      _idempotencyKeys.putIfAbsent(change.uid, () => const Uuid().v4());
      if (change.uid == _sharedDocumentUid) {
        sharedChange = true;
      }
    }
    unawaited(_saveState().catchError((Object _, StackTrace _) {}));
    _drainTimer?.cancel();
    _drainTimer = Timer(
      sharedChange ? Duration.zero : const Duration(milliseconds: 90),
      () => unawaited(syncNow()),
    );
    notifyListeners();
  }

  Future<void> _persistPreStartChanges(String userId, Set<String> changedUids) {
    final operation = _offlineQueueTail.catchError((Object _) {}).then((
      _,
    ) async {
      final key = _stateKey(userId);
      final raw = await readStoredText(key);
      final decoded = raw == null
          ? <String, dynamic>{'version': 1, 'cursor': 0}
          : jsonDecode(raw);
      if (decoded is! Map<String, dynamic> || decoded['version'] != 1) {
        throw const FormatException('Invalid saved account outbox.');
      }
      final previous = decoded['pending'];
      final keys = decoded['idempotencyKeys'];
      final pending = <String>{
        if (previous is List<dynamic>) ...previous.whereType<String>(),
        ...changedUids,
      };
      final idempotency = <String, dynamic>{
        if (keys is Map<String, dynamic>) ...keys,
        for (final uid in changedUids) uid: const Uuid().v4(),
      };
      await writeStoredText(
        key,
        jsonEncode({
          ...decoded,
          'pending': pending.toList()..sort(),
          'idempotencyKeys': idempotency,
        }),
      );
    });
    _offlineQueueTail = operation.catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      AppErrorLog.instance.record(
        error,
        stackTrace,
        source: 'LiveWebSyncService.persistOfflineOutbox',
      );
    });
    return _offlineQueueTail;
  }

  Future<void> syncNow() {
    final running = _activeSync;
    if (running != null) {
      _syncRequestedWhileRunning = true;
      return running;
    }
    final future = _syncNow();
    _activeSync = future;
    return future.whenComplete(() {
      if (identical(_activeSync, future)) {
        _activeSync = null;
      }
    });
  }

  Future<void> _syncNow() async {
    if (!_started || !session.isSignedIn) {
      return;
    }
    try {
      await _runSyncPass();
      lastError = null;
      lastSuccessfulSync = DateTime.now().toUtc();
      await _saveState();
    } on ApiException catch (error, stackTrace) {
      if (error.statusCode == 401) {
        try {
          await session.refresh();
          if (enableRealtime) {
            unawaited(_connectRealtime());
          }
          await _runSyncPass();
          lastError = null;
          lastSuccessfulSync = DateTime.now().toUtc();
          await _saveState();
        } catch (refreshError, refreshStackTrace) {
          lastError = refreshError.toString();
          AppErrorLog.instance.record(
            refreshError,
            refreshStackTrace,
            source: 'LiveWebSyncService.refreshSession',
          );
        }
      } else {
        lastError = error.toString();
        AppErrorLog.instance.record(
          error,
          stackTrace,
          source: 'LiveWebSyncService.syncNow',
        );
      }
    } catch (error, stackTrace) {
      lastError = error.toString();
      AppErrorLog.instance.record(
        error,
        stackTrace,
        source: 'LiveWebSyncService.syncNow',
      );
    }
    _scheduleFallback();
    if (!_disposed) {
      notifyListeners();
    }
  }

  void _scheduleFallback() {
    _fallbackTimer?.cancel();
    if (!_started || _disposed || !session.isSignedIn) {
      return;
    }
    final delay = lastError == null
        ? const Duration(seconds: 45)
        : const Duration(seconds: 10);
    _fallbackTimer = Timer(delay, () {
      _fallbackTimer = null;
      unawaited(syncNow());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _started && !_disposed) {
      unawaited(syncNow());
    }
  }

  Future<void> _runSyncPass() async {
    do {
      _syncRequestedWhileRunning = false;
      await _reconcileChanges();
      for (final uid in _pending.toList()) {
        await _push(uid);
      }
      // A new stroke can be persisted while a previous request is in
      // flight. Do not make it wait for the 45-second fallback poll.
    } while (_syncRequestedWhileRunning && _started && session.isSignedIn);
  }

  Future<void> _applyInitialPolicy(
    InitialSyncPolicy policy,
    List<_RemoteNotebookRecord> remote,
  ) async {
    final local = await repository.fetchNotebooks();
    if (policy == InitialSyncPolicy.uploadLocal && remote.isNotEmpty) {
      throw StateError(
        'The account already contains data; choose safe merge or download.',
      );
    }
    if (policy == InitialSyncPolicy.downloadRemote && local.isNotEmpty) {
      throw StateError(
        'This device already contains data; choose safe merge or upload.',
      );
    }

    final localByUid = {for (final item in local) item.uid: item};
    final imports = <Notebook>[];
    final remoteDeletes = <String>[];
    for (final record in remote) {
      final previousBase = _bases[record.uid];
      final localNotebook = localByUid[record.uid];
      _revisions[record.uid] = record.revision;
      if (record.notebook != null) {
        _bases[record.uid] = record.baseNotebook!;
      }
      if (record.deleted || record.notebook == null) {
        if (localNotebook != null) {
          if (_hasUnsentEdit(record.uid, localNotebook, previousBase)) {
            final copy = await _conflictCopy(localNotebook, reserved: imports);
            imports.add(copy);
            _queueConflictCopy(copy.uid);
          }
          remoteDeletes.add(record.uid);
        }
        _pending.remove(record.uid);
        _restorePending.remove(record.uid);
        _idempotencyKeys.remove(record.uid);
        _bases.remove(record.uid);
        continue;
      }
      if (localNotebook == null) {
        imports.add(record.notebook!);
        continue;
      }
      if (_sameNotebook(localNotebook, record.notebook!)) {
        _pending.remove(record.uid);
        _idempotencyKeys.remove(record.uid);
        continue;
      }
      if (previousBase != null &&
          _sameEncodedNotebook(localNotebook, previousBase)) {
        imports.add(record.notebook!);
        _pending.remove(record.uid);
        _idempotencyKeys.remove(record.uid);
        continue;
      }
      if (previousBase != null) {
        final merged = _mergeWithRemote(
          previousBase,
          localNotebook,
          record.baseNotebook!,
        );
        if (merged != null) {
          imports.add(merged);
          _pending.add(record.uid);
          _idempotencyKeys[record.uid] = const Uuid().v4();
          continue;
        }
      }
      if (_pending.contains(record.uid)) {
        final copy = await _conflictCopy(localNotebook, reserved: imports);
        imports.add(copy);
        _queueConflictCopy(copy.uid);
      }
      imports.add(record.notebook!);
      _pending.remove(record.uid);
      _idempotencyKeys.remove(record.uid);
    }
    if (imports.isNotEmpty) {
      await _applyRemoteImports(imports);
    }
    if (remoteDeletes.isNotEmpty) {
      _applyingRemote = true;
      try {
        for (final uid in remoteDeletes) {
          await repository.deleteNotebook(uid);
        }
      } finally {
        _applyingRemote = false;
      }
      remoteApplyEpoch++;
      await onRemoteApplied?.call();
    }
    if (policy != InitialSyncPolicy.downloadRemote) {
      for (final notebook in local) {
        if (!remote.any((record) => record.uid == notebook.uid)) {
          _pending.add(notebook.uid);
          _idempotencyKeys[notebook.uid] = const Uuid().v4();
        }
      }
    }
  }

  Future<void> _push(String uid, {bool retriedConflict = false}) async {
    final notebook = await repository.getNotebook(uid);
    final encodedNotebook = notebook == null
        ? null
        : _encodeSyncNotebook(notebook);
    final sentNotebook = encodedNotebook == null
        ? null
        : jsonEncode(encodedNotebook);
    final baseCreatedAt = _bases[uid]?['createdAt'];
    if (encodedNotebook != null &&
        baseCreatedAt is String &&
        DateTime.parse(baseCreatedAt).isAtSameMomentAs(notebook!.createdAt)) {
      // Shared editing treats createdAt as immutable, including its spelling.
      encodedNotebook['createdAt'] = baseCreatedAt;
    }
    final expectedRevision = _revisions[uid] ?? 0;
    final restoringDeleted = _restorePending.contains(uid);
    if (notebook == null && expectedRevision == 0) {
      _pending.remove(uid);
      _idempotencyKeys.remove(uid);
      return;
    }
    final idempotencyKey = _idempotencyKeys.putIfAbsent(
      uid,
      () => const Uuid().v4(),
    );
    final previousBase = _bases[uid];
    try {
      final response = notebook == null
          ? await apiClient.request(
              'DELETE',
              '/v1/sync/notebooks/${Uri.encodeComponent(uid)}',
              body: utf8.encode(
                jsonEncode({'expectedRevision': expectedRevision}),
              ),
              headers: {'Idempotency-Key': idempotencyKey},
            )
          : await apiClient.putJson(
              '/v1/sync/notebooks/${Uri.encodeComponent(uid)}',
              {
                'expectedRevision': expectedRevision,
                'notebook': encodedNotebook,
                if (_restorePending.contains(uid)) 'restoreDeleted': true,
                if (_bases[uid] case final Map<String, dynamic> base)
                  'baseNotebook': base,
              },
              headers: {'Idempotency-Key': idempotencyKey},
            );
      final result = _requireJsonObject(response.decodeJson());
      _revisions[uid] = (result['revision'] as num).toInt();
      _restorePending.remove(uid);
      if (result['notebook'] case final Map<String, dynamic> merged) {
        _bases[uid] = merged;
      } else if (notebook != null) {
        _bases[uid] = encodedNotebook!;
      } else {
        _bases.remove(uid);
      }
      final current = await repository.getNotebook(uid);
      final currentNotebook = current == null
          ? null
          : jsonEncode(_encodeSyncNotebook(current));
      if (currentNotebook == sentNotebook) {
        if (result['notebook'] case final Map<String, dynamic> merged) {
          if (jsonEncode(_normalizeSyncNotebook(merged)) != sentNotebook) {
            final authoritative = repository.decodeBackupStrict([
              merged,
            ]).single;
            await _applyRemoteImports([authoritative]);
          }
        }
        _pending.remove(uid);
        _idempotencyKeys.remove(uid);
      } else {
        _pending.add(uid);
        _idempotencyKeys[uid] = const Uuid().v4();
      }
    } on ApiException catch (error) {
      if (error.statusCode != 409) {
        rethrow;
      }
      final conflict = _conflictPayload(error.payload);
      final record = _decodeRemoteRecord(conflict);
      _revisions[uid] = record.revision;
      if (record.notebook != null) {
        _bases[uid] = record.baseNotebook!;
      }
      if (record.deleted) {
        _bases.remove(uid);
        if (notebook != null) {
          if (_hasUnsentEdit(uid, notebook, previousBase)) {
            final copy = await _conflictCopy(notebook);
            await _applyRemoteImports([copy]);
            _queueConflictCopy(copy.uid);
          }
          _applyingRemote = true;
          try {
            await repository.deleteNotebook(uid);
          } finally {
            _applyingRemote = false;
          }
          remoteApplyEpoch++;
          await onRemoteApplied?.call();
        }
        _restorePending.remove(uid);
      } else if (record.notebook != null) {
        if (notebook == null) {
          _pending.add(uid);
          _idempotencyKeys[uid] = const Uuid().v4();
          if (retriedConflict) {
            rethrow;
          }
          await _push(uid, retriedConflict: true);
          return;
        }
        if (previousBase != null && !retriedConflict) {
          final merged = _mergeWithRemote(
            previousBase,
            notebook,
            record.baseNotebook!,
          );
          if (merged != null) {
            await _applyRemoteImports([merged]);
            _pending.add(uid);
            _idempotencyKeys[uid] = const Uuid().v4();
            await _push(uid, retriedConflict: true);
            return;
          }
        }
        await _applyRemoteImports([record.notebook!], preserveLocalUids: {uid});
      }
      _pending.remove(uid);
      _idempotencyKeys.remove(uid);
    }
  }

  Future<void> _reconcileChanges() async {
    while (true) {
      final response = await _getJsonObject(
        '/v1/sync/changes',
        query: {'after': '$_cursor'},
      );
      final rawChanges = response['changes'];
      final latestCursor = response['cursor'];
      if (rawChanges is! List<dynamic> || latestCursor is! num) {
        throw const FormatException('Malformed sync changes response.');
      }
      if (rawChanges.isNotEmpty) {
        // Capture in-progress host edits before applying guest changes.
        await AppSaveCoordinator.instance.flushPending();
        await repository.waitForPendingSaves();
        // A shared document must reach the server through its merge path
        // before an incoming revision can replace the local editor's data.
        // CAS still protects ordinary, non-shared documents.
        for (final uid in _pending.toList()) {
          await _push(uid);
        }
      }
      final imports = <String, Notebook>{};
      final preserveLocal = <String>{};
      var removedRemote = false;
      for (final raw in rawChanges) {
        final record = _decodeRemoteRecord(raw);
        final ownRevision = _revisions[record.uid] ?? 0;
        if (record.revision <= ownRevision) {
          continue;
        }
        final local = await repository.getNotebook(record.uid);
        if (record.deleted) {
          imports.remove(record.uid);
          if (local != null) {
            if (_hasUnsentEdit(record.uid, local, _bases[record.uid])) {
              final copy = await _conflictCopy(local);
              imports[copy.uid] = copy;
              _queueConflictCopy(copy.uid);
            }
            _applyingRemote = true;
            try {
              await repository.deleteNotebook(record.uid);
            } finally {
              _applyingRemote = false;
            }
            removedRemote = true;
          }
          _restorePending.remove(record.uid);
          _pending.remove(record.uid);
          _idempotencyKeys.remove(record.uid);
        } else if (_pending.contains(record.uid) && local != null) {
          if (record.notebook != null) {
            final base = _bases[record.uid];
            final merged = base == null
                ? null
                : _mergeWithRemote(base, local, record.baseNotebook!);
            if (merged != null) {
              imports[record.uid] = merged;
              _pending.add(record.uid);
              _idempotencyKeys[record.uid] = const Uuid().v4();
              _syncRequestedWhileRunning = true;
            } else {
              imports[record.uid] = record.notebook!;
              preserveLocal.add(record.uid);
              _pending.remove(record.uid);
              _idempotencyKeys.remove(record.uid);
            }
          }
        } else if (record.notebook != null) {
          imports[record.uid] = record.notebook!;
        }
        _revisions[record.uid] = record.revision;
        if (record.deleted || record.notebook == null) {
          _bases.remove(record.uid);
        } else {
          _bases[record.uid] = record.baseNotebook!;
        }
      }
      if (imports.isNotEmpty) {
        await _applyRemoteImports(
          imports.values.toList(),
          preserveLocalUids: preserveLocal,
        );
      }
      if (removedRemote) {
        remoteApplyEpoch++;
        await onRemoteApplied?.call();
      }
      final hasMore = response['hasMore'];
      if (hasMore != null && hasMore is! bool) {
        throw const FormatException('Invalid sync pagination flag.');
      }
      if (hasMore == true && latestCursor.toInt() <= _cursor) {
        throw const FormatException('Sync cursor did not advance.');
      }
      _cursor = latestCursor.toInt();
      if (hasMore == false || (hasMore == null && rawChanges.length < 500)) {
        return;
      }
    }
  }

  Future<void> _applyRemoteImports(
    List<Notebook> notebooks, {
    Set<String> preserveLocalUids = const <String>{},
  }) async {
    final replacements = <Notebook>[];
    _applyingRemote = true;
    try {
      for (final notebook in notebooks) {
        final existing = await repository.getNotebook(notebook.uid);
        if (existing != null && _sameNotebook(existing, notebook)) {
          continue;
        }
        if (existing != null && preserveLocalUids.contains(notebook.uid)) {
          // Preserve concurrent local edits without replacing the
          // authoritative document's UID or folder.
          final preserved = await _conflictCopy(existing);
          await repository.importNotebooksAtomically([preserved]);
          _pending.add(preserved.uid);
          _idempotencyKeys[preserved.uid] = const Uuid().v4();
          // A conflict copy created during a push needs another sync pass.
          _syncRequestedWhileRunning = true;
        }
        replacements.add(notebook);
      }
      if (replacements.isNotEmpty) {
        // This data was validated by the authenticated sync endpoint.
        // Unlike ordinary imports, legitimate remote deletions must apply.
        await repository.importNotebooksAtomically(
          replacements,
          verifiedRemoteSync: true,
        );
      }
    } finally {
      _applyingRemote = false;
    }
    if (replacements.isNotEmpty) {
      remoteApplyEpoch++;
      await onRemoteApplied?.call();
    }
  }

  Future<void> _connectRealtime() async {
    if (!_started || _disposed || !session.isSignedIn) {
      return;
    }
    await _socketSubscription?.cancel();
    await _channel?.sink.close();
    try {
      final channel = WebSocketChannel.connect(apiClient.realtimeUri());
      _channel = channel;
      await channel.ready.timeout(const Duration(seconds: 10));
      channel.sink.add(
        jsonEncode({'type': 'authenticate', 'token': apiClient.accessToken}),
      );
      _reconnectAttempt = 0;
      _socketSubscription = channel.stream.listen(
        (event) {
          if (event is String) {
            try {
              final decoded = jsonDecode(event);
              if (decoded is Map && decoded['type'] == 'planner_changed') {
                final callback = onPlannerChanged;
                if (callback != null) {
                  unawaited(callback());
                }
                return;
              }
            } catch (_) {
              // Unknown messages fall back to normal notebook polling.
            }
          }
          unawaited(syncNow());
        },
        onError: (Object error, StackTrace stackTrace) {
          AppErrorLog.instance.record(
            error,
            stackTrace,
            source: 'LiveWebSyncService.realtime',
          );
          _scheduleReconnect();
        },
        onDone: _scheduleReconnect,
        cancelOnError: true,
      );
    } catch (error, stackTrace) {
      AppErrorLog.instance.record(
        error,
        stackTrace,
        source: 'LiveWebSyncService.connectRealtime',
      );
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (!_started || _disposed) {
      return;
    }
    _reconnectTimer?.cancel();
    _reconnectAttempt++;
    final seconds = (1 << _reconnectAttempt.clamp(0, 5)).clamp(2, 30);
    _reconnectTimer = Timer(Duration(seconds: seconds), () {
      unawaited(
        _connectRealtime().then((_) async {
          await syncNow();
          await onPlannerChanged?.call();
        }),
      );
    });
  }

  Future<Map<String, dynamic>> _getJsonObject(
    String path, {
    Map<String, String>? query,
  }) async {
    // A single permitted document may approach the 16 MiB write limit.
    // Server pages normally stay smaller than 8 MiB.
    final response = await apiClient.request(
      'GET',
      path,
      query: query,
      maxResponseBytes: 32 * 1024 * 1024,
    );
    return _requireJsonObject(response.decodeJson());
  }

  _RemoteNotebookRecord _decodeRemoteRecord(Object? raw) {
    final json = _requireJsonObject(raw);
    final uid = json['uid'];
    final revision = json['revision'];
    final deleted = json['deleted'] == true;
    if (uid is! String || revision is! num) {
      throw const FormatException('Malformed remote notebook record.');
    }
    Notebook? notebook;
    Map<String, dynamic>? baseNotebook;
    if (!deleted) {
      final encoded = json['notebook'];
      if (encoded is! Map<String, dynamic>) {
        throw const FormatException('Remote notebook content is missing.');
      }
      notebook = repository.decodeBackupStrict([encoded]).single;
      baseNotebook = encoded;
    }
    return _RemoteNotebookRecord(
      uid: uid,
      revision: revision.toInt(),
      deleted: deleted,
      notebook: notebook,
      baseNotebook: baseNotebook,
    );
  }

  Map<String, dynamic> _conflictPayload(Object? payload) {
    if (payload is Map<String, dynamic>) {
      final detail = payload['detail'];
      if (detail is Map<String, dynamic>) {
        return detail;
      }
    }
    throw const FormatException('Conflict response has no remote copy.');
  }

  /// Prevents absolute image paths from leaking between devices and from
  /// producing false conflicts when native imports relocate image files.
  Map<String, dynamic> _encodeSyncNotebook(Notebook notebook) =>
      _normalizeSyncNotebook(NotebookRepository.encodeNotebook(notebook));

  static Map<String, dynamic> _normalizeSyncNotebook(
    Map<String, dynamic> encoded,
  ) {
    // Keep the authenticated base snapshot intact for server verification.
    encoded = Map<String, dynamic>.of(encoded);
    // SQLite returns local DateTimes; wire comparisons must use one zone.
    for (final key in ['createdAt', 'updatedAt']) {
      final value = encoded[key];
      if (value is String) {
        encoded[key] = DateTime.parse(value).toUtc().toIso8601String();
      }
    }
    final pages = encoded['pages'];
    if (pages is! List<dynamic>) {
      return encoded;
    }
    final normalizedPages = <dynamic>[];
    encoded['pages'] = normalizedPages;
    for (final page in pages) {
      normalizedPages.add(page);
      if (page is! Map<String, dynamic>) {
        continue;
      }
      final images = page['imageBlocks'];
      if (images is! List<dynamic>) {
        continue;
      }
      final normalizedImages = <dynamic>[];
      normalizedPages[normalizedPages.length - 1] = {
        ...page,
        'imageBlocks': normalizedImages,
      };
      for (final image in images) {
        if (image is Map<String, dynamic> &&
            image['bytes'] is String &&
            (image['bytes'] as String).isNotEmpty) {
          normalizedImages.add({...image, 'path': ''});
        } else {
          normalizedImages.add(image);
        }
      }
    }
    return encoded;
  }

  bool _sameNotebook(Notebook first, Notebook second) {
    return jsonEncode(_encodeSyncNotebook(first)) ==
        jsonEncode(_encodeSyncNotebook(second));
  }

  bool _sameEncodedNotebook(Notebook notebook, Map<String, dynamic> base) =>
      jsonEncode(_encodeSyncNotebook(notebook)) ==
      jsonEncode(_normalizeSyncNotebook(base));

  bool _hasUnsentEdit(
    String uid,
    Notebook notebook,
    Map<String, dynamic>? base,
  ) =>
      _pending.contains(uid) &&
      (base == null || !_sameEncodedNotebook(notebook, base));

  Notebook? _mergeWithRemote(
    Map<String, dynamic> base,
    Notebook local,
    Map<String, dynamic> remote,
  ) {
    final merged = mergeNotebookChanges(
      _normalizeSyncNotebook(base),
      _encodeSyncNotebook(local),
      _normalizeSyncNotebook(remote),
    );
    if (merged == null) {
      return null;
    }
    try {
      return repository.decodeBackupStrict([merged]).single;
    } on FormatException {
      return null;
    }
  }

  void _queueConflictCopy(String uid) {
    _pending.add(uid);
    _idempotencyKeys[uid] = const Uuid().v4();
    _syncRequestedWhileRunning = true;
  }

  Future<Notebook> _conflictCopy(
    Notebook source, {
    Iterable<Notebook> reserved = const [],
  }) async {
    return numberedNotebookCopy(source, [
      ...await repository.fetchNotebooks(),
      ...reserved,
    ]);
  }

  String _stateKey(String id) {
    final suffix = sha256.convert(utf8.encode(id)).toString().substring(0, 16);
    return 'server_sync_state_$suffix.json';
  }

  Future<void> _loadState(String userId) async {
    final content = await readStoredText(_stateKey(userId));
    if (content == null) {
      return;
    }
    final json = jsonDecode(content);
    if (json is! Map<String, dynamic> || json['version'] != 1) {
      throw const FormatException('Unsupported local sync state.');
    }
    _cursor = (json['cursor'] as num?)?.toInt() ?? 0;
    final revisions = json['revisions'];
    final pending = json['pending'];
    final restorePending = json['restorePending'];
    final keys = json['idempotencyKeys'];
    final bases = json['bases'];
    if (bases is Map<String, dynamic>) {
      for (final entry in bases.entries) {
        if (entry.value is Map<String, dynamic>) {
          _bases[entry.key] = entry.value as Map<String, dynamic>;
        }
      }
    }
    if (revisions is Map<String, dynamic>) {
      for (final entry in revisions.entries) {
        if (entry.value is num) {
          _revisions[entry.key] = (entry.value as num).toInt();
        }
      }
    }
    if (pending is List<dynamic>) {
      _pending.addAll(pending.whereType<String>());
    }
    if (restorePending is List<dynamic>) {
      _restorePending.addAll(restorePending.whereType<String>());
    }
    if (keys is Map<String, dynamic>) {
      for (final entry in keys.entries) {
        if (entry.value is String) {
          _idempotencyKeys[entry.key] = entry.value as String;
        }
      }
    }
  }

  /// Bound durable merge ancestors so Web localStorage cannot exhaust quota.
  Map<String, Map<String, dynamic>> _basesForStorage() {
    const byteLimit = 1024 * 1024;
    const perNotebookLimit = 256 * 1024;
    var usedBytes = 0;
    final saved = <String, Map<String, dynamic>>{};
    for (final uid in {..._pending, ..._bases.keys}) {
      final base = _bases[uid];
      if (base == null) {
        continue;
      }
      final bytes = utf8.encode(jsonEncode(base)).length;
      if (bytes > perNotebookLimit || usedBytes + bytes > byteLimit) {
        continue;
      }
      saved[uid] = base;
      usedBytes += bytes;
    }
    return saved;
  }

  Future<void> _saveState() {
    final userId = _activeUserId;
    if (userId == null) {
      return Future<void>.value();
    }
    // Serialize state writes with the pre-start outbox. Otherwise a slow
    // older write can finish last and erase newer pending notebook changes.
    final write = _offlineQueueTail.catchError((Object _) {}).then((_) async {
      if (_activeUserId != userId) {
        return;
      }
      await writeStoredText(
        _stateKey(userId),
        jsonEncode({
          'version': 1,
          'cursor': _cursor,
          'revisions': _revisions,
          'bases': _basesForStorage(),
          'pending': _pending.toList()..sort(),
          'restorePending': _restorePending.toList()..sort(),
          'idempotencyKeys': _idempotencyKeys,
        }),
      );
    });
    _offlineQueueTail = write.catchError((Object error, StackTrace stackTrace) {
      AppErrorLog.instance.record(
        error,
        stackTrace,
        source: 'LiveWebSyncService.persistOutbox',
      );
    });
    return write;
  }

  static Map<String, dynamic> _requireJsonObject(Object? raw) {
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('Expected a JSON object.');
    }
    return raw;
  }

  Future<void> stop() async {
    _started = false;
    _drainTimer?.cancel();
    _reconnectTimer?.cancel();
    _fallbackTimer?.cancel();
    await _socketSubscription?.cancel();
    await _channel?.sink.close();
    _socketSubscription = null;
    _channel = null;
    await _activeSync;
    await _offlineQueueTail;
    _resetAccountState();
    notifyListeners();
  }

  void _resetAccountState() {
    _activeUserId = null;
    _cursor = 0;
    _reconnectAttempt = 0;
    _syncRequestedWhileRunning = false;
    _sharedDocumentUid = null;
    _revisions.clear();
    _bases.clear();
    _pending.clear();
    _restorePending.clear();
    _idempotencyKeys.clear();
    lastError = null;
    lastSuccessfulSync = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _drainTimer?.cancel();
    _reconnectTimer?.cancel();
    _fallbackTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_socketSubscription?.cancel());
    unawaited(_channel?.sink.close());
    super.dispose();
  }
}

class _RemoteNotebookRecord {
  const _RemoteNotebookRecord({
    required this.uid,
    required this.revision,
    required this.deleted,
    required this.notebook,
    required this.baseNotebook,
  });

  final String uid;
  final int revision;
  final bool deleted;
  final Notebook? notebook;
  final Map<String, dynamic>? baseNotebook;
}
