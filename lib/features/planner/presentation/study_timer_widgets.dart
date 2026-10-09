import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/study_planner_controller.dart';
import 'planner_screen.dart';

String studyClock(DateTime time) =>
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

String studyDuration(int seconds) {
  final safe = seconds < 0 ? 0 : seconds;
  final hours = safe ~/ 3600;
  final minutes = (safe ~/ 60) % 60;
  final remainder = safe % 60;
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${remainder.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:${remainder.toString().padLeft(2, '0')}';
}

void openStudyPlanner(BuildContext context) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const PlannerScreen()),
  );
}

Future<void> showStudySessionEditor(
  BuildContext context, {
  StudySession? session,
  DateTime? scheduledAt,
  StudyTechnique technique = StudyTechnique.custom,
  bool startAfterSave = false,
}) async {
  await showDialog<void>(
    context: context,
    builder: (_) => _StudySessionDialog(
      session: session,
      scheduledAt: scheduledAt,
      technique: technique,
      startAfterSave: startAfterSave,
    ),
  );
}

Future<void> showStudyRating(BuildContext context, StudySession session) async {
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Rate your productivity'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(session.title),
          const SizedBox(height: 12),
          const Text('How productive was this session?'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            children: [
              for (var score = 1; score <= 5; score++)
                ActionChip(
                  key: ValueKey('productivity-$score'),
                  label: Text('$score'),
                  onPressed: () {
                    context.read<StudyPlannerController>().rate(
                      session.id, score,
                    );
                    Navigator.pop(dialogContext);
                  },
                ),
            ],
          ),
          const SizedBox(height: 8),
          const Text('1 = low  ·  5 = excellent'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Rate later'),
        ),
      ],
    ),
  );
}

class _StudySessionDialog extends StatefulWidget {
  const _StudySessionDialog({
    this.session,
    this.scheduledAt,
    required this.technique,
    required this.startAfterSave,
  });

  final StudySession? session;
  final DateTime? scheduledAt;
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
  late DateTime _date;

  @override
  void initState() {
    super.initState();
    final session = widget.session;
    _technique = session?.technique ?? widget.technique;
    _date = session?.scheduledAt ?? widget.scheduledAt ?? DateTime.now();
    _title = TextEditingController(text: session?.title ?? '');
    _description = TextEditingController(text: session?.description ?? '');
    _minutes = TextEditingController(
      text: '${session?.minutes ?? 30}',
    );
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
      setState(() => _date = DateTime(
        picked.year, picked.month, picked.day, _date.hour, _date.minute,
      ));
    }
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_date),
    );
    if (picked != null && mounted) {
      setState(() => _date = DateTime(
        _date.year, _date.month, _date.day, picked.hour, picked.minute,
      ));
    }
  }

  void _save() {
    final planner = context.read<StudyPlannerController>();
    final minutes = int.tryParse(_minutes.text);
    if (_technique == StudyTechnique.custom &&
        (minutes == null || minutes < 1 || minutes > 1440)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Duration must be 1–1440 minutes.')),
      );
      return;
    }
    final session = widget.session;
    if (session == null) {
      final created = planner.create(
        title: _title.text,
        description: _description.text,
        scheduledAt: _date,
        minutes: minutes ?? 30,
        technique: _technique,
      );
      if (widget.startAfterSave && !planner.start(created.id)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Finish the current timer first.')),
        );
      }
    } else {
      planner.edit(
        session.id,
        title: _title.text,
        description: _description.text,
        scheduledAt: _date,
        minutes: minutes ?? 30,
        technique: _technique,
      );
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.session == null ? 'New study session' : 'Edit session'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _title,
                autofocus: true,
                maxLength: 100,
                decoration: const InputDecoration(
                  labelText: 'Session name',
                  hintText: 'e.g. Chemistry revision',
                ),
              ),
              TextField(
                controller: _description,
                maxLines: 3,
                maxLength: 500,
                decoration: const InputDecoration(labelText: 'Description'),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<StudyTechnique>(
                value: _technique,
                decoration: const InputDecoration(labelText: 'Study technique'),
                items: [
                  for (final method in StudyTechnique.values)
                    DropdownMenuItem(
                      value: method,
                      child: Text(method.label),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _technique = value);
                  }
                },
              ),
              if (_technique == StudyTechnique.custom)
                TextField(
                  controller: _minutes,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Minutes',
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    '${_technique.rounds} focus block(s) × '
                    '${_technique.focusMinutes} min; '
                    '${_technique.breakMinutes}-min breaks',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  OutlinedButton.icon(
                    onPressed: _pickDate,
                    icon: const Icon(Icons.calendar_today_outlined, size: 18),
                    label: Text(
                      '${_date.day.toString().padLeft(2, '0')}.'
                      '${_date.month.toString().padLeft(2, '0')}.'
                      '${_date.year}',
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _pickTime,
                    icon: const Icon(Icons.schedule, size: 18),
                    label: Text(studyClock(_date)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _save,
          child: Text(widget.startAfterSave ? 'Save & start' : 'Save'),
        ),
      ],
    );
  }
}

