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
import '../data/backup/v2_backup_recovery_service.dart';
import '../data/backup/remote_backup_scheduler.dart';
import '../data/drift/notes_database.dart';
import '../data/sync/account_session_controller.dart';
import '../data/sync/account_settings_sync_service.dart';
import '../data/sync/api_client.dart';
import '../data/sync/app_activity_wake_service.dart';
import '../data/sync/diagnostics_upload_service.dart';
import '../data/sync/device_clock_check.dart';
import '../data/sync/editor_v2_account_runtime.dart';
import '../data/sync/local_account_import_service.dart';
import '../data/sync/legacy_v2_projection_cutover.dart';
import '../data/sync/legacy_sync_archive.dart';
import '../data/sync/operation_store.dart';
import '../data/sync/persistent_operation_actor.dart';
import '../data/sync/planner_sync_service.dart';
import '../features/editor/state/ink_color_presets.dart';
import '../features/library/presentation/library_account_slot.dart';
import '../features/library/presentation/library_controller.dart';
import '../features/library/presentation/library_screen.dart';
import '../features/notebook/data/notebook_repository.dart';
import '../features/notebook/domain/notebook.dart';
import '../features/planner/state/study_planner_controller.dart';
import 'account_bootstrap_barrier.dart';
import 'account_protocol_editor_gate.dart';

class AppScope extends StatefulWidget {
  const AppScope({super.key, this.onNamespaceSwitch})
    : _openDatabase = null,
      _testApiClient = null,
      _testExit = null;

  @visibleForTesting
  const AppScope.forTesting({
    super.key,
    this.onNamespaceSwitch,
    required Future<DatabaseOpenResult> Function() openDatabase,
    required ApiClient apiClient,
    Future<ui.AppExitResponse> Function()? exit,
  }) : _openDatabase = openDatabase,
       _testApiClient = apiClient,
       _testExit = exit;

  final VoidCallback? onNamespaceSwitch;
  final Future<DatabaseOpenResult> Function()? _openDatabase;
  final ApiClient? _testApiClient;
  final Future<ui.AppExitResponse> Function()? _testExit;

  @override
  State<AppScope> createState() => _AppScopeState();
}

class _AppScopeState extends State<AppScope> with WidgetsBindingObserver {
  late final Future<DatabaseOpenResult> _openFuture = _openScopedDatabase();
  StorageNamespace? _namespace;
  bool _switchingNamespace = false;
  Object? _namespaceSwitchFailure;
  String? _localImportFailure;
  NotebookRepository? _repository;
  LocalBackupService? _backupService;
  ApiClient? _apiClient;
  AppActivityWakeService? _activityWake;
  AccountSessionController? _accountSession;
  RemoteBackupService? _remoteBackupService;
  RemoteBackupScheduler? _remoteBackupScheduler;
  EditorV2AccountRuntime? _v2AccountRuntime;
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
  String? _accountStartupFailure;
  String? _clockCheckedForUser;
  final GlobalKey<ScaffoldMessengerState> _notificationMessengerKey =
      GlobalKey<ScaffoldMessengerState>();
  bool _databaseWasReset = false;
  bool _databaseFreshFile = false;
  final ValueNotifier<bool> _finishingExit = ValueNotifier<bool>(false);
  final ValueNotifier<String?> _exitFailure = ValueNotifier<String?>(null);
  final ValueNotifier<ShutdownPhase> _exitPhase = ValueNotifier<ShutdownPhase>(
    ShutdownPhase.idle,
  );
  final ValueNotifier<bool> _allowOfflineExit = ValueNotifier<bool>(false);
  Future<void>? _exitDrain;
  Future<void>? _exitWriterDrain;
  bool _allowExit = false;
  bool _openErrorRecorded = false;

