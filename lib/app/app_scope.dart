import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/error/app_error_log.dart';
import '../core/input/app_preferences_controller.dart';
import '../core/theme/app_theme.dart';
import '../data/backup/local_backup_service.dart';
import '../data/isar/isar_service.dart';
import '../data/sync/cloud_sync_service.dart';
import '../features/library/presentation/library_controller.dart';
import '../features/library/presentation/library_screen.dart';
import '../features/notebook/data/notebook_repository.dart';

class AppScope extends StatefulWidget {
  const AppScope({super.key});

  @override
  State<AppScope> createState() => _AppScopeState();
}

class _AppScopeState extends State<AppScope> {
  late final Future<IsarOpenResult> _openFuture = IsarService.open();
  NotebookRepository? _repository;
  LocalBackupService? _backupService;
  CloudSyncService? _cloudSync;
  _BackupScheduler? _backupScheduler;
  bool _openErrorRecorded = false;

  @override
  void dispose() {
    _backupScheduler?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<IsarOpenResult>(
      future: _openFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          if (!_openErrorRecorded) {
            _openErrorRecorded = true;
            AppErrorLog.instance.record(
              snapshot.error!,
              snapshot.stackTrace,
              source: 'App bootstrap',
            );
          }
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            title: 'Notatek',
            theme: AppTheme.light(),
            home: const _StartupErrorScreen(),
          );
        }

        if (!snapshot.hasData) {
          return const MaterialApp(
            home: Scaffold(body: Center(child: CircularProgressIndicator())),
          );
        }

        final result = snapshot.data!;
        final isarService = result.service;

        final repository =
            _repository ??
            NotebookRepository(
              isarService.isar,
              onChanged: () => _backupScheduler?.schedule(),
            );
        _repository = repository;
        final backupService = _backupService ?? LocalBackupService(repository);
        _backupService = backupService;
        final cloudSync = _cloudSync ?? CloudSyncService(repository);
        _cloudSync = cloudSync;
        _backupScheduler ??= _BackupScheduler(
          repository: repository,
          backupService: backupService,
        );

        return MultiProvider(
          providers: [
            ChangeNotifierProvider(
              create: (_) => AppPreferencesController()..load(),
            ),
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
            debugShowCheckedModeBanner: false,
            title: 'Notatek',
            theme: AppTheme.light(),
            home: const LibraryScreen(),
          ),
        );
      },
    );
  }
}

class _StartupErrorScreen extends StatelessWidget {
  const _StartupErrorScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Startup error')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'The app could not finish startup.',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Copy the error details and send them with your test report.',
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(
                        text: AppErrorLog.instance.toClipboardText(),
                      ),
                    );
                    if (!context.mounted) {
                      return;
                    }
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Errors copied.')),
                    );
                  },
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy errors'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BackupScheduler with WidgetsBindingObserver {
  _BackupScheduler({required this.repository, required this.backupService}) {
    WidgetsBinding.instance.addObserver(this);
  }

  static const Duration _idleDelay = Duration(seconds: 8);

  final NotebookRepository repository;
  final LocalBackupService backupService;
  Timer? _timer;
  bool _dirty = false;
  bool _isRunning = false;

  void schedule() {
    _dirty = true;
    _timer?.cancel();
    _timer = Timer(_idleDelay, () {
      unawaited(flush(reason: 'idle'));
    });
  }

  Future<void> flush({required String reason}) async {
    _timer?.cancel();
    _timer = null;
    if (!_dirty) {
      return;
    }
    if (_isRunning) {
      _dirty = true;
      return;
    }
    _dirty = false;
    _isRunning = true;
    try {
      final items = await repository.fetchNotebooks();
      if (repository.lastFetchSkippedCorruptRows) {
        return;
      }
      await backupService.snapshot(items);
    } catch (e) {
      debugPrint('BackupScheduler.flush failed: $e');
    } finally {
      _isRunning = false;
      if (_dirty) {
        schedule();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(flush(reason: state.name));
    }
  }

  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
  }
}
