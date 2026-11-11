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
import '../core/storage/active_storage_namespace.dart';
import '../core/storage/app_save_coordinator.dart';
import '../core/storage/storage_namespace_manager.dart';
import '../core/storage/shutdown_coordinator.dart';
import '../core/storage/text_storage.dart';
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
import '../data/sync/device_clock_check.dart';
import '../data/sync/editor_v2_account_runtime.dart';
import '../data/sync/local_account_import_service.dart';
import '../data/sync/live_web_sync_service.dart';
import '../data/sync/operation_store.dart';
import '../data/sync/persistent_operation_actor.dart';
import '../data/sync/planner_sync_service.dart';
import '../features/editor/state/ink_color_presets.dart';
import '../features/library/presentation/library_controller.dart';
import '../features/library/presentation/library_screen.dart';
import '../features/notebook/data/notebook_repository.dart';
import '../features/notebook/domain/notebook.dart';
import '../features/planner/state/study_planner_controller.dart';
import 'account_bootstrap_barrier.dart';
import 'account_protocol_editor_gate.dart';
import 'unsupported_account_protocol_screen.dart';

class AppScope extends StatefulWidget {
  const AppScope({super.key, this.onNamespaceSwitch});

  final VoidCallback? onNamespaceSwitch;

  @override
  State<AppScope> createState() => _AppScopeState();
}

class _AppScopeState extends State<AppScope> with WidgetsBindingObserver {
  late final Future<DatabaseOpenResult> _openFuture = _openScopedDatabase();
  StorageNamespace? _namespace;
  bool _switchingNamespace = false;
  Object? _namespaceSwitchFailure;
  NotebookRepository? _repository;
  LocalBackupService? _backupService;
  CloudSyncService? _cloudSync;
  ApiClient? _apiClient;
  AppActivityWakeService? _activityWake;
  AccountSessionController? _accountSession;
  RemoteBackupService? _remoteBackupService;
  RemoteBackupScheduler? _remoteBackupScheduler;
  LiveWebSyncService? _liveSync;
  EditorV2AccountRuntime? _v2AccountRuntime;
  static const bool _enableV2AccountPreview = bool.fromEnvironment(
    'NN_ENABLE_V2_ACCOUNT',
    defaultValue: false,
  );
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
  final AccountBootstrapBarrier _accountBootstrapBarrier =
      AccountBootstrapBarrier();
  Timer? _rememberedLoginRetry;
  bool _appIsForeground = true;
  String? _bootstrappedAccount;
  String? _legacyProtocolReadyUser;
  String? _incompatibleProtocolUser;
  String? _clockCheckedForUser;
  final GlobalKey<ScaffoldMessengerState> _notificationMessengerKey =
      GlobalKey<ScaffoldMessengerState>();
  bool _databaseWasReset = false;
  bool _databaseFreshFile = false;
  final ValueNotifier<bool> _finishingExit = ValueNotifier<bool>(false);
  final ValueNotifier<String?> _exitFailure = ValueNotifier<String?>(null);
  final ValueNotifier<bool> _allowOfflineExit = ValueNotifier<bool>(false);
  Future<void>? _exitDrain;
  bool _allowExit = false;
  bool _openErrorRecorded = false;

  Future<DatabaseOpenResult> _openScopedDatabase() async {
    final profile = await readStoredText(
      AccountSessionController.profileStorageKey,
    );
    final namespace = ActiveStorageNamespace.fromProfile(profile);
    _namespace = namespace;
    ActiveStorageNamespace.activate(namespace);
    return NotesDatabase.open(
      databaseName: kIsWeb
          ? namespace.webDatabaseName
          : namespace.nativeDatabaseName,
    );
  }

