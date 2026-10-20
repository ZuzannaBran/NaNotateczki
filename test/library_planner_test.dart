import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:program/core/storage/text_storage.dart';
import 'package:program/core/theme/app_colors.dart';
import 'package:program/data/backup/local_backup_service.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/data/sync/cloud_sync_service.dart';
import 'package:program/features/library/presentation/library_controller.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/notebook_kind.dart';
import 'package:program/features/planner/presentation/task_list_screen.dart';
import 'package:program/features/planner/state/planner_task.dart';

import 'support/native_test_documents.dart';

void main() {
  useIsolatedNativeTestDocuments();
  useInMemoryTestTextStorage();

  test('deadline colors follow status, not the absence of a deadline', () {
    final now = DateTime(2026, 10, 20, 16);
    const undated = PlannerTask(id: 'a', title: 'Undated');
    final upcoming = PlannerTask(
      id: 'b',
      title: 'Upcoming',
      deadline: DateTime(2026, 10, 21),
    );
    final late = PlannerTask(
      id: 'c',
      title: 'Late',
      deadline: DateTime(2026, 10, 19),
    );
    final done = late.copyWith(completed: true);
    final todayAllDay = upcoming.copyWith(
      deadline: DateTime(2026, 10, 20),
    );
    final timed = upcoming.copyWith(
      deadline: DateTime(2026, 10, 20, 15),
      deadlineHasTime: true,
    );

    expect(undated.toneAt(now), PlannerTaskTone.undated);
    expect(undated.copyWith(completed: true).toneAt(now),
        PlannerTaskTone.undated);
    expect(upcoming.toneAt(now), PlannerTaskTone.upcoming);
    expect(late.toneAt(now), PlannerTaskTone.overdue);
    expect(done.toneAt(now), PlannerTaskTone.completed);
    expect(todayAllDay.toneAt(now), PlannerTaskTone.upcoming);
    expect(timed.toneAt(now), PlannerTaskTone.overdue);
    expect(
      PlannerTask.fromJson(upcoming.toJson())!.deadline,
      upcoming.deadline,
    );
    expect(
      upcoming.copyWith(clearDeadline: true).deadlineHasTime,
      isFalse,
    );
    expect(PlannerTask.fromJson({'title': 'Bad'}), isNull);
  });

  test('planner rows use beige tones and fade completed tasks', () {
    expect(
      plannerTaskBackground(PlannerTaskTone.undated, darkMode: false),
      AppColors.background,
    );
    expect(
      plannerTaskBackground(PlannerTaskTone.upcoming, darkMode: false),
      AppColors.toolbar,
    );
    expect(
      plannerTaskBackground(PlannerTaskTone.overdue, darkMode: false),
      AppColors.divider,
    );
    expect(
      plannerTaskBackground(PlannerTaskTone.undated, darkMode: true),
      AppColors.darkCanvas,
    );
    expect(
      plannerTaskBackground(
        PlannerTaskTone.completed,
        darkMode: false,
        completed: true,
      ),
      isNot(AppColors.background),
    );
    expect(
      plannerTaskBackground(
        PlannerTaskTone.completed,
        darkMode: true,
        completed: true,
      ),
      isNot(AppColors.darkCanvas),
    );
  });

  test('planner tasks survive reload, updates and deletion', () async {
    final db = NotesDatabase(NativeDatabase.memory());
    final repository = NotebookRepository(db);
    LibraryController newLibrary() => LibraryController(
      repository,
      CloudSyncService(repository),
      LocalBackupService(repository),
    );
    final library = newLibrary();
    await library.initialize();
    final planner = await library.createPlanner();
    expect(planner.kind, NotebookKind.planner);

    final task = await library.addPlannerTask(planner.uid);
    await library.updatePlannerTask(
      planner.uid,
      task.id,
      title: 'Finish assignment',
      deadline: DateTime(2026, 10, 21, 17, 30),
      deadlineHasTime: true,
      completed: true,
    );
    await library.flushPlannerTasks();
    final portable = repository.encodePortableBackup(
      await repository.fetchNotebooks(),
      folders: library.folderNames,
      plannerTasks: {
        planner.uid: library.plannerTasks(planner.uid)
            .map((item) => item.toJson())
            .toList(),
      },
    );
    final decoded = repository.decodePortableBackup(portable);
    expect(decoded.plannerTasks.containsKey(planner.uid), isTrue);
    expect((decoded.plannerTasks[planner.uid] as List), hasLength(1));
    final payload = jsonDecode((await readStoredText(
      'library_folders.json',
    ))!) as Map<String, dynamic>;
    expect((payload['plannerTasks'] as Map)[planner.uid], hasLength(1));

    final restored = newLibrary();
    await restored.initialize();
    final result = restored.plannerTasks(planner.uid).single;
    expect(result.id, task.id);
    expect(result.title, 'Finish assignment');
    expect(result.completed, isTrue);
    expect(result.deadlineHasTime, isTrue);
    expect(result.deadline!.hour, 17);
    expect(restored.plannerCompletedLast(planner.uid), isTrue);

    final second = await restored.addPlannerTask(planner.uid);
    expect(
      restored.plannerTasks(planner.uid).map((task) => task.id).toList(),
      [second.id, result.id],
    );
    await restored.setPlannerCompletedLast(planner.uid, false);
    expect(
      restored.plannerTasks(planner.uid).map((task) => task.id).toList(),
      [result.id, second.id],
    );
    await restored.flushPlannerTasks();
    final withSavedSetting = newLibrary();
    await withSavedSetting.initialize();
    expect(withSavedSetting.plannerCompletedLast(planner.uid), isFalse);
    withSavedSetting.dispose();

    await restored.updatePlannerTask(
      planner.uid,
      result.id,
      clearDeadline: true,
    );
    await restored.flushPlannerTasks();
    expect(restored.plannerTasks(planner.uid).single.deadline, isNull);

    await restored.removePlannerTask(planner.uid, result.id);
    await restored.removePlannerTask(planner.uid, second.id);
    await restored.flushPlannerTasks();
    expect(restored.plannerTasks(planner.uid), isEmpty);

    await restored.deleteItem(planner.uid);
    await restored.flushPlannerTasks();
    final empty = newLibrary();
    await empty.initialize();
    expect(empty.plannerTasks(planner.uid), isEmpty);
    expect(empty.items.where((item) => item.uid == planner.uid), isEmpty);
    empty.dispose();
    restored.dispose();
    library.dispose();
    await db.close();
  });

  testWidgets('task canvas creates, edits, checks and deletes rows', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(950, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final db = NotesDatabase(NativeDatabase.memory());
    final repository = NotebookRepository(db);
    final library = LibraryController(
      repository,
      CloudSyncService(repository),
      LocalBackupService(repository),
    );
    await library.initialize();
    final planner = await library.createPlanner();

    await tester.pumpWidget(
      ChangeNotifierProvider<LibraryController>.value(
        value: library,
        child: MaterialApp(home: TaskListScreen(planner: planner)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No tasks yet. Add your first task.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('planner-add-task')));
    await tester.pumpAndSettle();
    final task = library.plannerTasks(planner.uid).single;
    expect(
      find.byKey(ValueKey('planner-task-deadline:${task.id}')),
      findsNothing,
    );

    final deleteButton = find.byKey(
      ValueKey('planner-task-delete:${task.id}'),
    );
    final originalDeleteRight = tester.getTopRight(deleteButton).dx;
    await tester.enterText(
      find.byKey(ValueKey('planner-task-name:${task.id}')),
      'Read chapter',
    );
    await tester.pump();
    expect(library.plannerTasks(planner.uid).single.title, 'Read chapter');
    await library.updatePlannerTask(
      planner.uid,
      task.id,
      deadline: DateTime.now().add(const Duration(days: 1)),
    );
    await tester.pump();
    expect(
      find.byKey(ValueKey('planner-task-deadline:${task.id}')),
      findsOneWidget,
    );
    expect(
      tester.getTopRight(deleteButton).dx,
      closeTo(originalDeleteRight, 1),
    );
    await tester.binding.setSurfaceSize(const Size(370, 800));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(ValueKey('planner-task-date:${task.id}')), findsOneWidget);
    expect(
      tester.getTopRight(deleteButton).dx,
      greaterThan(tester.getTopRight(
        find.byKey(ValueKey('planner-task-date:${task.id}')),
      ).dx),
    );

    await tester.tap(
      find.byKey(ValueKey('planner-task-check:${task.id}')),
    );
    await tester.pump();
    expect(library.plannerTasks(planner.uid).single.completed, isTrue);
    await tester.tap(
      find.byKey(ValueKey('planner-task-delete:${task.id}')),
    );
    await tester.pump();
    expect(library.plannerTasks(planner.uid), isEmpty);
    await library.flushPlannerTasks();
    await tester.pumpWidget(const SizedBox.shrink());
    library.dispose();
    await db.close();
  });
}