  Future<DatabaseOpenResult> _openScopedDatabase() async {
    final profile = await readStoredText(
      AccountSessionController.profileStorageKey,
    );
    final namespace = ActiveStorageNamespace.fromProfile(profile);
    _namespace = namespace;
    ActiveStorageNamespace.activate(namespace);
    if (widget._openDatabase case final open?) {
      return open();
    }
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
      await InkActivityTracker.instance.waitForNoActiveContacts();
      _settingsPoll?.cancel();
      _settingsDebounce?.cancel();
      _plannerDebounce?.cancel();
      _bootstrappedAccount = null;
      _accountStartupFailure = null;
      _plannerSync?.stop();
      _accountSettingsSync?.stop();
      await AppSaveCoordinator.instance.flushPending();
      await _libraryController?.flushPlannerTasks();
      await _studyPlanner?.flush();
      await _repository?.waitForPendingSaves();
      await _backupScheduler?.flushForExit();
      await _backupService?.waitUntilIdle();
      await SharedRecentColors.load();
      await waitForPendingTextStorageOperations();
      await _v2AccountRuntime?.stop();
      _libraryController?.attachV2LibraryOperations(null);
      await _remoteBackupScheduler?.stop();
      await _plannerSync?.stopAndDrain();
      await _accountSettingsSync?.stopAndDrain();
    });
  }

  /// Finishes local gestures, SQLite writers and queued file saves before I/O.
  Future<void> _flushLocallyForShutdown() async {
    final repository = _repository;
    final scheduler = _backupScheduler;
    final backupService = _backupService;
    if (repository == null || scheduler == null || backupService == null) {
      throw StateError('Local persistence has not finished initializing.');
    }
    await InkActivityTracker.instance.waitForNoActiveContacts();
    for (var attempt = 0; attempt < 3; attempt++) {
      await AppSaveCoordinator.instance.flushPending();
      await _libraryController?.flushPlannerTasks();
      await _studyPlanner?.flush();
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
  }

  Future<void> _syncRemotelyForShutdown() async {
    final session = _accountSession;
    if (session == null || !session.isSignedIn) {
      return;
    }
    final v2 = _v2AccountRuntime;
    if (v2 == null || _bootstrappedAccount != session.userId) {
      throw StateError('V2 runtime has not completed account startup.');
    }
    await v2.engine.syncNow();
    if (v2.engine.lastError != null ||
        (await v2.store.pending(limit: 1, includeDeferred: true)).isNotEmpty) {
      throw StateError('V2 outbox has unacknowledged local operations.');
    }
    await _accountSettingsSync?.syncNow();
    if (_accountSettingsSync?.lastError != null) {
      throw StateError('Account settings are not synchronized.');
    }
    await _plannerSync?.syncNow();
    if (_plannerSync?.lastError != null) {
      throw StateError('Planner changes are not synchronized.');
    }
  }

  Future<void> _verifyShutdownBackup() async {
    if (_accountSession?.isSignedIn != true) {
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
    if (remote.hasPendingBackup || remote.lastError != null) {
      throw StateError('The final remote backup is not verified.');
    }
  }

  /// One shutdown fence for both the account menu and blocked editor screens.
  Future<void> _prepareAccountLogout(bool preserveOffline) async {
    try {
      await ShutdownCoordinator(
        flushLocal: _flushLocallyForShutdown,
        syncRemote: _syncRemotelyForShutdown,
        verifyBackup: _verifyShutdownBackup,
        stopServices: _quiesceAccountWriters,
        timeout: const Duration(seconds: 45),
      ).run(preserveOffline: preserveOffline);
    } catch (_) {
      _backupScheduler?.resumeAfterExitCancellation();
      rethrow;
    }
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
        if (_namespace?.kind == StorageNamespaceKind.account &&
            !session.isSignedIn) {
          // Account data never mounts a Local/snapshot editor while credentials
          // are being restored or after they have expired.
          return Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: !session.profileLoaded || session.isBusy
                    ? const CircularProgressIndicator()
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('Sign in to open your account library.'),
                          FilledButton(
                            onPressed: () => showLibraryAccountDialog(
                              context,
                              liveSyncAvailable: true,
                            ),
                            child: const Text('Sign in'),
                          ),
                        ],
                      ),
              ),
            ),
          );
        }
        return AccountProtocolEditorGate(
          isSignedIn: session.isSignedIn,
          userId: session.userId,
          v2ReadyUser: session.hasPendingLocalImport(session.userId ?? '')
              ? null
              : (_v2AccountRuntime == null ? null : _bootstrappedAccount),
          onRetry: _startAccountSync,
          onLogOut: session.logout,
          onLogOutOffline: session.logoutOffline,
          blockingReason: session.hasPendingLocalImport(session.userId ?? '')
              ? (_localImportFailure ??
                    'Importing Local data into this account. Editing is '
                        'paused until the transfer and remote acknowledgements '
                        'are complete. Use Retry if the connection is restored.')
              : _accountStartupFailure,
          child: _v2AccountRuntime != null && session.userId != null
              ? _SyncRecoveryNotice(
                  key: ValueKey(session.userId),
                  runtime: _v2AccountRuntime!,
                  child: const LibraryScreen(),
                )
              : const LibraryScreen(),
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
          .catchError((Object _, StackTrace _) {}),
    );
    final backupService = _backupService;
    if (backupService != null) {
      backupService.dispose();
    }
    _finishingExit.dispose();
    _exitFailure.dispose();
    _exitPhase.dispose();
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

  Future<ui.AppExitResponse> _requestPlatformExit() =>
      widget._testExit?.call() ??
      ServicesBinding.instance.exitApplication(ui.AppExitType.required);

  Future<void> _finishPendingWorkAndExit({bool preserveOffline = false}) async {
    final repository = _repository;
    final backupService = _backupService;
    final scheduler = _backupScheduler;
    if (repository == null || backupService == null || scheduler == null) {
      if (_hasPendingExitWork) {
        _exitFailure.value = 'Exit stopped: local storage is not ready.';
        _exitDrain = null;
        return;
      }
      _allowExit = true;
      await _requestPlatformExit();
      return;
    }

    _exitFailure.value = null;
    _allowOfflineExit.value = false;
    _finishingExit.value = true;
    _exitPhase.value = ShutdownPhase.idle;
    final coordinator = ShutdownCoordinator(
      flushLocal: _flushLocallyForShutdown,
      syncRemote: _syncRemotelyForShutdown,
      verifyBackup: _verifyShutdownBackup,
      stopServices: () => _exitWriterDrain = _quiesceAccountWriters(),
      onPhase: (phase) => _exitPhase.value = phase,
      timeout: const Duration(seconds: 45),
    );
    try {
      await coordinator.run(preserveOffline: preserveOffline);
      _allowExit = true;
      _exitFailure.value = null;
      final response = await _requestPlatformExit();
      if (response == ui.AppExitResponse.cancel) {
        _allowExit = false;
        _finishingExit.value = false;
        _cancelPendingExit();
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
    final drain = _exitWriterDrain;
    if (drain != null) {
      unawaited(_resumeAfterExitDrain(drain));
    }
  }

  Future<void> _resumeAfterExitDrain(Future<void> drain) async {
    try {
      await drain;
    } catch (_) {
      // Quiescence has released its fence. Startup still verifies its scope.
    }
    if (mounted &&
        !_finishingExit.value &&
        !_allowExit &&
        identical(_exitWriterDrain, drain)) {
      _exitWriterDrain = null;
      await _startAccountSync();
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
    if (_accountSession?.hasPendingLocalImport(_accountSession?.userId ?? '') ==
            true ||
        (_accountSettingsSync?.isApplying ?? false)) {
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
    // Do not make requests until the account journal is ready.
    if (_accountSession?.isSignedIn == true &&
        _bootstrappedAccount != _accountSession?.userId) {
      return;
    }
    try {
      // A planner task may still be in its short local save debounce.
      // Flush it before the account reconciles preferences.
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
    if (_accountSession?.hasPendingLocalImport(_accountSession?.userId ?? '') ==
        true) {
      return;
    }
    _plannerDebounce?.cancel();
    _plannerDebounce = Timer(const Duration(milliseconds: 200), () {
      unawaited(_syncPlanner());
    });
  }

  Future<void> _syncPlanner() async {
    if (_bootstrappedAccount == null ||
        _v2AccountRuntime == null ||
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

  bool _ownsAccountScope(String userId, int generation) =>
      mounted &&
      _accountBootstrapBarrier.isCurrent(generation) &&
      !_switchingNamespace &&
      _accountSession?.isSignedIn == true &&
      _accountSession?.userId == userId &&
      _namespace == StorageNamespace.account(userId);

  bool _isCurrentAccountBootstrap(String userId, int generation) =>
      _ownsAccountScope(userId, generation) && _accountSession?.isBusy == false;

  /// Completes a previously authorized Local import before enabling backups.
  Future<void> _importPendingLocalData(String userId, int generation) async {
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
    if (_localImportFailure != null && mounted) {
      setState(() => _localImportFailure = null);
    }
    try {
      final runtime = _v2AccountRuntime;
      if (runtime == null) {
        throw StateError('V2 synchronization is not ready for import.');
      }
      await LocalAccountImportService(
        accountId: userId,
        repository: repository,
        planner: planner,
        isCurrentAccount: current,
        onLibraryChanged: library.reloadFromAccount,
        libraryV2: runtime.libraryOperations,
      ).run();
      if (!current()) {
        return;
      }
      await runtime.engine.syncNow();
      if (!current()) {
        return;
      }
      if (runtime.engine.lastError != null ||
          (await runtime.store.pending(includeDeferred: true)).isNotEmpty) {
        throw StateError(
          'Imported document/library operations are waiting for ACK.',
        );
      }
      await _plannerSync?.syncNow();
      if (!current()) {
        return;
      }
      if (_plannerSync?.lastError != null) {
        throw StateError('Imported study entries have not synchronized.');
      }
      await session.completeLocalImport(userId);
      if (mounted) {
        setState(() => _localImportFailure = null);
      }
    } catch (error) {
      if (mounted && current()) {
        setState(() => _localImportFailure = error.toString());
      }
      rethrow;
    }
  }

  /// Starts the operational engine for an explicitly confirmed v2 account.
  Future<void> _startV2Account(String userId, int generation) async {
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
    final legacyCutover = await apiClient.ensureV2AccountReady();
    if (!isCurrent()) {
      return;
    }
    final cutover = legacyCutover == null
        ? null
        : LegacyV2ProjectionCutover(
            repository: repository,
            apiClient: apiClient,
            accountId: userId,
            isCurrent: isCurrent,
          );
    if (cutover == null) {
      await LegacySyncArchive.requireEmptyLegacyOutbox(userId);
    } else {
      await cutover.prepare(legacyCutover!);
    }
    if (!isCurrent()) {
      return;
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
        onLibraryChanged: library.reloadFromAccount,
        enableRealtime: widget._testApiClient == null,
      );
      // Publish ownership before startup so logout can stop this transport.
      _v2AccountRuntime = runtime;
    }
    final verifiedBackup = _remoteBackupService;
    final backupScheduler = _remoteBackupScheduler;
    if (verifiedBackup == null || backupScheduler == null) {
      throw StateError('V2 recovery requires the account backup services.');
    }
    final recovery = V2BackupRecoveryService(
      runtime: runtime,
      repository: repository,
      apiClient: apiClient,
      session: _accountSession!,
    );
    final interrupted = await recovery.hasInterruptedRecovery(userId);
    final missingDatabase =
        _databaseWasReset ||
        (_databaseFreshFile &&
            await verifiedBackup.wasDatabaseInitialized(userId));
    if (missingDatabase || interrupted) {
      // Replay must finish before the editor writer or REST pull can run.
      await runtime.stop();
      if (!isCurrent()) {
        return;
      }
      await recovery.recoverVerifiedArchive(databaseWasReset: missingDatabase);
      if (!isCurrent()) {
        await runtime.stop();
        return;
      }
      await _studyPlanner?.load();
      await _preferences?.load();
    }
    library.attachV2LibraryOperations(runtime.libraryOperations);
    if (!await runtime.startForCurrentAccount(isCurrent: isCurrent)) {
      return;
    }
    if (runtime.engine.lastError != null) {
      throw StateError(
        'V2 replay and catch-up failed: '
        '${runtime.engine.lastError}',
      );
    }
    final cursorResponse = await apiClient.get('/v2/sync/checkpoint');
    final currentCursor =
        (cursorResponse.decodeJson() as Map<String, dynamic>)['cursor'];
    if (currentCursor is! int ||
        (legacyCutover != null &&
            currentCursor < legacyCutover.operationCursor) ||
        await runtime.store.checkpoint('account:$userId') != currentCursor) {
      throw StateError('V2 recovery has not reached the server checkpoint.');
    }
    if (!isCurrent()) {
      return;
    }
    if (cutover != null) {
      // Pause the feed while deriving deltas from the current projection.
      // Concurrent server edits are handled by the ordinary v2 journal.
      await runtime.stop();
      if (!isCurrent()) {
        return;
      }
      await cutover.replayPending(
        writer: runtime.writer,
        store: runtime.store,
        library: runtime.libraryOperations,
      );
      if (!await runtime.startForCurrentAccount(isCurrent: isCurrent)) {
        return;
      }
    }
    await verifiedBackup.markDatabaseInitialized(userId);
    // Keep the archive's pending marker until the separate SQLite recovery
    // flag has been cleared. A crash between these writes can resume safely.
    if (missingDatabase) {
      await repository.database.clearRecoveryMarker();
    }
    await recovery.completeRecovery();
    _databaseWasReset = false;
    _databaseFreshFile = false;
    await runtime.libraryOperations.refreshReadModel();
    await library.reloadFromAccount();
    if (!isCurrent()) {
      await runtime.stop();
      return;
    }
    // Stage 8: planner entries use their independent revision/CAS ledger;
    // folder and task changes use only the @library operation journal.
    _plannerSync?.stop();
    _plannerSync = PlannerSyncService(
      apiClient: apiClient,
      session: _accountSession!,
      planner: _studyPlanner!,
    );
    _accountSettingsSync?.stop();
    _accountSettingsSync = AccountSettingsSyncService(
      apiClient: apiClient,
      session: _accountSession!,
      onRemoteApplied: () async {
        await _preferences?.load();
        await _remoteBackupScheduler?.refreshAccountPreference();
      },
    );
    await _importPendingLocalData(userId, generation);
    if (!isCurrent()) {
      await runtime.stop();
      return;
    }
    try {
      await _accountSettingsSync!.syncNow();
      await _plannerSync!.syncNow();
    } catch (error, stackTrace) {
      AppErrorLog.instance.record(
        error,
        stackTrace,
        source: 'AppScope.initialV2MetadataSync',
      );
    }
    if (!isCurrent()) {
      await runtime.stop();
      return;
    }
    backupScheduler.uploadOperationalSnapshot = (deviceId) =>
        recovery.uploadVerifiedSnapshot(deviceId: deviceId);
    // Capture the non-null owner, not the mutable nullable startup local.
    final backupRuntime = runtime;
    backupScheduler.reconcileBeforeBackup = () async {
      // Logout makes the session busy before its final backup, but retains
      // its identity and generation until writers are actually drained.
      bool ownsScope() => _ownsAccountScope(userId, generation);
      if (!ownsScope()) {
        throw StateError('Account changed before v2 backup.');
      }
      await backupRuntime.engine.syncNow();
      if (!ownsScope() ||
          backupRuntime.engine.lastError != null ||
          (await backupRuntime.store.pending(
            limit: 1,
            includeDeferred: true,
          )).isNotEmpty) {
        throw StateError('V2 outbox must be ACKed before remote backup.');
      }
      await _accountSettingsSync?.syncNow();
      if (_accountSettingsSync?.lastError != null) {
        throw StateError('Account preferences have not synchronized.');
      }
      await _plannerSync?.syncNow();
      if (_plannerSync?.lastError != null) {
        throw StateError('Planner has not synchronized.');
      }
    };
    backupScheduler.enableForSignedInAccount();
    _observedIdleSeconds = backupScheduler.idleSeconds;
    _settingsPoll?.cancel();
    _settingsPoll = Timer.periodic(const Duration(seconds: 45), (_) {
      unawaited(_syncAccountSettings());
      unawaited(_syncPlanner());
    });
    setState(() {
      _bootstrappedAccount = userId;
      _accountStartupFailure = null;
    });
  }

  Future<void> _startAccountSync() {
    final session = _accountSession;
    final backup = _remoteBackupService;
    final scheduler = _remoteBackupScheduler;
    final library = _libraryController;
    final preferences = _preferences;
    final planner = _studyPlanner;
    if (!mounted ||
        _finishingExit.value ||
        _allowExit ||
        session == null ||
        !session.isSignedIn ||
        session.isBusy ||
        _switchingNamespace ||
        !_accountBootstrapBarrier.canStart ||
        _namespace != StorageNamespace.account(session.userId!) ||
        backup == null ||
        scheduler == null ||
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
        await _startV2Account(userId, generation);
      } catch (error, stackTrace) {
        if (!isCurrent()) {
          return;
        }
        if (mounted) {
          setState(() => _accountStartupFailure = error.toString());
        }
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
              },
            );
        _repository = repository;
        final backupService = _backupService ?? LocalBackupService(repository);
        _backupService = backupService;
        final apiClient = _apiClient ?? widget._testApiClient ?? ApiClient();
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
              onBeforeLogout: _prepareAccountLogout,
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
            RemoteBackupScheduler(session: accountSession);
        _remoteBackupScheduler = remoteBackupScheduler;
        _backupScheduler ??= _BackupScheduler(
          repository: repository,
          backupService: backupService,
        );
        final libraryController =
            _libraryController ??
            LibraryController(
              repository,
              backupService,
              wasReset: result.wasReset,
              freshFile: result.freshFile,
              resetReason: result.resetReason,
            );
        _libraryController = libraryController;
        final preferences =
            _preferences ?? (AppPreferencesController()..load());
        _preferences = preferences;
        final planner = _studyPlanner ?? StudyPlannerController();
        _studyPlanner = planner;
        _plannerReady ??= planner.load();
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
              _accountStartupFailure = null;
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
                          exitPhase: _exitPhase,
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

/// Offers explicit recovery without interrupting the rest of the library.
class _SyncRecoveryNotice extends StatelessWidget {
  const _SyncRecoveryNotice({
    super.key,
    required this.runtime,
    required this.child,
  });

  final EditorV2AccountRuntime runtime;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: runtime.engine,
      builder: (context, _) => FutureBuilder<String?>(
        future: runtime.recoveryReport(),
        builder: (context, snapshot) {
          final report = snapshot.data;
          return Column(
            children: [
              if (report != null)
                MaterialBanner(
                  content: const Text(
                    'Some sync changes need review. The original edits were kept.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: report));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Recovery data copied.'),
                            ),
                          );
                        }
                      },
                      child: const Text('Copy recovery data'),
                    ),
                    TextButton(
                      onPressed: () async {
                        try {
                          final session = context
                              .read<AccountSessionController>();
                          final userId = session.userId;
                          final namespace = ActiveStorageNamespace.current;
                          await runtime.restoreRecoveryCopies(
                            isCurrent: () =>
                                context.mounted &&
                                userId != null &&
                                session.isSignedIn &&
                                !session.isBusy &&
                                session.userId == userId &&
                                ActiveStorageNamespace.current == namespace,
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Recovery copies checked.'),
                              ),
                            );
                          }
                        } catch (_) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'A recovery copy could not be created. The original data is still available.',
                                ),
                              ),
                            );
                          }
                        }
                      },
                      child: const Text('Recover notebook copies'),
                    ),
                  ],
                ),
              Expanded(child: child),
            ],
          );
        },
      ),
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
    required this.exitPhase,
    required this.allowOfflineExit,
    required this.onRetry,
    required this.onCancel,
    required this.onExitOffline,
    required this.child,
  });

  final ValueListenable<bool> finishingExit;
  final ValueListenable<String?> exitFailure;
  final ValueListenable<ShutdownPhase> exitPhase;
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
                  Positioned.fill(
                    child: ValueListenableBuilder<ShutdownPhase>(
                      valueListenable: exitPhase,
                      builder: (context, phase, _) =>
                          _FinishingExitOverlay(phase: phase),
                    ),
                  )
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
  const _FinishingExitOverlay({required this.phase});

  final ShutdownPhase phase;

  @override
  Widget build(BuildContext context) {
    final message = switch (phase) {
      ShutdownPhase.flushLocal => 'Saving local edits and outbox...',
      ShutdownPhase.syncRemote => 'Synchronizing account changes...',
      ShutdownPhase.verifyBackup => 'Verifying remote backup...',
      ShutdownPhase.stopServices => 'Stopping background services...',
      _ => 'Finishing saves before closing...',
    };
    return AbsorbPointer(
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
                  Text(message),
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
