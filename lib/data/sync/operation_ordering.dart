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
    this.documentId,
    this.actorSeq = 0,
    this.logicalClock = 0,
    this.previousOperationId,
  }) {
    if (actorId.isEmpty ||
        actorId.length > 128 ||
        actorSeq < 0 ||
        actorSeq > OperationEnvelope.maxSafeInteger ||
        logicalClock < 0 ||
        logicalClock > OperationEnvelope.maxSafeInteger ||
        (actorSeq > 0 && previousOperationId == null) ||
        (actorSeq > 0 && documentId == null) ||
        (documentId != null &&
            (documentId!.isEmpty || documentId!.length > 128))) {
      throw ArgumentError('Invalid actor checkpoint.');
    }
  }

  final String actorId;
  String? documentId;
  int actorSeq;
  int logicalClock;
  String? previousOperationId;

  final Map<String, OperationEnvelope> _observed = {};

  /// Observe only committed, causally available remote operations.
  void observe(OperationEnvelope remote) {
    if (documentId != null && remote.documentId != documentId) {
      return;
    }
    if (remote.actorId != actorId) {
      final previous = _observed[remote.actorId];
      if (previous != null &&
          previous.actorSeq == remote.actorSeq &&
          previous.operationId != remote.operationId) {
        throw const FormatException('Forked observed actor sequence.');
      }
      if (previous == null || remote.actorSeq > previous.actorSeq) {
        _observed[remote.actorId] = remote;
      }
    }
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
    if (this.documentId != null && this.documentId != documentId) {
      throw const FormatException('Actor cannot cross document scope.');
    }
    final observed = _observed.values
        .where((op) => op.documentId == documentId)
        .toList();
    final observedIds = observed.map((op) => op.operationId).toSet();
    final coveredIds = <String>{
      for (final op in observed)
        for (final parent in op.dependencies)
          if (observedIds.contains(parent)) parent,
    };
    final causalIds = <String>{
      ...dependencies,
      if (revertsOperationId != null) revertsOperationId,
      for (final id in observedIds)
        if (!coveredIds.contains(id)) id,
      if (previousOperationId != null) previousOperationId!,
    }.toList()..sort();
    if (causalIds.length > 256 ||
        actorSeq >= OperationEnvelope.maxSafeInteger ||
        logicalClock >= OperationEnvelope.maxSafeInteger) {
      throw const FormatException('Actor clock or dependency limit exceeded.');
    }
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
    this.documentId = documentId;
    _observed.removeWhere((_, remote) => remote.documentId != documentId);
    return operation;
  }

  Map<String, dynamic> toCheckpoint() => {
    'actorId': actorId,
    if (documentId != null) 'documentId': documentId,
    'actorSeq': actorSeq,
    'logicalClock': logicalClock,
    if (previousOperationId != null) 'previousOperationId': previousOperationId,
    'observedOperations': [for (final op in _observed.values) op.toJson()],
  };

  factory OperationActorClock.fromCheckpoint(Map<String, dynamic> json) {
    final clock = OperationActorClock(
      actorId: json['actorId'] as String,
      documentId: json['documentId'] as String?,
      actorSeq: json['actorSeq'] as int,
      logicalClock: json['logicalClock'] as int,
      previousOperationId: json['previousOperationId'] as String?,
    );
    final observed = json['observedOperations'] as List? ?? [];
    for (final entry in observed) {
      final remote = OperationEnvelope.fromJson(
        Map<String, dynamic>.from(entry as Map),
      );
      if (remote.logicalClock > clock.logicalClock) {
        throw const FormatException('Observed frontier exceeds actor clock.');
      }
      clock.observe(remote);
    }
    return clock;
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

/// A lossless stage-2 checkpoint. Compaction needs a durable ID lookup.
class OperationCheckpoint {
  OperationCheckpoint({
    required List<OperationEnvelope> operations,
    Map<String, String> rejectedOperations = const {},
  }) : operations = List.unmodifiable(operations),
       rejectedOperations = Map.unmodifiable(rejectedOperations);

  static const schemaVersion = 1;
  final List<OperationEnvelope> operations;
  final Map<String, String> rejectedOperations;

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'operations': [for (final op in operations) op.toJson()],
    'rejectedOperations': Map<String, String>.of(rejectedOperations),
  };

  factory OperationCheckpoint.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != schemaVersion || json['operations'] is! List) {
      throw const FormatException('Invalid operation checkpoint.');
    }
    final rejected = Map<String, String>.from(
      json['rejectedOperations'] as Map? ?? const {},
    );
    if (rejected.values.any((reason) => reason.isEmpty)) {
      throw const FormatException('Invalid rejected operations.');
    }
    return OperationCheckpoint(
      operations: [
        for (final value in json['operations'] as List)
          OperationEnvelope.fromJson(Map<String, dynamic>.from(value as Map)),
      ],
      rejectedOperations: rejected,
    );
  }
}

