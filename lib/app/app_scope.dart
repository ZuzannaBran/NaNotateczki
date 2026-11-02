import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/diagnostics/frame_timing_tracker.dart';
import '../core/diagnostics/optimization_log.dart';
import '../core/error/app_error_log.dart';
import '../core/input/app_preferences_controller.dart';
import '../core/input/app_scroll_behavior.dart';
import '../core/input/ink_activity_tracker.dart';
import '../core/storage/app_save_coordinator.dart';
import '../core/theme/app_theme.dart';
import '../data/backup/local_backup_service.dart';
import '../data/backup/remote_backup_service.dart';
import '../data/backup/remote_backup_scheduler.dart';
import '../data/drift/notes_database.dart';
import '../data/sync/account_session_controller.dart';
import '../data/sync/account_settings_sync_service.dart';
import '../data/sync/api_client.dart';
import '../data/sync/app_activity_wake_service.dart';
import '../data/sync/cloud_sync_service.dart';
import '../data/sync/diagnostics_upload_service.dart';
import '../data/sync/live_web_sync_service.dart';
import '../data/sync/planner_sync_service.dart';
import '../features/editor/state/ink_color_presets.dart';
import '../features/library/presentation/library_controller.dart';
import '../features/library/presentation/library_screen.dart';
import '../features/notebook/data/notebook_repository.dart';
import '../features/notebook/domain/notebook.dart';
import '../features/planner/state/study_planner_controller.dart';

class AppScope extends StatefulWidget {
  const AppScope({super.key});

  @override
  State<AppScope> createState() => _AppScopeState();
}

