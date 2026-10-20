import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/input/app_preferences_controller.dart';
import '../../../core/input/touch_navigation_scroll_physics.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_header_divider.dart';
import '../../../core/widgets/workspace_document_app_bar.dart';
import '../../library/presentation/library_controller.dart';
import '../../notebook/domain/notebook.dart';
import '../state/planner_task.dart';
import 'study_timer_widgets.dart';

/// Keeps planner tasks within the application's warm beige palette.
Color plannerTaskBackground(
  PlannerTaskTone tone, {
  required bool darkMode,
  bool completed = false,
}) {
  final resolvedTone = completed ? PlannerTaskTone.completed : tone;
  final color = darkMode
      ? switch (resolvedTone) {
          PlannerTaskTone.undated => AppColors.darkActive,
          PlannerTaskTone.upcoming => AppColors.darkCanvas,
          PlannerTaskTone.overdue => AppColors.darkPaper,
          PlannerTaskTone.completed => AppColors.darkCanvas,
        }
      : switch (tone) {
          PlannerTaskTone.undated => AppColors.divider,
          PlannerTaskTone.upcoming => AppColors.toolbar,
          PlannerTaskTone.overdue => AppColors.background,
          PlannerTaskTone.completed => AppColors.background,
        };
  if (!completed) {
    return color;
  }
  return Color.alphaBlend(
    color.withValues(alpha: 0.42),
    darkMode ? AppColors.darkToolbar : AppColors.paper,
  );
}


class TaskListScreen extends StatelessWidget {
  const TaskListScreen({
    required this.planner,
    required this.onSettings,
    this.showCompactTimer = false,
    this.onOpenNavigation,
    super.key,
  });

  final Notebook planner;
  final VoidCallback onSettings;
  final bool showCompactTimer;
  final VoidCallback? onOpenNavigation;

