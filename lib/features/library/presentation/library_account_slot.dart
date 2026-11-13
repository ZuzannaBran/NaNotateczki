import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/error/one_shot_error_notice.dart';
import '../../../core/input/ink_activity_tracker.dart';
import '../../../core/storage/app_save_coordinator.dart';
import '../../../core/storage/shutdown_coordinator.dart';
import '../../../core/storage/text_storage.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_dialog_actions.dart';
import '../../../core/widgets/app_header_divider.dart';
import '../../../core/widgets/app_labeled_field.dart';
import '../../../data/backup/remote_backup_scheduler.dart';
import '../../notebook/data/notebook_repository.dart';
import '../../../data/sync/account_session_controller.dart';
import '../../../data/sync/api_client.dart';
import '../../../data/sync/editor_v2_account_runtime.dart';
import '../../../data/sync/sync_engine.dart';

TextStyle _accountSecondaryTextStyle(BuildContext context) => TextStyle(
  fontSize: AppTypography.small,
  color: Theme.of(context).colorScheme.onSurfaceVariant,
);

Future<void> showLibraryAccountDialog(
  BuildContext context, {
  required bool liveSyncAvailable,
  bool startupRequired = false,
}) {
  final session = context.read<AccountSessionController?>();
  final backup = context.read<RemoteBackupScheduler?>();
  final sync = context.read<EditorV2AccountRuntime?>();
  final repository = context.read<NotebookRepository?>();
  if (session == null || backup == null) {
    return Future<void>.value();
  }
  session.beginAccountInteraction();
  return showDialog<void>(
    context: context,
    barrierDismissible: !startupRequired,
    builder: (_) => MultiProvider(
      providers: [
        ChangeNotifierProvider<AccountSessionController>.value(value: session),
        ChangeNotifierProvider<RemoteBackupScheduler>.value(value: backup),
        Provider<EditorV2AccountRuntime?>.value(value: sync),
        if (repository != null)
          Provider<NotebookRepository>.value(value: repository),
      ],
      child: _AccountDialog(
        liveSyncAvailable: liveSyncAvailable,
        startupRequired: startupRequired,
      ),
    ),
  ).whenComplete(session.endAccountInteraction);
}

class LibraryAccountSlot extends StatelessWidget {
  const LibraryAccountSlot({super.key, this.liveSyncAvailable = true});

  final bool liveSyncAvailable;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AccountSessionController?>();
    final backup = context.watch<RemoteBackupScheduler?>();
    final sync = context.watch<EditorV2AccountRuntime?>()?.engine;
    if (session == null || backup == null) {
      return const SizedBox.shrink();
    }
    final subtitle = session.isSignedIn
        ? _remoteSubtitle(backup, sync, DateTime.now())
        : session.preferredMode == AccountDataMode.account
        ? 'Sign in to sync'
        : session.isLocalProfile
        ? 'Local mode'
        : 'Not signed in';

