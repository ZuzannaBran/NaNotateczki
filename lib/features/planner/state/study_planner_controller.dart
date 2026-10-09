import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../../core/storage/app_save_coordinator.dart';
import '../../../core/storage/text_storage.dart';

enum StudyTechnique { custom, pomodoro, focus50, deep90 }

extension StudyTechniqueDetails on StudyTechnique {
  String get label => switch (this) {
    StudyTechnique.custom => 'Custom timer',
    StudyTechnique.pomodoro => 'Pomodoro · 25 / 5',
    StudyTechnique.focus50 => 'Focus · 50 / 10',
    StudyTechnique.deep90 => 'Deep work · 90 / 20',
  };

  int get focusMinutes => switch (this) {
    StudyTechnique.custom => 30,
    StudyTechnique.pomodoro => 25,
    StudyTechnique.focus50 => 50,
    StudyTechnique.deep90 => 90,
  };

  int get breakMinutes => switch (this) {
    StudyTechnique.custom => 0,
    StudyTechnique.pomodoro => 5,
    StudyTechnique.focus50 => 10,
    StudyTechnique.deep90 => 20,
  };

  int get rounds => switch (this) {
    StudyTechnique.custom => 1,
    StudyTechnique.pomodoro => 4,
    StudyTechnique.focus50 => 2,
    StudyTechnique.deep90 => 1,
  };
}

enum StudyStatus { planned, running, paused, review, completed }

enum StudyPhase { focus, breakTime }

class StudySession {
  StudySession({
    required this.id,
    required this.title,
    required this.scheduledAt,
    required this.minutes,
    this.description = '',
    this.technique = StudyTechnique.custom,
    this.status = StudyStatus.planned,
    this.phase = StudyPhase.focus,
    this.round = 1,
    this.remainingSeconds = 0,
    this.deadline,
    this.startedAt,
    this.finishedAt,
    this.productivity,
  });

  final String id;
  String title;
  String description;
  DateTime scheduledAt;
  int minutes;
  StudyTechnique technique;
  StudyStatus status;
  StudyPhase phase;
  int round;
  int remainingSeconds;
  DateTime? deadline;
  DateTime? startedAt;
  DateTime? finishedAt;
  int? productivity;

  int get totalFocusMinutes => technique == StudyTechnique.custom
      ? minutes
      : technique.focusMinutes * technique.rounds;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'description': description,
    'scheduledAt': scheduledAt.toIso8601String(),
    'minutes': minutes,
    'technique': technique.name,
    'status': status.name,
    'phase': phase.name,
    'round': round,
    'remainingSeconds': remainingSeconds,
    'deadline': deadline?.toIso8601String(),
    'startedAt': startedAt?.toIso8601String(),
    'finishedAt': finishedAt?.toIso8601String(),
    'productivity': productivity,
  };

  static StudySession fromJson(Map<String, dynamic> json) {
    T parseEnum<T extends Enum>(List<T> values, Object? name, T fallback) {
      for (final value in values) {
        if (value.name == name) {
          return value;
        }
      }
      return fallback;
    }

    DateTime? date(Object? input) =>
        input is String ? DateTime.tryParse(input)?.toLocal() : null;
    final planned = date(json['scheduledAt']);
    if (json['id'] is! String || planned == null) {
      throw const FormatException('Invalid study session');
    }
    return StudySession(
      id: json['id'] as String,
      title: (json['title'] as String?) ?? 'Study session',
      description: (json['description'] as String?) ?? '',
      scheduledAt: planned,
      minutes: ((json['minutes'] as num?)?.toInt() ?? 30)
          .clamp(1, 1440).toInt(),
      technique: parseEnum(StudyTechnique.values, json['technique'],
          StudyTechnique.custom),
      status: parseEnum(StudyStatus.values, json['status'],
          StudyStatus.planned),
      phase: parseEnum(StudyPhase.values, json['phase'], StudyPhase.focus),
      round: ((json['round'] as num?)?.toInt() ?? 1)
          .clamp(1, 100).toInt(),
      remainingSeconds:
          ((json['remainingSeconds'] as num?)?.toInt() ?? 0)
              .clamp(0, 86400).toInt(),
      deadline: date(json['deadline']),
      startedAt: date(json['startedAt']),
      finishedAt: date(json['finishedAt']),
      productivity: json['productivity'] is num
          ? (json['productivity'] as num).toInt().clamp(1, 5).toInt()
          : null,
    );
  }
}

typedef StudyRead = Future<String?> Function(String key);
typedef StudyWrite = Future<void> Function(String key, String value);

