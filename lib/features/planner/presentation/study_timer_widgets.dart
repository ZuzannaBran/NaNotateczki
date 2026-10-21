import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/input/app_preferences_controller.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/input/touch_navigation_scroll_physics.dart';
import '../../../core/widgets/app_dialog_actions.dart';
import '../../../core/widgets/app_header_divider.dart';
import '../../editor/presentation/widgets/editor_toolbar.dart';
import '../../editor/state/ink_color_presets.dart';
import '../state/study_planner_controller.dart';
import 'planner_screen.dart';
import 'study_action_theme.dart';

String studyClock(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:'
    '${time.minute.toString().padLeft(2, '0')}';

String studyDuration(int seconds) {
  final safe = seconds < 0 ? 0 : seconds;
  final hours = safe ~/ 3600;
  final minutes = (safe ~/ 60) % 60;
  final remainder = safe % 60;
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${remainder.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:'
      '${remainder.toString().padLeft(2, '0')}';
}

String studyRatingStars(int? rating) {
  if (rating == null) {
    return 'Not rated';
  }
  return List.generate(5, (index) => index < rating ? '★' : '☆').join();
}

void openStudyPlanner(BuildContext context) {
  Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const PlannerScreen()));
}

Future<void> showStudySessionEditor(
  BuildContext context, {
  StudySession? session,
  DateTime? scheduledAt,
  StudyEntryKind kind = StudyEntryKind.session,
  StudyTechnique technique = StudyTechnique.custom,
  bool startAfterSave = false,
}) async {
  await showDialog<void>(
    context: context,
    builder: (_) => StudyActionTheme(
      child: _StudySessionDialog(
        session: session,
        scheduledAt: scheduledAt,
        kind: kind,
        technique: technique,
        startAfterSave: startAfterSave,
      ),
    ),
  );
}

