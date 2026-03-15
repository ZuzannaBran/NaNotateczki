import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme/app_theme.dart';
import '../data/isar/isar_service.dart';
import '../data/sync/cloud_sync_service.dart';
import '../features/library/presentation/library_controller.dart';
import '../features/notebook/data/notebook_repository.dart';
import '../features/library/presentation/library_screen.dart';

class AppScope extends StatelessWidget {
  const AppScope({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<IsarService>(
      future: IsarService.open(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const MaterialApp(
            home: Scaffold(body: Center(child: CircularProgressIndicator())),
          );
        }

        final isarService = snapshot.data!;
        final repository = NotebookRepository(isarService.isar);
        final cloudSync = CloudSyncService(repository);

        return MultiProvider(
          providers: [
            Provider<NotebookRepository>.value(value: repository),
            ChangeNotifierProvider(
              create: (_) => LibraryController(repository, cloudSync),
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
