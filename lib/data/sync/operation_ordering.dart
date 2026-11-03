import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:uuid/uuid.dart';

import 'operation_protocol.dart';

/// The actor counter must be persisted atomically with its future outbox entry.
/// Stage 3 will provide the storage transaction; this class is intentionally
/// not connected to the existing snapshot sync.
class OperationActorClock {
  OperationActorClock({
    required this.actorId,
    this.actorSeq = 0,
    this.logicalClock = 0,
    this.previousOperationId,
  }) {
    if (actorId.isEmpty || actorSeq < 0 || logicalClock < 0) {
      throw ArgumentError('Invalid actor checkpoint.');
    }
  }

  final String actorId;
  int actorSeq;
  int logicalClock;
  String? previousOperationId;

  void observe(OperationEnvelope remote) {
    if (remote.logicalClock > logicalClock) {
      logicalClock = remote.logicalClock;
    }
  }

  OperationEnvelope next({
    required String documentId,
    required OperationKind kind,
    Map<String, dynamic> payload = const {},
    String? pageId,
    String? objectId,
    String? revertsOperationId,
    List<String> dependencies = const [],
  }) {
    final causalIds = <String>{
      ...dependencies,
      if (previousOperationId != null) previousOperationId!,
    }.toList()..sort();
    final operation = OperationEnvelope(
      operationId: const Uuid().v4(),
      actorId: actorId,
      actorSeq: actorSeq + 1,
      documentId: documentId,
      kind: kind,
      payload: payload,
      pageId: pageId,
      objectId: objectId,
      revertsOperationId: revertsOperationId,
      dependencies: causalIds,
      logicalClock: logicalClock + 1,
    );
    actorSeq = operation.actorSeq;
    logicalClock = operation.logicalClock;
    previousOperationId = operation.operationId;
    return operation;
  }

  Map<String, dynamic> toCheckpoint() => {
    'actorId': actorId,
    'actorSeq': actorSeq,
    'logicalClock': logicalClock,
    if (previousOperationId != null)
      'previousOperationId': previousOperationId,
  };

  factory OperationActorClock.fromCheckpoint(Map<String, dynamic> json) {
    return OperationActorClock(
      actorId: json['actorId'] as String,
      actorSeq: json['actorSeq'] as int,
      logicalClock: json['logicalClock'] as int,
      previousOperationId: json['previousOperationId'] as String?,
    );
  }
}

class OperationOrderException implements Exception {
  const OperationOrderException(this.message);

  final String message;

  @override
  String toString() => 'OperationOrderException: $message';
}

/// Deterministic precedence for concurrent writes to the same field.
///
/// Causal writes necessarily have a larger Lamport clock. This comparator
/// never examines DateTime.now or a device's wall-clock timestamp.
int compareOperationPrecedence(OperationEnvelope a, OperationEnvelope b) {
  final clock = a.logicalClock.compareTo(b.logicalClock);
  if (clock != 0) {
    return clock;
  }
  final actor = a.actorId.compareTo(b.actorId);
  if (actor != 0) {
    return actor;
  }
  final sequence = a.actorSeq.compareTo(b.actorSeq);
  if (sequence != 0) {
    return sequence;
  }
  return a.operationId.compareTo(b.operationId);
}

/// Buffers out-of-order operations across documents in a storage namespace.
///
/// [initialActorSequences] and [knownOperationIds] must come from the same
/// durable checkpoint. A buffered operation is never reported as applied.
/// No writes occur here: stage 3 will commit projection and cursor together.
class CausalOperationBuffer {
  CausalOperationBuffer({
    Map<String, int> initialActorSequences = const {},
    Set<String> knownOperationIds = const {},
    this.maximumPending = 10000,
  }) : _actorSequences = Map.of(initialActorSequences),
       _knownIds = Set.of(knownOperationIds) {
    if (maximumPending < 1 ||
        _actorSequences.values.any((value) => value < 0)) {
      throw ArgumentError('Invalid causal checkpoint.');
    }
  }

  final int maximumPending;
  final Map<String, int> _actorSequences;
  final Set<String> _knownIds;
  final Map<String, OperationEnvelope> _pending = {};
  final Map<String, OperationEnvelope> _accepted = {};
  final Map<String, Map<int, String>> _sequenceIds = {};
  final Map<String, OperationEnvelope> _latestActorOperation = {};

  int get pendingCount => _pending.length;
  Map<String, int> get actorSequences => Map.unmodifiable(_actorSequences);

  List<String> missingDependencies(OperationEnvelope operation) =>
      operation.dependencies
          .where((id) => !_knownIds.contains(id))
          .toList(growable: false);

  /// Accepts an envelope, returning only operations with satisfied parents.
  /// A repeated identical packet is harmless. An ID/actorSeq fork is fatal.
  List<OperationEnvelope> ingest(OperationEnvelope operation) {
    final existing = _pending[operation.operationId] ??
        _accepted[operation.operationId];
    if (existing != null) {
      if (!const DeepCollectionEquality().equals(
        existing.toJson(),
        operation.toJson(),
      )) {
        throw const OperationOrderException('Operation ID was reused.');
      }
      return const [];
    }
    if (_knownIds.contains(operation.operationId)) {
      return const [];
    }
    if (operation.actorSeq <= (_actorSequences[operation.actorId] ?? 0)) {
      throw const OperationOrderException('Sequence precedes checkpoint.');
    }
    final actorKeys = _sequenceIds.putIfAbsent(
      operation.actorId,
      () => <int, String>{},
    );
    final previousId = actorKeys[operation.actorSeq];
    if (previousId != null && previousId != operation.operationId) {
      throw const OperationOrderException('Actor sequence was forked.');
    }
    if (_pending.length >= maximumPending) {
      throw const OperationOrderException('Causal queue is full.');
    }
    actorKeys[operation.actorSeq] = operation.operationId;
    _pending[operation.operationId] = operation;
    if (_hasDependencyCycle(operation.operationId, <String>{}, <String>{})) {
      _pending.remove(operation.operationId);
      actorKeys.remove(operation.actorSeq);
      throw const OperationOrderException('Causal dependency cycle.');
    }
    return _drainReady();
  }

