import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/study_planner_controller.dart';
import 'study_timer_widgets.dart';

enum CalendarMode { today, week, month }

class PlannerScreen extends StatefulWidget {
  const PlannerScreen({super.key});

  @override
  State<PlannerScreen> createState() => _PlannerScreenState();
}

class _PlannerScreenState extends State<PlannerScreen> {
  CalendarMode _mode = CalendarMode.week;
  DateTime _anchor = DateUtils.dateOnly(DateTime.now());
  bool _history = false;

  DateTime _monday(DateTime date) =>
      DateTime(date.year, date.month, date.day - (date.weekday - 1));

  DateTime _firstDay() => switch (_mode) {
    CalendarMode.today => DateUtils.dateOnly(_anchor),
    CalendarMode.week => _monday(_anchor),
    CalendarMode.month =>
      _monday(DateTime(_anchor.year, _anchor.month, 1)),
  };

  List<DateTime> _visibleDays() {
    final first = _firstDay();
    final count = switch (_mode) {
      CalendarMode.today => 1,
      CalendarMode.week => 7,
      CalendarMode.month => 42,
    };
    return List.generate(count, (i) =>
        DateTime(first.year, first.month, first.day + i));
  }

  void _navigate(int direction) {
    setState(() {
      _anchor = switch (_mode) {
        CalendarMode.today => DateTime(
            _anchor.year, _anchor.month, _anchor.day + direction),
        CalendarMode.week => DateTime(
            _anchor.year, _anchor.month, _anchor.day + 7 * direction),
        CalendarMode.month =>
          DateTime(_anchor.year, _anchor.month + direction,
              _anchor.day.clamp(1, 28)),
      };
    });
  }

  String _heading() {
    if (_mode == CalendarMode.month) {
      return '${_monthName(_anchor.month)} ${_anchor.year}';
    }
    final dates = _visibleDays();
    if (_mode == CalendarMode.today) {
      return '${dates.first.day} ${_monthName(dates.first.month)} '
          '${dates.first.year}';
    }
    return '${dates.first.day} ${_monthName(dates.first.month)} – '
        '${dates.last.day} ${_monthName(dates.last.month)}';
  }

  String _monthName(int month) => const [
    'January', 'February', 'March', 'April', 'May', 'June', 'July',
    'August', 'September', 'October', 'November', 'December',
  ][month - 1];

  bool _isSameDate(DateTime a, DateTime b) => a.year == b.year &&
      a.month == b.month && a.day == b.day;