  Future<void> _quiesceAccountWriters() {
    return _accountBootstrapBarrier.quiesce(() async {
      // A pending actor/protocol read must settle before its SQLite namespace
      // or API identity is replaced. The invalidated bootstrap cannot publish UI.
      await _accountBootstrap;
      await AppSaveCoordinator.instance.flushPending();
      await _repository?.waitForPendingSaves();
      await _backupScheduler?.flushForExit();
      await _backupService?.waitUntilIdle();
      await SharedRecentColors.load();
      await waitForPendingTextStorageOperations();
      await _liveSync?.stop();
      await _v2AccountRuntime?.stop();
      _plannerSync?.stop();
      _accountSettingsSync?.stop();
      await _remoteBackupScheduler?.stop();
      _bootstrappedAccount = null;
      _legacyProtocolReadyUser = null;
      _incompatibleProtocolUser = null;
    });
  }

  Future<void> _switchNamespaceIfNeeded() async {
    final session = _accountSession;
    if (session == null ||
        !session.profileLoaded ||
        session.isBusy ||
        _switchingNamespace) {
      return;
    }
    final next = session.isSignedIn
        ? StorageNamespace.account(session.userId!)
        : session.preferredMode == AccountDataMode.localOnly
        ? StorageNamespace.local()
        : _namespace;
    if (next == null || _namespace == next) {
      return;
    }
    setState(() {
      _switchingNamespace = true;
      _namespaceSwitchFailure = null;
    });
    try {
      await _quiesceAccountWriters();
      if (mounted) {
        widget.onNamespaceSwitch?.call();
      }
    } catch (error, stackTrace) {
      AppErrorLog.instance.record(
        error,
        stackTrace,
        source: 'AppScope.namespaceSwitch',
      );
      if (mounted) {
        setState(() {
          _switchingNamespace = false;
          _namespaceSwitchFailure = error;
        });
      }
    }
  }

  Widget _namespaceGuardedLibrary() {
    return Consumer<AccountSessionController>(
      builder: (context, session, _) {
        final expected = session.isSignedIn
            ? StorageNamespace.account(session.userId!)
            : session.preferredMode == AccountDataMode.localOnly
            ? StorageNamespace.local()
            : _namespace;
        if (_namespaceSwitchFailure != null) {
          return _StartupErrorScreen(error: _namespaceSwitchFailure!);
        }
        if (!ActiveStorageNamespace.canDisplay(
          opened: _namespace,
          expected: expected,
          switching: _switchingNamespace,
          failed: _namespaceSwitchFailure != null,
        )) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (session.isSignedIn && _incompatibleProtocolUser == session.userId) {
          return UnsupportedAccountProtocolScreen(onLogOut: session.logout);
        }
        return AccountProtocolEditorGate(
          isSignedIn: session.isSignedIn,
          userId: session.userId,
          legacyReadyUser: session.hasPendingLocalImport(session.userId ?? '')
              ? null
              : _legacyProtocolReadyUser,
          v2ReadyUser: session.hasPendingLocalImport(session.userId ?? '')
              ? null
              : (_v2AccountRuntime == null ? null : _bootstrappedAccount),
          onRetry: _startAccountSync,
          onLogOut: session.logout,
          child: const LibraryScreen(),
        );
      },
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_handleGlobalKeyEvent);
    FrameTimingTracker.instance.initialize();
    _rememberedLoginRetry = Timer.periodic(const Duration(seconds: 45), (_) {
      if (_appIsForeground) {
        final session = _accountSession;
        if (session != null) {
          unawaited(session.retryPersistedSession());
        }
      }
    });
  }

