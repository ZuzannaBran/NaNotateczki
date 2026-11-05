import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api_client.dart';
import 'operation_gateway.dart';
import 'operation_protocol.dart';
import 'operation_store.dart';

/// Applies one remote intent inside the OperationStore SQLite transaction.
///
/// [pendingLocal] includes deferred retries. A reducer must merge remote
/// fields into the current projection and rebase those intents, rather than
/// installing a complete server snapshot over optimistic local edits.
typedef RemoteOperationReducer =
    Future<void> Function(
      OperationEnvelope remote,
      List<OperationEnvelope> pendingLocal,
    );

/// Notifies the editor only after a remote operation is durable in SQLite.
/// This callback must be idempotent: a failed notification is retried on replay.
typedef RemoteOperationCommitted =
    Future<void> Function(OperationEnvelope remote);

/// Prepares verified external bytes before opening the SQLite transaction.
/// The callback may download assets; the reducer must use staged local bytes
/// and must not initiate network I/O while the journal is being committed.
typedef RemoteOperationPreparer =
    Future<void> Function(OperationEnvelope remote);

/// The opt-in v2 journal driver. A migrated namespace must own one instance.
///
/// Legacy v1 snapshot writers must not run for documents driven by this
/// engine. Enabling the engine for existing v1 accounts requires stage 11.
class SyncEngine extends ChangeNotifier with WidgetsBindingObserver {
  SyncEngine({
    required this.store,
    required this.gateway,
    required this.actorId,
    required this.checkpointScope,
    required this.applyRemote,
    this.prepareRemoteOperation,
    this.onRemoteCommitted,
    this.apiClient,
    this.shareId,
    this.guestTicket,
    this.onShareEnded,
    this.refreshAuthentication,
    this.enableRealtime = true,
    this.pollInterval = const Duration(seconds: 45),
  }) {
    if (actorId.isEmpty || checkpointScope.isEmpty) {
      throw ArgumentError('An actor and isolated checkpoint are required.');
    }
    if ((shareId == null) != (guestTicket == null) ||
        (guestTicket != null && refreshAuthentication != null)) {
      throw ArgumentError('Share requires an ephemeral guest ticket.');
    }
    if (gateway is HttpOperationGateway &&
        (gateway as HttpOperationGateway).shareId != shareId) {
      throw ArgumentError('Share IDs must match REST and WebSocket.');
    }
    if (gateway is HttpOperationGateway &&
        (gateway as HttpOperationGateway).guestTicket != guestTicket) {
      throw ArgumentError('REST and WebSocket credentials must match.');
    }
  }

  static const maxBatchSize = 50;
  static const maxBatchPayloadBytes = 800 * 1024;
  static const maxConcurrentActors = 3;
  static const maxPagesPerPass = 100;

  final OperationStore store;
  final OperationGateway gateway;
  final String actorId;
  final String checkpointScope;
  final RemoteOperationReducer applyRemote;
  final RemoteOperationPreparer? prepareRemoteOperation;
  final RemoteOperationCommitted? onRemoteCommitted;
  final ApiClient? apiClient;
  final String? shareId;

  /// Guest ticket stays in memory; it is never part of an operation envelope.
  final String? guestTicket;

  /// Called once when a v2 guest session is revoked or expires.
  final void Function()? onShareEnded;
  final Future<void> Function()? refreshAuthentication;
  final bool enableRealtime;
  final Duration pollInterval;

  bool _started = false;
  bool _disposed = false;
  bool _requested = false;
  int _generation = 0;
  int _failures = 0;
  final Map<String, int> _actorFailures = {};
  // A cursor may replay a committed remote operation after a later gap.
  // Keep successful UI deliveries within this engine session idempotent.
  final Set<String> _notifiedRemoteOperations = <String>{};
  static const _maxRememberedUiOperations = 4096;
  Future<void>? _active;
  Timer? _poll;
  Timer? _debounce;
  Timer? _retry;
  DateTime? _retryDueAt;
  Timer? _socketRetry;
  WebSocketChannel? _socket;
  StreamSubscription<dynamic>? _socketSubscription;

  String? lastError;
  DateTime? lastSuccessfulSync;