  Future<void> _sessionOptions(StudySession session) async {
    final planner = context.read<StudyPlannerController>();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(session.title),
        content: SizedBox(
          width: 340,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${session.scheduledAt.day} '
                '${_monthName(session.scheduledAt.month)} '
                '${studyClock(session.scheduledAt)}',
              ),
              const SizedBox(height: 6),
              Text(session.technique.label),
              if (session.description.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(session.description),
              ],
              if (session.productivity != null) ...[
                const SizedBox(height: 10),
                Text('Productivity: ${session.productivity}/5'),
              ],
              if (session.status == StudyStatus.review) ...[
                const SizedBox(height: 10),
                const Text('Review needed before adding to history.'),
              ],
            ],
          ),
        ),
        actions: [
          if (session.status == StudyStatus.planned)
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                showStudySessionEditor(context, session: session);
              },
              child: const Text('Edit'),
            ),
          if (session.status == StudyStatus.planned)
            TextButton(
              onPressed: planner.active == null
                  ? () {
                      planner.start(session.id);
                      Navigator.pop(dialogContext);
                    }
                  : null,
              child: const Text('Start'),
            ),
          if (session.status == StudyStatus.review)
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                showStudyRating(context, session);
              },
              child: const Text('Rate'),
            ),
          if (session.status == StudyStatus.planned ||
              session.status == StudyStatus.completed)
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                _confirmDelete(session);
              },
              child: const Text('Delete'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(StudySession session) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this session?'),
        content: Text('Delete "${session.title}" and its history?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      context.read<StudyPlannerController>().delete(session.id);
    }
  }

  Widget _sessionTile(StudySession session, {bool compact = false}) {
    final scheme = Theme.of(context).colorScheme;
    final planner = context.read<StudyPlannerController>();
    final done = session.status == StudyStatus.completed;
    final reviewing = session.status == StudyStatus.review;
    final color = done
        ? scheme.secondaryContainer
        : reviewing
        ? scheme.tertiaryContainer
        : scheme.surfaceContainerHigh;
    final tile = Material(
      color: color,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _sessionOptions(session),
        child: Padding(
          padding: EdgeInsets.all(compact ? 6 : 9),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${studyClock(session.scheduledAt)}  ${session.title}',
                maxLines: compact ? 2 : 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: compact ? 11 : 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (!compact) ...[
                const SizedBox(height: 3),
                Text(
                  done
                      ? 'Done · ${session.productivity}/5'
                      : reviewing
                      ? 'Rate productivity'
                      : session.status == StudyStatus.planned &&
                              session.scheduledAt.isBefore(DateTime.now())
                          ? 'Not started'
                          : session.technique.label,
                  style: TextStyle(
                    fontSize: 11, color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    if (session.status != StudyStatus.planned) {
      return tile;
    }
    return LongPressDraggable<StudySession>(
      data: session,
      feedback: Material(
        elevation: 5,
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 190),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(session.title),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: tile),
      child: tile,
      onDragEnd: (_) => planner.tick(),
    );
  }

  Widget _dayCell(DateTime day, List<StudySession> sessions,
      {bool compact = false}) {
    final scheme = Theme.of(context).colorScheme;
    final today = _isSameDate(day, DateTime.now());
    final inMonth = _mode != CalendarMode.month ||
        day.month == _anchor.month;
    final items = sessions
        .where((s) => _isSameDate(s.scheduledAt, day))
        .toList()
      ..sort((a, b) => a.scheduledAt.compareTo(b.scheduledAt));

    return DragTarget<StudySession>(
      onWillAcceptWithDetails: (details) =>
          details.data.status == StudyStatus.planned,
      onAcceptWithDetails: (details) {
        context.read<StudyPlannerController>().move(details.data.id, day);
      },
      builder: (context, candidates, rejected) {
        return Container(
          decoration: BoxDecoration(
            color: candidates.isNotEmpty
                ? scheme.primaryContainer
                : today
                    ? scheme.surfaceContainerLow
                    : scheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: today ? scheme.outline : scheme.outlineVariant,
            ),
          ),
          margin: const EdgeInsets.all(3),
          padding: EdgeInsets.all(compact ? 6 : 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${day.day} ${_mode == CalendarMode.today ? _monthName(day.month) : ''}',
                      style: TextStyle(
                        fontSize: compact ? 12 : 15,
                        fontWeight: today ? FontWeight.bold : FontWeight.w500,
                        color: inMonth ? scheme.onSurface :
                            scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (!compact)
                    IconButton(
                      tooltip: 'Plan on this day',
                      icon: const Icon(Icons.add_rounded, size: 18),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => showStudySessionEditor(
                        context,
                        scheduledAt: DateTime(
                          day.year, day.month, day.day, 9,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              if (compact || _mode == CalendarMode.week)
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.zero,
                    children: [
                      for (final item in items)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 5),
                          child: _sessionTile(item, compact: compact),
                        ),
                      if (items.isEmpty)
                        InkWell(
                          onTap: () => showStudySessionEditor(
                            context,
                            scheduledAt: DateTime(
                              day.year, day.month, day.day, 9,
                            ),
                          ),
                          child: const SizedBox(height: 45),
                        ),
                    ],
                  ),
                )
              else
                for (final item in items)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 5),
                    child: _sessionTile(item, compact: compact),
                  ),
            ],
          ),
        );
      },
    );
  }

  Widget _calendar(List<StudySession> sessions) {
    final days = _visibleDays();
    if (_mode == CalendarMode.today) {
      return ListView(
        padding: const EdgeInsets.all(18),
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 400),
            child: _dayCell(days.first, sessions),
          ),
        ],
      );
    }

    final minimumWidth = _mode == CalendarMode.week ? 1050.0 : 980.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth < minimumWidth
            ? minimumWidth
            : constraints.maxWidth;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: width,
            child: _mode == CalendarMode.week
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final day in days)
                        Expanded(child: _dayCell(day, sessions)),
                    ],
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                    child: Column(
                      children: [
                        const Row(
                          children: [
                            for (final name in [
                              'Mon', 'Tue', 'Wed', 'Thu',
                              'Fri', 'Sat', 'Sun'
                            ])
                              Expanded(
                                child: Padding(
                                  padding: EdgeInsets.all(8),
                                  child: Text(name,
                                    textAlign: TextAlign.center),
                                ),
                              ),
                          ],
                        ),
                        GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: days.length,
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 7,
                            childAspectRatio: 1.1,
                          ),
                          itemBuilder: (context, i) =>
                              _dayCell(days[i], sessions, compact: true),
                        ),
                      ],
                    ),
                  ),
          ),
        );
      },
    );
  }

  Widget _historyView(StudyPlannerController planner) {
    final list = [...planner.pendingReviews, ...planner.history];
    if (list.isEmpty) {
      return const Center(child: Text('No study history yet.'));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(22),
      itemCount: list.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final session = list[i];
        return ListTile(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          tileColor: Theme.of(context).colorScheme.surfaceContainerLow,
          leading: Icon(session.status == StudyStatus.review
              ? Icons.star_border_rounded : Icons.check_circle_outline),
          title: Text(session.title),
          subtitle: Text(
            '${session.scheduledAt.day}/${session.scheduledAt.month}/'
            '${session.scheduledAt.year} · '
            '${session.totalFocusMinutes} min · '
            '${session.productivity == null ? 'Rate now' : '${session.productivity}/5'}',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _sessionOptions(session),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final planner = context.watch<StudyPlannerController>();
    final colors = Theme.of(context).colorScheme;
    final narrow = MediaQuery.sizeOf(context).width < 760;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Study planner'),
        leading: IconButton(
          tooltip: 'Back to notes',
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            tooltip: _history ? 'Calendar' : 'Study history',
            onPressed: () => setState(() => _history = !_history),
            icon: Icon(_history
                ? Icons.calendar_month_outlined
                : Icons.history_rounded),
          ),
          if (narrow) ...[
            IconButton(
              tooltip: 'Smart session',
              onPressed: () => showStudySessionEditor(
                context,
                technique: StudyTechnique.pomodoro,
                startAfterSave: true,
              ),
              icon: const Icon(Icons.auto_awesome_outlined),
            ),
            IconButton(
              tooltip: 'New session',
              onPressed: () => showStudySessionEditor(context),
              icon: const Icon(Icons.add_rounded),
            ),
          ] else ...[
            TextButton.icon(
              onPressed: () => showStudySessionEditor(
                context,
                technique: StudyTechnique.pomodoro,
                startAfterSave: true,
              ),
              icon: const Icon(Icons.auto_awesome_outlined),
              label: const Text('Smart session'),
            ),
            FilledButton.tonalIcon(
              onPressed: () => showStudySessionEditor(context),
              icon: const Icon(Icons.add_rounded),
              label: const Text('New session'),
            ),
          ],
          const SizedBox(width: 16),
        ],
      ),
      body: Column(
        children: [
          if (planner.active != null || planner.pendingReviews.isNotEmpty)
            Material(
              color: colors.surfaceContainerLow,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 20, vertical: 7),
                child: Row(
                  children: [
                    if (planner.active != null) ...[
                      const Icon(Icons.timer_outlined),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          '${planner.active!.title} · '
                          '${studyDuration(planner.secondsLeft(planner.active!))}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: planner.active!.status == StudyStatus.running
                            ? planner.pause
                            : planner.resume,
                        icon: Icon(planner.active!.status == StudyStatus.running
                            ? Icons.pause : Icons.play_arrow),
                        label: Text(planner.active!.status == StudyStatus.running
                            ? 'Pause' : 'Resume'),
                      ),
                      IconButton(
                        tooltip: 'Stop session',
                        onPressed: () {
                          planner.stop();
                          if (planner.pendingReviews.isNotEmpty) {
                            showStudyRating(
                              context, planner.pendingReviews.last);
                          }
                        },
                        icon: const Icon(Icons.stop_rounded),
                      ),
                    ] else ...[
                      const Expanded(
                        child: Text('A study session needs your review.'),
                      ),
                      TextButton(
                        onPressed: () => showStudyRating(
                          context, planner.pendingReviews.first),
                        child: const Text('Rate productivity'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          if (!_history) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: math.max(
                    740, MediaQuery.sizeOf(context).width - 36),
                  child: Row(
                children: [
                  IconButton(
                    tooltip: 'Previous',
                    icon: const Icon(Icons.chevron_left),
                    onPressed: () => _navigate(-1),
                  ),
                  IconButton(
                    tooltip: 'Next',
                    icon: const Icon(Icons.chevron_right),
                    onPressed: () => _navigate(1),
                  ),
                  TextButton(
                    onPressed: () => setState(
                      () => _anchor = DateUtils.dateOnly(DateTime.now())),
                    child: const Text('Today'),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _heading(),
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  SegmentedButton<CalendarMode>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                          value: CalendarMode.today, label: Text('Today')),
                      ButtonSegment(
                          value: CalendarMode.week, label: Text('Week')),
                      ButtonSegment(
                          value: CalendarMode.month, label: Text('Month')),
                    ],
                    selected: {_mode},
                    onSelectionChanged: (next) => setState(
                      () => _mode = next.first),
                  ),
                ],
                  ),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 18),
              child: Text(
                'Long-press and drag a planned session to another day. '
                'Tap any session to edit, delete or start it.',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ],
          Expanded(
            child: _history
                ? _historyView(planner)
                : _calendar(planner.sessions),
          ),
        ],
      ),
    );
  }
}
