import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../storage/text_storage.dart';

class OptimizationLog extends ChangeNotifier {
  OptimizationLog._();

  static final OptimizationLog instance = OptimizationLog._();

  static const String _fileName = 'optimization_log.json';
  static const int _maxEntries = 80;
  static const Duration _retention = Duration(days: 3);

  final List<OptimizationLogEntry> _entries = [];

  List<OptimizationLogEntry> get entries => List.unmodifiable(_entries);

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
        ..addAll(decoded.map(OptimizationLogEntry.fromJson).nonNulls);
      _prune();
      notifyListeners();
      unawaited(_save());
    } catch (e) {
      debugPrint('OptimizationLog.load failed: $e');
    }
  }

  void recordInkStroke({
    required String surface,
    required int pageIndex,
    required String tool,
    required int points,
    required int moves,
    required int durationMs,
    required int existingStrokes,
    required int moveUsAvg,
    required int moveUsMax,
    required int notifyCalls,
    required int frames,
    required int frameUsAvg,
    required int frameUsMax,
    required int inputToPaintUsAvg,
    required int inputToPaintUsMax,
  }) {
    final reasons = <String>[];
    final score = _inkScore(
      points: points,
      moves: moves,
      durationMs: durationMs,
      moveUsAvg: moveUsAvg,
      moveUsMax: moveUsMax,
      notifyCalls: notifyCalls,
      frames: frames,
      frameUsAvg: frameUsAvg,
      frameUsMax: frameUsMax,
      inputToPaintUsAvg: inputToPaintUsAvg,
      inputToPaintUsMax: inputToPaintUsMax,
      reasons: reasons,
    );
    if (reasons.isEmpty) {
      return;
    }
    _record(
      OptimizationLogEntry(
        occurredAt: DateTime.now(),
        category: 'ink',
        label: '$surface/$tool p=$pageIndex',
        score: score,
        reasons: reasons,
        details: {
          'surface': surface,
          'page': pageIndex,
          'tool': tool,
          'points': points,
          'moves': moves,
          'durationMs': durationMs,
          'existingStrokes': existingStrokes,
          'moveUsAvg': moveUsAvg,
          'moveUsMax': moveUsMax,
          'notify': notifyCalls,
          'frames': frames,
          'frameUsAvg': frameUsAvg,
          'frameUsMax': frameUsMax,
          'inputToPaintUsAvg': inputToPaintUsAvg,
          'inputToPaintUsMax': inputToPaintUsMax,
        },
      ),
    );
  }

  void recordBackup({
    required String reason,
    required int items,
    required int fetchMs,
    required int snapshotMs,
    required int totalMs,
    String? status,
    String? error,
  }) {
    final reasons = <String>[];
    final score = _backupScore(
      fetchMs: fetchMs,
      snapshotMs: snapshotMs,
      totalMs: totalMs,
      reasons: reasons,
    );
    if (status == 'failed' || status == 'corruptRows') {
      reasons.add(status!);
    }
    if (reasons.isEmpty) {
      return;
    }
    _record(
      OptimizationLogEntry(
        occurredAt: DateTime.now(),
        category: 'backup',
        label: 'backup/$reason',
        score: score,
        reasons: reasons,
        details: {
          'reason': reason,
          'items': items,
          'fetchMs': fetchMs,
          'snapshotMs': snapshotMs,
          'totalMs': totalMs,
          'status': status,
          'error': error,
        },
      ),
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
      return 'No suspicious optimization events recorded.';
    }
    final entries = List<OptimizationLogEntry>.from(_entries)
      ..sort((a, b) {
        final scoreCompare = b.score.compareTo(a.score);
        if (scoreCompare != 0) {
          return scoreCompare;
        }
        return b.occurredAt.compareTo(a.occurredAt);
      });
    return entries.map((entry) => entry.format()).join('\n\n');
  }

  int _inkScore({
    required int points,
    required int moves,
    required int durationMs,
    required int moveUsAvg,
    required int moveUsMax,
    required int notifyCalls,
    required int frames,
    required int frameUsAvg,
    required int frameUsMax,
    required int inputToPaintUsAvg,
    required int inputToPaintUsMax,
    required List<String> reasons,
  }) {
    var score = 0;
    if (moveUsMax >= 4000 || moveUsAvg >= 1000) {
      reasons.add('slow move handler');
      score = max(score, moveUsMax ~/ 1000);
    }
    if (frameUsMax >= 20000 || frameUsAvg >= 10000) {
      reasons.add('slow frame scheduling');
      score = max(score, frameUsMax ~/ 1000);
    }
    if (inputToPaintUsMax >= 20000 || inputToPaintUsAvg >= 10000) {
      reasons.add('slow input-to-paint');
      score = max(score, inputToPaintUsMax ~/ 1000);
    }
    if (moves >= 120 && points <= max(3, moves ~/ 20)) {
      reasons.add('many moves accepted as few points');
      score = max(score, moves ~/ max(1, points));
    }
    if (durationMs >= 2000 && points <= 3) {
      reasons.add('long contact with tiny stroke');
      score = max(score, durationMs);
    }
    if (notifyCalls >= 120 && frames <= max(1, notifyCalls ~/ 4)) {
      reasons.add('many repaint requests per frame');
      score = max(score, notifyCalls);
    }
    return score;
  }

  int _backupScore({
    required int fetchMs,
    required int snapshotMs,
    required int totalMs,
    required List<String> reasons,
  }) {
    var score = 0;
    if (fetchMs >= 16) {
      reasons.add('slow backup fetch');
      score = max(score, fetchMs);
    }
    if (snapshotMs >= 16) {
      reasons.add('slow backup snapshot');
      score = max(score, snapshotMs);
    }
    if (totalMs >= 32) {
      reasons.add('slow backup total');
      score = max(score, totalMs);
    }
    return score;
  }

  void _record(OptimizationLogEntry entry) {
    _entries.insert(0, entry);
    _prune();
    notifyListeners();
    unawaited(_save());
  }

  void _prune() {
    final oldestAllowed = DateTime.now().subtract(_retention);
    _entries.removeWhere((entry) => entry.occurredAt.isBefore(oldestAllowed));
    _entries.sort((a, b) {
      final scoreCompare = b.score.compareTo(a.score);
      if (scoreCompare != 0) {
        return scoreCompare;
      }
      return b.occurredAt.compareTo(a.occurredAt);
    });
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
      debugPrint('OptimizationLog._save failed: $e');
    }
  }
}

