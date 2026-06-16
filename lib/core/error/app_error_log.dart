import 'package:flutter/foundation.dart';

class AppErrorLog extends ChangeNotifier {
  AppErrorLog._();

  static final AppErrorLog instance = AppErrorLog._();

  static const int _maxEntries = 80;

  final List<AppErrorLogEntry> _entries = [];

  List<AppErrorLogEntry> get entries => List.unmodifiable(_entries);

  bool get isEmpty => _entries.isEmpty;

  int get length => _entries.length;

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
    if (_entries.length > _maxEntries) {
      _entries.removeRange(_maxEntries, _entries.length);
    }
    notifyListeners();
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
  }

  String toClipboardText() {
    if (_entries.isEmpty) {
      return 'No errors recorded.';
    }
    return _entries.map((entry) => entry.format()).join('\n\n');
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
