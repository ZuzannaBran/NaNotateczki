import 'dart:convert';

/// Decision made from a durable server acknowledgment, never device time.
enum PlannerSyncDecision { unchanged, adoptRemote, sendLocal, conflict }

class PlannerRevision {
  const PlannerRevision({required this.revision, required this.signature});

  final int revision;
  final String signature;

  Map<String, dynamic> toJson() => {
    'revision': revision,
    'signature': signature,
  };

  static PlannerRevision fromJson(Map<String, dynamic> json) {
    final revision = json['revision'];
    final signature = json['signature'];
    if (revision is! int ||
        revision < 1 ||
        signature is! String ||
        signature.isEmpty) {
      throw const FormatException('Invalid planner revision checkpoint');
    }
    return PlannerRevision(revision: revision, signature: signature);
  }
}

/// A per-account checkpoint for planner entries and durable tombstones.
///
/// Legacy modifiedAt is deliberately omitted from conflict resolution.
class PlannerRevisionLedger {
  PlannerRevisionLedger([Map<String, PlannerRevision>? initial])
    : _records = {...?initial};

  final Map<String, PlannerRevision> _records;

  PlannerRevision? operator [](String id) => _records[id];

  static PlannerRevisionLedger fromJson(Object? raw) {
    if (raw == null) {
      return PlannerRevisionLedger();
    }
    if (raw is! Map<String, dynamic> || raw['version'] != 1) {
      throw const FormatException('Unsupported planner revision ledger');
    }
    final records = raw['records'];
    if (records is! Map<String, dynamic>) {
      throw const FormatException('Invalid planner revision ledger');
    }
    return PlannerRevisionLedger({
      for (final item in records.entries)
        item.key: PlannerRevision.fromJson(
          Map<String, dynamic>.from(item.value as Map),
        ),
    });
  }

  String encode() => jsonEncode({
    'version': 1,
    'records': {
      for (final entry in _records.entries) entry.key: entry.value.toJson(),
    },
  });

  /// Timestamps do not identify a meaningful edit to the same record.
  static String signature(Map<String, dynamic> record) {
    if (record['deleted'] == true) {
      return 'deleted';
    }
    final content = record['entry'];
    if (content is! Map<String, dynamic>) {
      throw const FormatException('Invalid planner entry');
    }
    final clean = Map<String, dynamic>.from(content)..remove('modifiedAt');
    return jsonEncode(_canonical(clean));
  }

  static Object? _canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.whereType<String>().toList()..sort();
      return {for (final key in keys) key: _canonical(value[key])};
    }
    if (value is List) {
      return value.map(_canonical).toList();
    }
    return value;
  }

  PlannerSyncDecision decide({
    required String id,
    required Map<String, dynamic>? local,
    required Map<String, dynamic>? remote,
  }) {
    final known = _records[id];
    final localSignature = local == null ? null : signature(local);
    final remoteSignature = remote == null ? null : signature(remote);
    final remoteRevision = remote?['revision'];
    if (remote != null && (remoteRevision is! int || remoteRevision < 1)) {
      throw const FormatException('Remote planner revision is missing');
    }
    if (known == null) {
      if (remote == null) {
        return local == null
            ? PlannerSyncDecision.unchanged
            : PlannerSyncDecision.sendLocal;
      }
      if (local == null) {
        return PlannerSyncDecision.adoptRemote;
      }
      if (localSignature == remoteSignature) {
        return PlannerSyncDecision.unchanged;
      }
      // The account might predate the namespace migration. Never silently
      // interpret an unknown local record as an authorized account edit.
      return remote['deleted'] == true
          ? PlannerSyncDecision.adoptRemote
          : PlannerSyncDecision.conflict;
    }
    if (remote == null || remoteRevision < known.revision) {
      return PlannerSyncDecision.conflict;
    }
    if (localSignature == remoteSignature) {
      return PlannerSyncDecision.unchanged;
    }
    if (localSignature == known.signature) {
      return PlannerSyncDecision.adoptRemote;
    }
    if (remoteSignature == known.signature) {
      return PlannerSyncDecision.sendLocal;
    }
    if (local?['deleted'] == true && remote['deleted'] != true) {
      // Deletion wins against a simultaneous edit.
      return PlannerSyncDecision.sendLocal;
    }
    if (remote['deleted'] == true) {
      return PlannerSyncDecision.adoptRemote;
    }
    return PlannerSyncDecision.conflict;
  }

  void acknowledge(Map<String, dynamic> remote) {
    final id = remote['id'];
    final revision = remote['revision'];
    if (id is! String || id.isEmpty || revision is! int || revision < 1) {
      throw const FormatException('Invalid planner acknowledgment');
    }
    final old = _records[id];
    if (old != null && revision < old.revision) {
      throw StateError('Planner checkpoint cannot move backwards');
    }
    _records[id] = PlannerRevision(
      revision: revision,
      signature: signature(remote),
    );
  }
}
