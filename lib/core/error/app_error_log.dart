import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class AppErrorLog extends ChangeNotifier {
  AppErrorLog._();

  static final AppErrorLog instance = AppErrorLog._();

  static const String _fileName = 'app_error_log.json';
  static const int _maxEntries = 80;
  static const Duration _retention = Duration(days: 3);

  final List<AppErrorLogEntry> _entries = [];

  List<AppErrorLogEntry> get entries => List.unmodifiable(_entries);

  bool get isEmpty => _entries.isEmpty;

  int get length => _entries.length;

  Future<void> load() async {
    try {
      final file = await _logFile();
      if (!await file.exists()) {
        return;
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List<dynamic>) {
        return;
      }
      _entries
        ..clear()
        ..addAll(decoded.map(AppErrorLogEntry.fromJson).nonNulls);
      _prune();
      notifyListeners();
      unawaited(_save());
    } catch (e) {
      debugPrint('AppErrorLog.load failed: $e');
    }
  }

  void record(Object error, StackTrace? stackTrace, {required String source}) {
    _entries.insert(
      0,
      AppErrorLogEntry(
        occurredAt: DateTime.now(),
        source: source,
        error: error.toString(),
        stackTrace: stackTrace?.toString(),
      ),
    );
    _prune();
    notifyListeners();
    unawaited(_save());
  }

  void recordFlutterError(FlutterErrorDetails details) {
    record(
      details.exception,
      details.stack,
      source: details.context?.toDescription() ?? 'Flutter framework',
    );
  }

  void clear() {
    if (_entries.isEmpty) {
      return;
    }
    _entries.clear();
    notifyListeners();
    unawaited(_save());
  }

  String toClipboardText() {
    if (_entries.isEmpty) {
      return 'No errors recorded.';
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
      final file = await _logFile();
      await file.writeAsString(
        jsonEncode(_entries.map((entry) => entry.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('AppErrorLog._save failed: $e');
    }
  }

  Future<File> _logFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }
}

class AppErrorLogEntry {
  const AppErrorLogEntry({
    required this.occurredAt,
    required this.source,
    required this.error,
    required this.stackTrace,
  });

  final DateTime occurredAt;
  final String source;
  final String error;
  final String? stackTrace;

  static AppErrorLogEntry? fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      return null;
    }
    final occurredAtText = value['occurredAt'];
    final source = value['source'];
    final error = value['error'];
    final stackTrace = value['stackTrace'];
    if (occurredAtText is! String || source is! String || error is! String) {
      return null;
    }
    final occurredAt = DateTime.tryParse(occurredAtText);
    if (occurredAt == null) {
      return null;
    }
    return AppErrorLogEntry(
      occurredAt: occurredAt,
      source: source,
      error: error,
      stackTrace: stackTrace is String ? stackTrace : null,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'occurredAt': occurredAt.toIso8601String(),
      'source': source,
      'error': error,
      'stackTrace': stackTrace,
    };
  }

  String format() {
    final buffer = StringBuffer()
      ..writeln('[${occurredAt.toIso8601String()}] $source')
      ..writeln(error);
    final stack = stackTrace;
    if (stack != null && stack.isNotEmpty) {
      buffer.write(stack);
    }
    return buffer.toString().trimRight();
  }
}
