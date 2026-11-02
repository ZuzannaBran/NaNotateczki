import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

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

enum StudyEntryKind { session, event }

enum StudyRepeat { none, daily, weekly, monthly, yearly }

enum StudyStatus { planned, running, paused, review, completed }

enum StudyPhase { focus, breakTime }

class StudySession {
  StudySession({
    required this.id,
    required this.title,
    required this.scheduledAt,
    required this.minutes,
    this.kind = StudyEntryKind.session,
    this.description = '',
    this.technique = StudyTechnique.custom,
    int? focusBlocks,
    this.colorValue,
    this.status = StudyStatus.planned,
    this.phase = StudyPhase.focus,
    this.round = 1,
    this.remainingSeconds = 0,
    this.deadline,
    this.startedAt,
    this.finishedAt,
    this.productivity,
    this.allDay = false,
    this.eventEndDate,
    this.repeat = StudyRepeat.none,
    this.repeatEvery = 1,
    this.seriesId,
    DateTime? modifiedAt,
  }) : modifiedAt = modifiedAt ??
           DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
       focusBlocks = (focusBlocks ?? technique.rounds).clamp(1, 12).toInt();

  final String id;
  final StudyEntryKind kind;
  DateTime modifiedAt;
  String title;
  String description;
  DateTime scheduledAt;
  int minutes;
  StudyTechnique technique;
  int focusBlocks;
  int? colorValue;
  StudyStatus status;
  StudyPhase phase;
  int round;
  int remainingSeconds;
  DateTime? deadline;
  DateTime? startedAt;
  DateTime? finishedAt;
  int? productivity;
  bool allDay;
  DateTime? eventEndDate;
  StudyRepeat repeat;
  int repeatEvery;
  final String? seriesId;

  int get totalFocusMinutes => technique == StudyTechnique.custom
      ? minutes
      : technique.focusMinutes * focusBlocks;

