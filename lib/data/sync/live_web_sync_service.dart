import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/error/app_error_log.dart';
import '../../core/storage/text_storage.dart';
import '../../features/notebook/data/notebook_repository.dart';
import '../../features/notebook/domain/notebook.dart';
import '../sync/account_session_controller.dart';
import '../sync/api_client.dart';

enum InitialSyncPolicy { uploadLocal, downloadRemote, mergeSafely }

class LiveWebSyncService extends ChangeNotifier {
  LiveWebSyncService({
    required this.repository,
    required this.apiClient,
    required this.session,
  });

  final NotebookRepository repository;
  final ApiClient apiClient;
  final AccountSessionController session;
  final Map<String, int> _revisions = <String, int>{};
  final Set<String> _pending = <String>{};
  final Map<String, String> _idempotencyKeys = <String, String>{};
  Timer? _drainTimer;
  Timer? _reconnectTimer;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _socketSubscription;
  Future<void>? _activeSync;
  bool _applyingRemote = false;
  bool _started = false;
  bool _disposed = false;
  int _cursor = 0;
  int _reconnectAttempt = 0;
  String? _activeUserId;
  String? lastError;
  DateTime? lastSuccessfulSync;
  Future<void> Function()? onRemoteApplied;

  bool get isStarted => _started;
  bool get hasPendingChanges => _pending.isNotEmpty;

  Future<void> start(InitialSyncPolicy policy) async {
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
    await _loadState(userId);
    final bootstrap = await _getJsonObject('/v1/sync/bootstrap');
    final rawRecords = bootstrap['notebooks'];
    final cursor = bootstrap['cursor'];
    if (rawRecords is! List<dynamic> || cursor is! num) {
      throw const FormatException('Malformed sync bootstrap response.');
    }
    final remote = rawRecords.map(_decodeRemoteRecord).toList();
    await _applyInitialPolicy(policy, remote);
    _cursor = cursor.toInt();
    _started = true;
    await _saveState();
    await syncNow();
    if (kIsWeb) {
      unawaited(_connectRealtime());
    }
    notifyListeners();
  }

  void enqueue(Iterable<NotebookRepositoryChange> changes) {
    if (!_started || _applyingRemote || !session.isSignedIn) {
      return;
    }
    for (final change in changes) {
      _pending.add(change.uid);
      _idempotencyKeys.putIfAbsent(change.uid, () => const Uuid().v4());
    }
    unawaited(_saveState());
    _drainTimer?.cancel();
    _drainTimer = Timer(const Duration(milliseconds: 600), () {
      unawaited(syncNow());
    });
    notifyListeners();
  }

  Future<void> syncNow() {
    final running = _activeSync;
    if (running != null) {
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
    if (!_disposed) {
      notifyListeners();
    }
  }

  Future<void> _runSyncPass() async {
    await _reconcileChanges();
    for (final uid in _pending.toList()) {
      await _push(uid);
    }
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
    for (final record in remote) {
      _revisions[record.uid] = record.revision;
      if (record.deleted || record.notebook == null) {
        continue;
      }
      final localNotebook = localByUid[record.uid];
      if (localNotebook == null) {
        imports.add(record.notebook!);
        continue;
      }
      if (_sameNotebook(localNotebook, record.notebook!)) {
        continue;
      }
      imports.add(_conflictCopy(record.notebook!, 'server'));
      _pending.add(localNotebook.uid);
      _idempotencyKeys[localNotebook.uid] = const Uuid().v4();
    }
    if (imports.isNotEmpty) {
      await _applyRemoteImports(imports);
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

  Future<void> _push(String uid) async {
    final notebook = await repository.getNotebook(uid);
    final sentNotebook = notebook == null
        ? null
        : jsonEncode(NotebookRepository.encodeNotebook(notebook));
    final expectedRevision = _revisions[uid] ?? 0;
    if (notebook == null && expectedRevision == 0) {
      _pending.remove(uid);
      _idempotencyKeys.remove(uid);
      return;
    }
    final idempotencyKey = _idempotencyKeys.putIfAbsent(
      uid,
      () => const Uuid().v4(),
    );
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
                'notebook': NotebookRepository.encodeNotebook(notebook),
              },
              headers: {'Idempotency-Key': idempotencyKey},
            );
      final result = _requireJsonObject(response.decodeJson());
      _revisions[uid] = (result['revision'] as num).toInt();
      final current = await repository.getNotebook(uid);
      final currentNotebook = current == null
          ? null
          : jsonEncode(NotebookRepository.encodeNotebook(current));
      if (currentNotebook == sentNotebook) {
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
      if (!record.deleted && record.notebook != null) {
        await _applyRemoteImports([record.notebook!]);
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
      final imports = <Notebook>[];
      for (final raw in rawChanges) {
        final record = _decodeRemoteRecord(raw);
        final ownRevision = _revisions[record.uid] ?? 0;
        if (record.revision <= ownRevision) {
          continue;
        }
        final local = await repository.getNotebook(record.uid);
        if (_pending.contains(record.uid) && local != null) {
          if (record.notebook != null) {
            imports.add(_conflictCopy(record.notebook!, 'server'));
          }
        } else if (record.deleted) {
          if (local != null) {
            _applyingRemote = true;
            try {
              await repository.deleteNotebook(record.uid);
            } finally {
              _applyingRemote = false;
            }
          }
        } else if (record.notebook != null) {
          imports.add(record.notebook!);
        }
        _revisions[record.uid] = record.revision;
      }
      if (imports.isNotEmpty) {
        await _applyRemoteImports(imports);
      }
      _cursor = latestCursor.toInt();
      if (rawChanges.length < 500) {
        return;
      }
    }
  }

  Future<void> _applyRemoteImports(List<Notebook> notebooks) async {
    final replacements = <Notebook>[];
    _applyingRemote = true;
    try {
      for (final notebook in notebooks) {
        final existing = await repository.getNotebook(notebook.uid);
        if (existing == null) {
          replacements.add(notebook);
          continue;
        }
        if (_sameNotebook(existing, notebook)) {
          continue;
        }
        await repository.importNotebooksAtomically([
          _conflictCopy(existing, 'this device'),
        ]);
        await repository.deleteNotebook(existing.uid);
        replacements.add(notebook);
      }
      if (replacements.isNotEmpty) {
        await repository.importNotebooksAtomically(replacements);
      }
    } finally {
      _applyingRemote = false;
    }
    await onRemoteApplied?.call();
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
        (_) => unawaited(syncNow()),
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
      unawaited(_connectRealtime().then((_) => syncNow()));
    });
  }