    return SizedBox(
      key: const ValueKey('account-menu-button'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    session.displayName,
                    key: const ValueKey('account-display-name'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: AppTypography.document,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    key: const ValueKey('account-status'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _accountSecondaryTextStyle(context),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              key: const ValueKey('account-settings-button'),
              tooltip: 'Account settings',
              icon: const Icon(Icons.settings_outlined, size: 18),
              onPressed: () => showLibraryAccountDialog(
                context,
                liveSyncAvailable: liveSyncAvailable,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _remoteSubtitle(
    RemoteBackupScheduler backup,
    SyncEngine? sync,
    DateTime now,
  ) {
    if (backup.lastError != null || sync?.lastError != null) {
      return 'Sync needs attention';
    }
    if (backup.isUploading) {
      return 'Backing up now';
    }
    final verifiedAt = backup.lastVerifiedBackup?.verifiedAt;
    if (verifiedAt != null) {
      return 'Backup ${_relativeTime(verifiedAt, now)}';
    }
    if (liveSyncAvailable && sync?.isStarted == true) {
      return 'V2 sync active';
    }
    return backup.isEnabled ? 'Remote backup enabled' : 'Connecting to account';
  }

  String _relativeTime(DateTime value, DateTime now) {
    final difference = now.toUtc().difference(value.toUtc());
    if (difference < const Duration(minutes: 1)) {
      return 'just now';
    }
    if (difference < const Duration(hours: 1)) {
      return '${difference.inMinutes}m ago';
    }
    if (difference < const Duration(days: 1)) {
      return '${difference.inHours}h ago';
    }
    return '${difference.inDays}d ago';
  }
}

class _AccountAvatar extends StatelessWidget {
  const _AccountAvatar({super.key, required this.letter, this.radius = 16});

  final String letter;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: radius * 2,
      height: radius * 2,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        shape: BoxShape.circle,
        border: Border.all(color: colors.onSurface.withValues(alpha: 0.18)),
      ),
      child: Text(
        letter,
        style: TextStyle(
          color: colors.onSurface,
          fontSize: AppTypography.folder,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

enum _AccountView { landing, signIn, register, local, settings, password }

enum _LogoutRecovery { retry, cancel, offline }

class _AccountDialog extends StatefulWidget {
  const _AccountDialog({
    required this.liveSyncAvailable,
    required this.startupRequired,
  });

  final bool liveSyncAvailable;
  final bool startupRequired;

  @override
  State<_AccountDialog> createState() => _AccountDialogState();
}

class _AccountDialogState extends State<_AccountDialog> {
  static final _serviceNotices = OneShotErrorNotice();
  String? _newServiceError;

  final _signInFormKey = GlobalKey<FormState>();
  final _registerFormKey = GlobalKey<FormState>();
  final _localFormKey = GlobalKey<FormState>();
  final _passwordFormKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _passwordConfirmationController = TextEditingController();
  final _localNameController = TextEditingController();
  final _currentPasswordController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _newPasswordConfirmationController = TextEditingController();
  final Set<TextEditingController> _visiblePasswords = {};
  late _AccountView _view;
  bool _isWorking = false;
  String? _actionError;
  String? _actionMessage;

  @override
  void initState() {
    super.initState();
    final session = context.read<AccountSessionController>();
    _serviceNotices.acknowledge(session, session.error);
    final backup = context.read<RemoteBackupScheduler>();
    _serviceNotices.acknowledge(backup, backup.lastError);
    final sync = context.read<EditorV2AccountRuntime?>()?.engine;
    if (sync != null) _serviceNotices.acknowledge(sync, sync.lastError);
    _usernameController.text =
        session.lastAccountUsername ?? session.username ?? '';
    _localNameController.text = session.localDisplayName ?? '';
    final hasLocalProfile =
        session.preferredMode == AccountDataMode.localOnly &&
        session.isLocalProfile;
    _view = widget.startupRequired
        ? _AccountView.landing
        : session.isSignedIn || hasLocalProfile
        ? _AccountView.settings
        : session.onboardingComplete
        ? _AccountView.signIn
        : _AccountView.landing;
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _passwordConfirmationController.dispose();
    _localNameController.dispose();
    _currentPasswordController.dispose();
    _newPasswordController.dispose();
    _newPasswordConfirmationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AccountSessionController>();
    final backup = context.watch<RemoteBackupScheduler>();
    final sync = context.watch<EditorV2AccountRuntime?>()?.engine;
    for (final (source, message) in <(Object, String?)>[
      (session, session.error),
      (backup, backup.lastError),
      if (sync != null) (sync, sync.lastError),
    ]) {
      if (_serviceNotices.shouldPresent(source, message)) {
        _newServiceError = message;
      }
    }
    if (_newServiceError != null &&
        session.error != _newServiceError &&
        backup.lastError != _newServiceError &&
        sync?.lastError != _newServiceError) {
      _newServiceError = null;
    }
    final error = _actionError ?? _newServiceError;
    final canClose = !widget.startupRequired;

    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      backgroundColor: colors.surface,
      elevation: 10,
      shadowColor: colors.shadow.withValues(alpha: 0.12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      titlePadding: const EdgeInsets.fromLTRB(28, 24, 28, 0),
      title: Text(
        _title,
        key: const ValueKey('account-dialog-title'),
        textAlign: TextAlign.center,
        style: AppHeaderDivider.titleStyle,
      ),
      contentPadding: const EdgeInsets.fromLTRB(28, 16, 28, 24),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: _buildView(session, backup, sync, error),
        ),
      ),
      actions: canClose
          ? appDialogActions(context, [
              TextButton(
                onPressed: _isWorking
                    ? null
                    : () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ])
          : null,
    );
  }

  String get _title => switch (_view) {
    _AccountView.landing => 'NaNotateczki',
    _AccountView.signIn => 'Sign in',
    _AccountView.register => 'Create account',
    _AccountView.local => 'Use local mode',
    _AccountView.settings => 'Account settings',
    _AccountView.password => 'Change password',
  };

  Widget _buildView(
    AccountSessionController session,
    RemoteBackupScheduler backup,
    SyncEngine? sync,
    String? error,
  ) {
    final child = switch (_view) {
      _AccountView.landing => _buildLanding(),
      _AccountView.signIn => _buildSignIn(error),
      _AccountView.register => _buildRegister(error),
      _AccountView.local => _buildLocal(error),
      _AccountView.settings => _buildSettings(session, backup, sync, error),
      _AccountView.password => _buildPassword(error),
    };
    return KeyedSubtree(key: ValueKey(_view), child: child);
  }

  Widget _buildLanding() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          kIsWeb
              ? 'Welcome. Sign in to access your account library.'
              : 'Welcome. Choose how you want to use NaNotateczki. '
                    'You can switch modes later in account settings.',
          key: const ValueKey('account-welcome-description'),
          textAlign: TextAlign.center,
          style: _accountSecondaryTextStyle(
            context,
          ).copyWith(fontSize: AppTypography.document),
        ),
        const SizedBox(height: 28),
        FilledButton(
          key: const ValueKey('account-create-choice'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: _isWorking ? null : () => _show(_AccountView.register),
          child: const Text('Create account'),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          key: const ValueKey('account-sign-in-choice'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
          onPressed: _isWorking ? null : () => _show(_AccountView.signIn),
          child: const Text('Sign in'),
        ),
        if (!kIsWeb) ...[
          const SizedBox(height: 12),
          TextButton(
            key: const ValueKey('account-local-choice'),
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(44)),
            onPressed: _isWorking ? null : () => _show(_AccountView.local),
            child: const Text('Try local'),
          ),
        ],
      ],
    );
  }

  Widget _buildSignIn(String? error) {
    return Form(
      key: _signInFormKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _usernameField(),
          const SizedBox(height: 18),
          _passwordField(_passwordController),
          if (_actionMessage != null) _MessageText(_actionMessage!),
          _ProgressAndError(isWorking: _isWorking, error: error),
          const SizedBox(height: 24),
          FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            key: const ValueKey('account-login-submit'),
            onPressed: _isWorking ? null : _login,
            child: const Text('Sign in'),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: _isWorking ? null : () => _show(_AccountView.landing),
            child: const Text('Back'),
          ),
        ],
      ),
    );
  }