class StudyTimerCard extends StatelessWidget {
  const StudyTimerCard({super.key});

  @override
  Widget build(BuildContext context) {
    final planner = context.watch<StudyPlannerController?>();
    if (planner == null) {
      return const SizedBox.shrink();
    }
    final active = planner.active;
    final next = planner.upcoming.take(2).toList();
    final reviews = planner.pendingReviews;
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('study-timer-card'),
      margin: const EdgeInsets.fromLTRB(10, 10, 10, 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: colors.outlineVariant.withValues(alpha: 0.65),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.timer_outlined, size: 19),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('Study timer',
                    style: TextStyle(fontWeight: FontWeight.w600)),
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
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 4),
            Text(
              studyDuration(planner.secondsLeft(active)),
              key: const ValueKey('study-countdown'),
              style: const TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            if (active.technique != StudyTechnique.custom)
              Text(
                '${active.phase == StudyPhase.focus ? 'Focus' : 'Break'}'
                ' · ${active.round}/${active.technique.rounds}',
                style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
              ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: active.status == StudyStatus.running
                        ? planner.pause : planner.resume,
                    icon: Icon(active.status == StudyStatus.running
                        ? Icons.pause_rounded : Icons.play_arrow_rounded),
                    label: Text(active.status == StudyStatus.running
                        ? 'Pause' : 'Resume'),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.outlined(
                  tooltip: 'Stop session',
                  onPressed: () {
                    planner.stop();
                    final pending = planner.pendingReviews;
                    if (pending.isNotEmpty) {
                      showStudyRating(context, pending.last);
                    }
                  },
                  icon: const Icon(Icons.stop_rounded),
                ),
              ],
            ),
          ] else ...[
            Text(
              'Ready for your next focus session?',
              style: TextStyle(
                fontSize: 12, color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
          ],
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              TextButton.icon(
                onPressed: planner.isLoaded && planner.error == null
                    ? () => showStudySessionEditor(
                        context, startAfterSave: true)
                    : null,
                icon: const Icon(Icons.play_circle_outline, size: 18),
                label: const Text('Start session'),
              ),
              TextButton.icon(
                onPressed: planner.isLoaded
                    ? () => showStudySessionEditor(
                        context,
                        technique: StudyTechnique.pomodoro,
                        startAfterSave: true,
                      )
                    : null,
                icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                label: const Text('Smart'),
              ),
            ],
          ),
          if (next.isNotEmpty) ...[
            const Divider(height: 16),
            Text('Upcoming',
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
            for (final item in next)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                title: Text(item.title,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  '${item.scheduledAt.day}/${item.scheduledAt.month}'
                  ' · ${studyClock(item.scheduledAt)}',
                  style: const TextStyle(fontSize: 11),
                ),
                trailing: IconButton(
                  tooltip: 'Start scheduled session',
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  onPressed: active == null
                      ? () => planner.start(item.id)
                      : null,
                ),
              ),
          ],
          if (reviews.isNotEmpty) ...[
            const Divider(height: 14),
            TextButton.icon(
              onPressed: () => showStudyRating(context, reviews.first),
              icon: const Icon(Icons.star_border_rounded, size: 18),
              label: Text('Rate ${reviews.length} session(s)'),
            ),
          ],
          if (planner.error != null)
            Text(planner.error!,
                style: TextStyle(fontSize: 11, color: colors.error)),
        ],
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 8),
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        shape: StadiumBorder(
          side: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
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
                    fontSize: 13,
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