  Future<Map<String, dynamic>> _getJsonObject(
    String path, {
    Map<String, String>? query,
  }) async {
    final response = await apiClient.get(path, query: query);
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
    if (!deleted) {
      final encoded = json['notebook'];
      if (encoded is! Map<String, dynamic>) {
        throw const FormatException('Remote notebook content is missing.');
      }
      notebook = repository.decodeBackupStrict([encoded]).single;
    }
    return _RemoteNotebookRecord(
      uid: uid,
      revision: revision.toInt(),
      deleted: deleted,
      notebook: notebook,
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

  bool _sameNotebook(Notebook first, Notebook second) {
    return jsonEncode(NotebookRepository.encodeNotebook(first)) ==
        jsonEncode(NotebookRepository.encodeNotebook(second));
  }

  Notebook _conflictCopy(Notebook source, String origin) {
    final now = DateTime.now().toUtc();
    return source.copyWith(
      uid: const Uuid().v4(),
      title: '${source.title} (Conflict from $origin)',
      createdAt: now,
      updatedAt: now,
      pages: [
        for (final page in source.pages)
          page.copyWith(
            id: const Uuid().v4(),
            textBlocks: [
              for (final block in page.textBlocks)
                block.copyWith(id: const Uuid().v4()),
            ],
            imageBlocks: [
              for (final block in page.imageBlocks)
                block.copyWith(id: const Uuid().v4()),
            ],
            inkStrokes: [
              for (final stroke in page.inkStrokes)
                stroke.copyWith(id: const Uuid().v4()),
            ],
          ),
      ],
    );
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
    final keys = json['idempotencyKeys'];
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
    if (keys is Map<String, dynamic>) {
      for (final entry in keys.entries) {
        if (entry.value is String) {
          _idempotencyKeys[entry.key] = entry.value as String;
        }
      }
    }
  }

  Future<void> _saveState() {
    final userId = _activeUserId;
    if (userId == null) {
      return Future<void>.value();
    }
    return writeStoredText(
      _stateKey(userId),
      jsonEncode({
        'version': 1,
        'cursor': _cursor,
        'revisions': _revisions,
        'pending': _pending.toList()..sort(),
        'idempotencyKeys': _idempotencyKeys,
      }),
    );
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
    await _socketSubscription?.cancel();
    await _channel?.sink.close();
    _socketSubscription = null;
    _channel = null;
    await _activeSync;
    _resetAccountState();
    notifyListeners();
  }

  void _resetAccountState() {
    _activeUserId = null;
    _cursor = 0;
    _reconnectAttempt = 0;
    _revisions.clear();
    _pending.clear();
    _idempotencyKeys.clear();
    lastError = null;
    lastSuccessfulSync = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _drainTimer?.cancel();
    _reconnectTimer?.cancel();
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
  });

  final String uid;
  final int revision;
  final bool deleted;
  final Notebook? notebook;
}