  @override
  Widget build(BuildContext context) {
    final library = context.watch<LibraryController>();
    final tasks = library.plannerTasks(planner.uid);
    final theme = Theme.of(context);
    final surface = theme.brightness == Brightness.dark
        ? AppColors.darkCanvas
        : AppColors.paper;
    final navigationSensitivity =
        context.watch<AppPreferencesController?>()
            ?.touchNavigationSensitivity ??
        1.0;

    return Scaffold(
      appBar: WorkspaceDocumentAppBar(
        title: planner.title,
        onSettings: onSettings,
        onOpenNavigation: onOpenNavigation,
        extraActions: [
          if (showCompactTimer) const CompactStudyTimer(),
        ],
      ),
      body: Column(
        children: [
          const AppHeaderDivider(),
          Expanded(
            child: SingleChildScrollView(
              physics: TouchNavigationScrollPhysics(
                sensitivity: navigationSensitivity,
              ),
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 960),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton.icon(
                          key: const ValueKey('planner-add-task'),
                          style: FilledButton.styleFrom(
                            backgroundColor: theme.brightness == Brightness.dark
                                ? AppColors.darkPaper
                                : AppColors.toolbar,
                            foregroundColor: theme.brightness == Brightness.dark
                                ? AppColors.darkText
                                : AppColors.inkBlack,
                          ),
                          onPressed: () =>
                              unawaited(library.addPlannerTask(planner.uid)),
                          icon: const Icon(Icons.add_rounded, size: 18),
                          label: const Text('Add task'),
                        ),
                      ),
                      const SizedBox(height: 16),
                      DecoratedBox(
                        decoration: const BoxDecoration(
                          borderRadius: BorderRadius.all(Radius.circular(24)),
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.shadow,
                              blurRadius: 9,
                              offset: Offset(0, 2),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(24),
                          child: Material(
                            color: surface,
                            child: tasks.isEmpty
                                ? const Padding(
                                    padding: EdgeInsets.symmetric(
                                      vertical: 50,
                                      horizontal: 20,
                                    ),
                                    child: Center(
                                      child: Text(
                                        'No tasks yet. Add your first task.',
                                        style: TextStyle(
                                          fontSize: AppTypography.document,
                                        ),
                                      ),
                                    ),
                                  )
                                : Column(
                                    children: [
                                      for (var i = 0; i < tasks.length; i++) ...[
                                        _PlannerTaskRow(
                                          key: ValueKey(
                                            'planner-task-${tasks[i].id}',
                                          ),
                                          plannerUid: planner.uid,
                                          task: tasks[i],
                                        ),
                                        if (i != tasks.length - 1)
                                          Divider(
                                            height: 1,
                                            thickness: 1,
                                            color: AppHeaderDivider.colorOf(
                                              context,
                                            ),
                                          ),
                                      ],
                                    ],
                                  ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlannerTaskRow extends StatefulWidget {
  const _PlannerTaskRow({
    required this.plannerUid,
    required this.task,
    super.key,
  });

  final String plannerUid;
  final PlannerTask task;

  @override
  State<_PlannerTaskRow> createState() => _PlannerTaskRowState();
}

class _PlannerTaskRowState extends State<_PlannerTaskRow> {
  late final TextEditingController _title;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.task.title);
  }

  @override
  void didUpdateWidget(covariant _PlannerTaskRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.task.title != _title.text) {
      _title.value = TextEditingValue(
        text: widget.task.title,
        selection: TextSelection.collapsed(offset: widget.task.title.length),
      );
    }
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final current = widget.task.deadline;
    final selected = await showDatePicker(
      context: context,
      initialDate: current ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (selected == null || !mounted) {
      return;
    }
    final next = DateTime(
      selected.year,
      selected.month,
      selected.day,
      widget.task.deadlineHasTime ? current!.hour : 0,
      widget.task.deadlineHasTime ? current!.minute : 0,
    );
    await context.read<LibraryController>().updatePlannerTask(
      widget.plannerUid,
      widget.task.id,
      deadline: next,
    );
  }

  Future<void> _pickTime() async {
    final current = widget.task.deadline;
    if (current == null) {
      return;
    }
    final picked = await showTimePicker(
      context: context,
      initialTime: widget.task.deadlineHasTime
          ? TimeOfDay.fromDateTime(current)
          : const TimeOfDay(hour: 12, minute: 0),
    );
    if (picked == null || !mounted) {
      return;
    }
    await context.read<LibraryController>().updatePlannerTask(
      widget.plannerUid,
      widget.task.id,
      deadline: DateTime(
        current.year,
        current.month,
        current.day,
        picked.hour,
        picked.minute,
      ),
      deadlineHasTime: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final darkMode = Theme.of(context).brightness == Brightness.dark;
    final background = plannerTaskBackground(
      task.toneAt(DateTime.now()),
      darkMode: darkMode,
      completed: task.completed,
    );
    final ink = (darkMode ? AppColors.darkText : AppColors.inkBlack)
        .withValues(alpha: task.completed ? 0.7 : 1);
    final library = context.read<LibraryController>();

    final deadlineControls = <Widget>[
      if (task.deadline != null)
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 210),
          child: Container(
            key: ValueKey('planner-task-deadline:${task.id}'),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              border: Border.all(color: ink.withValues(alpha: 0.5)),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '${task.deadline!.day.toString().padLeft(2, '0')}.'
              '${task.deadline!.month.toString().padLeft(2, '0')}.'
              '${task.deadline!.year}'
              '${task.deadlineHasTime ? ' ${TimeOfDay.fromDateTime(task.deadline!).format(context)}' : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: ink,
                fontSize: AppTypography.small,
              ),
            ),
          ),
        ),
      IconButton(
        key: ValueKey('planner-task-date:${task.id}'),
        tooltip: task.deadline == null ? 'Add deadline' : 'Change date',
        icon: const Icon(Icons.event_outlined, size: 19),
        color: ink,
        visualDensity: VisualDensity.compact,
        onPressed: _pickDate,
      ),
      if (task.deadline != null) ...[
        IconButton(
          tooltip: task.deadlineHasTime ? 'Change time' : 'Add time',
          icon: const Icon(Icons.schedule_outlined, size: 19),
          color: ink,
          visualDensity: VisualDensity.compact,
          onPressed: _pickTime,
        ),
        IconButton(
          tooltip: task.deadlineHasTime ? 'Remove time' : 'Remove deadline',
          icon: Icon(
            task.deadlineHasTime
                ? Icons.timer_off_outlined
                : Icons.event_busy_outlined,
            size: 18,
          ),
          color: ink,
          visualDensity: VisualDensity.compact,
          onPressed: () => unawaited(
            library.updatePlannerTask(
              widget.plannerUid,
              task.id,
              clearDeadline: !task.deadlineHasTime,
              deadlineHasTime: false,
            ),
          ),
        ),
        if (task.deadlineHasTime)
          IconButton(
            tooltip: 'Remove deadline',
            icon: const Icon(Icons.event_busy_outlined, size: 18),
            color: ink,
            visualDensity: VisualDensity.compact,
            onPressed: () => unawaited(
              library.updatePlannerTask(
                widget.plannerUid,
                task.id,
                clearDeadline: true,
              ),
            ),
          ),
      ],
    ];

    return Container(
      key: ValueKey('planner-task-row:${task.id}'),
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 760;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Checkbox(
                    key: ValueKey('planner-task-check:${task.id}'),
                    value: task.completed,
                    checkColor: background,
                    activeColor: ink,
                    side: BorderSide(color: ink, width: 1.5),
                    onChanged: (value) => unawaited(
                      library.updatePlannerTask(
                        widget.plannerUid,
                        task.id,
                        completed: value ?? false,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: TextField(
                      key: ValueKey('planner-task-name:${task.id}'),
                      controller: _title,
                      autofocus: task.title.isEmpty,
                      maxLines: 1,
                      maxLength: 200,
                      style: TextStyle(
                        color: ink,
                        fontSize: AppTypography.document,
                        decoration: task.completed
                            ? TextDecoration.lineThrough
                            : null,
                        decorationColor: ink,
                      ),
                      cursorColor: ink,
                      decoration: InputDecoration(
                        hintText: 'Task name',
                        hintStyle: TextStyle(
                          color: ink.withValues(alpha: 0.68),
                        ),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        isDense: true,
                        counterText: '',
                        filled: false,
                      ),
                      onChanged: (value) => unawaited(
                        library.updatePlannerTask(
                          widget.plannerUid,
                          task.id,
                          title: value,
                        ),
                      ),
                    ),
                  ),
                  if (!narrow)
                    Flexible(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Wrap(
                          alignment: WrapAlignment.end,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 2,
                          runSpacing: 2,
                          children: deadlineControls,
                        ),
                      ),
                    ),
                  IconButton(
                    key: ValueKey('planner-task-delete:${task.id}'),
                    tooltip: 'Delete task',
                    onPressed: () => unawaited(
                      library.removePlannerTask(widget.plannerUid, task.id),
                    ),
                    icon: const Icon(Icons.delete_outline, size: 19),
                    color: ink,
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              if (narrow)
                Padding(
                  padding: const EdgeInsets.only(left: 50),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 2,
                      runSpacing: 2,
                      children: deadlineControls,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