  int get scheduledDurationMinutes {
    if (kind == StudyEntryKind.event) {
      final last = eventEndDate ?? scheduledAt;
      final days = DateTime.utc(last.year, last.month, last.day)
          .difference(
            DateTime.utc(scheduledAt.year, scheduledAt.month, scheduledAt.day),
          )
          .inDays;
      if (allDay) {
        return (days + 1) * 1440;
      }
      if (eventEndDate != null) {
        return days * 1440 + minutes;
      }
      return minutes;
    }
    return technique == StudyTechnique.custom
        ? minutes
        : totalFocusMinutes + (focusBlocks - 1) * technique.breakMinutes;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'modifiedAt': modifiedAt.toUtc().toIso8601String(),
    'kind': kind.name,
    'title': title,
    'description': description,
    'scheduledAt': kind == StudyEntryKind.event && allDay
        ? scheduledAt.toIso8601String()
        : scheduledAt.toUtc().toIso8601String(),
    'minutes': minutes,
    'technique': technique.name,
    'focusBlocks': focusBlocks,
    'colorValue': colorValue,
    'status': status.name,
    'phase': phase.name,
    'round': round,
    'remainingSeconds': remainingSeconds,
    'deadline': deadline?.toUtc().toIso8601String(),
    'startedAt': startedAt?.toUtc().toIso8601String(),
    'finishedAt': finishedAt?.toUtc().toIso8601String(),
    'productivity': productivity,
    'allDay': kind == StudyEntryKind.event && allDay,
    'eventEndDate': eventEndDate?.toIso8601String(),
    'repeat': repeat.name,
    'repeatEvery': repeatEvery,
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
    final technique = parseEnum(
      StudyTechnique.values,
      json['technique'],
      StudyTechnique.custom,
    );
    return StudySession(
      id: json['id'] as String,
      modifiedAt: date(json['modifiedAt'])?.toUtc(),
      kind: parseEnum(
        StudyEntryKind.values,
        json['kind'],
        StudyEntryKind.session,
      ),
      title: (json['title'] as String?) ?? 'Study session',
      description: (json['description'] as String?) ?? '',
      scheduledAt: planned,
      minutes: ((json['minutes'] as num?)?.toInt() ?? 30)
          .clamp(1, 1440)
          .toInt(),
      technique: technique,
      focusBlocks: (json['focusBlocks'] as num?)?.toInt() ?? technique.rounds,
      colorValue: json['colorValue'] is int
          ? (json['colorValue'] as int) | 0xFF000000
          : null,
      status: parseEnum(
        StudyStatus.values,
        json['status'],
        StudyStatus.planned,
      ),
      phase: parseEnum(StudyPhase.values, json['phase'], StudyPhase.focus),
      round: ((json['round'] as num?)?.toInt() ?? 1).clamp(1, 100).toInt(),
      remainingSeconds: ((json['remainingSeconds'] as num?)?.toInt() ?? 0)
          .clamp(0, 86400)
          .toInt(),
      deadline: date(json['deadline']),
      startedAt: date(json['startedAt']),
      finishedAt: date(json['finishedAt']),
      productivity: json['productivity'] is num
          ? (json['productivity'] as num).toInt().clamp(1, 5).toInt()
          : null,
      allDay: json['allDay'] == true,
      eventEndDate: date(json['eventEndDate']),
      repeat: parseEnum(StudyRepeat.values, json['repeat'], StudyRepeat.none),
      repeatEvery: ((json['repeatEvery'] as num?)?.toInt() ?? 1)
          .clamp(1, 365)
          .toInt(),
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
  final Map<String, DateTime> _tombstones = {};
  final Map<String, String> _knownContents = {};
  Timer? _ticker;
  Future<void> _saveTail = Future<void>.value();
  final ValueNotifier<int> savedRevision = ValueNotifier<int>(0);
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
        .where(
          (s) =>
              s.kind == StudyEntryKind.session &&
              s.status == StudyStatus.planned &&
              !s.scheduledAt.isBefore(
                DateTime(_clock().year, _clock().month, _clock().day),
              ),
        )
        .toList();
    list.sort((a, b) => a.scheduledAt.compareTo(b.scheduledAt));
    return list;
  }

  StudySession originalFor(StudySession entry) =>
      _find(entry.seriesId ?? entry.id);

  /// Generates visible event occurrences without duplicating persisted data.
  List<StudySession> calendarEntries(DateTime first, DateTime last) {
    final start = DateTime(first.year, first.month, first.day);
    final end = DateTime(last.year, last.month, last.day + 1);
    final result = <StudySession>[];

    DateTime wallClock(DateTime time) =>
        DateTime.utc(time.year, time.month, time.day, time.hour, time.minute);

    bool visible(StudySession entry) {
      final began = wallClock(entry.scheduledAt);
      return began.isBefore(wallClock(end)) &&
          began
              .add(Duration(minutes: entry.scheduledDurationMinutes))
              .isAfter(wallClock(start));
    }

    for (final session in _sessions) {
      if (session.kind != StudyEntryKind.event ||
          session.repeat == StudyRepeat.none) {
        if (visible(session)) {
          result.add(session);
        }
        continue;
      }

      final startDay = DateTime.utc(
        session.scheduledAt.year,
        session.scheduledAt.month,
        session.scheduledAt.day,
      );
      final windowDay = DateTime.utc(start.year, start.month, start.day);
      final daysBefore = windowDay.difference(startDay).inDays;
      final spanDays = (session.scheduledDurationMinutes + 1439) ~/ 1440;
      final earlier = math.max(0, daysBefore - spanDays - 1);
      final every = session.repeatEvery.clamp(1, 365).toInt();
      final index = switch (session.repeat) {
        StudyRepeat.daily => earlier ~/ every,
        StudyRepeat.weekly => earlier ~/ (7 * every),
        StudyRepeat.monthly => math.max(
          0,
          ((start.year - session.scheduledAt.year) * 12 +
                  start.month -
                  session.scheduledAt.month -
                  2) ~/
              every,
        ),
        StudyRepeat.yearly => math.max(
          0,
          (start.year - session.scheduledAt.year - 2) ~/ every,
        ),
        StudyRepeat.none => 0,
      };
      for (var i = index; i < index + 128; i++) {
        final at = _repeatDate(session.scheduledAt, session.repeat, every, i);
        if (!at.isBefore(end)) {
          break;
        }
        final occurrence = i == 0
            ? session
            : StudySession(
                id: '${session.id}@${at.toIso8601String()}',
                seriesId: session.id,
                kind: StudyEntryKind.event,
                title: session.title,
                description: session.description,
                scheduledAt: at,
                minutes: session.minutes,
                allDay: session.allDay,
                eventEndDate: session.eventEndDate == null
                    ? null
                    : DateTime(
                        at.year,
                        at.month,
                        at.day +
                            DateTime.utc(
                              session.eventEndDate!.year,
                              session.eventEndDate!.month,
                              session.eventEndDate!.day,
                            ).difference(startDay).inDays,
                      ),
                repeat: session.repeat,
                repeatEvery: every,
                colorValue: session.colorValue,
              );
        if (visible(occurrence)) {
          result.add(occurrence);
        }
      }
    }
    return result;
  }

  static DateTime _repeatDate(
    DateTime date,
    StudyRepeat repeat,
    int every,
    int index,
  ) {
    if (repeat == StudyRepeat.daily || repeat == StudyRepeat.weekly) {
      return DateTime(
        date.year,
        date.month,
        date.day + index * every * (repeat == StudyRepeat.weekly ? 7 : 1),
        date.hour,
        date.minute,
      );
    }
    final year = repeat == StudyRepeat.yearly
        ? date.year + every * index
        : date.year;
    final month = repeat == StudyRepeat.monthly
        ? date.month + every * index
        : date.month;
    final first = DateTime(year, month);
    final lastDay = DateTime(first.year, first.month + 1, 0).day;
    return DateTime(
      first.year,
      first.month,
      math.min(lastDay, date.day),
      date.hour,
      date.minute,
    );
  }

  List<StudySession> get history =>
      _sessions.where((s) => s.status == StudyStatus.completed).toList()..sort(
        (a, b) => (b.finishedAt ?? b.scheduledAt).compareTo(
          a.finishedAt ?? a.scheduledAt,
        ),
      );

  List<StudySession> get pendingReviews =>
      _sessions.where((s) => s.status == StudyStatus.review).toList();

  int secondsLeft(StudySession session) {
    if (session.status != StudyStatus.running || session.deadline == null) {
      return session.remainingSeconds;
    }
    return ((session.deadline!.millisecondsSinceEpoch -
                _clock().millisecondsSinceEpoch) /
            1000)
        .ceil()
        .clamp(0, 86400)
        .toInt();
  }

  Future<void> load() async {
    if (_disposed) {
      return;
    }
    _ticker?.cancel();
    _ticker = null;
    try {
      final value = await _read(storageKey);
      if (_disposed) {
        return;
      }
      var recoveredReviews = false;
      _tombstones.clear();
      _knownContents.clear();
      if (value != null) {
        final decoded = jsonDecode(value) as Map<String, dynamic>;
        final entries = decoded['sessions'] as List<dynamic>;
        final deleted = decoded['tombstones'];
        if (deleted is Map<String, dynamic>) {
          for (final item in deleted.entries) {
            final time = item.value is String
                ? DateTime.tryParse(item.value as String)?.toUtc()
                : null;
            if (time != null) {
              _tombstones[item.key] = time;
            }
          }
        }
        _sessions
          ..clear()
          ..addAll(
            entries.map(
              (entry) => StudySession.fromJson(entry as Map<String, dynamic>),
            ),
          );
        for (final entry in _sessions) {
          _knownContents[entry.id] = _contentSignature(entry);
        }
        final running = _sessions
            .where(
              (s) =>
                  s.status == StudyStatus.running ||
                  s.status == StudyStatus.paused,
            )
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
      if (_disposed) {
        return;
      }
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
    int? focusBlocks,
    int? colorValue,
    StudyEntryKind kind = StudyEntryKind.session,
    bool allDay = false,
    DateTime? eventEndDate,
    StudyRepeat repeat = StudyRepeat.none,
    int repeatEvery = 1,
  }) {
    final session = StudySession(
      id: const Uuid().v4(),
      kind: kind,
      title: title.trim().isEmpty
          ? (kind == StudyEntryKind.event ? 'Event' : 'Study session')
          : title.trim(),
      description: description.trim(),
      scheduledAt: scheduledAt,
      minutes: minutes.clamp(1, 1440).toInt(),
      technique: technique,
      focusBlocks: focusBlocks,
      colorValue: colorValue,
      allDay: kind == StudyEntryKind.event && allDay,
      eventEndDate: kind == StudyEntryKind.event ? eventEndDate : null,
      repeat: kind == StudyEntryKind.event ? repeat : StudyRepeat.none,
      repeatEvery: repeatEvery.clamp(1, 365).toInt(),
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
    int? focusBlocks,
    int? colorValue,
    bool updateColor = false,
    bool allDay = false,
    DateTime? eventEndDate,
    StudyRepeat repeat = StudyRepeat.none,
    int repeatEvery = 1,
  }) {
    final session = _find(id);
    if (session.status != StudyStatus.planned) {
      return;
    }
    session.title = title.trim().isEmpty
        ? (session.kind == StudyEntryKind.event ? 'Event' : 'Study session')
        : title.trim();
    session.description = description.trim();
    session.scheduledAt = scheduledAt;
    session.minutes = minutes.clamp(1, 1440).toInt();
    session.technique = technique;
    if (session.kind == StudyEntryKind.event) {
      session.allDay = allDay;
      session.eventEndDate = eventEndDate;
      session.repeat = repeat;
      session.repeatEvery = repeatEvery.clamp(1, 365).toInt();
    }
    session.focusBlocks = (focusBlocks ?? technique.rounds)
        .clamp(1, 12)
        .toInt();
    if (updateColor) {
      session.colorValue = colorValue;
    }
    _changed();
  }

  void move(String id, DateTime date) {
    final session = _find(id);
    if (session.status != StudyStatus.planned) {
      return;
    }
    final difference = DateTime.utc(date.year, date.month, date.day)
        .difference(
          DateTime.utc(
            session.scheduledAt.year,
            session.scheduledAt.month,
            session.scheduledAt.day,
          ),
        )
        .inDays;
    session.scheduledAt = DateTime(
      date.year,
      date.month,
      date.day,
      session.scheduledAt.hour,
      session.scheduledAt.minute,
    );
    final last = session.eventEndDate;
    if (last != null) {
      session.eventEndDate = DateTime(
        last.year,
        last.month,
        last.day + difference,
      );
    }
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
    if (session.kind == StudyEntryKind.event) {
      return false;
    }
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
    session.remainingSeconds =
        (session.technique == StudyTechnique.custom
            ? session.minutes
            : session.technique.focusMinutes) *
        60;
    session.deadline = _clock().add(
      Duration(seconds: session.remainingSeconds),
    );
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
    session.deadline = _clock().add(
      Duration(seconds: session.remainingSeconds),
    );
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
        !_clock().isBefore(current.deadline!) &&
        transitions++ < 100) {
      final boundary = current.deadline!;
      if (current.phase == StudyPhase.focus &&
          current.round < current.focusBlocks) {
        current.phase = StudyPhase.breakTime;
        current.remainingSeconds = current.technique.breakMinutes * 60;
        current.deadline = boundary.add(
          Duration(seconds: current.remainingSeconds),
        );
        _announce('Focus complete. Take a break.');
      } else if (current.phase == StudyPhase.breakTime) {
        current.phase = StudyPhase.focus;
        current.round++;
        current.remainingSeconds = current.technique.focusMinutes * 60;
        current.deadline = boundary.add(
          Duration(seconds: current.remainingSeconds),
        );
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

  static String _contentSignature(StudySession entry) {
    final value = Map<String, dynamic>.from(entry.toJson());
    value.remove('modifiedAt');
    return jsonEncode(value);
  }

  DateTime _nextModification(DateTime? previous) {
    final now = _clock().toUtc();
    if (previous != null && !now.isAfter(previous)) {
      return previous.add(const Duration(microseconds: 1));
    }
    return now;
  }

  void _changed() {
    final next = <String, String>{};
    for (final entry in _sessions) {
      final signature = _contentSignature(entry);
      if (_knownContents[entry.id] != signature) {
        entry.modifiedAt = _nextModification(entry.modifiedAt);
      }
      next[entry.id] = signature;
      _tombstones.remove(entry.id);
    }
    for (final id in _knownContents.keys) {
      if (!next.containsKey(id)) {
        _tombstones[id] = _nextModification(_tombstones[id]);
      }
    }
    _knownContents
      ..clear()
      ..addAll(next);
    _persist();
  }

  /// Per-entry state includes deletion tombstones for offline reconciliation.
  Map<String, Map<String, dynamic>> get syncRecords {
    final records = <String, Map<String, dynamic>>{};
    for (final entry in _sessions) {
      records[entry.id] = {
        'id': entry.id,
        'modifiedAt': entry.modifiedAt.toUtc().toIso8601String(),
        'deleted': false,
        'entry': entry.toJson(),
      };
    }
    for (final item in _tombstones.entries) {
      records[item.key] = {
        'id': item.key,
        'modifiedAt': item.value.toUtc().toIso8601String(),
        'deleted': true,
        'entry': null,
      };
    }
    return records;
  }

  /// Accepts newer records and server-authoritative timestamp ties.
  void applyRemoteRecords(Iterable<Map<String, dynamic>> incoming) {
    if (!isLoaded || _disposed) {
      return;
    }
    var changed = false;
    final local = syncRecords;
    for (final record in incoming) {
      final id = record['id'];
      final rawTime = record['modifiedAt'];
      final deleted = record['deleted'];
      if (id is! String ||
          rawTime is! String ||
          deleted is! bool ||
          id.isEmpty) {
        throw const FormatException('Invalid remote planner record');
      }
      final time = DateTime.tryParse(rawTime)?.toUtc();
      if (time == null) {
        throw const FormatException('Invalid remote planner timestamp');
      }
      final existing = local[id];
      final oldTime = existing == null
          ? null
          : DateTime.tryParse(existing['modifiedAt'] as String)?.toUtc();
      if (oldTime != null && time.isBefore(oldTime)) {
        continue;
      }
      final content = record['entry'];
      if (!deleted &&
          (content is! Map<String, dynamic> || content['id'] != id)) {
        throw const FormatException('Invalid remote planner entry');
      }
      final normalized = deleted
          ? null
          : StudySession.fromJson({
              ...content as Map<String, dynamic>,
              'modifiedAt': time.toIso8601String(),
            }).toJson();
      if (oldTime != null &&
          time.isAtSameMomentAs(oldTime) &&
          existing!['deleted'] == deleted &&
          jsonEncode(existing['entry']) == jsonEncode(normalized)) {
        continue;
      }
      _sessions.removeWhere((entry) => entry.id == id);
      if (deleted) {
        _tombstones[id] = time;
      } else {
        final value = Map<String, dynamic>.from(
          content as Map<String, dynamic>,
        );
        value['modifiedAt'] = time.toIso8601String();
        _sessions.add(StudySession.fromJson(value));
        _tombstones.remove(id);
      }
      changed = true;
    }
    if (changed) {
      _knownContents
        ..clear()
        ..addEntries(_sessions.map(
          (entry) => MapEntry(entry.id, _contentSignature(entry)),
        ));
      _persist();
    }
  }

  void _persist() {
    notifyListeners();
    final snapshot = jsonEncode({
      'version': 2,
      'sessions': _sessions.map((s) => s.toJson()).toList(),
      'tombstones': {
        for (final item in _tombstones.entries)
          item.key: item.value.toUtc().toIso8601String(),
      },
    });
    _pendingWrites++;
    _saveTail = _saveTail
        .then((_) async {
          await _write(storageKey, snapshot);
          if (!_disposed) {
            savedRevision.value++;
          }
        })
        .catchError((Object e) {
          error = 'Could not save study history: $e';
          if (!_disposed) {
            notifyListeners();
          }
        })
        .whenComplete(() => _pendingWrites--);
  }

  Future<void> flush() => _saveTail;

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    AppSaveCoordinator.instance.unregister(this);
    savedRevision.dispose();
    super.dispose();
  }
}