  bool get isStarted => _started;

  /// Earliest scheduled retry across independent actors and pull failures.
  DateTime? get retryDeadline => _retryDueAt;

  /// Writes the projection and outbox in one transaction before scheduling IO.
  Future<OperationEnvelope> writeLocal({
    required String documentId,
    required OperationKind kind,
    required Map<String, dynamic> payload,
    required Future<void> Function(OperationEnvelope) apply,
    String? pageId,
    String? objectId,
    String? revertsOperationId,
    List<String> dependencies = const [],
  }) async {
    OperationEnvelope.validateV2Payload(
      kind: kind,
      payload: payload,
      documentId: documentId,
      objectId: objectId,
      pageId: pageId,
    );
    // Actor sequences and causal frontiers are document-scoped. An account
    // may edit unrelated documents concurrently, and guests cannot fetch
    // dependencies on private documents belonging to the owner.
    final operation = await store.writeLocal(
      actorId: _scopedActorId(documentId),
      documentId: documentId,
      kind: kind,
      payload: payload,
      apply: apply,
      pageId: pageId,
      objectId: objectId,
      revertsOperationId: revertsOperationId,
      dependencies: dependencies,
    );
    requestSync();
    return operation;
  }

  String _scopedActorId(String documentId) {
    final actorData = jsonEncode([actorId, checkpointScope, documentId]);
    return sha256.convert(utf8.encode(actorData)).toString();
  }

  /// Persists a whole completed gesture before requesting network delivery.
  ///
  /// Every draft is validated before the transaction. The store commits all
  /// projections, actor sequence numbers and outbox rows or none of them.
  Future<List<OperationEnvelope>> writeLocalBatch({
    required String documentId,
    required List<LocalOperationDraft> operations,
    required Future<void> Function(OperationEnvelope) apply,
  }) async {
    if (operations.isEmpty) {
      throw ArgumentError.value(operations, 'operations', 'Empty gesture.');
    }
    for (final draft in operations) {
      OperationEnvelope.validateV2Payload(
        kind: draft.kind,
        payload: draft.payload,
        documentId: documentId,
        pageId: draft.pageId,
        objectId: draft.objectId,
      );
    }
    final committed = await store.writeLocalBatch(
      actorId: _scopedActorId(documentId),
      documentId: documentId,
      operations: operations,
      apply: apply,
    );
    requestSync();
    return committed;
  }

  Future<void> start() async {
    if (_disposed) {
      throw StateError('A disposed sync engine cannot restart.');
    }
    if (_started) {
      return syncNow();
    }
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    final generation = ++_generation;
    _poll = Timer.periodic(pollInterval, (_) => requestSync());
    if (enableRealtime && apiClient != null) {
      unawaited(_connectSocket(generation));
    }
    await syncNow();
  }

  Future<void> stop() async {
    WidgetsBinding.instance.removeObserver(this);
    _started = false;
    ++_generation;
    _requested = false;
    _poll?.cancel();
    _debounce?.cancel();
    _retry?.cancel();
    _socketRetry?.cancel();
    _poll = null;
    _debounce = null;
    _retry = null;
    _retryDueAt = null;
    _socketRetry = null;
    _notifiedRemoteOperations.clear();
    final subscription = _socketSubscription;
    _socketSubscription = null;
    await subscription?.cancel();
    final socket = _socket;
    _socket = null;
    await socket?.sink.close();
    await _active;
    // A callback finishing during stop must not leave stale UI deliveries
    // after the engine is restarted with a different editor instance.
    _notifiedRemoteOperations.clear();
  }