/// Buffers causal gaps and atomically acknowledges ready operations.
///
/// Stage 3 will persist accepted operations with their projections in a
/// single SQLite transaction. Pending operations belong in the outbox.
class CausalOperationBuffer {
  CausalOperationBuffer({this.maximumPending = 10000}) {
    if (maximumPending < 1) {
      throw ArgumentError('Invalid causal queue capacity.');
    }
  }

  factory CausalOperationBuffer.fromCheckpoint(
    OperationCheckpoint checkpoint, {
    int maximumPending = 10000,
  }) {
    final queue = CausalOperationBuffer(maximumPending: maximumPending);
    final operations = [...checkpoint.operations]
      ..sort(compareOperationPrecedence);
    for (final operation in operations) {
      queue.ingest(operation);
    }
    if (queue.pendingCount != 0 ||
        queue._accepted.length != operations.length ||
        checkpoint.rejectedOperations.keys.any(queue._accepted.containsKey)) {
      throw const FormatException('Inconsistent causal checkpoint.');
    }
    queue._rejected.addAll(checkpoint.rejectedOperations);
    return queue;
  }

  final int maximumPending;
  final Map<String, int> _actorSequences = {};
  final Set<String> _knownIds = {};
  final Map<String, OperationEnvelope> _pending = {};
  final Map<String, OperationEnvelope> _accepted = {};
  final Map<String, Map<int, String>> _sequenceIds = {};
  final Map<String, OperationEnvelope> _latestActorOperation = {};
  final Map<String, String> _rejected = {};

  int get pendingCount => _pending.length;
  Map<String, int> get actorSequences => Map.unmodifiable(_actorSequences);
  Map<String, String> get rejectedOperations => Map.unmodifiable(_rejected);

  OperationCheckpoint exportCheckpoint() {
    if (_pending.isNotEmpty) {
      throw const OperationOrderException(
        'Pending operations must be stored separately.',
      );
    }
    return OperationCheckpoint(
      operations: _accepted.values.toList()..sort(compareOperationPrecedence),
      rejectedOperations: _rejected,
    );
  }

  List<String> missingDependencies(OperationEnvelope operation) => operation
      .dependencies
      .where((id) => !_knownIds.contains(id))
      .toList(growable: false);

