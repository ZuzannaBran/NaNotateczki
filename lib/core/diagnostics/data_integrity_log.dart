import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../storage/text_storage.dart';

class DataIntegrityLog extends ChangeNotifier {
  DataIntegrityLog._();

  static final DataIntegrityLog instance = DataIntegrityLog._();

  static const String _fileName = 'data_integrity_log.json';
  static const int _maxEntries = 100;
  static const Duration _retention = Duration(days: 180);

  final List<DataIntegrityIncident> _entries = [];

  List<DataIntegrityIncident> get entries => List.unmodifiable(_entries);

  bool get isEmpty => _entries.isEmpty;

  int get length => _entries.length;

  Future<void> load() async {
    try {
      final content = await readStoredText(_fileName);
      if (content == null) {
        return;
      }
      final decoded = jsonDecode(content);
      if (decoded is! List<dynamic>) {
        return;
      }
      _entries
        ..clear()
        ..addAll(decoded.map(DataIntegrityIncident.fromJson).nonNulls);
      _prune();
      notifyListeners();
      await _save();
    } catch (e) {
      debugPrint('DataIntegrityLog.load failed: $e');
    }
  }

  Future<void> record(DataIntegrityIncident incident) async {
    _entries.insert(0, incident);
    _prune();
    notifyListeners();
    await _save();
  }

  void clear() {
    if (_entries.isEmpty) {
      return;
    }
    _entries.clear();
    notifyListeners();
    unawaited(_save().catchError((Object _) {}));
  }

  String toClipboardText() {
    if (_entries.isEmpty) {
      return 'No data integrity incidents recorded.';
    }
    return _entries.map((entry) => entry.format()).join('\n\n');
  }

  void _prune() {
    final oldestAllowed = DateTime.now().subtract(_retention);
    _entries.removeWhere((entry) => entry.occurredAt.isBefore(oldestAllowed));
    _entries.sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
    if (_entries.length > _maxEntries) {
      _entries.removeRange(_maxEntries, _entries.length);
    }
  }

  Future<void> _save() async {
    try {
      await writeStoredText(
        _fileName,
        jsonEncode(_entries.map((entry) => entry.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('DataIntegrityLog._save failed: $e');
      rethrow;
    }
  }
}

class DataIntegrityIncident {
  const DataIntegrityIncident({
    required this.id,
    required this.occurredAt,
    required this.operation,
    required this.notebookUid,
    required this.notebookTitle,
    required this.reasons,
    required this.affectedPageIds,
    required this.before,
    required this.attempted,
    required this.stackTrace,
    this.archivePath,
  });

  final String id;
  final DateTime occurredAt;
  final String operation;
  final String notebookUid;
  final String notebookTitle;
  final List<String> reasons;
  final List<String> affectedPageIds;
  final Map<String, int> before;
  final Map<String, int> attempted;
  final String stackTrace;
  final String? archivePath;

  DataIntegrityIncident copyWith({String? archivePath}) {
    return DataIntegrityIncident(
      id: id,
      occurredAt: occurredAt,
      operation: operation,
      notebookUid: notebookUid,
      notebookTitle: notebookTitle,
      reasons: reasons,
      affectedPageIds: affectedPageIds,
      before: before,
      attempted: attempted,
      stackTrace: stackTrace,
      archivePath: archivePath ?? this.archivePath,
    );
  }

  static DataIntegrityIncident? fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      return null;
    }
    final occurredAtText = value['occurredAt'];
    if (occurredAtText is! String) {
      return null;
    }
    final occurredAt = DateTime.tryParse(occurredAtText);
    final before = _intMap(value['before']);
    final attempted = _intMap(value['attempted']);
    if (occurredAt == null || before == null || attempted == null) {
      return null;
    }
    final id = value['id'];
    final operation = value['operation'];
    final notebookUid = value['notebookUid'];
    final notebookTitle = value['notebookTitle'];
    final stackTrace = value['stackTrace'];
    if (id is! String ||
        operation is! String ||
        notebookUid is! String ||
        notebookTitle is! String ||
        stackTrace is! String) {
      return null;
    }
    return DataIntegrityIncident(
      id: id,
      occurredAt: occurredAt,
      operation: operation,
      notebookUid: notebookUid,
      notebookTitle: notebookTitle,
      reasons: (value['reasons'] as List<dynamic>? ?? [])
          .whereType<String>()
          .toList(),
      affectedPageIds: (value['affectedPageIds'] as List<dynamic>? ?? [])
          .whereType<String>()
          .toList(),
      before: before,
      attempted: attempted,
      stackTrace: stackTrace,
      archivePath: value['archivePath'] as String?,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'occurredAt': occurredAt.toIso8601String(),
      'operation': operation,
      'notebookUid': notebookUid,
      'notebookTitle': notebookTitle,
      'reasons': reasons,
      'affectedPageIds': affectedPageIds,
      'before': before,
      'attempted': attempted,
      'stackTrace': stackTrace,
      'archivePath': archivePath,
    };
  }

  String format() {
    final buffer = StringBuffer()
      ..writeln('[${occurredAt.toIso8601String()}] $operation')
      ..writeln('incidentId=$id')
      ..writeln('notebookUid=$notebookUid')
      ..writeln('notebookTitle=$notebookTitle')
      ..writeln('reasons=${reasons.join(',')}')
      ..writeln('affectedPageIds=${affectedPageIds.join(',')}')
      ..writeln('before=${jsonEncode(before)}')
      ..writeln('attempted=${jsonEncode(attempted)}')
      ..writeln('archivePath=${archivePath ?? 'not available'}')
      ..writeln('stackTrace:')
      ..write(stackTrace);
    return buffer.toString().trimRight();
  }

  static Map<String, int>? _intMap(Object? value) {
    if (value is! Map<String, dynamic>) {
      return null;
    }
    final result = <String, int>{};
    for (final entry in value.entries) {
      final number = entry.value;
      if (number is! num) {
        return null;
      }
      result[entry.key] = number.toInt();
    }
    return result;
  }
}
