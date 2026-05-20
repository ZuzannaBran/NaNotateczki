import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/app_theme.dart';
import '../data/backup/local_backup_service.dart';
import '../data/isar/isar_service.dart';
import '../data/sync/cloud_sync_service.dart';
import '../features/library/presentation/library_controller.dart';
import '../features/notebook/data/notebook_repository.dart';
import '../features/library/presentation/library_screen.dart';

class AppScope extends StatelessWidget {
  const AppScope({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<IsarOpenResult>(
      future: IsarService.open(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const MaterialApp(
            home: Scaffold(body: Center(child: CircularProgressIndicator())),
          );
        }

        final result = snapshot.data!;
        final isarService = result.service;

        late final NotebookRepository repository;
        late final LocalBackupService backupService;

        Future<void> runBackup() async {
          try {
            final items = await repository.fetchNotebooks();
            await backupService.snapshot(items);
          } catch (e) {
            debugPrint('AppScope backup hook failed: $e');
          }
        }

        repository = NotebookRepository(
          isarService.isar,
          onChanged: () => unawaited(runBackup()),
        );
        backupService = LocalBackupService(repository);
        final cloudSync = CloudSyncService(repository);

        return MultiProvider(
          providers: [
            Provider<NotebookRepository>.value(value: repository),
            Provider<LocalBackupService>.value(value: backupService),
            ChangeNotifierProvider(
              create: (_) => LibraryController(
                repository,
                cloudSync,
                backupService,
                wasReset: result.wasReset,
                freshFile: result.freshFile,
                resetReason: result.resetReason,
              ),
            ),
          ],
          child: MaterialApp(
            title: 'Notatek',
            theme: AppTheme.light(),
            home: const LibraryScreen(),
          ),
        );
      },
    );
  }
}