Future<void> showStudyRating(BuildContext context, StudySession session) async {
  final planner = context.read<StudyPlannerController>();
  var hovered = 0;
  final score = await showDialog<int>(
    context: context,
    builder: (dialogContext) => StudyActionTheme(
      child: AlertDialog(
        title: const Center(
          child: Text(
            "Great job! Time's up.",
            key: ValueKey('study-finished-title'),
            textAlign: TextAlign.center,
            style: AppHeaderDivider.titleStyle,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(session.title),
            const SizedBox(height: 12),
            const Text('How productive was this session?'),
            const SizedBox(height: 12),
            StatefulBuilder(
              builder: (context, setDialogState) => Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var value = 1; value <= 5; value++)
                    IconButton(
                      key: ValueKey('productivity-$value'),
                      tooltip: '$value ${value == 1 ? 'star' : 'stars'}',
                      onHover: (isHovering) {
                        setDialogState(() {
                          hovered = isHovering ? value : 0;
                        });
                      },
                      onPressed: () => Navigator.pop(dialogContext, value),
                      icon: Icon(
                        value <= hovered
                            ? Icons.star_rounded
                            : Icons.star_border_rounded,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        actions: appDialogActions(context, [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Skip rating'),
          ),
        ]),
      ),
    ),
  );
  if (!context.mounted) {
    return;
  }
  if (score == null) {
    planner.skipRating(session.id);
  } else {
    planner.rate(session.id, score);
  }
}

class _StudySessionDialog extends StatefulWidget {
  const _StudySessionDialog({
    this.session,
    this.scheduledAt,
    required this.kind,
    required this.technique,
    required this.startAfterSave,
  });

  final StudySession? session;
  final DateTime? scheduledAt;
  final StudyEntryKind kind;
  final StudyTechnique technique;
  final bool startAfterSave;

  @override
  State<_StudySessionDialog> createState() => _StudySessionDialogState();
}

class _StudySessionDialogState extends State<_StudySessionDialog> {
  late final TextEditingController _title;
  late final TextEditingController _description;
  late final TextEditingController _minutes;
  late StudyTechnique _technique;
  late StudyEntryKind _kind;
  late int _focusBlocks;
  late bool _allDay;
  DateTime? _endDate;
  late StudyRepeat _repeat;
  late int _repeatEvery;
  Color? _color;
  late DateTime _date;

  @override
  void initState() {
    super.initState();
    final session = widget.session;
    _kind = session?.kind ?? widget.kind;
    _technique = session?.technique ?? widget.technique;
    _focusBlocks = session?.focusBlocks ?? _technique.rounds;
    _allDay = session?.allDay ?? false;
    _endDate = session?.eventEndDate;
    _repeat = session?.repeat ?? StudyRepeat.none;
    _repeatEvery = session?.repeatEvery ?? 1;
    _color = session == null || session.colorValue == null
        ? null
        : Color(session.colorValue!);
    _date = session?.scheduledAt ?? widget.scheduledAt ?? DateTime.now();
    _title = TextEditingController(text: session?.title ?? '');
    _description = TextEditingController(text: session?.description ?? '');
    _minutes = TextEditingController(text: '${session?.minutes ?? 30}');
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _minutes.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) {
      if (_endDate != null &&
          _endDate!.isBefore(DateTime(picked.year, picked.month, picked.day))) {
        _endDate = null;
      }
      setState(
        () => _date = DateTime(
          picked.year,
          picked.month,
          picked.day,
          _date.hour,
          _date.minute,
        ),
      );
    }
  }

  Future<void> _pickEndDate() async {
    final first = DateTime(_date.year, _date.month, _date.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: _endDate ?? first,
      firstDate: first,
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) {
      setState(() => _endDate = picked);
    }
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_date),
    );
    if (picked != null && mounted) {
      setState(
        () => _date = DateTime(
          _date.year,
          _date.month,
          _date.day,
          picked.hour,
          picked.minute,
        ),
      );
    }
  }

  Future<void> _pickColor() async {
    final recent = await SharedRecentColors.load();
    if (!mounted) {
      return;
    }
    final picked = await EditorToolbar.pickColor(
      context,
      _color ?? AppColors.blueColorSet.first,
      recent,
      onPaletteColorSelected: (color) {
        if (mounted) {
          setState(() => _color = color);
        }
      },
    );
    if (picked != null && mounted) {
      setState(() => _color = picked);
    }
  }

  void _save() {
    final planner = context.read<StudyPlannerController>();
    final minutes = int.tryParse(_minutes.text);
    if ((_kind == StudyEntryKind.event
            ? !_allDay
            : _technique == StudyTechnique.custom) &&
        (minutes == null || minutes < 1 || minutes > 1440)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Duration must be 1–1440 minutes.')),
      );
      return;
    }
    final session = widget.session;
    final isEvent = _kind == StudyEntryKind.event;
    final scheduledAt = isEvent && _allDay
        ? DateTime(_date.year, _date.month, _date.day)
        : _date;
    final duration = isEvent && _allDay ? 1440 : (minutes ?? 30);
    if (session == null) {
      final created = planner.create(
        title: _title.text,
        description: _description.text,
        scheduledAt: scheduledAt,
        kind: _kind,
        minutes: duration,
        allDay: isEvent && _allDay,
        eventEndDate: isEvent ? _endDate : null,
        repeat: isEvent ? _repeat : StudyRepeat.none,
        repeatEvery: _repeatEvery,
        technique: _technique,
        focusBlocks: _focusBlocks,
        colorValue: _color?.toARGB32(),
      );
      if (_kind == StudyEntryKind.session &&
          widget.startAfterSave &&
          !planner.start(created.id)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Finish the current timer first.')),
        );
      }
    } else {
      planner.edit(
        session.id,
        title: _title.text,
        description: _description.text,
        scheduledAt: scheduledAt,
        minutes: duration,
        allDay: isEvent && _allDay,
        eventEndDate: isEvent ? _endDate : null,
        repeat: isEvent ? _repeat : StudyRepeat.none,
        repeatEvery: _repeatEvery,
        technique: _technique,
        focusBlocks: _focusBlocks,
        colorValue: _color?.toARGB32(),
        updateColor: true,
      );
    }
    if (_color != null) {
      unawaited(SharedRecentColors.record(_color!));
    }
    Navigator.pop(context);
  }

  Widget _labeledField({
    required String label,
    required Widget child,
    Key? labelKey,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            key: labelKey,
            style: const TextStyle(
              fontSize: AppTypography.document,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(
        widget.session == null
            ? (_kind == StudyEntryKind.event
                  ? 'New event'
                  : 'New study session')
            : (_kind == StudyEntryKind.event ? 'Edit event' : 'Edit session'),
      ),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          physics: TouchNavigationScrollPhysics(
            sensitivity:
                context
                    .watch<AppPreferencesController?>()
                    ?.touchNavigationSensitivity ??
                1.0,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _labeledField(
                label: 'Name',
                labelKey: const ValueKey('study-entry-name-label'),
                child: TextField(
                  key: const ValueKey('study-entry-name-field'),
                  controller: _title,
                  autofocus: true,
                  maxLength: 100,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(12)),
                    ),
                    floatingLabelBehavior: FloatingLabelBehavior.never,
                    counterText: '',
                  ),
                ),
              ),
              _labeledField(
                label: 'Description',
                labelKey: const ValueKey('study-entry-description-label'),
                child: TextField(
                  key: const ValueKey('study-entry-description-field'),
                  controller: _description,
                  minLines: 3,
                  maxLines: 3,
                  maxLength: 500,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(12)),
                    ),
                    floatingLabelBehavior: FloatingLabelBehavior.never,
                    counterText: '',
                  ),
                ),
              ),
              const SizedBox(height: 8),
              if (_kind == StudyEntryKind.session)
                _labeledField(
                  label: 'Study technique',
                  child: DropdownButtonFormField<StudyTechnique>(
                    initialValue: _technique,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(12)),
                      ),
                    ),
                    items: [
                      for (final method in StudyTechnique.values)
                        DropdownMenuItem(
                          value: method,
                          child: Text(method.label),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setState(() {
                          _technique = value;
                          _focusBlocks = value.rounds;
                        });
                      }
                    },
                  ),
                ),
              if ((_kind == StudyEntryKind.event && !_allDay) ||
                  (_kind == StudyEntryKind.session &&
                      _technique == StudyTechnique.custom))
                _labeledField(
                  label: _kind == StudyEntryKind.event
                      ? 'Duration (minutes)'
                      : 'Minutes',
                  child: TextField(
                    controller: _minutes,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(12)),
                      ),
                    ),
                  ),
                )
              else if (_kind == StudyEntryKind.session) ...[
                _labeledField(
                  label: 'Focus blocks',
                  child: KeyedSubtree(
                    key: ValueKey('blocks-for-${_technique.name}'),
                    child: DropdownButtonFormField<int>(
                      key: const ValueKey('study-focus-blocks'),
                      initialValue: _focusBlocks,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(12)),
                        ),
                      ),
                      items: [
                        for (var blocks = 1; blocks <= 12; blocks++)
                          DropdownMenuItem(
                            value: blocks,
                            child: Text('$blocks'),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setState(() => _focusBlocks = value);
                        }
                      },
                    ),
                  ),
                ),
                Text(
                  '${_technique.focusMinutes}-min focus; '
                  '${_technique.breakMinutes}-min breaks',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  OutlinedButton.icon(
                    key: const ValueKey('study-session-colour'),
                    onPressed: _pickColor,
                    icon: Icon(
                      Icons.palette_outlined,
                      color: _color == null ? scheme.onSurface : _color!,
                      size: 18,
                    ),
                    label: const Text('Colour'),
                  ),
                  if (_color != null)
                    TextButton(
                      key: const ValueKey('study-session-colour-reset'),
                      onPressed: () => setState(() => _color = null),
                      child: const Text('Default colour'),
                    ),
                  OutlinedButton.icon(
                    onPressed: _pickDate,
                    icon: const Icon(Icons.calendar_today_outlined, size: 18),
                    label: Text(
                      '${_date.day.toString().padLeft(2, '0')}.'
                      '${_date.month.toString().padLeft(2, '0')}.'
                      '${_date.year}',
                    ),
                  ),
                  if (_kind == StudyEntryKind.session || !_allDay)
                    OutlinedButton.icon(
                      onPressed: _pickTime,
                      icon: const Icon(Icons.schedule, size: 18),
                      label: Text(studyClock(_date)),
                    ),
                ],
              ),
              if (_kind == StudyEntryKind.event) ...[
                const SizedBox(height: 10),
                CheckboxListTile(
                  key: const ValueKey('event-all-day'),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('All day'),
                  value: _allDay,
                  onChanged: (value) {
                    if (value != null) {
                      setState(() => _allDay = value);
                    }
                  },
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      key: const ValueKey('event-end-date'),
                      onPressed: _pickEndDate,
                      icon: const Icon(Icons.date_range_outlined, size: 18),
                      label: Text(
                        _endDate == null
                            ? 'End date (optional)'
                            : '${_endDate!.day}.${_endDate!.month}.'
                                  '${_endDate!.year}',
                      ),
                    ),
                    if (_endDate != null)
                      TextButton(
                        onPressed: () => setState(() => _endDate = null),
                        child: const Text('Single day'),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                _labeledField(
                  label: 'Repeat',
                  child: DropdownButtonFormField<StudyRepeat>(
                    key: const ValueKey('event-repeat'),
                    initialValue: _repeat,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(12)),
                      ),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: StudyRepeat.none,
                        child: Text('Does not repeat'),
                      ),
                      DropdownMenuItem(
                        value: StudyRepeat.daily,
                        child: Text('Daily'),
                      ),
                      DropdownMenuItem(
                        value: StudyRepeat.weekly,
                        child: Text('Weekly'),
                      ),
                      DropdownMenuItem(
                        value: StudyRepeat.monthly,
                        child: Text('Monthly'),
                      ),
                      DropdownMenuItem(
                        value: StudyRepeat.yearly,
                        child: Text('Yearly'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => _repeat = value);
                      }
                    },
                  ),
                ),
                if (_repeat != StudyRepeat.none)
                  _labeledField(
                    label: 'Repeat every (${_repeat.name})',
                    child: DropdownButtonFormField<int>(
                      key: const ValueKey('event-repeat-every'),
                      initialValue: _repeatEvery.clamp(1, 12).toInt(),
                      isExpanded: true,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(12)),
                        ),
                      ),
                      items: [
                        for (var interval = 1; interval <= 12; interval++)
                          DropdownMenuItem(
                            value: interval,
                            child: Text('$interval'),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setState(() => _repeatEvery = value);
                        }
                      },
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: appDialogActions(context, [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: StudyActionStyles.primary(Theme.of(context)),
          onPressed: _save,
          child: Text(widget.startAfterSave ? 'Save & start' : 'Save'),
        ),
      ]),
    );
  }
}