class StudyPlannerController extends ChangeNotifier {
  StudyPlannerController({
    StudyRead read = readStoredText,
    StudyWrite write = writeStoredText,
    DateTime Function()? clock,
    bool autoTick = true,
  }) : _read = read,
       _write = write,
       _clock = clock ?? DateTime.now,
       _autoTick = autoTick {
    AppSaveCoordinator.instance.register(
      this,
      hasPendingWork: () => _pendingWrites > 0,
      flush: flush,
    );
  }

  static const storageKey = 'study_planner.json';
  final StudyRead _read;
  final StudyWrite _write;
  final DateTime Function() _clock;
  final bool _autoTick;
  final List<StudySession> _sessions = [];
  Timer? _ticker;
  Future<void> _saveTail = Future<void>.value();
  int _pendingWrites = 0;
  bool _disposed = false;
  bool isLoaded = false;
  String? error;
  int noticeRevision = 0;
  String? notice;
  bool noticeRequiresReviewPrompt = false;

  List<StudySession> get sessions => List.unmodifiable(_sessions);
  StudySession? get active {
    for (final session in _sessions) {
      if (session.status == StudyStatus.running ||
          session.status == StudyStatus.paused) {
        return session;
      }
    }
    return null;
  }

  List<StudySession> get upcoming {
    final list = _sessions
        .where((s) => s.status == StudyStatus.planned &&
            !s.scheduledAt.isBefore(DateTime(
              _clock().year, _clock().month, _clock().day)))
        .toList();
    list.sort((a, b) => a.scheduledAt.compareTo(b.scheduledAt));
    return list;
  }

  List<StudySession> get history =>
      _sessions.where((s) => s.status == StudyStatus.completed).toList()
        ..sort((a, b) => (b.finishedAt ?? b.scheduledAt)
            .compareTo(a.finishedAt ?? a.scheduledAt));

  List<StudySession> get pendingReviews =>
      _sessions.where((s) => s.status == StudyStatus.review).toList();

  int secondsLeft(StudySession session) {
    if (session.status != StudyStatus.running ||
        session.deadline == null) {
      return session.remainingSeconds;
    }
    return ((session.deadline!.millisecondsSinceEpoch -
                _clock().millisecondsSinceEpoch) /
            1000)
        .ceil()
        .clamp(0, 86400).toInt();
  }

