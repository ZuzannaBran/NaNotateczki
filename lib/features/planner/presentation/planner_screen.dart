import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/input/app_preferences_controller.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/input/touch_navigation_scroll_physics.dart';
import '../../../core/widgets/app_dialog_actions.dart';
import '../../../core/widgets/app_header_divider.dart';
import '../state/study_planner_controller.dart';
import 'study_action_theme.dart';
import 'study_timer_widgets.dart';

enum CalendarMode { today, week, month }

Color plannerDaySurface(ThemeData theme, {required bool highlighted}) {
  final colors = theme.colorScheme;
  final base = colors.surfaceContainerLowest;
  if (!highlighted) {
    return base;
  }
  final shade = theme.brightness == Brightness.dark
      ? colors.surface
      : colors.surfaceContainerHighest;
  return Color.alphaBlend(shade.withValues(alpha: 0.5), base);
}

List<DateTime> monthCalendarDays(DateTime month) {
  final first = DateTime(month.year, month.month);
  final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
  final leadingDays = first.weekday - DateTime.monday;
  final dayCount = ((leadingDays + daysInMonth + 6) ~/ 7) * 7;
  final firstMonday = DateTime(first.year, first.month, 1 - leadingDays);
  return List.generate(
    dayCount,
    (index) =>
        DateTime(firstMonday.year, firstMonday.month, firstMonday.day + index),
  );
}

class PlannerScreen extends StatefulWidget {
  const PlannerScreen({super.key});

  @override
  State<PlannerScreen> createState() => _PlannerScreenState();
}

class _PlannerScreenState extends State<PlannerScreen> {
  CalendarMode _mode = CalendarMode.week;
  DateTime _anchor = DateUtils.dateOnly(DateTime.now());
  late final Timer _timeRefresh;

  @override
  void initState() {
    super.initState();
    _timeRefresh = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _timeRefresh.cancel();
    super.dispose();
  }

  TouchNavigationScrollPhysics get _navigationPhysics =>
      TouchNavigationScrollPhysics(
        sensitivity:
            context
                .watch<AppPreferencesController?>()
                ?.touchNavigationSensitivity ??
            1.0,
      );

  DateTime _monday(DateTime date) =>
      DateTime(date.year, date.month, date.day - (date.weekday - 1));

  DateTime _firstDay() => switch (_mode) {
    CalendarMode.today => DateUtils.dateOnly(_anchor),
    CalendarMode.week => _monday(_anchor),
    CalendarMode.month => _monday(DateTime(_anchor.year, _anchor.month, 1)),
  };

  List<DateTime> _visibleDays() {
    if (_mode == CalendarMode.month) {
      return monthCalendarDays(_anchor);
    }
    final first = _firstDay();
    final count = _mode == CalendarMode.today ? 1 : 7;
    return List.generate(
      count,
      (i) => DateTime(first.year, first.month, first.day + i),
    );
  }

  void _navigate(int direction) {
    setState(() {
      _anchor = switch (_mode) {
        CalendarMode.today => DateTime(
          _anchor.year,
          _anchor.month,
          _anchor.day + direction,
        ),
        CalendarMode.week => DateTime(
          _anchor.year,
          _anchor.month,
          _anchor.day + 7 * direction,
        ),
        CalendarMode.month => DateTime(
          _anchor.year,
          _anchor.month + direction,
          _anchor.day.clamp(1, 28).toInt(),
        ),
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
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ][month - 1];

  String _weekdayName(int weekday, {bool short = false}) {
    const days = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    final name = days[weekday - DateTime.monday];
    return short ? name.substring(0, 3) : name;
  }

  String _dayLabel(DateTime date) {
    if (_mode == CalendarMode.today) {
      return '${_weekdayName(date.weekday)} ${date.day} '
          '${_monthName(date.month)}';
    }
    return '${_weekdayName(date.weekday, short: true)} ${date.day}';
  }

  bool _isSameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Future<void> _sessionOptions(StudySession session) async {
    final planner = context.read<StudyPlannerController>();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StudyActionTheme(
        child: AlertDialog(
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
                  Text(
                    'Productivity: ${studyRatingStars(session.productivity)}',
                  ),
                ],
                if (session.status == StudyStatus.review) ...[
                  const SizedBox(height: 10),
                  const Text('Review needed before adding to history.'),
                ],
              ],
            ),
          ),
          actions: appDialogActions(context, [
            if (session.status == StudyStatus.planned)
              TextButton(
                onPressed: () {
                  Navigator.pop(dialogContext);
                  showStudySessionEditor(context, session: session);
                },
                child: const Text('Edit'),
              ),
            if (session.status == StudyStatus.planned)
              FilledButton(
                style: StudyActionStyles.primary(Theme.of(context)),
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
          ]),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(StudySession session) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StudyActionTheme(
        child: AlertDialog(
          title: const Text('Delete this session?'),
          content: Text('Delete "${session.title}" and its history?'),
          actions: appDialogActions(context, [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Delete'),
            ),
          ]),
        ),
      ),
    );
    if (confirmed == true && mounted) {
      context.read<StudyPlannerController>().delete(session.id);
    }
  }