class _AppScopeState extends State<AppScope> with WidgetsBindingObserver {
  late final Future<DatabaseOpenResult> _openFuture = NotesDatabase.open();
  NotebookRepository? _repository;
  LocalBackupService? _backupService;
  CloudSyncService? _cloudSync;
  ApiClient? _apiClient;
  AppActivityWakeService? _activityWake;
  AccountSessionController? _accountSession;
  RemoteBackupService? _remoteBackupService;
  RemoteBackupScheduler? _remoteBackupScheduler;
  LiveWebSyncService? _liveSync;
  AccountSettingsSyncService? _accountSettingsSync;
  PlannerSyncService? _plannerSync;
  Future<void>? _plannerReady;
  Timer? _plannerDebounce;
  DiagnosticsUploadService? _diagnosticsUpload;
  Timer? _settingsPoll;
  Timer? _settingsDebounce;
  int? _observedIdleSeconds;
  LibraryController? _libraryController;
  AppPreferencesController? _preferences;
  StudyPlannerController? _studyPlanner;
  _BackupScheduler? _backupScheduler;
  Future<void>? _accountBootstrap;
  String? _bootstrappedAccount;
  final ValueNotifier<bool> _finishingExit = ValueNotifier<bool>(false);
  Future<void>? _exitDrain;
  bool _allowExit = false;
  bool _openErrorRecorded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_handleGlobalKeyEvent);
    FrameTimingTracker.instance.initialize();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_handleGlobalKeyEvent);
    _activityWake?.dispose();
    _settingsPoll?.cancel();
    _settingsDebounce?.cancel();
    _plannerDebounce?.cancel();
    _plannerSync?.stop();
    _backupScheduler?.dispose();
    _remoteBackupScheduler?.dispose();
    _liveSync?.dispose();
    final scheduler = _remoteBackupScheduler;
    if (scheduler != null) {
      SharedRecentColors.revision.removeListener(scheduler.markDirty);
      scheduler.removeListener(_onBackupDelayChanged);
    }
    SharedRecentColors.revision.removeListener(_scheduleAccountSettingsSync);
    _preferences?.removeListener(_scheduleAccountSettingsSync);
    _libraryController?.dispose();
    _preferences?.dispose();
    if (scheduler != null) {
      _studyPlanner?.savedRevision.removeListener(scheduler.markDirty);
    }
    _studyPlanner?.savedRevision.removeListener(_schedulePlannerSync);
    _studyPlanner?.dispose();
    _diagnosticsUpload?.dispose();
    _accountSession?.dispose();
    _apiClient?.close();
    final backupService = _backupService;
    if (backupService != null) {
      unawaited(backupService.dispose());
    }
    _finishingExit.dispose();
    super.dispose();
  }

  bool get _hasPendingExitWork {
    final repository = _repository;
    final backupService = _backupService;
    final scheduler = _backupScheduler;
    return InkActivityTracker.instance.hasActiveContacts ||
        AppSaveCoordinator.instance.hasPendingWork ||
        (repository?.hasPendingSaves ?? false) ||
        (scheduler?.hasPendingWork ?? false) ||
        (backupService?.snapshotInProgress.value ?? false);
  }

  @override
  Future<ui.AppExitResponse> didRequestAppExit() async {
    if (_allowExit || !_hasPendingExitWork) {
      return ui.AppExitResponse.exit;
    }
    _exitDrain ??= _finishPendingWorkAndExit();
    return ui.AppExitResponse.cancel;
  }

  Future<void> _finishPendingWorkAndExit() async {
    final repository = _repository;
    final backupService = _backupService;
    final scheduler = _backupScheduler;
    if (repository == null || backupService == null || scheduler == null) {
      _allowExit = true;
      await ServicesBinding.instance.exitApplication(ui.AppExitType.required);
      return;
    }

    _finishingExit.value = true;
    try {
      await InkActivityTracker.instance.waitForNoActiveContacts();
      for (var attempt = 0; attempt < 3; attempt++) {
        await AppSaveCoordinator.instance.flushPending();
        await repository.waitForPendingSaves();
        if (!AppSaveCoordinator.instance.hasPendingWork &&
            !repository.hasPendingSaves) {
          break;
        }
      }
      if (AppSaveCoordinator.instance.hasPendingWork ||
          repository.hasPendingSaves) {
        throw StateError('Pending editor saves did not settle.');
      }

      await scheduler.flushForExit();
      await backupService.waitUntilIdle();

      _allowExit = true;
      final response = await ServicesBinding.instance.exitApplication(
        ui.AppExitType.required,
      );
      if (response == ui.AppExitResponse.cancel) {
        _allowExit = false;
        scheduler.resumeAfterExitCancellation();
        _finishingExit.value = false;
      }
    } catch (error, stackTrace) {
      _allowExit = false;
      scheduler.resumeAfterExitCancellation();
      AppErrorLog.instance.record(
        error,
        stackTrace,
        source: 'AppScope.finishPendingWorkAndExit',
      );
      if (mounted) {
        _finishingExit.value = false;
      }
    } finally {
      if (!_allowExit) {
        _exitDrain = null;
      }
    }
  }

  bool _handleGlobalKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent) {
      _activityWake?.noteActivity();
    }
    return false;
  }

  void _updateActivityWakePermission(AccountSessionController session) {
    _activityWake?.setEnabled(
      session.profileLoaded && session.preferredMode == AccountDataMode.account,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _activityWake?.setForeground(state == AppLifecycleState.resumed);
    if (state == AppLifecycleState.resumed) {
      unawaited(_startAccountSync());
      unawaited(_syncAccountSettings());
      unawaited(_syncPlanner());
    }
  }

  void _scheduleAccountSettingsSync() {
    if (_accountSettingsSync?.isApplying ?? false) {
      return;
    }
    _settingsDebounce?.cancel();
    _settingsDebounce = Timer(const Duration(milliseconds: 400), () {
      unawaited(_syncAccountSettings());
    });
  }

  void _onBackupDelayChanged() {
    final delay = _remoteBackupScheduler?.idleSeconds;
    if (delay != null && delay != _observedIdleSeconds) {
      _observedIdleSeconds = delay;
      _scheduleAccountSettingsSync();
    }
  }

  Future<void> _syncAccountSettings() async {
    try {
      await _accountSettingsSync?.syncNow();
    } catch (error, stackTrace) {
      AppErrorLog.instance.record(
        error,
        stackTrace,
        source: 'AppScope.syncAccountSettings',
      );
    }
  }

  void _schedulePlannerSync() {
    _plannerDebounce?.cancel();
    _plannerDebounce = Timer(const Duration(milliseconds: 200), () {
      unawaited(_syncPlanner());
    });
  }

  Future<void> _syncPlanner() async {
    if (_bootstrappedAccount == null || _plannerSync == null) {
      return;
    }
    try {
      await _plannerSync!.syncNow();
    } catch (error, stackTrace) {
      AppErrorLog.instance.record(
        error,
        stackTrace,
        source: 'AppScope.syncPlanner',
      );
    }
  }

  Future<void> _startAccountSync() {
    final session = _accountSession;
    final backup = _remoteBackupService;
    final scheduler = _remoteBackupScheduler;
    final sync = _liveSync;
    final library = _libraryController;
    final preferences = _preferences;
    final planner = _studyPlanner;
    if (!mounted ||
        session == null ||
        !session.isSignedIn ||
        session.isBusy ||
        backup == null ||
        scheduler == null ||
        sync == null ||
        library == null ||
        preferences == null ||
        planner == null) {
      return Future<void>.value();
    }
    final userId = session.userId!;
    if (_bootstrappedAccount == userId) {
      return Future<void>.value();
    }
    final running = _accountBootstrap;
    if (running != null) {
      return running;
    }
    final future = () async {
      try {
        await _plannerReady;
        final restored = await backup.hydrateFromLatestAccountBackup();
        if (!mounted || session.userId != userId) {
          return;
        }
        if (restored) {
          await library.reloadFromAccount();
          await preferences.load();
          await planner.load();
        }
        // Settings use their own versioned account record rather than
        // replacing a newer device preference with a stale backup.
        await _syncAccountSettings();
        await sync.start(InitialSyncPolicy.mergeSafely);
        try {
          await _plannerSync?.syncNow();
        } catch (error, stackTrace) {
          AppErrorLog.instance.record(
            error,
            stackTrace,
            source: 'AppScope.initialPlannerSync',
          );
        }
        if (!mounted || session.userId != userId) {
          return;
        }
        _bootstrappedAccount = userId;
        scheduler.enableForSignedInAccount();
        _observedIdleSeconds = scheduler.idleSeconds;
        _settingsPoll?.cancel();
        _settingsPoll = Timer.periodic(const Duration(seconds: 45), (_) {
          unawaited(_syncAccountSettings());
          unawaited(_syncPlanner());
        });
      } catch (error, stackTrace) {
        sync.reportStartupFailure(error);
        AppErrorLog.instance.record(
          error,
          stackTrace,
          source: 'AppScope.startAccountSync',
        );
      }
    }();
    _accountBootstrap = future;
    return future.whenComplete(() {
      if (identical(_accountBootstrap, future)) {
        _accountBootstrap = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DatabaseOpenResult>(
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
            scrollBehavior: const AppScrollBehavior(),
            title: 'NaNotateczki',
            theme: AppTheme.light(),
            home: _StartupErrorScreen(error: snapshot.error!),
          );
        }

        if (!snapshot.hasData) {
          return const MaterialApp(
            scrollBehavior: AppScrollBehavior(),
            home: Scaffold(body: Center(child: CircularProgressIndicator())),
          );
        }

        final result = snapshot.data!;
        final repository =
            _repository ??
            NotebookRepository(
              result.database,
              onChanged: (changes) {
                _backupScheduler?.schedule(changes: changes);
                _remoteBackupScheduler?.markDirty();
                _liveSync?.enqueue(changes);
              },
            );
        _repository = repository;
        final backupService = _backupService ?? LocalBackupService(repository);
        _backupService = backupService;
        final cloudSync = _cloudSync ?? CloudSyncService(repository);
        _cloudSync = cloudSync;
        final apiClient = _apiClient ?? ApiClient();
        _apiClient = apiClient;
        _activityWake ??= AppActivityWakeService(apiClient: apiClient);
        final newAccountSession = _accountSession == null;
        final accountSession =
            _accountSession ??
            AccountSessionController(
              apiClient,
              onBeforeAccountRestore: () {
                _activityWake?.setEnabled(true);
              },
            );
        _accountSession = accountSession;
        _diagnosticsUpload ??= DiagnosticsUploadService(
          apiClient: apiClient,
          session: accountSession,
        );
        final remoteBackup =
            _remoteBackupService ??
            RemoteBackupService(
              repository: repository,
              apiClient: apiClient,
              session: accountSession,
            );
        _remoteBackupService = remoteBackup;
        final remoteBackupScheduler =
            _remoteBackupScheduler ??
            RemoteBackupScheduler(
              service: remoteBackup,
              session: accountSession,
            );
        _remoteBackupScheduler = remoteBackupScheduler;
        final liveSync =
            _liveSync ??
            LiveWebSyncService(
              repository: repository,
              apiClient: apiClient,
              session: accountSession,
              enableRealtime: true,
            );
        _liveSync = liveSync;
        _backupScheduler ??= _BackupScheduler(
          repository: repository,
          backupService: backupService,
        );
        final libraryController =
            _libraryController ??
            LibraryController(
              repository,
              cloudSync,
              backupService,
              wasReset: result.wasReset,
              freshFile: result.freshFile,
              resetReason: result.resetReason,
            );
        _libraryController = libraryController;
        liveSync.onRemoteApplied = libraryController.loadItems;
        liveSync.onPlannerChanged = _syncPlanner;
        final preferences =
            _preferences ?? (AppPreferencesController()..load());
        _preferences = preferences;
        final planner = _studyPlanner ?? StudyPlannerController();
        _studyPlanner = planner;
        _plannerReady ??= planner.load();
        _plannerSync ??= PlannerSyncService(
          apiClient: apiClient,
          session: accountSession,
          planner: planner,
        );
        _accountSettingsSync ??= AccountSettingsSyncService(
          apiClient: apiClient,
          session: accountSession,
          onRemoteApplied: () async {
            await preferences.load();
            await remoteBackupScheduler.refreshAccountPreference();
          },
        );
        if (newAccountSession) {
          preferences.addListener(remoteBackupScheduler.markDirty);
          preferences.addListener(_scheduleAccountSettingsSync);
          SharedRecentColors.revision.addListener(_scheduleAccountSettingsSync);
          remoteBackupScheduler.addListener(_onBackupDelayChanged);
          planner.savedRevision.addListener(remoteBackupScheduler.markDirty);
          planner.savedRevision.addListener(_schedulePlannerSync);
          SharedRecentColors.revision.addListener(
            remoteBackupScheduler.markDirty,
          );
          accountSession.addListener(() {
            _updateActivityWakePermission(accountSession);
            if (accountSession.isSignedIn && !accountSession.isBusy) {
              unawaited(_startAccountSync());
            } else if (!accountSession.isSignedIn) {
              _bootstrappedAccount = null;
              _settingsPoll?.cancel();
              _settingsDebounce?.cancel();
              _plannerDebounce?.cancel();
              _plannerSync?.stop();
              _accountSettingsSync?.stop();
            }
          });
          unawaited(
            accountSession.loadProfile().then((_) {
              if (mounted) {
                _updateActivityWakePermission(accountSession);
                return _startAccountSync();
              }
            }),
          );
        }

        return MultiProvider(
          providers: [
            ChangeNotifierProvider<AppPreferencesController>.value(
              value: preferences,
            ),
            ChangeNotifierProvider<StudyPlannerController>.value(
              value: planner,
            ),
            Provider<ApiClient>.value(value: apiClient),
            Provider<NotebookRepository>.value(value: repository),
            Provider<LocalBackupService>.value(value: backupService),
            ChangeNotifierProvider<AccountSessionController>.value(
              value: accountSession,
            ),
            Provider<RemoteBackupService>.value(value: remoteBackup),
            ChangeNotifierProvider<RemoteBackupScheduler>.value(
              value: remoteBackupScheduler,
            ),
            ChangeNotifierProvider<LiveWebSyncService>.value(value: liveSync),
            ChangeNotifierProvider<LibraryController>.value(
              value: libraryController,
            ),
          ],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            scrollBehavior: const AppScrollBehavior(),
            title: 'NaNotateczki',
            theme: AppTheme.light(),
            home: const LibraryScreen(),
            builder: (context, child) {
              return Consumer<AppPreferencesController>(
                builder: (context, preferences, _) {
                  return Theme(
                    data: preferences.darkMode
                        ? AppTheme.dark()
                        : AppTheme.light(accentColor: preferences.accentColor),
                    child: AppUiScale(
                      scale: preferences.uiScale,
                      child: Listener(
                        behavior: HitTestBehavior.translucent,
                        onPointerDown: (_) => _activityWake?.noteActivity(),
                        onPointerMove: (_) => _activityWake?.noteActivity(),
                        onPointerHover: (_) => _activityWake?.noteActivity(),
                        onPointerSignal: (_) => _activityWake?.noteActivity(),
                        child: _ExitGuardOverlay(
                          finishingExit: _finishingExit,
                          child: child ?? const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        );
      },
    );
  }
}

/// Scales the complete application viewport while keeping its layout usable.
class AppUiScale extends StatelessWidget {
  const AppUiScale({super.key, required this.scale, required this.child});

  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = constraints.biggest;
        if (!viewport.isFinite || viewport.isEmpty) {
          return child;
        }
        final logicalSize = viewport / scale;
        final query = MediaQuery.of(context);
        return ClipRect(
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: 0,
            minHeight: 0,
            maxWidth: double.infinity,
            maxHeight: double.infinity,
            child: Transform.scale(
              scale: scale,
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: logicalSize.width,
                height: logicalSize.height,
                child: MediaQuery(
                  data: query.copyWith(
                    size: logicalSize,
                    padding: query.padding / scale,
                    viewPadding: query.viewPadding / scale,
                    viewInsets: query.viewInsets / scale,
                    systemGestureInsets: query.systemGestureInsets / scale,
                  ),
                  child: child,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ExitGuardOverlay extends StatelessWidget {
  const _ExitGuardOverlay({required this.finishingExit, required this.child});

  final ValueListenable<bool> finishingExit;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: finishingExit,
      builder: (context, isFinishingExit, _) {
        return Stack(
          children: [
            child,
            if (isFinishingExit)
              const Positioned.fill(child: _FinishingExitOverlay()),
          ],
        );
      },
    );
  }
}

class _FinishingExitOverlay extends StatelessWidget {
  const _FinishingExitOverlay();

  @override
  Widget build(BuildContext context) {
    return const AbsorbPointer(
      child: ColoredBox(
        color: Colors.black26,
        child: Center(
          child: Card(
            elevation: 8,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox.square(
                    dimension: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                  SizedBox(width: 14),
                  Text('Finishing saves before closing...'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StartupErrorScreen extends StatelessWidget {
  const _StartupErrorScreen({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    final databaseError = error is DatabaseOpenException
        ? error as DatabaseOpenException
        : null;
    return Scaffold(
      appBar: AppBar(title: const Text('Startup error')),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      databaseError == null
                          ? 'The app could not finish startup.'
                          : 'The notes database could not be opened.',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    if (databaseError != null) ...[
                      Text('Failed stage: ${databaseError.stageLabel}.'),
                      const SizedBox(height: 6),
                      Text('Attempts: ${databaseError.attempts}.'),
                      const SizedBox(height: 6),
                      SelectableText('System error: ${databaseError.cause}'),
                      const SizedBox(height: 12),
                      const Text(
                        'The database file was left untouched. No automatic '
                        'reset was performed.',
                      ),
                    ] else
                      SelectableText('System error: $error'),
                    const SizedBox(height: 12),
                    const Text(
                      'Copy the full error details and send them with your '
                      'test report.',
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
        ),
      ),
    );
  }
}

class _BackupScheduler with WidgetsBindingObserver {
  _BackupScheduler({required this.repository, required this.backupService}) {
    WidgetsBinding.instance.addObserver(this);
  }

  static const Duration _idleDelay = Duration(seconds: 2);
  static const Duration _maximumDelay = Duration(seconds: 30);
  static const Duration _failureRetryDelay = Duration(seconds: 30);

  final NotebookRepository repository;
  final LocalBackupService backupService;
  Timer? _timer;
  Timer? _maximumTimer;
  bool _dirty = false;
  bool _isRunning = false;
  bool _closing = false;
  final Map<String, Set<String>?> _pendingChanges = <String, Set<String>?>{};

  bool get hasPendingWork => _dirty || _isRunning || _pendingChanges.isNotEmpty;

  void schedule({
    Iterable<NotebookRepositoryChange> changes =
        const <NotebookRepositoryChange>[],
  }) {
    _dirty = true;
    for (final change in changes) {
      _mergeChange(change.uid, change.pageIds);
    }
    if (_closing) {
      return;
    }
    _timer?.cancel();
    _timer = Timer(_idleDelay, () {
      unawaited(flush(reason: 'idle'));
    });
    _maximumTimer ??= Timer(_maximumDelay, () {
      _maximumTimer = null;
      unawaited(flush(reason: 'maximum-delay'));
    });
  }

  Future<void> flush({
    required String reason,
    bool ignoreInkActivity = false,
    bool rethrowFailures = false,
  }) async {
    _timer?.cancel();
    _timer = null;
    if (!_dirty) {
      _maximumTimer?.cancel();
      _maximumTimer = null;
      return;
    }
    if (!ignoreInkActivity && InkActivityTracker.instance.isBusy) {
      _timer = Timer(InkActivityTracker.idleDelay, () {
        unawaited(flush(reason: reason));
      });
      return;
    }
    if (_isRunning) {
      _dirty = true;
      return;
    }
    _maximumTimer?.cancel();
    _maximumTimer = null;
    final pendingChanges = <String, Set<String>?>{
      for (final entry in _pendingChanges.entries)
        entry.key: entry.value == null ? null : Set<String>.from(entry.value!),
    };
    _pendingChanges.clear();
    _dirty = false;
    _isRunning = true;
    final frameCursor = FrameTimingTracker.instance.captureCursor();
    final totalStopwatch = Stopwatch()..start();
    var fetchMs = 0;
    BackupSnapshotReport? snapshotReport;
    var itemCount = 0;
    var retryAfterFailure = false;
    try {
      final fetchStopwatch = Stopwatch()..start();
      final items =
          repository.cachedNotebooks ?? await repository.fetchNotebooks();
      fetchStopwatch.stop();
      fetchMs = fetchStopwatch.elapsedMilliseconds;
      itemCount = items.length;
      final corruptUids = repository.lastCorruptNotebookIds.toSet();
      final snapshotItems = <Notebook>[
        for (final item in items)
          if (!corruptUids.contains(item.uid)) item,
      ];
      if (corruptUids.isNotEmpty) {
        for (final uid in corruptUids) {
          final previous = await backupService.readLatest(requiredUids: {uid});
          Notebook? safeCopy;
          for (final candidate in previous) {
            if (candidate.uid == uid) {
              safeCopy = candidate;
              break;
            }
          }
          if (safeCopy != null) {
            snapshotItems.add(safeCopy);
          }
        }
        if (snapshotItems.isEmpty) {
          final frameSummary = FrameTimingTracker.instance.summarySince(
            frameCursor,
          );
          debugPrint(
            '[backup] reason=$reason skipped=noSafeDocuments '
            'corrupt=${corruptUids.length} items=$itemCount '
            'fetchMs=$fetchMs totalMs=${totalStopwatch.elapsedMilliseconds} '
            '${frameSummary.toLogString()}',
          );
          OptimizationLog.instance.recordBackup(
            reason: reason,
            items: itemCount,
            fetchMs: fetchMs,
            snapshotMs: 0,
            totalMs: totalStopwatch.elapsedMilliseconds,
            status: 'noSafeDocuments',
          );
          return;
        }
      }
      snapshotReport = await backupService.snapshot(
        snapshotItems,
        dirtyPageIdsByNotebook: pendingChanges,
      );
      final frameSummary = FrameTimingTracker.instance.summarySince(
        frameCursor,
      );
      debugPrint(
        '[backup] reason=$reason items=$itemCount fetchMs=$fetchMs '
        'snapshotMs=${snapshotReport.totalMs} '
        'totalMs=${totalStopwatch.elapsedMilliseconds} '
        '${snapshotReport.toLogString()} ${frameSummary.toLogString()}',
      );
      OptimizationLog.instance.recordBackup(
        reason: reason,
        items: itemCount,
        fetchMs: fetchMs,
        snapshotMs: snapshotReport.totalMs,
        totalMs: totalStopwatch.elapsedMilliseconds,
        status: 'ok',
      );
    } on BackupSnapshotInterrupted {
      for (final entry in pendingChanges.entries) {
        _mergeChange(entry.key, entry.value);
      }
      _dirty = true;
      debugPrint('[backup] reason=$reason interrupted=worker');
      if (rethrowFailures) {
        rethrow;
      }
    } catch (e) {
      if (e is! BackupDataException || rethrowFailures || _closing) {
        for (final entry in pendingChanges.entries) {
          _mergeChange(entry.key, entry.value);
        }
        _dirty = true;
        retryAfterFailure = !rethrowFailures && !_closing;
      }
      final frameSummary = FrameTimingTracker.instance.summarySince(
        frameCursor,
      );
      debugPrint(
        '[backup] reason=$reason failed=1 items=$itemCount '
        'fetchMs=$fetchMs snapshotMs=${snapshotReport?.totalMs ?? 0} '
        'totalMs=${totalStopwatch.elapsedMilliseconds} '
        '${frameSummary.toLogString()} error=$e',
      );
      OptimizationLog.instance.recordBackup(
        reason: reason,
        items: itemCount,
        fetchMs: fetchMs,
        snapshotMs: snapshotReport?.totalMs ?? 0,
        totalMs: totalStopwatch.elapsedMilliseconds,
        status: 'failed',
        error: e.toString(),
      );
      if (rethrowFailures) {
        rethrow;
      }
    } finally {
      _isRunning = false;
      if (_dirty && !_closing) {
        if (retryAfterFailure) {
          _scheduleFailureRetry();
        } else {
          schedule();
        }
      }
    }
  }

  Future<void> flushForExit() async {
    _closing = true;
    _timer?.cancel();
    _timer = null;
    _maximumTimer?.cancel();
    _maximumTimer = null;
    try {
      while (_isRunning) {
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
      while (_dirty) {
        await flush(
          reason: 'exit',
          ignoreInkActivity: true,
          rethrowFailures: true,
        );
        while (_isRunning) {
          await Future<void>.delayed(const Duration(milliseconds: 16));
        }
      }
    } catch (_) {
      resumeAfterExitCancellation();
      rethrow;
    }
  }

  void resumeAfterExitCancellation() {
    if (!_closing) {
      return;
    }
    _closing = false;
    if (_dirty) {
      schedule();
    }
  }

  void _mergeChange(String uid, Set<String>? pageIds) {
    if (!_pendingChanges.containsKey(uid)) {
      _pendingChanges[uid] = pageIds == null ? null : Set<String>.from(pageIds);
      return;
    }
    final existing = _pendingChanges[uid];
    if (existing == null || pageIds == null) {
      _pendingChanges[uid] = null;
      return;
    }
    existing.addAll(pageIds);
  }

  void _scheduleFailureRetry() {
    _timer?.cancel();
    _maximumTimer?.cancel();
    _maximumTimer = null;
    _timer = Timer(_failureRetryDelay, () {
      unawaited(flush(reason: 'retry'));
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(flush(reason: state.name));
    }
  }

  void dispose() {
    _timer?.cancel();
    _maximumTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
  }
}