  Widget _buildRegister(String? error) {
    return Form(
      key: _registerFormKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _usernameField(),
          const SizedBox(height: 18),
          _passwordField(_passwordController, newPassword: true),
          const SizedBox(height: 18),
          _passwordField(
            _passwordConfirmationController,
            key: const ValueKey('account-password-confirmation'),
            label: 'Repeat password',
            confirmationOf: _passwordController,
          ),
          _ProgressAndError(isWorking: _isWorking, error: error),
          const SizedBox(height: 24),
          FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            key: const ValueKey('account-register-submit'),
            onPressed: _isWorking ? null : _register,
            child: const Text('Create account'),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: _isWorking ? null : () => _show(_AccountView.landing),
            child: const Text('Back'),
          ),
        ],
      ),
    );
  }

  Widget _buildLocal(String? error) {
    return Form(
      key: _localFormKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Local mode keeps your library on this device and does not '
            'connect to the account server.',
          ),
          const SizedBox(height: 24),
          _accountLabeledField(
            label: 'Your name',
            child: TextFormField(
              key: const ValueKey('account-local-name'),
              controller: _localNameController,
              enabled: !_isWorking,
              textInputAction: TextInputAction.done,
              decoration: _accountInputDecoration(),
              validator: (value) {
                final length = value?.trim().length ?? 0;
                return length < 1 || length > 80
                    ? 'Enter a name containing 1 to 80 characters.'
                    : null;
              },
              onFieldSubmitted: (_) {
                if (!_isWorking) {
                  _useLocal();
                }
              },
            ),
          ),
          _ProgressAndError(isWorking: _isWorking, error: error),
          const SizedBox(height: 24),
          FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            key: const ValueKey('account-local-submit'),
            onPressed: _isWorking ? null : _useLocal,
            child: const Text('Continue locally'),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: _isWorking ? null : () => _show(_AccountView.landing),
            child: const Text('Back'),
          ),
        ],
      ),
    );
  }

  Widget _buildSettings(
    AccountSessionController session,
    RemoteBackupScheduler backup,
    SyncEngine? sync,
    String? error,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              children: [
                _AccountAvatar(
                  key: const ValueKey('account-dialog-avatar'),
                  letter: session.avatarLetter,
                  radius: 20,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        session.displayName,
                        key: const ValueKey('account-dialog-display-name'),
                        style: AppHeaderDivider.titleStyle,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        session.isSignedIn ? 'Online account' : 'Local mode',
                        key: const ValueKey('account-dialog-mode'),
                        style: _accountSecondaryTextStyle(context),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        if (session.isSignedIn) ...[
          Text(
            _backupStatus(backup),
            key: const ValueKey('remote-backup-status'),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Expanded(child: Text('Back up after inactivity')),
              const SizedBox(width: 12),
              DropdownButton<int>(
                key: const ValueKey('account-backup-idle'),
                value: backup.idleSeconds,
                onChanged: _isWorking
                    ? null
                    : (seconds) {
                        if (seconds != null) {
                          unawaited(_setBackupIdle(seconds));
                        }
                      },
                items: const [
                  DropdownMenuItem(value: 15, child: Text('15 sec')),
                  DropdownMenuItem(value: 30, child: Text('30 sec')),
                  DropdownMenuItem(value: 60, child: Text('1 min')),
                  DropdownMenuItem(value: 120, child: Text('2 min')),
                  DropdownMenuItem(value: 300, child: Text('5 min')),
                  DropdownMenuItem(value: 900, child: Text('15 min')),
                  DropdownMenuItem(value: 1800, child: Text('30 min')),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            key: const ValueKey('account-backup-now'),
            onPressed: _isWorking || backup.isUploading ? null : _backupNow,
            child: const Text('Back up now'),
          ),
          if (widget.liveSyncAvailable) ...[
            const SizedBox(height: 20),
            Text(
              'Live synchronization',
              style: const TextStyle(
                fontSize: AppTypography.folder,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              sync?.isStarted == true
                  ? 'V2 sync is active.'
                  : 'Connecting to v2.',
              key: const ValueKey('live-sync-status'),
            ),
          ],
          const SizedBox(height: 12),
          OutlinedButton(
            key: const ValueKey('account-change-password'),
            onPressed: _isWorking ? null : () => _show(_AccountView.password),
            child: const Text('Change password'),
          ),
          if (!kIsWeb) ...[
            const SizedBox(height: 12),
            TextButton(
              key: const ValueKey('account-switch-local'),
              onPressed: _isWorking ? null : () => _show(_AccountView.local),
              child: const Text('Switch to local mode'),
            ),
          ],
          const SizedBox(height: 12),
          OutlinedButton(
            key: const ValueKey('account-logout'),
            onPressed: _isWorking ? null : _logout,
            child: const Text('Log out'),
          ),
        ] else ...[
          const Text(
            'Remote backup and live synchronization are disabled '
            'in local mode.',
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            key: const ValueKey('account-edit-local-name'),
            onPressed: _isWorking ? null : () => _show(_AccountView.local),
            child: const Text('Change local name'),
          ),
          const SizedBox(height: 12),
          FilledButton(
            key: const ValueKey('account-switch-online'),
            onPressed: _isWorking ? null : () => _show(_AccountView.landing),
            child: const Text('Sign in or create account'),
          ),
        ],
        if (_actionMessage != null) _MessageText(_actionMessage!),
        _ProgressAndError(isWorking: _isWorking, error: error),
      ],
    );
  }

  Widget _buildPassword(String? error) {
    return Form(
      key: _passwordFormKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _passwordField(
            _currentPasswordController,
            key: const ValueKey('account-current-password'),
            label: 'Current password',
            allowAnyNonEmpty: true,
          ),
          const SizedBox(height: 18),
          _passwordField(
            _newPasswordController,
            key: const ValueKey('account-new-password'),
            label: 'New password',
            newPassword: true,
          ),
          const SizedBox(height: 18),
          _passwordField(
            _newPasswordConfirmationController,
            key: const ValueKey('account-new-password-confirmation'),
            label: 'Repeat new password',
            confirmationOf: _newPasswordController,
          ),
          _ProgressAndError(isWorking: _isWorking, error: error),
          const SizedBox(height: 24),
          FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            key: const ValueKey('account-change-password-submit'),
            onPressed: _isWorking ? null : _changePassword,
            child: const Text('Change password'),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: _isWorking ? null : () => _show(_AccountView.settings),
            child: const Text('Back'),
          ),
        ],
      ),
    );
  }

  Widget _usernameField() {
    return _accountLabeledField(
      label: 'Username',
      child: TextFormField(
        key: const ValueKey('account-username'),
        controller: _usernameController,
        enabled: !_isWorking,
        keyboardType: TextInputType.text,
        autofillHints: const [AutofillHints.username],
        textInputAction: TextInputAction.next,
        decoration: _accountInputDecoration(),
        validator: (value) =>
            AccountSessionController.usernamePattern.hasMatch(
              value?.trim() ?? '',
            )
            ? null
            : 'Use 3–32 letters, numbers or underscores.',
      ),
    );
  }

  Widget _accountLabeledField({required String label, required Widget child}) {
    return AppLabeledField(
      label: label,
      labelKey: ValueKey('account-field-label-$label'),
      child: child,
    );
  }

  InputDecoration _accountInputDecoration({Widget? suffixIcon}) {
    return appFormFieldDecoration(suffixIcon: suffixIcon);
  }

  Widget _passwordField(
    TextEditingController controller, {
    Key? key,
    String label = 'Password',
    bool newPassword = false,
    bool allowAnyNonEmpty = false,
    TextEditingController? confirmationOf,
  }) {
    final visible = _visiblePasswords.contains(controller);
    final isNewPassword = newPassword || confirmationOf != null;
    return _accountLabeledField(
      label: label,
      child: TextFormField(
        key: key ?? const ValueKey('account-password'),
        controller: controller,
        enabled: !_isWorking,
        obscureText: !visible,
        enableSuggestions: false,
        autocorrect: false,
        autofillHints: [
          isNewPassword ? AutofillHints.newPassword : AutofillHints.password,
        ],
        decoration: _accountInputDecoration(
          suffixIcon: IconButton(
            key: ValueKey('account-password-visibility-$label'),
            tooltip: visible ? 'Hide $label' : 'Show $label',
            onPressed: () {
              setState(() {
                if (visible) {
                  _visiblePasswords.remove(controller);
                } else {
                  _visiblePasswords.add(controller);
                }
              });
            },
            icon: Icon(
              visible
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
            ),
          ),
        ),
        validator: (value) {
          final password = value ?? '';
          if (allowAnyNonEmpty) {
            return password.isEmpty ? 'Enter the current password.' : null;
          }
          if (confirmationOf != null && password != confirmationOf.text) {
            return 'Passwords do not match.';
          }
          if (isNewPassword) {
            return password.length < 8 || password.length > 128
                ? 'Use 8 to 128 characters.'
                : null;
          }
          return password.isEmpty || password.length > 256
              ? 'Enter your password.'
              : null;
        },
      ),
    );
  }

  String _backupStatus(RemoteBackupScheduler backup) {
    if (backup.isUploading) {
      return 'Remote backup is running.';
    }
    final receipt = backup.lastVerifiedBackup;
    if (receipt != null) {
      return 'Last verified backup: ${receipt.verifiedAt.toLocal()}';
    }
    return backup.isEnabled
        ? 'Verified remote backup is enabled.'
        : 'Remote backup is stopped.';
  }

  void _show(_AccountView view) {
    context.read<AccountSessionController>().clearError();
    setState(() {
      _view = view;
      _actionError = null;
      _newServiceError = null;
      _actionMessage = null;
    });
  }

  Future<void> _login() => _authenticate(register: false);

  Future<void> _register() => _authenticate(register: true);

  Future<void> _authenticate({required bool register}) async {
    final form = register ? _registerFormKey : _signInFormKey;
    if (form.currentState?.validate() != true) {
      return;
    }
    _startWorking();
    try {
      final session = context.read<AccountSessionController>();
      var importLocalData = false;
      if (session.isLocalProfile &&
          session.preferredMode == AccountDataMode.localOnly) {
        final decision = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Local data'),
            content: const Text(
              'Would you like to add a copy of your Local notebooks, '
              'folders, tasks and study sessions to this account? '
              'Your Local library will remain unchanged. '
              'Account preferences will take priority.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
              TextButton(
                key: const ValueKey('account-keep-local-separate'),
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Keep local data separate'),
              ),
              FilledButton(
                key: const ValueKey('account-import-local'),
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Add local data to this account'),
              ),
            ],
          ),
        );
        if (decision == null || !mounted) {
          return;
        }
        importLocalData = decision;
      }
      if (register) {
        await session.register(
          _usernameController.text,
          _passwordController.text,
          importLocalData: importLocalData,
        );
      } else {
        await session.login(
          _usernameController.text,
          _passwordController.text,
          importLocalData: importLocalData,
        );
      }
      if (!mounted) {
        return;
      }
      // AppScope restores the account before enabling new backups.
      _passwordController.clear();
      _passwordConfirmationController.clear();
      if (widget.liveSyncAvailable) {
        _show(_AccountView.settings);
      } else if (widget.startupRequired) {
        Navigator.of(context).pop();
      } else {
        _show(_AccountView.settings);
      }
    } catch (failure) {
      _showFailure(failure);
    } finally {
      _stopWorking();
    }
  }

  /// Flush all local writes before any network operation or credential change.
  Future<void> _finishSignedInSession({bool preserveOffline = false}) async {
    final session = context.read<AccountSessionController>();
    if (!session.isSignedIn) {
      return;
    }
    if (session.onBeforeLogout != null) {
      if (preserveOffline) {
        await session.logoutOffline();
      } else {
        await session.logout();
      }
      return;
    }
    final runtime = context.read<EditorV2AccountRuntime?>();
    final backup = context.read<RemoteBackupScheduler>();
    final repository = context.read<NotebookRepository?>();
    final coordinator = ShutdownCoordinator(
      flushLocal: () async {
        await InkActivityTracker.instance.waitForNoActiveContacts();
        await AppSaveCoordinator.instance.flushPending();
        await repository?.waitForPendingSaves();
        await waitForPendingTextStorageOperations();
        if (AppSaveCoordinator.instance.hasPendingWork ||
            (repository?.hasPendingSaves ?? false)) {
          throw StateError('Local editor writes are still pending.');
        }
      },
      syncRemote: () async {
        if (runtime == null || !runtime.engine.isStarted) {
          throw StateError('V2 sync has not started.');
        }
        await runtime.engine.syncNow();
        if (runtime.engine.lastError != null ||
            (await runtime.store.pending(
              limit: 1,
              includeDeferred: true,
            )).isNotEmpty) {
          throw StateError('Unsent account operations remain in the outbox.');
        }
      },
      verifyBackup: () async {
        if (!backup.isEnabled) {
          backup.enableForSignedInAccount();
        }
        await backup.ensureVerifiedForExit();
        if (backup.hasPendingBackup || backup.lastError != null) {
          throw StateError('The final account backup is not verified.');
        }
      },
      stopServices: () async {
        // Timeouts from the preceding network steps do not cancel I/O.
        // Join all writers before clearing or changing account identity.
        await runtime?.stop();
        await backup.stop();
        await waitForPendingTextStorageOperations();
      },
      endSession: () async {
        try {
          await session.logout();
        } catch (_) {
          // The server may be offline, but local credentials are erased
          // in logout's finally block. Never mask local persistence errors.
          if (session.isSignedIn) {
            rethrow;
          }
        }
      },
    );
    await coordinator.run(preserveOffline: preserveOffline);
  }

  Future<bool> _finishSessionWithChoice() async {
    while (true) {
      try {
        await _finishSignedInSession();
        return true;
      } on ShutdownInterrupted catch (failure) {
        if (!failure.localSafe || !mounted) {
          rethrow;
        }
        final choice = await showDialog<_LogoutRecovery>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Account sync not complete'),
            content: Text(
              'Local changes are saved. Remote sync or backup stopped '
              'at ${failure.phase.name}. Your unsent changes will remain '
              'on this device.',
            ),
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(_LogoutRecovery.cancel),
                child: const Text('Stay signed in'),
              ),
              TextButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(_LogoutRecovery.retry),
                child: const Text('Retry'),
              ),
              TextButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(_LogoutRecovery.offline),
                child: const Text('Log out offline'),
              ),
            ],
          ),
        );
        if (choice == _LogoutRecovery.cancel || choice == null) {
          return false;
        }
        if (choice == _LogoutRecovery.offline) {
          await _finishSignedInSession(preserveOffline: true);
          return true;
        }
      }
    }
  }

  Future<void> _useLocal() async {
    if (_localFormKey.currentState?.validate() != true) {
      return;
    }
    final session = context.read<AccountSessionController>();
    _startWorking();
    try {
      if (!await _finishSessionWithChoice()) {
        return;
      }
      await session.useLocalProfile(_localNameController.text);
      if (!mounted) {
        return;
      }
      if (widget.startupRequired) {
        Navigator.of(context).pop();
      } else {
        _show(_AccountView.settings);
      }
    } catch (failure) {
      _showFailure(failure);
    } finally {
      _stopWorking();
    }
  }

  Future<void> _logout() async {
    _startWorking();
    try {
      if (!await _finishSessionWithChoice()) {
        return;
      }
      if (mounted) {
        _show(_AccountView.landing);
      }
    } catch (failure) {
      // A failed backup is a recoverable state, never permission to discard
      // the active session or its unsent edits.
      _showFailure(failure);
    } finally {
      _stopWorking();
    }
  }

  Future<void> _setBackupIdle(int seconds) async {
    try {
      await context.read<RemoteBackupScheduler>().setIdleSeconds(seconds);
    } catch (failure) {
      _showFailure(failure);
    }
  }

  Future<void> _backupNow() async {
    _startWorking();
    try {
      final backup = context.read<RemoteBackupScheduler>();
      await backup.backupNow();
      if (backup.lastError != null) {
        throw StateError(backup.lastError!);
      }
      if (mounted) {
        setState(() => _actionMessage = 'Backup verified.');
      }
    } catch (failure) {
      _showFailure(failure);
    } finally {
      _stopWorking();
    }
  }

  Future<void> _changePassword() async {
    if (_passwordFormKey.currentState?.validate() != true) {
      return;
    }
    final session = context.read<AccountSessionController>();
    final runtime = context.read<EditorV2AccountRuntime?>();
    final backup = context.read<RemoteBackupScheduler>();
    _startWorking();
    try {
      await session.changePassword(
        _currentPasswordController.text,
        _newPasswordController.text,
      );
      await runtime?.stop();
      await backup.stop();
      await session.requireAccountReauthentication();
      _currentPasswordController.clear();
      _newPasswordController.clear();
      _newPasswordConfirmationController.clear();
      if (mounted) {
        setState(() {
          _view = _AccountView.signIn;
          _actionMessage = 'Password changed. Sign in again.';
        });
      }
    } catch (failure) {
      _showFailure(failure);
    } finally {
      _stopWorking();
    }
  }

  void _startWorking() {
    setState(() {
      _isWorking = true;
      _actionError = null;
      _newServiceError = null;
      _actionMessage = null;
    });
  }

  void _stopWorking() {
    if (mounted) {
      setState(() => _isWorking = false);
    }
  }

  void _showFailure(Object failure) {
    if (mounted) {
      setState(() => _actionError = _failureMessage(failure));
    }
  }

  String _failureMessage(Object failure) {
    if (failure is ApiException) {
      return failure.message;
    }
    if (failure is FormatException) {
      return failure.message;
    }
    if (failure is StateError) {
      return failure.message;
    }
    return failure.toString();
  }
}

class _ProgressAndError extends StatelessWidget {
  const _ProgressAndError({required this.isWorking, required this.error});

  final bool isWorking;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isWorking) ...[
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
        ],
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              error!,
              key: const ValueKey('account-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
  }
}

class _MessageText extends StatelessWidget {
  const _MessageText(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(
        message,
        key: const ValueKey('account-message'),
        style: TextStyle(color: Theme.of(context).colorScheme.primary),
      ),
    );
  }
}