  Widget _sessionTile(StudySession session, {bool compact = false}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final planner = context.read<StudyPlannerController>();
    final done = session.status == StudyStatus.completed;
    final reviewing = session.status == StudyStatus.review;
    final darkMode = theme.brightness == Brightness.dark;
    final color = reviewing
        ? scheme.tertiaryContainer
        : done
        ? (darkMode
              ? scheme.surfaceContainerLowest
              : scheme.surfaceContainerHighest)
        : StudyActionStyles.plannedSessionColor(theme);
    final tile = Material(
      key: ValueKey('planner-session-tile:${session.id}'),
      color: StudyActionStyles.sessionCardColor(
        theme,
        session.colorValue,
        baseColor: color,
      ),
      shape: StudyActionStyles.sessionCardShape(scheme),
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
                  fontSize: compact
                      ? AppTypography.small
                      : AppTypography.document,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (!compact) ...[
                const SizedBox(height: 3),
                Text(
                  done
                      ? 'Done · ${studyRatingStars(session.productivity)}'
                      : reviewing
                      ? 'Rate productivity'
                      : session.status == StudyStatus.planned &&
                            session.scheduledAt.isBefore(DateTime.now())
                      ? 'Not started'
                      : session.technique.label,
                  style: TextStyle(
                    fontSize: AppTypography.small,
                    color: scheme.onSurfaceVariant,
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

  Widget _dayCell(
    DateTime day,
    List<StudySession> sessions, {
    bool compact = false,
    int? monthColumn,
    bool lastMonthRow = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final today = _isSameDate(day, DateTime.now());
    final inMonth =
        _mode != CalendarMode.month ||
        (day.month == _anchor.month && day.year == _anchor.year);
    final items =
        sessions.where((s) => _isSameDate(s.scheduledAt, day)).toList()
          ..sort((a, b) => a.scheduledAt.compareTo(b.scheduledAt));

    return Opacity(
      opacity: inMonth || monthColumn != null ? 1 : 0.5,
      child: DragTarget<StudySession>(
        onWillAcceptWithDetails: (details) =>
            details.data.status == StudyStatus.planned,
        onAcceptWithDetails: (details) {
          context.read<StudyPlannerController>().move(details.data.id, day);
        },
        builder: (context, candidates, rejected) {
          return Container(
            key: ValueKey(
              'planner-day-cell-${day.year}-${day.month}-${day.day}',
            ),
            decoration: BoxDecoration(
              color: candidates.isNotEmpty
                  ? scheme.primaryContainer
                  : plannerDaySurface(
                      Theme.of(context),
                      highlighted: today && _mode != CalendarMode.today,
                    ),
              borderRadius: monthColumn == null
                  ? BorderRadius.circular(14)
                  : null,
              border: monthColumn == null
                  ? Border.all(
                      color: today ? scheme.outline : scheme.outlineVariant,
                    )
                  : Border(
                      right: monthColumn == 6
                          ? BorderSide.none
                          : BorderSide(color: scheme.outlineVariant),
                      bottom: lastMonthRow
                          ? BorderSide.none
                          : BorderSide(color: scheme.outlineVariant),
                    ),
            ),
            margin: monthColumn == null
                ? const EdgeInsets.all(3)
                : EdgeInsets.zero,
            padding: EdgeInsets.all(compact ? 6 : 12),
            child: Opacity(
              opacity: !inMonth && monthColumn != null ? 0.5 : 1,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _dayLabel(day),
                          key: ValueKey(
                            'planner-day-label-${day.year}-'
                            '${day.month}-${day.day}',
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: compact
                                ? AppTypography.small
                                : AppTypography.document,
                            fontWeight: today
                                ? FontWeight.bold
                                : FontWeight.w500,
                            color: inMonth
                                ? scheme.onSurface
                                : scheme.onSurfaceVariant,
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
                              day.year,
                              day.month,
                              day.day,
                              9,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  if (_mode != CalendarMode.month)
                    Expanded(
                      child: _HourlyDaySchedule(
                        key: ValueKey(
                          'planner-hourly-${day.year}-${day.month}-${day.day}',
                        ),
                        day: day,
                        now: DateTime.now(),
                        sessions: items,
                        compact: compact,
                        physics: _navigationPhysics,
                        buildTile: (item) =>
                            _sessionTile(item, compact: compact),
                        onPlanAt: (hour) => showStudySessionEditor(
                          context,
                          scheduledAt: DateTime(
                            day.year,
                            day.month,
                            day.day,
                            hour,
                          ),
                        ),
                      ),
                    )
                  else
                    Expanded(
                      child: ListView(
                        physics: _navigationPhysics,
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
                                  day.year,
                                  day.month,
                                  day.day,
                                  9,
                                ),
                              ),
                              child: const SizedBox(height: 45),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _calendar(List<StudySession> sessions) {
    final days = _visibleDays();
    if (_mode == CalendarMode.week) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: _navigationPhysics,
            child: SizedBox(
              width: math.max(1050.0, constraints.maxWidth),
              child: _WeekTimeGrid(
                key: ValueKey(
                  'planner-week-${days.first.year}-'
                  '${days.first.month}-${days.first.day}',
                ),
                days: days,
                now: DateTime.now(),
                sessions: sessions,
                physics: _navigationPhysics,
                dayLabel: _dayLabel,
                buildTile: (session) => _sessionTile(
                  session,
                  compact: true,
                ),
                onPlanAt: (day, hour) => showStudySessionEditor(
                  context,
                  scheduledAt: DateTime(
                    day.year,
                    day.month,
                    day.day,
                    hour,
                  ),
                ),
                onMove: (id, day) =>
                    context.read<StudyPlannerController>().move(id, day),
              ),
            ),
          ),
        ),
      );
    }
    if (_mode == CalendarMode.today) {
      return Padding(
        padding: const EdgeInsets.all(18),
        child: _dayCell(days.first, sessions),
      );
    }

    const minimumWidth = 980.0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 960) {
            final compactDays = days
                .where((day) => day.month == _anchor.month)
                .toList();
            return Container(
              key: const ValueKey('planner-mobile-month-surface'),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              child: ListView.builder(
                key: const ValueKey('mobile-planner-days'),
                physics: _navigationPhysics,
                padding: EdgeInsets.zero,
                itemCount: compactDays.length,
                itemBuilder: (context, index) => SizedBox(
                  height: 168,
                  child: _dayCell(
                    compactDays[index],
                    sessions,
                    monthColumn: 6,
                    lastMonthRow: index == compactDays.length - 1,
                  ),
                ),
              ),
            );
          }
          final width = constraints.maxWidth < minimumWidth
              ? minimumWidth
              : constraints.maxWidth;
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: _navigationPhysics,
            child: SizedBox(
              width: width,
              child: SingleChildScrollView(
                physics: _navigationPhysics,
                padding: const EdgeInsets.fromLTRB(0, 0, 0, 16),
                child: Column(
                  children: [
                    _CalendarHeaderStrip(
                      key: const ValueKey('planner-month-header-strip'),
                      days: [
                        for (final name in const [
                          'Mon',
                          'Tue',
                          'Wed',
                          'Thu',
                          'Fri',
                          'Sat',
                          'Sun',
                        ])
                          Center(
                            child: Text(
                              name,
                              style: const TextStyle(
                                fontSize: AppTypography.small,
                              ),
                            ),
                          ),
                      ],
                    ),
                    Container(
                      key: const ValueKey('planner-month-grid-surface'),
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerLowest,
                        borderRadius: const BorderRadius.only(
                          bottomLeft: Radius.circular(12),
                          bottomRight: Radius.circular(12),
                        ),
                      ),
                      foregroundDecoration: BoxDecoration(
                        borderRadius: const BorderRadius.only(
                          bottomLeft: Radius.circular(12),
                          bottomRight: Radius.circular(12),
                        ),
                        border: Border(
                          left: BorderSide(
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                          right: BorderSide(
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                          bottom: BorderSide(
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                        ),
                      ),
                      child: GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: days.length,
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 7,
                              childAspectRatio: 1.1,
                            ),
                        itemBuilder: (context, i) => _dayCell(
                          days[i],
                          sessions,
                          compact: true,
                          monthColumn: i % 7,
                          lastMonthRow: i >= days.length - 7,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _smartButton() => SizedBox(
    height: StudyActionStyles.sessionButtonHeight,
    child: OutlinedButton(
      key: const ValueKey('planner-smart-session'),
      style: StudyActionStyles.sessionOutlined(),
      onPressed: () => showStudySessionEditor(
        context,
        technique: StudyTechnique.pomodoro,
        startAfterSave: true,
      ),
      child: StudyActionStyles.sessionButtonContent(
        icon: Icons.auto_awesome_rounded,
        label: 'Smart session',
        contentKey: const ValueKey('planner-smart-session-content'),
      ),
    ),
  );

  Widget _newSessionButton() => SizedBox(
    height: StudyActionStyles.sessionButtonHeight,
    child: FilledButton(
      key: const ValueKey('planner-new-session'),
      style: StudyActionStyles.sessionPrimary(Theme.of(context)),
      onPressed: () => showStudySessionEditor(context),
      child: StudyActionStyles.sessionButtonContent(
        icon: Icons.add_rounded,
        label: 'New session',
        contentKey: const ValueKey('planner-new-session-content'),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final planner = context.watch<StudyPlannerController>();
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 760;
        final compactCalendar = constraints.maxWidth < 960;
        return StudyActionTheme(
          child: Scaffold(
            appBar: AppBar(
              toolbarHeight: AppHeaderDivider.toolbarHeight,
              titleSpacing: MediaQuery.sizeOf(context).width >= 600 ? 44 : null,
              scrolledUnderElevation: 0,
              surfaceTintColor: Colors.transparent,
              title: const Text(
                'Study planner',
                style: AppHeaderDivider.titleStyle,
              ),
              leading: IconButton(
                tooltip: 'Back to notes',
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.pop(context),
              ),
              actions: [
                if (!narrow) ...[
                  SizedBox(width: 148, child: _smartButton()),
                  const SizedBox(width: 8),
                  SizedBox(width: 148, child: _newSessionButton()),
                ],
                const SizedBox(width: 16),
              ],
            ),
            body: SafeArea(
              top: false,
              child: Column(
                children: [
                  const AppHeaderDivider(),
                  if (narrow)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                      child: Row(
                        children: [
                          Expanded(child: _smartButton()),
                          const SizedBox(width: 8),
                          Expanded(child: _newSessionButton()),
                        ],
                      ),
                    ),
                  if (planner.active != null ||
                      planner.pendingReviews.isNotEmpty)
                    Material(
                      color: colors.surfaceContainerLow,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 7,
                        ),
                        child: Row(
                          children: [
                            if (planner.active != null) ...[
                              const Icon(Icons.timer_outlined),
                              const SizedBox(width: 9),
                              Expanded(
                                child: Text(
                                  '${planner.active!.title} · '
                                  '${studyDuration(
                                    planner.secondsLeft(planner.active!),
                                  )}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              TextButton.icon(
                                onPressed:
                                    planner.active!.status ==
                                        StudyStatus.running
                                    ? planner.pause
                                    : planner.resume,
                                icon: Icon(
                                  planner.active!.status == StudyStatus.running
                                      ? Icons.pause
                                      : Icons.play_arrow,
                                ),
                                label: Text(
                                  planner.active!.status == StudyStatus.running
                                      ? 'Pause'
                                      : 'Resume',
                                ),
                              ),
                              IconButton(
                                tooltip: 'Stop session',
                                onPressed: () {
                                  final session = planner.active;
                                  if (session != null && planner.stop()) {
                                    showStudyRating(context, session);
                                  }
                                },
                                icon: const Icon(Icons.stop_rounded),
                              ),
                            ] else ...[
                              const Expanded(
                                child: Text(
                                  'A study session needs your review.',
                                ),
                              ),
                              TextButton(
                                onPressed: () => showStudyRating(
                                  context,
                                  planner.pendingReviews.first,
                                ),
                                child: const Text('Rate productivity'),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  if (compactCalendar)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              IconButton(
                                tooltip: 'Previous',
                                icon: const Icon(Icons.chevron_left),
                                onPressed: () => _navigate(-1),
                              ),
                              Expanded(
                                child: Text(
                                  _heading(),
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                              ),
                              IconButton(
                                tooltip: 'Next',
                                icon: const Icon(Icons.chevron_right),
                                onPressed: () => _navigate(1),
                              ),
                              TextButton(
                                onPressed: () => setState(
                                  () => _anchor = DateUtils.dateOnly(
                                    DateTime.now(),
                                  ),
                                ),
                                child: const Text('Today'),
                              ),
                            ],
                          ),
                          SegmentedButton<CalendarMode>(
                            showSelectedIcon: false,
                            segments: const [
                              ButtonSegment(
                                value: CalendarMode.today,
                                label: Text('Today'),
                              ),
                              ButtonSegment(
                                value: CalendarMode.week,
                                label: Text('Week'),
                              ),
                              ButtonSegment(
                                value: CalendarMode.month,
                                label: Text('Month'),
                              ),
                            ],
                            selected: {_mode},
                            onSelectionChanged: (next) =>
                                setState(() => _mode = next.first),
                          ),
                        ],
                      ),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        physics: _navigationPhysics,
                        child: SizedBox(
                          width: math.max(
                            740.0,
                            MediaQuery.sizeOf(context).width - 36,
                          ),
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
                                  () => _anchor = DateUtils.dateOnly(
                                    DateTime.now(),
                                  ),
                                ),
                                child: const Text('Today'),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _heading(),
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                              ),
                              SegmentedButton<CalendarMode>(
                                showSelectedIcon: false,
                                segments: const [
                                  ButtonSegment(
                                    value: CalendarMode.today,
                                    label: Text('Today'),
                                  ),
                                  ButtonSegment(
                                    value: CalendarMode.week,
                                    label: Text('Week'),
                                  ),
                                  ButtonSegment(
                                    value: CalendarMode.month,
                                    label: Text('Month'),
                                  ),
                                ],
                                selected: {_mode},
                                onSelectionChanged: (next) =>
                                    setState(() => _mode = next.first),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  Expanded(child: _calendar(planner.sessions)),
                  const SizedBox(
                    key: ValueKey('planner-calendar-bottom-gap'),
                    height: 24,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _HourlyDaySchedule extends StatefulWidget {
  const _HourlyDaySchedule({
    required this.day,
    required this.now,
    required this.sessions,
    required this.compact,
    required this.physics,
    required this.buildTile,
    required this.onPlanAt,
    super.key,
  });

  final DateTime day;
  final DateTime now;
  final List<StudySession> sessions;
  final bool compact;
  final ScrollPhysics physics;
  final Widget Function(StudySession) buildTile;
  final ValueChanged<int> onPlanAt;

  @override
  State<_HourlyDaySchedule> createState() => _HourlyDayScheduleState();
}

class _HourlyDayScheduleState extends State<_HourlyDaySchedule> {
  static const double _hourHeight = 64;
  late final ScrollController _scrollController;

  bool get _isToday => DateUtils.isSameDay(widget.day, widget.now);

  String get _dateKey =>
      '${widget.day.year}-${widget.day.month}-${widget.day.day}';

  @override
  void initState() {
    super.initState();
    final focusHour = DateUtils.isSameDay(widget.day, widget.now)
        ? widget.now.hour
        : widget.sessions.isNotEmpty
        ? widget.sessions.first.scheduledAt.hour
        : 8;
    _scrollController = ScrollController(
      initialScrollOffset: math.max(0, focusHour - 2) * _hourHeight,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Widget _hourRow(int hour) {
    final scheme = Theme.of(context).colorScheme;
    final sessions = widget.sessions.where(
      (session) => session.scheduledAt.hour == hour,
    );
    final currentHour = _isToday && widget.now.hour == hour;
    final minuteFraction =
        (widget.now.minute + widget.now.second / 60) / 60;
    return Stack(
      key: ValueKey('planner-hour-row-$_dateKey-$hour'),
      children: [
        if (currentHour)
          Positioned.fill(
            child: IgnorePointer(
              child: Align(
                alignment: Alignment(0, minuteFraction * 2 - 1),
                child: Container(
                  key: ValueKey('planner-now-line-$_dateKey'),
                  width: double.infinity,
                  height: 2,
                  color: scheme.onSurface.withValues(alpha: 0.8),
                ),
              ),
            ),
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.65),
                width: 0.7,
              ),
            ),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: _hourHeight),
            child: InkWell(
              onTap: () => widget.onPlanAt(hour),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 7, 3, 7),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: widget.compact ? 34 : 42,
                      child: FractionalTranslation(
                        translation: const Offset(0, -0.5),
                        child: Text(
                          '${hour.toString().padLeft(2, '0')}:00',
                          style: TextStyle(
                            fontSize: AppTypography.small,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 22),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final session in sessions)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 5),
                              child: widget.buildTile(session),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListView(
    key: ValueKey('planner-hour-list-$_dateKey'),
    controller: _scrollController,
    physics: widget.physics,
    padding: const EdgeInsets.fromLTRB(0, 10, 0, 4),
    children: [for (var hour = 0; hour < 24; hour++) _hourRow(hour)],
  );
}


class _CalendarHeaderStrip extends StatelessWidget {
  const _CalendarHeaderStrip({
    required this.days,
    super.key,
  });

  final List<Widget> days;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      height: 40,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(12),
          topRight: Radius.circular(12),
        ),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          for (var index = 0; index < days.length; index++)
            Expanded(
              child: Container(
                foregroundDecoration: index == days.length - 1
                    ? null
                    : BoxDecoration(
                        border: Border(
                          right: BorderSide(
                            color: colorScheme.outlineVariant,
                          ),
                        ),
                      ),
                child: days[index],
              ),
            ),
        ],
      ),
    );
  }
}

class _WeekTimeGrid extends StatefulWidget {
  const _WeekTimeGrid({
    required this.days,
    required this.now,
    required this.sessions,
    required this.physics,
    required this.dayLabel,
    required this.buildTile,
    required this.onPlanAt,
    required this.onMove,
    super.key,
  });

  final List<DateTime> days;
  final DateTime now;
  final List<StudySession> sessions;
  final ScrollPhysics physics;
  final String Function(DateTime) dayLabel;
  final Widget Function(StudySession) buildTile;
  final void Function(DateTime, int) onPlanAt;
  final void Function(String, DateTime) onMove;

  @override
  State<_WeekTimeGrid> createState() => _WeekTimeGridState();
}

class _WeekTimeGridState extends State<_WeekTimeGrid> {
  static const double _hourHeight = 64;
  static const double _axisWidth = 52;
  late final ScrollController _controller;

  @override
  void initState() {
    super.initState();
    final includesToday = widget.days.any(
      (date) => DateUtils.isSameDay(date, widget.now),
    );
    final focusHour = includesToday
        ? widget.now.hour
        : widget.sessions.isNotEmpty
        ? widget.sessions.first.scheduledAt.hour
        : 8;
    _controller = ScrollController(
      initialScrollOffset: math.max(0, focusHour - 2) * _hourHeight,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _dayKey(DateTime day) =>
      '${day.year}-${day.month}-${day.day}';

  Widget _header(DateTime day) {
    final theme = Theme.of(context);
    final isToday = DateUtils.isSameDay(day, widget.now);
    return Container(
      key: ValueKey('planner-day-cell-${_dayKey(day)}'),
      padding: const EdgeInsets.symmetric(horizontal: 5),
      color: plannerDaySurface(theme, highlighted: isToday),
      child: Row(
        children: [
          Expanded(
            child: Text(
              widget.dayLabel(day),
              key: ValueKey('planner-day-label-${_dayKey(day)}'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppTypography.small,
                fontWeight: isToday ? FontWeight.bold : FontWeight.w500,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Plan on this day',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.add_rounded, size: 18),
            onPressed: () => widget.onPlanAt(day, 9),
          ),
        ],
      ),
    );
  }

  Widget _hourCell(DateTime day, int hour) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dateKey = _dayKey(day);
    final isToday = DateUtils.isSameDay(day, widget.now);
    final nowHour = isToday && widget.now.hour == hour;
    final atHour = widget.sessions.where(
      (session) =>
          DateUtils.isSameDay(session.scheduledAt, day) &&
          session.scheduledAt.hour == hour,
    );
    final fraction =
        (widget.now.minute + widget.now.second / 60) / 60;
    return DragTarget<StudySession>(
      onWillAcceptWithDetails: (details) =>
          details.data.status == StudyStatus.planned,
      onAcceptWithDetails: (details) =>
          widget.onMove(details.data.id, day),
      builder: (context, candidates, rejected) => Container(
        key: ValueKey('planner-week-cell-$dateKey-$hour'),
        constraints: const BoxConstraints(minHeight: _hourHeight),
        decoration: BoxDecoration(
          color: candidates.isNotEmpty
              ? scheme.primaryContainer
              : plannerDaySurface(theme, highlighted: isToday),
          border: Border(
            top: BorderSide(
              width: 0.7,
              color: scheme.outlineVariant.withValues(alpha: 0.65),
            ),
          ),
        ),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 7, 4, 7),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final item in atHour)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 5),
                      child: widget.buildTile(item),
                    ),
                  if (atHour.isEmpty)
                    InkWell(
                      onTap: () => widget.onPlanAt(day, hour),
                      child: const SizedBox(height: 49),
                    ),
                ],
              ),
            ),
            if (nowHour)
              Positioned.fill(
                child: IgnorePointer(
                  child: Align(
                    alignment: Alignment(0, fraction * 2 - 1),
                    child: Container(
                      key: ValueKey('planner-week-now-line-$dateKey'),
                      width: double.infinity,
                      height: 2,
                      color: scheme.onSurface.withValues(alpha: 0.8),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _hourRow(int hour) {
    final scheme = Theme.of(context).colorScheme;
    return IntrinsicHeight(
      child: Row(
        key: ValueKey('planner-week-hour-row-$hour'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: _axisWidth,
            child: Align(
              alignment: Alignment.topLeft,
              child: FractionalTranslation(
                translation: Offset.zero,
                child: Padding(
                  padding: const EdgeInsets.only(left: 2),
                  child: Text(
                    '${hour.toString().padLeft(2, '0')}:00',
                    key: ValueKey('planner-week-hour-label-$hour'),
                    style: TextStyle(
                      fontSize: AppTypography.small,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
          for (final day in widget.days)
            Expanded(child: _hourCell(day, hour)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    key: const ValueKey('planner-week-time-grid'),
    children: [
      Padding(
        padding: const EdgeInsets.only(left: _axisWidth),
        child: _CalendarHeaderStrip(
          key: const ValueKey('planner-week-header-strip'),
          days: [for (final day in widget.days) _header(day)],
        ),
      ),
      Expanded(
        child: ListView(
          key: const ValueKey('planner-week-hours'),
          controller: _controller,
          physics: widget.physics,
          padding: EdgeInsets.zero,
          children: [
            for (var hour = 0; hour < 24; hour++) _hourRow(hour),
          ],
        ),
      ),
    ],
  );
}