class OptimizationLogEntry {
  const OptimizationLogEntry({
    required this.occurredAt,
    required this.category,
    required this.label,
    required this.score,
    required this.reasons,
    required this.details,
  });

  final DateTime occurredAt;
  final String category;
  final String label;
  final int score;
  final List<String> reasons;
  final Map<String, Object?> details;

  static OptimizationLogEntry? fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      return null;
    }
    final occurredAtText = value['occurredAt'];
    final category = value['category'];
    final label = value['label'];
    final score = value['score'];
    final reasons = value['reasons'];
    final details = value['details'];
    if (occurredAtText is! String ||
        category is! String ||
        label is! String ||
        score is! int ||
        reasons is! List<dynamic> ||
        details is! Map<String, dynamic>) {
      return null;
    }
    final occurredAt = DateTime.tryParse(occurredAtText);
    if (occurredAt == null) {
      return null;
    }
    return OptimizationLogEntry(
      occurredAt: occurredAt,
      category: category,
      label: label,
      score: score,
      reasons: reasons.whereType<String>().toList(),
      details: Map<String, Object?>.from(details),
    );
  }

  Map<String, Object?> toJson() {
    return {
      'occurredAt': occurredAt.toIso8601String(),
      'category': category,
      'label': label,
      'score': score,
      'reasons': reasons,
      'details': details,
    };
  }

  String format() {
    final reasonsText = reasons.join(', ');
    final detailsText = details.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join(' ');
    final buffer = StringBuffer();
    buffer.writeln(
      '[${occurredAt.toIso8601String()}] $category score=$score $label',
    );
    buffer.writeln('reasons=$reasonsText');
    buffer.write(detailsText);
    return buffer.toString();
  }
}
