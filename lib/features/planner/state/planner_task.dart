enum PlannerTaskTone { undated, upcoming, overdue, completed }

class PlannerTask {
  const PlannerTask({
    required this.id,
    required this.title,
    this.completed = false,
    this.deadline,
    this.deadlineHasTime = false,
  });

  final String id;
  final String title;
  final bool completed;
  final DateTime? deadline;
  final bool deadlineHasTime;

  PlannerTaskTone toneAt(DateTime now) {
    if (deadline == null) {
      return PlannerTaskTone.undated;
    }
    if (completed) {
      return PlannerTaskTone.completed;
    }
    final due = deadlineHasTime
        ? deadline!
        : DateTime(deadline!.year, deadline!.month, deadline!.day + 1);
    return now.isBefore(due)
        ? PlannerTaskTone.upcoming
        : PlannerTaskTone.overdue;
  }

  PlannerTask copyWith({
    String? title,
    bool? completed,
    DateTime? deadline,
    bool clearDeadline = false,
    bool? deadlineHasTime,
  }) {
    return PlannerTask(
      id: id,
      title: title ?? this.title,
      completed: completed ?? this.completed,
      deadline: clearDeadline ? null : (deadline ?? this.deadline),
      deadlineHasTime: clearDeadline
          ? false
          : (deadlineHasTime ?? this.deadlineHasTime),
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'completed': completed,
    'deadline': deadline?.toIso8601String(),
    'deadlineHasTime': deadlineHasTime,
  };

  static PlannerTask? fromJson(Object? value) {
    if (value is! Map ||
        value['id'] is! String ||
        (value['id'] as String).isEmpty ||
        value['title'] is! String) {
      return null;
    }
    final rawDeadline = value['deadline'];
    final deadline = rawDeadline is String
        ? DateTime.tryParse(rawDeadline)?.toLocal()
        : null;
    return PlannerTask(
      id: value['id'] as String,
      title: value['title'] as String,
      completed: value['completed'] == true,
      deadline: deadline,
      deadlineHasTime: deadline != null && value['deadlineHasTime'] == true,
    );
  }
}