class StudyTimerCard extends StatelessWidget {
  const StudyTimerCard({super.key, this.upcomingMaxHeight = 200});

  final double upcomingMaxHeight;

  @override
  Widget build(BuildContext context) {
    final planner = context.watch<StudyPlannerController?>();
    if (planner == null) {
      return const SizedBox.shrink();
    }
    final active = planner.active;
    final next = planner.upcoming;
    final colors = Theme.of(context).colorScheme;
    return StudyActionTheme(
      child: Padding(
        key: const ValueKey('study-timer-card'),
        padding: EdgeInsets.fromLTRB(14, 20, 14, next.isEmpty ? 16 : 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Study timer',
                    style: AppHeaderDivider.titleStyle,
                  ),
                ),
                IconButton(
                  tooltip: 'Open planner',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => openStudyPlanner(context),
                  icon: const Icon(Icons.calendar_month_outlined, size: 20),
                ),
              ],
            ),
            if (active != null) ...[
              Text(
                active.title,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: AppTypography.small),
              ),
              const SizedBox(height: 4),
              Text(
                studyDuration(planner.secondsLeft(active)),
                key: const ValueKey('study-countdown'),
                style: const TextStyle(
                  fontSize: AppTypography.heading,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              if (active.technique != StudyTechnique.custom)
                Text(
                  '${active.phase == StudyPhase.focus ? 'Focus' : 'Break'}'
                  ' · ${active.round}/${active.focusBlocks}',
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: AppTypography.small,
                  ),
                ),
              const SizedBox(height: 20),
              SizedBox(
                height: StudyActionStyles.sessionButtonHeight,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        key: const ValueKey('sidebar-timer-toggle'),
                        style: StudyActionStyles.sessionOutlined(),
                        onPressed: active.status == StudyStatus.running
                            ? planner.pause
                            : planner.resume,
                        child: StudyActionStyles.sessionButtonContent(
                          icon: active.status == StudyStatus.running
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          label: active.status == StudyStatus.running
                              ? 'Pause'
                              : 'Resume',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 42,
                      child: Tooltip(
                        message: 'Stop session',
                        child: OutlinedButton(
                          key: const ValueKey('sidebar-timer-stop'),
                          style: StudyActionStyles.sessionOutlined().copyWith(
                            padding: const WidgetStatePropertyAll(
                              EdgeInsets.zero,
                            ),
                          ),
                          onPressed: () {
                            if (planner.stop()) {
                              showStudyRating(context, active);
                            }
                          },
                          child: const Icon(Icons.stop_rounded, size: 18),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ] else ...[
              Text(
                'Ready for your next focus session?',
                style: TextStyle(
                  fontSize: AppTypography.small,
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 30),
            ],
            if (active == null)
              SizedBox(
                height: StudyActionStyles.sessionButtonHeight,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: FilledButton(
                        key: const ValueKey('sidebar-start-session'),
                        style: StudyActionStyles.sessionPrimary(
                          Theme.of(context),
                        ),
                        onPressed: planner.isLoaded && planner.error == null
                            ? () => showStudySessionEditor(
                                context,
                                startAfterSave: true,
                              )
                            : null,
                        child: StudyActionStyles.sessionButtonContent(
                          icon: Icons.play_arrow_rounded,
                          label: 'Start session',
                          contentKey: const ValueKey(
                            'sidebar-start-session-content',
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        key: const ValueKey('sidebar-smart-session'),
                        style: StudyActionStyles.sessionOutlined(),
                        onPressed: planner.isLoaded && planner.error == null
                            ? () => showStudySessionEditor(
                                context,
                                technique: StudyTechnique.pomodoro,
                                startAfterSave: true,
                              )
                            : null,
                        child: StudyActionStyles.sessionButtonContent(
                          icon: Icons.auto_awesome_rounded,
                          label: 'Smart',
                          contentKey: const ValueKey(
                            'sidebar-smart-session-content',
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (active != null || next.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                'Upcoming',
                style: TextStyle(
                  fontSize: AppTypography.small,
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                key: const ValueKey('sidebar-upcoming-height-cap'),
                constraints: BoxConstraints(maxHeight: upcomingMaxHeight),
                child: ListView(
                  key: const ValueKey('sidebar-upcoming-scroll'),
                  shrinkWrap: true,
                  primary: false,
                  physics: TouchNavigationScrollPhysics(
                    sensitivity:
                        context
                            .watch<AppPreferencesController?>()
                            ?.touchNavigationSensitivity ??
                        1.0,
                  ),
                  padding: EdgeInsets.zero,
                  children: [
                    if (next.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 4),
                        child: Text('No upcoming sessions'),
                      ),
                    for (final item in next)
                      Padding(
                        padding: EdgeInsets.only(
                          bottom: item == next.last ? 0 : 8,
                        ),
                        child: Material(
                          key: ValueKey('sidebar-upcoming-card:${item.id}'),
                          color: StudyActionStyles.sessionCardColor(
                            Theme.of(context),
                            item.colorValue,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(
                              color:
                                  Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? colors.outlineVariant
                                  : AppColors.toolbar,
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(9, 5, 2, 5),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        item.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: AppTypography.document,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        '${item.scheduledAt.day}/'
                                        '${item.scheduledAt.month}'
                                        ' · ${studyClock(item.scheduledAt)}',
                                        style: TextStyle(
                                          fontSize: AppTypography.small,
                                          color: colors.onSurfaceVariant,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Start scheduled session',
                                  icon: const Icon(
                                    Icons.play_arrow_rounded,
                                    size: 18,
                                  ),
                                  onPressed: active == null
                                      ? () => planner.start(item.id)
                                      : null,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
            if (planner.error != null)
              Text(
                planner.error!,
                style: TextStyle(
                  fontSize: AppTypography.small,
                  color: colors.error,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class CompactStudyTimer extends StatelessWidget {
  const CompactStudyTimer({super.key});

  @override
  Widget build(BuildContext context) {
    final planner = context.watch<StudyPlannerController?>();
    if (planner == null) {
      return const SizedBox.shrink();
    }
    final active = planner.active;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 8),
      child: Material(
        color: StudyActionStyles.background(theme),
        shape: StadiumBorder(
          side: BorderSide(
            color: StudyActionStyles.outline(theme),
            width: 1.15,
          ),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: () => openStudyPlanner(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.timer_outlined, size: 17),
                const SizedBox(width: 7),
                Text(
                  active == null
                      ? 'Study planner'
                      : studyDuration(planner.secondsLeft(active)),
                  key: const ValueKey('compact-study-timer'),
                  style: const TextStyle(
                    fontSize: AppTypography.document,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