  List<OperationEnvelope> _drainReady() {
    final applied = <OperationEnvelope>[];
    while (true) {
      final ready = _pending.values.where((op) {
        return op.actorSeq == (_actorSequences[op.actorId] ?? 0) + 1 &&
            op.dependencies.every(_knownIds.contains);
      }).toList()..sort(compareOperationPrecedence);
      if (ready.isEmpty) {
        break;
      }
      for (final operation in ready) {
        final last = _latestActorOperation[operation.actorId];
        if (last != null &&
            (!operation.dependencies.contains(last.operationId) ||
                operation.logicalClock <= last.logicalClock)) {
          throw const OperationOrderException('Invalid actor causality.');
        }
        for (final dependency in operation.dependencies) {
          final parent = _accepted[dependency];
          if (parent != null &&
              operation.logicalClock <= parent.logicalClock) {
            throw const OperationOrderException('Invalid logical clock.');
          }
        }
        _pending.remove(operation.operationId);
        _knownIds.add(operation.operationId);
        _accepted[operation.operationId] = operation;
        _actorSequences[operation.actorId] = operation.actorSeq;
        _latestActorOperation[operation.actorId] = operation;
        applied.add(operation);
      }
    }
    return applied;
  }

  bool _hasDependencyCycle(
    String id,
    Set<String> visiting,
    Set<String> finished,
  ) {
    if (visiting.contains(id)) {
      return true;
    }
    if (!finished.add(id)) {
      return false;
    }
    visiting.add(id);
    final operation = _pending[id];
    if (operation != null) {
      for (final dependency in operation.dependencies) {
        if (_pending.containsKey(dependency) &&
            _hasDependencyCycle(dependency, visiting, finished)) {
          return true;
        }
      }
    }
    visiting.remove(id);
    return false;
  }
}

/// Small field-register projection proving convergence of ordinary edits.
/// Text atom CRDT, geometry transforms and assets get their domain-specific
/// reducers in later stages. They must not be silently applied as LWW JSON.
class OperationPropertyRegister {
  final Map<String, Map<String, Object?>> _values = {};
  final Map<String, Map<String, OperationEnvelope>> _versions = {};
  final Set<String> _tombstones = {};

  void apply(OperationEnvelope operation) {
    switch (operation.kind) {
      case OperationKind.documentDelete:
      case OperationKind.pageDelete:
      case OperationKind.objectDelete:
      case OperationKind.folderDelete:
        _tombstones.add(_key(operation));
        return;
      case OperationKind.documentCreate:
      case OperationKind.documentSet:
      case OperationKind.pageCreate:
      case OperationKind.pageSet:
      case OperationKind.strokeCreate:
      case OperationKind.objectCreate:
      case OperationKind.objectSet:
      case OperationKind.objectTransform:
      case OperationKind.objectReorder:
      case OperationKind.folderCreate:
      case OperationKind.folderSet:
      case OperationKind.folderMove:
        break;
      case OperationKind.textInsert:
      case OperationKind.textDelete:
      case OperationKind.assetAttach:
      case OperationKind.assetDetach:
        throw UnsupportedError('Domain-specific reducer required.');
    }
    if (_isDeleted(operation)) {
      return;
    }
    final fields = operation.payload['properties'] ??
        operation.payload['value'];
    if (fields is! Map) {
      throw const FormatException('Projection needs properties or value.');
    }
    final key = _key(operation);
    final values = _values.putIfAbsent(key, () => <String, Object?>{});
    final versions = _versions.putIfAbsent(
      key,
      () => <String, OperationEnvelope>{},
    );
    for (final entry in fields.entries) {
      final name = entry.key;
      if (name is! String) {
        throw const FormatException('Property names must be strings.');
      }
      final last = versions[name];
      if (last == null ||
          compareOperationPrecedence(operation, last) > 0) {
        values[name] = entry.value;
        versions[name] = operation;
      }
    }
  }

  Map<String, Object?>? fieldsFor(OperationEnvelope operation) {
    if (_isDeleted(operation)) {
      return null;
    }
    final fields = _values[_key(operation)];
    return fields == null ? null : Map.unmodifiable(fields);
  }

  bool _isDeleted(OperationEnvelope operation) {
    if (_tombstones.contains(_documentKey(operation.documentId))) {
      return true;
    }
    if (operation.kind.target == OperationTarget.object &&
        _tombstones.contains(
          _pageKey(operation.documentId, operation.pageId!),
        )) {
      return true;
    }
    return _tombstones.contains(_key(operation));
  }

  String _key(OperationEnvelope operation) {
    switch (operation.kind.target) {
      case OperationTarget.document:
        return _documentKey(operation.documentId);
      case OperationTarget.page:
        return _pageKey(operation.documentId, operation.objectId!);
      case OperationTarget.object:
        return jsonEncode([
          operation.documentId,
          'object',
          operation.pageId,
          operation.objectId,
        ]);
      case OperationTarget.folder:
        return jsonEncode(['@library', 'folder', operation.objectId]);
    }
  }

  String _documentKey(String id) => jsonEncode([id, 'document']);

  String _pageKey(String documentId, String id) =>
      jsonEncode([documentId, 'page', id]);
}