  void requestSync() {
    if (!_started || _disposed) {
      return;
    }
    _requested = true;
    if (_active != null || _debounce?.isActive == true) {
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 40), () {
      _debounce = null;
      unawaited(syncNow());
    });
  }

  /// Concurrent callers share one bounded, serial synchronization pass.
  Future<void> syncNow() {
    if (!_started || _disposed) {
      return Future<void>.value();
    }
    _requested = true;
    final current = _active;
    if (current != null) {
      return current;
    }
    final future = _drain(_generation);
    _active = future;
    return future.whenComplete(() {
      if (identical(_active, future)) {
        _active = null;
      }
      if (_requested && _started) {
        requestSync();
      }
    });
  }

  bool _isActive(int generation) =>
      _started && !_disposed && _generation == generation;

  Future<void> _drain(int generation) async {
    while (_isActive(generation) && _requested) {
      _requested = false;
      try {
        // A corrupt remote projection may not hold unrelated local writes
        // hostage. Always attempt the push, then recheck the blocked pull.
        try {
          await _pull(generation);
        } catch (error) {
          lastError = error.toString();
          notifyListeners();
        }
        if (!_isActive(generation)) {
          return;
        }
        await _push(generation);
        if (!_isActive(generation)) {
          return;
        }
        await _pull(generation);
        if (!_isActive(generation)) {
          return;
        }
        _failures = 0;
        lastError = null;
        lastSuccessfulSync = DateTime.now().toUtc();
        notifyListeners();
      } catch (error) {
        if (!_isActive(generation)) {
          return;
        }
        lastError = error.toString();
        notifyListeners();
        _failures++;
        _scheduleRetry(_backoff(_failures));
        break;
      }
    }
  }

  /// Do not advance the durable global cursor past an unapplied operation.
  /// Other independent operations in the same page can still be committed:
  /// replay after a crash or gap is idempotent.
  Future<void> _pull(int generation) async {
    var cursor = await store.checkpoint(checkpointScope);
    for (var pageNumber = 0; pageNumber < maxPagesPerPass; pageNumber++) {
      final page = await _authorized(() => gateway.readAfter(cursor));
      if (!_isActive(generation)) {
        return;
      }
      var contiguous = cursor;
      Object? blocked;
      var gap = false;
      for (final item in page.operations) {
        try {
          final queuedEcho = await store.isPending(item.operation.operationId);
          final isMediaAttach =
              item.operation.kind == OperationKind.assetAttach;
          final isMediaSwitch =
              item.operation.kind == OperationKind.objectSet &&
              item.operation.payload['properties'] is Map &&
              (item.operation.payload['properties'] as Map)
                  .containsKey('assetId');
          if ((isMediaAttach || isMediaSwitch) &&
              await store.operation(item.operation.operationId) == null) {
            await prepareRemoteOperation?.call(item.operation);
          }
          await store.applyRemote(
            item.operation,
            serverSequence: item.cursor,
            apply: () async {
              // No replacement of the whole document or optimistic edits.
              final pending = <OperationEnvelope>[];
              while (true) {
                final page = await store.pending(
                  documentId: item.operation.documentId,
                  limit: 1000,
                  offset: pending.length,
                  includeDeferred: true,
                );
                pending.addAll(page);
                if (page.length < 1000) {
                  break;
                }
              }
              await applyRemote(item.operation, pending);
            },
          );
          if (!_isActive(generation)) {
            return;
          }
          // This runs after the SQLite commit. Failure holds the cursor for
          // replay; the UI must never be mutated inside a rollbackable write.
          // ACKed local operations are also echoes and must not repaint.
          if (!queuedEcho &&
              !await store.isLocalOperation(item.operation.operationId) &&
              !_notifiedRemoteOperations.contains(item.operation.operationId)) {
            await onRemoteCommitted?.call(item.operation);
            if (onRemoteCommitted != null) {
              _notifiedRemoteOperations.add(item.operation.operationId);
              if (_notifiedRemoteOperations.length >
                  _maxRememberedUiOperations) {
                _notifiedRemoteOperations.remove(
                  _notifiedRemoteOperations.first,
                );
              }
            }
          }
          if (!_isActive(generation)) {
            return;
          }
          if (queuedEcho) {
            await store.acknowledge(
              item.operation.operationId,
              serverSequence: item.cursor,
            );
          }
          if (!gap) {
            contiguous = item.cursor;
          }
        } catch (error) {
          blocked ??= error;
          gap = true;
        }
      }
      if (!_isActive(generation)) {
        return;
      }
      if (contiguous > cursor) {
        await store.advanceCheckpoint(checkpointScope, contiguous);
        cursor = contiguous;
      }
      if (blocked != null) {
        throw StateError('Operation feed has an unresolved gap: $blocked');
      }
      if (!page.hasMore) {
        return;
      }
    }
    // Keep processing long feeds without monopolizing the UI event loop.
    _requested = true;
  }

  Future<void> _push(int generation) async {
    final ready = await store.pending(limit: 1000);
    if (!_isActive(generation) || ready.isEmpty) {
      return;
    }
    final groups = <String, List<OperationEnvelope>>{};
    final bytesByActor = <String, int>{};
    final full = <String>{};
    for (final operation in ready) {
      final actor = operation.actorId;
      if (full.contains(actor)) {
        continue;
      }
      final group = groups.putIfAbsent(actor, () => []);
      final size = utf8.encode(jsonEncode(operation.toJson())).length;
      final total = bytesByActor[actor] ?? 0;
      if (group.length >= maxBatchSize ||
          (group.isNotEmpty && total + size > maxBatchPayloadBytes)) {
        full.add(actor);
        continue;
      }
      group.add(operation);
      bytesByActor[actor] = total + size;
      if (total + size > maxBatchPayloadBytes) {
        // An oversized individual operation is retained and rejected by
        // the transport, never silently bypassed by later actor edits.
        full.add(actor);
      }
    }
    final selected = groups.entries.take(maxConcurrentActors).toList();
    await Future.wait([
      for (final group in selected)
        _sendActor(generation, group.key, group.value),
    ]);
    final attempted = selected.fold<int>(
      0,
      (total, group) => total + group.value.length,
    );
    if (ready.length > attempted) {
      _requested = true;
    }
  }

  Future<void> _acceptReceipts(
    int generation,
    List<OperationEnvelope> batch,
    List<OperationReceipt> receipts,
  ) async {
    final expected = batch.map((operation) => operation.operationId).toSet();
    final received = receipts.map((receipt) => receipt.operationId).toSet();
    if (received.length != receipts.length ||
        !setEquals(expected, received) ||
        receipts.any((receipt) => receipt.cursor <= 0)) {
      throw const FormatException('Incomplete or invalid server ACK.');
    }
    for (final receipt in receipts) {
      if (!_isActive(generation)) {
        return;
      }
      await store.acknowledge(
        receipt.operationId,
        serverSequence: receipt.cursor,
      );
    }
  }

  Future<void> _sendActor(
    int generation,
    String actor,
    List<OperationEnvelope> batch,
  ) async {
    try {
      final receipts = await _authorized(() => gateway.send(batch));
      if (!_isActive(generation)) {
        return;
      }
      await _acceptReceipts(generation, batch, receipts);
      _actorFailures.remove(actor);
    } catch (error) {
      if (!_isActive(generation)) {
        return;
      }
      Object failure = error;
      // The server commits an entire batch or none of it. If one later
      // intent fails, commit the safe prefix instead of penalizing its first
      // operation. Never jump over an invalid actor sequence.
      if (error is ApiException &&
          batch.length > 1 &&
          (error.statusCode == 409 ||
              error.statusCode == 413 ||
              error.statusCode == 422)) {
        try {
          final first = [batch.first];
          final receipts = await _authorized(() => gateway.send(first));
          if (!_isActive(generation)) {
            return;
          }
          await _acceptReceipts(generation, first, receipts);
          _actorFailures.remove(actor);
          _requested = true;
          return;
        } catch (firstError) {
          failure = firstError;
        }
      }
      if (!_isActive(generation)) {
        return;
      }
      lastError = failure.toString();
      notifyListeners();
      final failures = (_actorFailures[actor] ?? 0) + 1;
      _actorFailures[actor] = failures;
      final causalGap =
          failure is ApiException &&
          failure.statusCode == 409 &&
          failure.payload is Map &&
          (failure.payload as Map)['detail'] is Map &&
          ((failure.payload as Map)['detail'] as Map)['code'] == 'CAUSAL_GAP';
      final permanent =
          failure is ArgumentError ||
          failure is UnsupportedError ||
          failure is FormatException ||
          (failure is ApiException &&
              (failure.statusCode == 403 ||
                  failure.statusCode == 410 ||
                  failure.statusCode == 413 ||
                  failure.statusCode == 422 ||
                  (failure.statusCode == 409 && !causalGap)));
      if (permanent) {
        // No endless retry loop and no loss of the immutable outbox entry.
        await store.markBlocked(batch.first.operationId, failure.toString());
        return;
      }
      final delay = _backoff(failures);
      // Retry only the first unacknowledged actor sequence. Other actors
      // remain eligible while this one is deferred.
      await store.scheduleRetry(batch.first.operationId, delay: delay);
      _scheduleRetry(delay);
    }
  }

  void _endShare() {
    if (shareId == null || !_started) {
      return;
    }
    // stop() invalidates the connection generation immediately. The outbox
    // remains durable, available for explicit recovery after rejoining.
    unawaited(stop());
    onShareEnded?.call();
  }

  Future<T> _authorized<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on ApiException catch (error) {
      if (shareId != null && error.statusCode == 410) {
        _endShare();
        rethrow;
      }
      if (error.statusCode != 401 || refreshAuthentication == null) {
        rethrow;
      }
      await refreshAuthentication!();
      return action();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !_started) {
      return;
    }
    requestSync();
    if (enableRealtime && apiClient != null && _socket == null) {
      unawaited(_connectSocket(_generation));
    }
  }

  Duration _backoff(int failures) {
    final seconds = min(60, 1 << min(failures - 1, 6));
    return Duration(milliseconds: seconds * 1000 + Random().nextInt(350));
  }

  void _scheduleRetry(Duration delay) {
    if (!_started || _disposed) {
      return;
    }
    final next = DateTime.now().add(delay);
    // Preserve the earliest wakeup. A previous permanent error must not
    // delay a different actor's short transient retry.
    if (_retry?.isActive == true &&
        _retryDueAt != null &&
        !_retryDueAt!.isAfter(next)) {
      return;
    }
    _retry?.cancel();
    _retryDueAt = next;
    _retry = Timer(delay, () {
      _retry = null;
      _retryDueAt = null;
      requestSync();
    });
  }

  Future<void> _connectSocket(int generation) async {
    if (!_isActive(generation) || _socket != null) {
      return;
    }
    final api = apiClient;
    final token = guestTicket ?? api?.accessToken;
    if (api == null || token == null || token.isEmpty) {
      return;
    }
    final uri = api
        .resolve('/v2/realtime')
        .replace(scheme: api.baseUri.scheme == 'https' ? 'wss' : 'ws');
    final socket = WebSocketChannel.connect(uri);
    _socket = socket;
    _socketSubscription = socket.stream.listen(
      (event) {
        try {
          final message = jsonDecode(event as String);
          if (message is Map && message['type'] == 'operations_changed') {
            requestSync();
          } else if (shareId != null &&
              message is Map &&
              message['type'] == 'ended') {
            _endShare();
          }
        } catch (_) {
          // A malformed hint cannot advance a cursor or mutate a document.
        }
      },
      onError: (_) => _socketDisconnected(generation, socket),
      onDone: () => _socketDisconnected(generation, socket),
      cancelOnError: true,
    );
    try {
      await socket.ready.timeout(const Duration(seconds: 10));
      if (_isActive(generation) && identical(_socket, socket)) {
        socket.sink.add(
          jsonEncode({
            'type': 'authenticate',
            'token': token,
            if (shareId != null) 'shareId': shareId,
          }),
        );
        // A missed hint while disconnected is recovered by REST.
        requestSync();
      }
    } catch (_) {
      _socketDisconnected(generation, socket);
    }
  }

  void _socketDisconnected(int generation, WebSocketChannel socket) {
    if (!identical(_socket, socket)) {
      return;
    }
    _socket = null;
    _socketSubscription = null;
    unawaited(socket.sink.close());
    if (!_isActive(generation)) {
      return;
    }
    requestSync();
    _socketRetry?.cancel();
    _socketRetry = Timer(const Duration(seconds: 5), () {
      _socketRetry = null;
      unawaited(_connectSocket(generation));
    });
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    unawaited(stop());
    _disposed = true;
    super.dispose();
  }
}