  List<OperationEnvelope> ingest(OperationEnvelope operation) {
    final existing =
        _pending[operation.operationId] ?? _accepted[operation.operationId];
    if (existing != null) {
      if (!const DeepCollectionEquality().equals(
        existing.toJson(),
        operation.toJson(),
      )) {
        throw const OperationOrderException('Operation ID was reused.');
      }
      return const [];
    }
    if (_rejected.containsKey(operation.operationId)) {
      throw const OperationOrderException('Previously rejected operation ID.');
    }
    if (_knownIds.contains(operation.operationId)) {
      throw const OperationOrderException('Missing known operation payload.');
    }
    if (operation.actorSeq <= (_actorSequences[operation.actorId] ?? 0)) {
      throw const OperationOrderException('Sequence precedes checkpoint.');
    }
    final previousId = _sequenceIds[operation.actorId]?[operation.actorSeq];
    if (previousId != null) {
      throw const OperationOrderException('Actor sequence was forked.');
    }
    if (_pending.length >= maximumPending) {
      throw const OperationOrderException('Causal queue is full.');
    }

    final pending = Map<String, OperationEnvelope>.of(_pending);
    final accepted = Map<String, OperationEnvelope>.of(_accepted);
    final known = Set<String>.of(_knownIds);
    final sequences = Map<String, int>.of(_actorSequences);
    final sequenceIds = _sequenceIds.map(
      (actor, values) => MapEntry(actor, Map<int, String>.of(values)),
    );
    final latest = Map<String, OperationEnvelope>.of(_latestActorOperation);
    final rejected = Map<String, String>.of(_rejected);
    sequenceIds.putIfAbsent(operation.actorId, () => {})[operation.actorSeq] =
        operation.operationId;
    pending[operation.operationId] = operation;
    if (_hasDependencyCycle(
      pending,
      operation.operationId,
      <String>{},
      <String>{},
    )) {
      throw const OperationOrderException('Causal dependency cycle.');
    }

    final applied = <OperationEnvelope>[];
    while (true) {
      final ready = pending.values.where((op) {
        return op.actorSeq == (sequences[op.actorId] ?? 0) + 1 &&
            op.dependencies.every(known.contains);
      }).toList()..sort(compareOperationPrecedence);
      if (ready.isEmpty) {
        break;
      }
      for (final candidate in ready) {
        if (!pending.containsKey(candidate.operationId)) {
          continue;
        }
        String? invalid;
        final last = latest[candidate.actorId];
        if (last != null &&
            (!candidate.dependencies.contains(last.operationId) ||
                candidate.logicalClock <= last.logicalClock ||
                candidate.documentId != last.documentId)) {
          invalid = 'Invalid actor causality.';
        }
        for (final dependency in candidate.dependencies) {
          final parent = accepted[dependency];
          if (parent == null) {
            invalid ??= 'Unverifiable checkpoint dependency.';
          } else if (candidate.documentId != parent.documentId) {
            invalid ??= 'Cross-document causal dependency.';
          } else if (candidate.logicalClock <= parent.logicalClock) {
            invalid ??= 'Invalid logical clock.';
          }
        }
        if (invalid != null) {
          if (candidate.operationId == operation.operationId) {
            throw OperationOrderException(invalid);
          }
          pending.remove(candidate.operationId);
          sequenceIds[candidate.actorId]?.remove(candidate.actorSeq);
          rejected[candidate.operationId] = invalid;
          continue;
        }
        pending.remove(candidate.operationId);
        known.add(candidate.operationId);
        accepted[candidate.operationId] = candidate;
        sequences[candidate.actorId] = candidate.actorSeq;
        latest[candidate.actorId] = candidate;
        applied.add(candidate);
      }
    }

    _pending
      ..clear()
      ..addAll(pending);
    _accepted
      ..clear()
      ..addAll(accepted);
    _knownIds
      ..clear()
      ..addAll(known);
    _actorSequences
      ..clear()
      ..addAll(sequences);
    _sequenceIds
      ..clear()
      ..addAll(sequenceIds);
    _latestActorOperation
      ..clear()
      ..addAll(latest);
    _rejected
      ..clear()
      ..addAll(rejected);
    return applied;
  }

  bool _hasDependencyCycle(
    Map<String, OperationEnvelope> pending,
    String id,
    Set<String> visiting,
    Set<String> finished,
  ) {
    if (visiting.contains(id)) {
      return true;
    }
    if (finished.contains(id)) {
      return false;
    }
    visiting.add(id);
    final operation = pending[id];
    if (operation != null) {
      for (final dependency in operation.dependencies) {
        if (pending.containsKey(dependency) &&
            _hasDependencyCycle(pending, dependency, visiting, finished)) {
          return true;
        }
      }
    }
    visiting.remove(id);
    finished.add(id);
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
    final fields =
        operation.payload['properties'] ?? operation.payload['value'];
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
      if (last == null || compareOperationPrecedence(operation, last) > 0) {
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
