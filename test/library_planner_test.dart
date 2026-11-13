import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:program/core/input/app_preferences_controller.dart';
import 'package:program/core/storage/text_storage.dart';
import 'package:program/core/theme/app_colors.dart';
import 'package:program/core/theme/app_theme.dart';
import 'package:program/data/backup/local_backup_service.dart';
import 'package:program/data/drift/notes_database.dart';
import 'package:program/features/editor/presentation/editor_settings_screen.dart';
import 'package:program/features/library/presentation/library_controller.dart';
import 'package:program/features/library/presentation/library_screen.dart';
import 'package:program/features/notebook/data/notebook_repository.dart';
import 'package:program/features/notebook/domain/notebook.dart';
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
    final todayAllDay = upcoming.copyWith(deadline: DateTime(2026, 10, 20));
    final timed = upcoming.copyWith(
      deadline: DateTime(2026, 10, 20, 15),
      deadlineHasTime: true,
    );

    expect(undated.toneAt(now), PlannerTaskTone.undated);
    expect(
      undated.copyWith(completed: true).toneAt(now),
      PlannerTaskTone.completed,
    );
    expect(upcoming.toneAt(now), PlannerTaskTone.upcoming);
    expect(late.toneAt(now), PlannerTaskTone.overdue);
    expect(done.toneAt(now), PlannerTaskTone.completed);
    expect(todayAllDay.toneAt(now), PlannerTaskTone.upcoming);
    expect(timed.toneAt(now), PlannerTaskTone.overdue);
    expect(
      PlannerTask.fromJson(upcoming.toJson())!.deadline,
      upcoming.deadline,
    );
    expect(upcoming.copyWith(clearDeadline: true).deadlineHasTime, isFalse);
    expect(PlannerTask.fromJson({'title': 'Bad'}), isNull);
  });

  test('planner tones match the sidebar and keep overdue light', () {
    for (final theme in [AppTheme.light(), AppTheme.dark()]) {
      final darkMode = theme.brightness == Brightness.dark;
      final sidebar = theme.colorScheme.surfaceContainerLowest;

      expect(
        plannerTaskBackground(PlannerTaskTone.undated, theme: theme),
        sidebar,
      );
      expect(
        plannerTaskBackground(PlannerTaskTone.completed, theme: theme),
        sidebar,
      );
      expect(
        plannerTaskBackground(PlannerTaskTone.upcoming, theme: theme),
        darkMode ? AppColors.darkCanvas : AppColors.background,
      );
      expect(
        plannerTaskBackground(PlannerTaskTone.overdue, theme: theme),
        darkMode ? AppColors.darkPaper : AppColors.paper,
      );
    }
  });

  test('planner tasks survive reload, updates and deletion', () async {
    final db = NotesDatabase(NativeDatabase.memory());
    final repository = NotebookRepository(db);
    LibraryController newLibrary() =>
        LibraryController(repository, LocalBackupService(repository));
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
        planner.uid: library
            .plannerTasks(planner.uid)
            .map((item) => item.toJson())
            .toList(),
      },
    );
    final decoded = repository.decodePortableBackup(portable);
    expect(decoded.plannerTasks.containsKey(planner.uid), isTrue);
    expect((decoded.plannerTasks[planner.uid] as List), hasLength(1));
    final payload =
        jsonDecode((await readStoredText('library_folders.json'))!)
            as Map<String, dynamic>;
    expect((payload['plannerTasks'] as Map)[planner.uid], hasLength(1));

    final restored = newLibrary();
    await restored.initialize();
    final result = restored.plannerTasks(planner.uid).single;
    expect(result.id, task.id);
    expect(result.title, 'Finish assignment');
    expect(result.completed, isTrue);
    expect(result.deadlineHasTime, isTrue);
    expect(result.deadline!.hour, 17);
    final second = await restored.addPlannerTask(planner.uid);
    expect(restored.plannerTasks(planner.uid).map((item) => item.id).toList(), [
      second.id,
      result.id,
    ]);
    await restored.flushPlannerTasks();
    final saved =
        jsonDecode((await readStoredText('library_folders.json'))!)
            as Map<String, dynamic>;
    saved['plannerCompletedLast'] = {planner.uid: false};
    await writeStoredText('library_folders.json', jsonEncode(saved));

    final legacy = newLibrary();
    await legacy.initialize();
    expect(legacy.plannerTasks(planner.uid).map((item) => item.id).toList(), [
      second.id,
      result.id,
    ]);
    legacy.dispose();

    await restored.updatePlannerTask(planner.uid, result.id, completed: false);
    expect(restored.plannerTasks(planner.uid).map((item) => item.id).toList(), [
      result.id,
      second.id,
    ]);
    await restored.updatePlannerTask(planner.uid, result.id, completed: true);
    expect(restored.plannerTasks(planner.uid).map((item) => item.id).toList(), [
      second.id,
      result.id,
    ]);

    await restored.updatePlannerTask(
      planner.uid,
      result.id,
      clearDeadline: true,
    );
    await restored.flushPlannerTasks();
    expect(
      restored
          .plannerTasks(planner.uid)
          .firstWhere((item) => item.id == result.id)
          .deadline,
      isNull,
    );

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
    addTearDown(db.close);
    final repository = NotebookRepository(db);
    final library = LibraryController(
      repository,
      LocalBackupService(repository),
    );
    addTearDown(library.dispose);
    late Notebook planner;
    await tester.runAsync(() async {
      await library.initialize();
      planner = await library.createPlanner();
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<LibraryController>.value(
        value: library,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: TaskListScreen(planner: planner, onSettings: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No tasks yet. Add your first task.'), findsOneWidget);
    expect(find.byKey(const ValueKey('planner-completed-last')), findsNothing);
    final addButton = tester.widget<FilledButton>(
      find.byKey(const ValueKey('planner-add-task')),
    );
    expect(addButton.style!.backgroundColor!.resolve({}), AppColors.toolbar);
    await tester.tap(find.byKey(const ValueKey('planner-add-task')));
    await tester.pumpAndSettle();
    final task = library.plannerTasks(planner.uid).single;
    final row = find.byKey(ValueKey('planner-task-row:${task.id}'));
    expect(tester.widget<Container>(row).color, AppColors.toolbar);
    expect(
      find.byKey(ValueKey('planner-task-deadline:${task.id}')),
      findsNothing,
    );

    final deleteButton = find.byKey(ValueKey('planner-task-delete:${task.id}'));
    final originalDeleteRight = tester.getTopRight(deleteButton).dx;
    await tester.enterText(
      find.byKey(ValueKey('planner-task-name:${task.id}')),
      'Read chapter',
    );
    await tester.pump();
    expect(library.plannerTasks(planner.uid).single.title, 'Read chapter');

    final taskName = find.byKey(ValueKey('planner-task-name:${task.id}'));
    final taskCheckbox = find.byKey(ValueKey('planner-task-check:${task.id}'));
    final dateButton = find.byKey(ValueKey('planner-task-date:${task.id}'));
    final shortRowHeight = tester.getSize(row).height;
    final checkboxTop =
        tester.getTopLeft(taskCheckbox).dy - tester.getTopLeft(row).dy;
    final trailingMargin =
        tester.getTopRight(row).dx - tester.getTopRight(deleteButton).dx;
    expect(
      tester.getTopLeft(dateButton).dx - tester.getTopRight(taskName).dx,
      closeTo(trailingMargin, 1),
    );

    await library.updatePlannerTask(
      planner.uid,
      task.id,
      deadline: DateTime.now().add(const Duration(days: 1)),
      deadlineHasTime: true,
    );
    await tester.pump();
    final deadline = find.byKey(ValueKey('planner-task-deadline:${task.id}'));
    expect(deadline, findsOneWidget);
    expect(
      tester.getTopRight(deleteButton).dx,
      closeTo(originalDeleteRight, 1),
    );
    expect(
      tester.getTopLeft(deadline).dx - tester.getTopRight(taskName).dx,
      closeTo(trailingMargin, 1),
    );

    final longTitle = List.filled(7, 'Read and review the notes').join(' ');
    await tester.enterText(taskName, longTitle);
    await tester.pump();
    expect(library.plannerTasks(planner.uid).single.title, longTitle);
    expect(tester.widget<TextField>(taskName).maxLines, isNull);
    expect(tester.getSize(row).height, greaterThan(shortRowHeight));
    expect(
      tester.getTopLeft(taskCheckbox).dy - tester.getTopLeft(row).dy,
      closeTo(checkboxTop, 1),
    );
    expect(
      tester.getTopLeft(deadline).dx - tester.getTopRight(taskName).dx,
      closeTo(trailingMargin, 1),
    );

    await tester.binding.setSurfaceSize(const Size(370, 800));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getSize(row).height, greaterThan(shortRowHeight));
    expect(
      tester.getTopLeft(taskCheckbox).dy - tester.getTopLeft(row).dy,
      closeTo(checkboxTop, 1),
    );
    expect(
      tester.getTopLeft(deleteButton).dx - tester.getTopRight(taskName).dx,
      closeTo(
        tester.getTopRight(row).dx - tester.getTopRight(deleteButton).dx,
        1,
      ),
    );
    expect(
      find.byKey(ValueKey('planner-task-date:${task.id}')),
      findsOneWidget,
    );
    expect(
      tester.getTopRight(deleteButton).dx,
      closeTo(
        tester
            .getTopRight(find.byKey(ValueKey('planner-task-date:${task.id}')))
            .dx,
        1,
      ),
    );

    await library.updatePlannerTask(
      planner.uid,
      task.id,
      deadline: DateTime.now().subtract(const Duration(days: 1)),
    );
    await tester.pump();
    expect(tester.widget<Container>(row).color, AppColors.paper);

    await tester.tap(find.byKey(ValueKey('planner-task-check:${task.id}')));
    await tester.pump();
    expect(library.plannerTasks(planner.uid).single.completed, isTrue);
    expect(tester.widget<Container>(row).color, AppColors.toolbar);
    final rowOpacity = find.ancestor(of: row, matching: find.byType(Opacity));
    expect(rowOpacity, findsOneWidget);
    expect(tester.widget<Opacity>(rowOpacity).opacity, 0.6);
    await tester.tap(find.byKey(ValueKey('planner-task-delete:${task.id}')));
    await tester.pump();
    expect(library.plannerTasks(planner.uid), isEmpty);
    await tester.runAsync(library.flushPlannerTasks);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('planner header stays aligned and settings avoid editor', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final db = NotesDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repository = NotebookRepository(db);
    late Notebook planner;
    await tester.runAsync(() async {
      planner = await repository.createPlanner(
        title: 'New Planner',
        folder: 'Planner folder',
      );
    });
    final library = LibraryController(
      repository,
      LocalBackupService(repository),
    );
    addTearDown(library.dispose);
    await tester.runAsync(library.loadItems);
    final preferences = AppPreferencesController();
    addTearDown(preferences.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<LibraryController>.value(value: library),
          ChangeNotifierProvider<AppPreferencesController>.value(
            value: preferences,
          ),
          Provider<NotebookRepository>.value(value: repository),
        ],
        child: const MaterialApp(home: LibraryScreen()),
      ),
    );
    await tester.pumpAndSettle();
    final plannerRow = find.byKey(ValueKey('library-tree-item:${planner.uid}'));
    expect(
      find.descendant(
        of: plannerRow,
        matching: find.byIcon(Icons.check_box_outlined),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: plannerRow,
        matching: find.byIcon(Icons.checklist_rounded),
      ),
      findsNothing,
    );
    await tester.tap(plannerRow);
    await tester.pumpAndSettle();
    expect(find.byType(TaskListScreen), findsOneWidget);
    final tasksSurface = find.byKey(const ValueKey('planner-tasks-surface'));
    final box = tester.widget<DecoratedBox>(tasksSurface);
    expect(
      (box.decoration as BoxDecoration).borderRadius,
      BorderRadius.circular(12),
    );
    final clip = find.descendant(
      of: tasksSurface,
      matching: find.byType(ClipRRect),
    );
    expect(
      tester.widget<ClipRRect>(clip).borderRadius,
      BorderRadius.circular(12),
    );

    expect(find.byKey(const ValueKey('planner-completed-last')), findsNothing);

    final title = find.byKey(const ValueKey('workspace-document-title'));
    final toggle = find.byKey(const ValueKey('library-navigation-toggle'));
    expect(
      tester.getTopLeft(title).dx,
      greaterThan(tester.getRect(toggle).right),
    );
    expect(find.byTooltip('Settings'), findsOneWidget);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(EditorSettingsScreen), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('projects-home')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(EditorSettingsScreen), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