  Future<void> load() async {
    try {
      final value = await _read(storageKey);
      var recoveredReviews = false;
      if (value != null) {
        final decoded = jsonDecode(value) as Map<String, dynamic>;
        final entries = decoded['sessions'] as List<dynamic>;
        _sessions
          ..clear()
          ..addAll(entries.map((entry) =>
              StudySession.fromJson(entry as Map<String, dynamic>)));
        final running = _sessions
            .where((s) => s.status == StudyStatus.running ||
                s.status == StudyStatus.paused)
            .toList();
        for (final duplicate in running.skip(1)) {
          duplicate.status = StudyStatus.completed;
          duplicate.finishedAt = _clock();
          duplicate.deadline = null;
          recoveredReviews = true;
        }
        for (final session in _sessions) {
          if (session.status == StudyStatus.review) {
            session.status = StudyStatus.completed;
            recoveredReviews = true;
          }
        }
      }
      if (recoveredReviews) {
        _changed();
      }
    } catch (failure) {
      error = 'Study history could not be loaded: $failure';
    }
    isLoaded = true;
    if (_autoTick) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => tick());
    }
    tick();
    final interruptedReviews = _sessions.where(
      (session) => session.status == StudyStatus.review,
    );
    if (interruptedReviews.isNotEmpty) {
      for (final session in interruptedReviews) {
        session.status = StudyStatus.completed;
      }
      _changed();
    }
    notifyListeners();
  }

  StudySession create({
    required String title,
    required DateTime scheduledAt,
    String description = '',
    int minutes = 30,
    StudyTechnique technique = StudyTechnique.custom,
  }) {
    final session = StudySession(
      id: const Uuid().v4(),
      title: title.trim().isEmpty ? 'Study session' : title.trim(),
      description: description.trim(),
      scheduledAt: scheduledAt,
      minutes: minutes.clamp(1, 1440).toInt(),
      technique: technique,
    );
    if (!isLoaded || error != null) {
      throw StateError('Study planner storage is not available.');
    }
    _sessions.add(session);
    _changed();
    return session;
  }

  void edit(
    String id, {
    required String title,
    required String description,
    required DateTime scheduledAt,
    required int minutes,
    required StudyTechnique technique,
  }) {
    final session = _find(id);
    if (session.status != StudyStatus.planned) {
      return;
    }
    session.title = title.trim().isEmpty ? 'Study session' : title.trim();
    session.description = description.trim();
    session.scheduledAt = scheduledAt;
    session.minutes = minutes.clamp(1, 1440).toInt();
    session.technique = technique;
    _changed();
  }

  void move(String id, DateTime date) {
    final session = _find(id);
    if (session.status != StudyStatus.planned) {
      return;
    }
    session.scheduledAt = DateTime(date.year, date.month, date.day,
        session.scheduledAt.hour, session.scheduledAt.minute);
    _changed();
  }

  void delete(String id) {
    final session = _find(id);
    if (session.status == StudyStatus.running ||
        session.status == StudyStatus.paused) {
      throw StateError('Stop the active session first.');
    }
    _sessions.remove(session);
    _changed();
  }

  bool start(String id) {
    tick();
    final existing = active;
    if (existing != null && existing.id != id) {
      return false;
    }
    final session = _find(id);
    if (session.status == StudyStatus.paused) {
      return resume();
    }
    if (session.status != StudyStatus.planned) {
      return false;
    }
    session.status = StudyStatus.running;
    session.phase = StudyPhase.focus;
    session.round = 1;
    session.startedAt = _clock();
    session.remainingSeconds = (session.technique == StudyTechnique.custom
        ? session.minutes
        : session.technique.focusMinutes) * 60;
    session.deadline = _clock().add(Duration(seconds: session.remainingSeconds));
    _changed();
    return true;
  }

  bool pause() {
    tick();
    final session = active;
    if (session == null || session.status != StudyStatus.running) {
      return false;
    }
    session.remainingSeconds = secondsLeft(session);
    session.deadline = null;
    session.status = StudyStatus.paused;
    _changed();
    return true;
  }

  bool resume() {
    final session = active;
    if (session == null || session.status != StudyStatus.paused) {
      return false;
    }
    session.deadline = _clock().add(Duration(seconds: session.remainingSeconds));
    session.status = StudyStatus.running;
    _changed();
    return true;
  }

  bool stop() {
    tick();
    final session = active;
    if (session == null) {
      return false;
    }
    session.status = StudyStatus.review;
    session.finishedAt = _clock();
    session.deadline = null;
    _changed();
    _announce("Great job! Time's up.");
    return true;
  }

  void rate(String id, int score) {
    if (score < 1 || score > 5) {
      throw RangeError.range(score, 1, 5);
    }
    final session = _find(id);
    if (session.status != StudyStatus.review) {
      return;
    }
    session.productivity = score;
    session.status = StudyStatus.completed;
    _changed();
  }

  void skipRating(String id) {
    final session = _find(id);
    if (session.status != StudyStatus.review) {
      return;
    }
    session.status = StudyStatus.completed;
    _changed();
  }

  void tick() {
    final current = active;
    if (current == null || current.status != StudyStatus.running) {
      return;
    }
    var changed = false;
    var transitions = 0;
    while (current.deadline != null &&
        !_clock().isBefore(current.deadline!) && transitions++ < 100) {
      final boundary = current.deadline!;
      if (current.phase == StudyPhase.focus &&
          current.round < current.technique.rounds) {
        current.phase = StudyPhase.breakTime;
        current.remainingSeconds = current.technique.breakMinutes * 60;
        current.deadline =
            boundary.add(Duration(seconds: current.remainingSeconds));
        _announce('Focus complete. Take a break.');
      } else if (current.phase == StudyPhase.breakTime) {
        current.phase = StudyPhase.focus;
        current.round++;
        current.remainingSeconds = current.technique.focusMinutes * 60;
        current.deadline =
            boundary.add(Duration(seconds: current.remainingSeconds));
        _announce('Break finished. Ready to focus?');
      } else {
        current.status = StudyStatus.review;
        current.finishedAt = boundary;
        current.remainingSeconds = 0;
        current.deadline = null;
        _announce("Great job! Time's up.", promptReview: true);
      }
      changed = true;
    }
    if (changed) {
      _changed();
    } else {
      notifyListeners();
    }
  }

  void _announce(String message, {bool promptReview = false}) {
    noticeRequiresReviewPrompt = promptReview;
    notice = message;
    noticeRevision++;
    notifyListeners();
  }

  StudySession _find(String id) =>
      _sessions.firstWhere((session) => session.id == id);

  void _changed() {
    notifyListeners();
    final snapshot = jsonEncode({
      'version': 1,
      'sessions': _sessions.map((s) => s.toJson()).toList(),
    });
    _pendingWrites++;
    _saveTail = _saveTail.then((_) => _write(storageKey, snapshot))
        .catchError((Object e) {
      error = 'Could not save study history: $e';
      if (!_disposed) {
        notifyListeners();
      }
    }).whenComplete(() => _pendingWrites--);
  }

  Future<void> flush() => _saveTail;

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    AppSaveCoordinator.instance.unregister(this);
    super.dispose();
  }
}