  @override
  void dispose() {
    _accountBootstrapBarrier.dispose();
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_handleGlobalKeyEvent);
    _activityWake?.dispose();
    _settingsPoll?.cancel();
    _rememberedLoginRetry?.cancel();
    _settingsDebounce?.cancel();
    _plannerDebounce?.cancel();
    _plannerSync?.stop();
    _backupScheduler?.dispose();
    _remoteBackupScheduler?.dispose();
    _liveSync?.dispose();
    _v2AccountRuntime?.dispose();
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
    unawaited(
      _openFuture
          .then((opened) => opened.database.close())
          .catchError((Object _, StackTrace __) {}),
    );
    final backupService = _backupService;
    if (backupService != null) {
      backupService.dispose();
    }
    _finishingExit.dispose();
    _exitFailure.dispose();
    _allowOfflineExit.dispose();
    super.dispose();
  }

  bool get _hasPendingExitWork {
    // Signed-in devices must attempt a verified remote snapshot on exit,
    // even when the local save queue is currently empty.
    if (_accountSession?.isSignedIn == true) {
      return true;
    }
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

  Future<void> _finishPendingWorkAndExit({bool preserveOffline = false}) async {
    final repository = _repository;
    final backupService = _backupService;
    final scheduler = _backupScheduler;
    if (repository == null || backupService == null || scheduler == null) {
      _allowExit = true;
      await ServicesBinding.instance.exitApplication(ui.AppExitType.required);
      return;
    }

    _exitFailure.value = null;
    _allowOfflineExit.value = false;
    _finishingExit.value = true;
    final coordinator = ShutdownCoordinator(
      flushLocal: () async {
        await InkActivityTracker.instance.waitForNoActiveContacts();
        for (var attempt = 0; attempt < 3; attempt++) {
          await AppSaveCoordinator.instance.flushPending();
          await repository.waitForPendingSaves();
          await waitForPendingTextStorageOperations();
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
        await waitForPendingTextStorageOperations();
        if (_accountSession?.isSignedIn == true) {
          if (_v2AccountRuntime == null) {
            await _liveSync?.flushPersistedOutbox();
          }
        }
      },
      syncRemote: () async {
        if (_accountSession?.isSignedIn != true) {
          return;
        }
        final v2 = _v2AccountRuntime;
        if (v2 != null) {
          await v2.engine.syncNow();
          if (v2.engine.lastError != null ||
              (await v2.store.pending(
                limit: 1,
                includeDeferred: true,
              )).isNotEmpty) {
            throw StateError(
              'V2 outbox is not fully acknowledged; local data is preserved.',
            );
          }
          return;
        }
        if (_liveSync == null) {
          throw StateError('Account synchronization is unavailable.');
        }
        await _liveSync!.syncNow();
        if (_liveSync!.hasPendingChanges || _liveSync!.lastError != null) {
          throw StateError('Pending account changes remain in the outbox.');
        }
      },
      verifyBackup: () async {
        if (_accountSession?.isSignedIn != true) {
          return;
        }
        if (_v2AccountRuntime != null) {
          // The legacy snapshot protocol must not back up a v2 account.
          return;
        }
        final remote = _remoteBackupScheduler;
        if (remote == null) {
          throw StateError('Remote backup is not available.');
        }
        if (!remote.isEnabled) {
          remote.enableForSignedInAccount();
        }
        await remote.ensureVerifiedForExit();
      },
    );
    try {
      await coordinator.run(preserveOffline: preserveOffline);
      _allowExit = true;
      _exitFailure.value = null;
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
        _allowOfflineExit.value =
            error is ShutdownInterrupted && error.localSafe;
        _exitFailure.value = 'Exit stopped: $error';
        _finishingExit.value = false;
      }
    } finally {
      if (!_allowExit) {
        _exitDrain = null;
      }
    }
  }

  void _cancelPendingExit() {
    _exitFailure.value = null;
    _allowOfflineExit.value = false;
    _backupScheduler?.resumeAfterExitCancellation();
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
    _appIsForeground = state == AppLifecycleState.resumed;
    _activityWake?.setForeground(_appIsForeground);
    if (state == AppLifecycleState.detached ||
        (kIsWeb && state == AppLifecycleState.hidden)) {
      // A best-effort emergency backup: operating systems and browsers may
      // kill the process before network I/O completes.
      unawaited(_attemptEmergencyBackup());
    }
    if (_appIsForeground) {
      final session = _accountSession;
      if (session != null) {
        unawaited(session.retryPersistedSession());
      }
      unawaited(_startAccountSync());
      unawaited(_syncAccountSettings());
      unawaited(_syncPlanner());
    }
  }

  Future<void> _attemptEmergencyBackup() async {
    final remote = _remoteBackupScheduler;
    if (_accountSession?.isSignedIn != true ||
        remote == null ||
        !remote.isEnabled) {
      return;
    }
    if (!remote.hasPendingBackup &&
        !AppSaveCoordinator.instance.hasPendingWork &&
        !(_repository?.hasPendingSaves ?? false)) {
      return;
    }
    try {
      await AppSaveCoordinator.instance.flushPending();
      await _repository?.waitForPendingSaves();
      await remote.backupNow();
    } catch (error, stackTrace) {
      AppErrorLog.instance.record(
        error,
        stackTrace,
        source: 'AppScope.emergencyBackup',
      );
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
    // Settings can be triggered by listeners before the account bootstrap.
    // Do not issue v1 requests until this account's protocol is verified.
    if (_accountSession?.isSignedIn == true &&
        _legacyProtocolReadyUser != _accountSession?.userId) {
      return;
    }
    try {
      // A planner task may still be in its short local save debounce.
      // Flush it before reading library_folders.json for cloud sync.
      await _libraryController?.flushPlannerTasks();
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
    if (_bootstrappedAccount == null ||
        _legacyProtocolReadyUser != _bootstrappedAccount ||
        _plannerSync == null) {
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

  Future<void> _checkAccountClock(String userId) async {
    final api = _apiClient;
    if (api == null) {
      return;
    }
    try {
      final result = await DeviceClockCheck(apiClient: api).measure();
      if (!mounted ||
          _accountSession?.userId != userId ||
          _accountSession?.isSignedIn != true ||
          result == null ||
          !result.isSignificant) {
        return;
      }
      final seconds = result.offset.inSeconds.abs();
      final amount = seconds >= 120
          ? '${(seconds / 60).round()} minutes'
          : '$seconds seconds';
      final message =
          'Device clock is off by about $amount. '
          'Enable automatic date and time to avoid sync conflicts.';
      AppErrorLog.instance.record(
        StateError(message),
        null,
        source: 'Device clock',
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            _accountSession?.userId != userId ||
            _accountSession?.isSignedIn != true) {
          return;
        }
        final messenger = _notificationMessengerKey.currentState;
        if (messenger == null) {
          return;
        }
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 15),
            content: Text(message),
            action: SnackBarAction(
              label: 'Dismiss',
              onPressed: messenger.hideCurrentSnackBar,
            ),
          ),
        );
      });
      WidgetsBinding.instance.scheduleFrame();
    } catch (_) {
      // Old API versions, offline mode and unreliable measurements must not
      // interrupt signing in or synchronization.
    }
  }

  Future<String> _v2ActorId() =>
      loadPersistentOperationActor(OperationStore(_repository!.database));

  bool _isCurrentAccountBootstrap(String userId, int generation) =>
      mounted &&
      _accountBootstrapBarrier.isCurrent(generation) &&
      !_switchingNamespace &&
      _accountSession?.isSignedIn == true &&
      _accountSession?.isBusy == false &&
      _accountSession?.userId == userId &&
      _namespace == StorageNamespace.account(userId);

  /// Completes a previously authorized Local import before enabling backups.
  Future<void> _importPendingLocalData(
    String userId,
    int generation,
  ) async {
    final session = _accountSession;
    if (session == null || !session.hasPendingLocalImport(userId)) {
      return;
    }
    bool current() => _isCurrentAccountBootstrap(userId, generation);
    if (!current()) {
      return;
    }
    final repository = _repository;
    final planner = _studyPlanner;
    final library = _libraryController;
    if (repository == null || planner == null || library == null) {
      throw StateError('Local account import dependencies are unavailable.');
    }
    await LocalAccountImportService(
      accountId: userId,
      repository: repository,
      planner: planner,
      isCurrentAccount: current,
      onLibraryChanged: library.reloadFromAccount,
    ).run();
    if (!current()) {
      return;
    }
    await session.completeLocalImport(userId);
    if (mounted) {
      setState(() {});
    }
  }

  /// Starts the operational engine for an explicitly confirmed v2 account.
  Future<void> _startV2Account(String userId, int generation) async {
    if (!_enableV2AccountPreview) {
      throw AccountProtocolNotSupported();
    }
    bool isCurrent() => _isCurrentAccountBootstrap(userId, generation);
    if (!isCurrent()) {
      return;
    }
    final repository = _repository;
    final apiClient = _apiClient;
    final library = _libraryController;
    if (repository == null || apiClient == null || library == null) {
      throw StateError('V2 account cannot start without its SQLite scope.');
    }
    var runtime = _v2AccountRuntime;
    if (runtime == null) {
      final actorId = await _v2ActorId();
      if (!isCurrent()) {
        return;
      }
      runtime = EditorV2AccountRuntime(
        repository: repository,
        apiClient: apiClient,
        accountId: userId,
        actorId: actorId,
        onLibraryChanged: library.loadItems,
      );
      // Publish ownership before startup so logout can stop this transport.
      _v2AccountRuntime = runtime;
    }
    if (!await runtime.startForCurrentAccount(isCurrent: isCurrent)) {
      return;
    }
    await library.loadItems();
    if (!isCurrent()) {
      await runtime.stop();
      return;
    }
    await _importPendingLocalData(userId, generation);
    if (!isCurrent()) {
      await runtime.stop();
      return;
    }
    _bootstrappedAccount = userId;
    // Planner, Share and legacy remote snapshot services remain disabled
    // until they have their own verified v2 cutover.
    setState(() {
      _incompatibleProtocolUser = null;
    });
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
        _switchingNamespace ||
        !_accountBootstrapBarrier.canStart ||
        _namespace != StorageNamespace.account(session.userId!) ||
        backup == null ||
        scheduler == null ||
        sync == null ||
        library == null ||
        preferences == null ||
        planner == null) {
      return Future<void>.value();
    }
    final userId = session.userId!;
    if (_clockCheckedForUser != userId) {
      _clockCheckedForUser = userId;
      unawaited(_checkAccountClock(userId));
    }
    if (_bootstrappedAccount == userId) {
      return Future<void>.value();
    }
    final running = _accountBootstrap;
    if (running != null) {
      return running;
    }
    final generation = _accountBootstrapBarrier.generation;
    bool isCurrent() => _isCurrentAccountBootstrap(userId, generation);
    final future = () async {
      try {
        await _plannerReady;
        if (!isCurrent()) {
          return;
        }
        // Never restore an older snapshot or start v1 writers for a v2
        // account. Keep local data and the outbox untouched on failure.
        try {
          await _apiClient!.ensureLegacyAccountProtocol();
        } on AccountProtocolNotSupported {
          try {
            await _startV2Account(userId, generation);
          } on AccountProtocolNotSupported {
            if (isCurrent()) {
              setState(() => _incompatibleProtocolUser = userId);
            }
            rethrow;
          }
          return;
        }
        if (!isCurrent()) {
          return;
        }
        if (_incompatibleProtocolUser == userId && mounted) {
          setState(() => _incompatibleProtocolUser = null);
        }
        // Release the editor only after the server confirmed v1.
        // The gate keeps v2 documents away from snapshot writers.
        setState(() => _legacyProtocolReadyUser = userId);
        var restored = false;
        Object? recoveryFailure;
        // A new installation has no presence marker. If IndexedDB/SQLite
        // vanished after an earlier successful account start, recover it.
        final needsRecovery =
            _databaseWasReset ||
            (_databaseFreshFile && await backup.wasDatabaseInitialized(userId));
        if (needsRecovery) {
          try {
            restored = await backup.hydrateFromLatestAccountBackup(
              databaseWasReset: true,
            );
          } catch (error, stackTrace) {
            recoveryFailure = error;
            AppErrorLog.instance.record(
              error,
              stackTrace,
              source: 'AppScope.accountBackupRecovery',
            );
          }
        }
        if (!isCurrent()) {
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
        if (!isCurrent()) {
          return;
        }
        await sync.start(InitialSyncPolicy.mergeSafely);
        if (!isCurrent()) {
          await sync.stop();
          return;
        }
        try {
          await _plannerSync?.syncNow();
        } catch (error, stackTrace) {
          AppErrorLog.instance.record(
            error,
            stackTrace,
            source: 'AppScope.initialPlannerSync',
          );
        }
        if (!isCurrent()) {
          return;
        }
        if (recoveryFailure != null) {
          // Keep live sync available but do not upload a potentially
          // incomplete replacement snapshot. Retry recovery on resume.
          sync.reportStartupFailure(recoveryFailure);
          return;
        }
        await _importPendingLocalData(userId, generation);
        if (!isCurrent()) {
          return;
        }
        await backup.markDatabaseInitialized(userId);
        if (!isCurrent()) {
          return;
        }
        _databaseWasReset = false;
        _databaseFreshFile = false;
        _bootstrappedAccount = userId;
        scheduler.enableForSignedInAccount();
        _observedIdleSeconds = scheduler.idleSeconds;
        _settingsPoll?.cancel();
        _settingsPoll = Timer.periodic(const Duration(seconds: 45), (_) {
          unawaited(_syncAccountSettings());
          unawaited(_syncPlanner());
        });
      } catch (error, stackTrace) {
        if (!isCurrent()) {
          return;
        }
        if (error is AccountProtocolNotSupported) {
          setState(() => _incompatibleProtocolUser = userId);
        }
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
        if (_repository == null) {
          _databaseWasReset = result.wasReset;
          _databaseFreshFile = result.freshFile;
        }
        final repository =
            _repository ??
            NotebookRepository(
              result.database,
              onChanged: (changes) {
                _backupScheduler?.schedule(changes: changes);
                _remoteBackupScheduler?.markDirty();
                final signedInUser = _accountSession?.userId;
                if (signedInUser != null &&
                    _legacyProtocolReadyUser == signedInUser &&
                    _namespace == StorageNamespace.account(signedInUser)) {
                  _liveSync?.enqueue(changes);
                }
                if (changes.isEmpty) {
                  // Folder, cover and task metadata live in library_folders.
                  _scheduleAccountSettingsSync();
                }
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
              onBeforeAccountChange: _quiesceAccountWriters,
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
        remoteBackupScheduler.reconcileBeforeBackup = () async {
          if (!liveSync.isStarted) {
            throw StateError('Account sync must start before remote backup.');
          }
          // Pull changes even when this device has made no local edits.
          await liveSync.syncNow();
          if (liveSync.lastError != null || liveSync.hasPendingChanges) {
            throw StateError(
              'Pending notebook changes must sync before remote backup.',
            );
          }
          await libraryController.flushPlannerTasks();
          await _accountSettingsSync?.syncNow();
          if (_accountSettingsSync?.lastError != null) {
            throw StateError('Account preferences have not synchronized.');
          }
          await _plannerSync?.syncNow();
          if (_plannerSync?.lastError != null) {
            throw StateError('Planner has not synchronized.');
          }
        };
        _accountSettingsSync ??= AccountSettingsSyncService(
          apiClient: apiClient,
          session: accountSession,
          onRemoteApplied: () async {
            await libraryController.reloadFromAccount();
            await preferences.load();
            await remoteBackupScheduler.refreshAccountPreference();
            // Metadata and preferences downloaded from another device
            // also belong in the next verified snapshot.
            remoteBackupScheduler.markDirty();
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
            if (accountSession.profileLoaded && !accountSession.isBusy) {
              final target = accountSession.isSignedIn
                  ? StorageNamespace.account(accountSession.userId!)
                  : accountSession.preferredMode == AccountDataMode.localOnly
                  ? StorageNamespace.local()
                  : _namespace;
              if (target != _namespace) {
                _remoteBackupScheduler?.disable();
                _settingsPoll?.cancel();
                _settingsDebounce?.cancel();
                _plannerDebounce?.cancel();
                unawaited(_switchNamespaceIfNeeded());
              } else if (accountSession.isSignedIn) {
                unawaited(_startAccountSync());
              }
            }
            if (!accountSession.isSignedIn) {
              _bootstrappedAccount = null;
              _legacyProtocolReadyUser = null;
              _incompatibleProtocolUser = null;
              _clockCheckedForUser = null;
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
            Provider<EditorV2AccountRuntime?>.value(value: _v2AccountRuntime),
            ChangeNotifierProvider<LibraryController>.value(
              value: libraryController,
            ),
          ],
          child: MaterialApp(
            scaffoldMessengerKey: _notificationMessengerKey,
            debugShowCheckedModeBanner: false,
            scrollBehavior: const AppScrollBehavior(),
            title: 'NaNotateczki',
            theme: AppTheme.light(),
            home: _namespaceGuardedLibrary(),
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
                        onPointerMove: (event) {
                          if (AppActivityWakeService.isIntentionalPointer(
                            event,
                          )) {
                            _activityWake?.noteActivity();
                          }
                        },
                        onPointerSignal: (_) => _activityWake?.noteActivity(),
                        child: _ExitGuardOverlay(
                          finishingExit: _finishingExit,
                          exitFailure: _exitFailure,
                          allowOfflineExit: _allowOfflineExit,
                          onCancel: _cancelPendingExit,
                          onExitOffline: () {
                            _exitDrain ??= _finishPendingWorkAndExit(
                              preserveOffline: true,
                            );
                          },
                          onRetry: () {
                            _exitDrain ??= _finishPendingWorkAndExit();
                          },
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
  const _ExitGuardOverlay({
    required this.finishingExit,
    required this.exitFailure,
    required this.allowOfflineExit,
    required this.onRetry,
    required this.onCancel,
    required this.onExitOffline,
    required this.child,
  });

  final ValueListenable<bool> finishingExit;
  final ValueListenable<String?> exitFailure;
  final ValueListenable<bool> allowOfflineExit;
  final VoidCallback onRetry;
  final VoidCallback onCancel;
  final VoidCallback onExitOffline;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: finishingExit,
      builder: (context, isFinishingExit, _) {
        return ValueListenableBuilder<String?>(
          valueListenable: exitFailure,
          builder: (context, failure, _) {
            return Stack(
              children: [
                child,
                if (isFinishingExit)
                  const Positioned.fill(child: _FinishingExitOverlay())
                else if (failure != null)
                  Positioned(
                    left: 24,
                    right: 24,
                    bottom: 24,
                    child: Center(
                      child: Card(
                        elevation: 8,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(failure, textAlign: TextAlign.center),
                              ValueListenableBuilder<bool>(
                                valueListenable: allowOfflineExit,
                                builder: (context, canExitOffline, _) => Column(
                                  children: [
                                    TextButton(
                                      onPressed: onRetry,
                                      child: const Text('Retry'),
                                    ),
                                    if (canExitOffline)
                                      TextButton(
                                        onPressed: onExitOffline,
                                        child: const Text(
                                          'Exit with saved local changes',
                                        ),
                                      ),
                                    TextButton(
                                      onPressed: onCancel,
                                      child: const Text('Cancel exit'),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
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
