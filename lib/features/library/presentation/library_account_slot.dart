import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/app_dialog_actions.dart';
import '../../../data/backup/remote_backup_scheduler.dart';
import '../../../data/sync/account_session_controller.dart';
import '../../../data/sync/api_client.dart';
import '../../../data/sync/live_web_sync_service.dart';

Future<void> showLibraryAccountDialog(
  BuildContext context, {
  required bool liveSyncAvailable,
  bool startupRequired = false,
}) {
  final session = context.read<AccountSessionController?>();
  final backup = context.read<RemoteBackupScheduler?>();
  final sync = context.read<LiveWebSyncService?>();
  if (session == null || backup == null || sync == null) {
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
        ChangeNotifierProvider<LiveWebSyncService>.value(value: sync),
      ],
      child: _AccountDialog(
        liveSyncAvailable: liveSyncAvailable,
        startupRequired: startupRequired,
      ),
    ),
  ).whenComplete(session.endAccountInteraction);
}

class LibraryAccountSlot extends StatelessWidget {
  const LibraryAccountSlot({super.key, this.liveSyncAvailable = kIsWeb});

  final bool liveSyncAvailable;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AccountSessionController?>();
    final backup = context.watch<RemoteBackupScheduler?>();
    final sync = context.watch<LiveWebSyncService?>();
    if (session == null || backup == null || sync == null) {
      return const SizedBox.shrink();
    }
    final colors = Theme.of(context).colorScheme;
    final subtitle = session.isSignedIn
        ? _remoteSubtitle(backup, sync, DateTime.now())
        : null;

    return SizedBox(
      key: const ValueKey('account-menu-button'),
      child: Padding(
        padding: const EdgeInsets.only(left: 14, right: 4),
        child: Row(
          children: [
            CircleAvatar(
              key: const ValueKey('account-avatar'),
              radius: 16,
              backgroundColor: colors.surfaceContainerHigh,
              foregroundColor: colors.onSurface,
              child: Text(
                session.avatarLetter,
                style: const TextStyle(
                  fontSize: AppTypography.folder,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 10),
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
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      key: const ValueKey('account-remote-status'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ),
            IconButton(
              key: const ValueKey('account-settings-button'),
              tooltip: 'Account settings',
              icon: const Icon(Icons.settings_outlined),
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
    LiveWebSyncService sync,
    DateTime now,
  ) {
    if (backup.lastError != null || sync.lastError != null) {
      return 'Sync needs attention';
    }
    if (backup.isUploading) {
      return 'Backing up now';
    }
    final verifiedAt = backup.lastVerifiedBackup?.verifiedAt;
    if (verifiedAt != null) {
      return 'Backup ${_relativeTime(verifiedAt, now)}';
    }
    if (liveSyncAvailable && sync.isStarted) {
      return sync.hasPendingChanges ? 'Syncing changes' : 'Live sync active';
    }
    return 'Remote backup enabled';
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

enum _AccountView { landing, signIn, register, local, settings, password }

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
  final _signInFormKey = GlobalKey<FormState>();
  final _registerFormKey = GlobalKey<FormState>();
  final _localFormKey = GlobalKey<FormState>();
  final _passwordFormKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _passwordConfirmationController = TextEditingController();
  final _localNameController = TextEditingController();
  final _currentPasswordController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _newPasswordConfirmationController = TextEditingController();
  late _AccountView _view;
  bool _isWorking = false;
  String? _actionError;
  String? _actionMessage;

  @override
  void initState() {
    super.initState();
    final session = context.read<AccountSessionController>();
    _emailController.text = session.lastAccountEmail ?? session.email ?? '';
    _localNameController.text = session.localDisplayName ?? '';
    _view = widget.startupRequired
        ? _AccountView.landing
        : (session.isSignedIn || session.isLocalProfile)
        ? _AccountView.settings
        : _AccountView.landing;
  }

  @override
  void dispose() {
    _emailController.dispose();
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
    final sync = context.watch<LiveWebSyncService>();
    final error =
        _actionError ?? session.error ?? backup.lastError ?? sync.lastError;
    final canClose = !widget.startupRequired;

    return AlertDialog(
      title: Text(_title),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: _buildView(session, backup, sync, error),
          ),
        ),
      ),
      actions: appDialogActions(context, [
        if (canClose)
          TextButton(
            onPressed: _isWorking ? null : () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
      ]),
    );
  }

  String get _title => switch (_view) {
    _AccountView.landing => widget.startupRequired ? 'Welcome' : 'Account',
    _AccountView.signIn => 'Sign in',
    _AccountView.register => 'Create account',
    _AccountView.local => 'Use local mode',
    _AccountView.settings => 'Account settings',
    _AccountView.password => 'Change password',
  };

  Widget _buildView(
    AccountSessionController session,
    RemoteBackupScheduler backup,
    LiveWebSyncService sync,
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
        const Text(
          'Choose how you want to use Notatek. You can switch modes later '
          'from account settings.',
        ),
        const SizedBox(height: 20),
        FilledButton(
          key: const ValueKey('account-create-choice'),
          onPressed: _isWorking ? null : () => _show(_AccountView.register),
          child: const Text('Create account'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          key: const ValueKey('account-sign-in-choice'),
          onPressed: _isWorking ? null : () => _show(_AccountView.signIn),
          child: const Text('Sign in'),
        ),
        const SizedBox(height: 4),
        TextButton(
          key: const ValueKey('account-local-choice'),
          onPressed: _isWorking ? null : () => _show(_AccountView.local),
          child: const Text('Try local'),
        ),
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
          _emailField(),
          const SizedBox(height: 12),
          _passwordField(_passwordController),
          if (_actionMessage != null) _MessageText(_actionMessage!),
          _ProgressAndError(isWorking: _isWorking, error: error),
          const SizedBox(height: 16),
          FilledButton(
            key: const ValueKey('account-login-submit'),
            onPressed: _isWorking ? null : _login,
            child: const Text('Sign in'),
          ),
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
          _emailField(),
          const SizedBox(height: 12),
          _passwordField(_passwordController, newPassword: true),
          const SizedBox(height: 12),
          _passwordField(
            _passwordConfirmationController,
            key: const ValueKey('account-password-confirmation'),
            label: 'Repeat password',
            confirmationOf: _passwordController,
          ),
          _ProgressAndError(isWorking: _isWorking, error: error),
          const SizedBox(height: 16),
          FilledButton(
            key: const ValueKey('account-register-submit'),
            onPressed: _isWorking ? null : _register,
            child: const Text('Create account'),
          ),
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
          const SizedBox(height: 16),
          TextFormField(
            key: const ValueKey('account-local-name'),
            controller: _localNameController,
            enabled: !_isWorking,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(labelText: 'Your name'),
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
          _ProgressAndError(isWorking: _isWorking, error: error),
          const SizedBox(height: 16),
          FilledButton(
            key: const ValueKey('account-local-submit'),
            onPressed: _isWorking ? null : _useLocal,
            child: const Text('Continue locally'),
          ),
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
    LiveWebSyncService sync,
    String? error,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            CircleAvatar(child: Text(session.avatarLetter)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    session.displayName,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    session.isSignedIn ? 'Online account' : 'Local mode',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        if (session.isSignedIn) ...[
          Text(
            _backupStatus(backup),
            key: const ValueKey('remote-backup-status'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const ValueKey('account-backup-now'),
            onPressed: _isWorking || backup.isUploading ? null : _backupNow,
            icon: const Icon(Icons.cloud_upload_outlined),
            label: const Text('Back up now'),
          ),
          if (widget.liveSyncAvailable) ...[
            const SizedBox(height: 20),
            Text(
              'Live synchronization',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            if (!sync.isStarted) ...[
              const Text(
                'Choose how this browser should perform its first safe sync.',
              ),
              const SizedBox(height: 12),
              _SyncPolicyButton(
                key: const ValueKey('sync-policy-upload'),
                title: 'Upload local library',
                description: 'Only when the account library is empty.',
                onPressed: _isWorking
                    ? null
                    : () => _startSync(InitialSyncPolicy.uploadLocal),
              ),
              _SyncPolicyButton(
                key: const ValueKey('sync-policy-download'),
                title: 'Download remote library',
                description: 'Only when this browser library is empty.',
                onPressed: _isWorking
                    ? null
                    : () => _startSync(InitialSyncPolicy.downloadRemote),
              ),
              _SyncPolicyButton(
                key: const ValueKey('sync-policy-merge'),
                title: 'Merge safely',
                description: 'Keep both versions when content differs.',
                onPressed: _isWorking
                    ? null
                    : () => _startSync(InitialSyncPolicy.mergeSafely),
              ),
            ] else
              Text(
                sync.hasPendingChanges
                    ? 'Live sync is active. Changes are waiting to upload.'
                    : 'Live sync is active and up to date.',
                key: const ValueKey('live-sync-status'),
              ),
          ],
          const SizedBox(height: 12),
          OutlinedButton(
            key: const ValueKey('account-change-password'),
            onPressed: _isWorking ? null : () => _show(_AccountView.password),
            child: const Text('Change password'),
          ),
          TextButton(
            key: const ValueKey('account-switch-local'),
            onPressed: _isWorking ? null : () => _show(_AccountView.local),
            child: const Text('Switch to local mode'),
          ),
        ] else ...[
          const Text(
            'Remote backup and live synchronization are disabled in local mode.',
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            key: const ValueKey('account-edit-local-name'),
            onPressed: _isWorking ? null : () => _show(_AccountView.local),
            child: const Text('Change local name'),
          ),
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
          const SizedBox(height: 12),
          _passwordField(
            _newPasswordController,
            key: const ValueKey('account-new-password'),
            label: 'New password',
            newPassword: true,
          ),
          const SizedBox(height: 12),
          _passwordField(
            _newPasswordConfirmationController,
            key: const ValueKey('account-new-password-confirmation'),
            label: 'Repeat new password',
            confirmationOf: _newPasswordController,
          ),
          _ProgressAndError(isWorking: _isWorking, error: error),
          const SizedBox(height: 16),
          FilledButton(
            key: const ValueKey('account-change-password-submit'),
            onPressed: _isWorking ? null : _changePassword,
            child: const Text('Change password'),
          ),
          TextButton(
            onPressed: _isWorking ? null : () => _show(_AccountView.settings),
            child: const Text('Back'),
          ),
        ],
      ),
    );
  }

  Widget _emailField() {
    return TextFormField(
      key: const ValueKey('account-email'),
      controller: _emailController,
      enabled: !_isWorking,
      keyboardType: TextInputType.emailAddress,
      autofillHints: const [AutofillHints.email],
      textInputAction: TextInputAction.next,
      decoration: const InputDecoration(labelText: 'E-mail'),
      validator: (value) => value == null || !value.contains('@')
          ? 'Enter a valid e-mail address.'
          : null,
    );
  }

  Widget _passwordField(
    TextEditingController controller, {
    Key? key,
    String label = 'Password',
    bool newPassword = false,
    bool allowAnyNonEmpty = false,
    TextEditingController? confirmationOf,
  }) {
    return TextFormField(
      key: key ?? const ValueKey('account-password'),
      controller: controller,
      enabled: !_isWorking,
      obscureText: true,
      autofillHints: [
        newPassword ? AutofillHints.newPassword : AutofillHints.password,
      ],
      decoration: InputDecoration(labelText: label),
      validator: (value) {
        final password = value ?? '';
        if (allowAnyNonEmpty) {
          return password.isEmpty ? 'Enter the current password.' : null;
        }
        if (confirmationOf != null && password != confirmationOf.text) {
          return 'Passwords do not match.';
        }
        return password.length < 12 || password.length > 256
            ? 'Use 12 to 256 characters.'
            : null;
      },
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
      if (register) {
        await session.register(_emailController.text, _passwordController.text);
      } else {
        await session.login(_emailController.text, _passwordController.text);
      }
      if (!mounted) {
        return;
      }
      context.read<RemoteBackupScheduler>().enableForSignedInAccount();
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

  Future<void> _useLocal() async {
    if (_localFormKey.currentState?.validate() != true) {
      return;
    }
    final session = context.read<AccountSessionController>();
    final sync = context.read<LiveWebSyncService>();
    final backup = context.read<RemoteBackupScheduler>();
    _startWorking();
    try {
      if (session.isSignedIn) {
        await sync.stop();
        await backup.stop();
        await session.logout();
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

  Future<void> _startSync(InitialSyncPolicy policy) async {
    _startWorking();
    try {
      await context.read<LiveWebSyncService>().start(policy);
      if (!mounted) {
        return;
      }
      if (widget.startupRequired) {
        Navigator.of(context).pop();
      } else {
        setState(() => _actionMessage = 'Live sync started.');
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
    final sync = context.read<LiveWebSyncService>();
    final backup = context.read<RemoteBackupScheduler>();
    _startWorking();
    try {
      await session.changePassword(
        _currentPasswordController.text,
        _newPasswordController.text,
      );
      await sync.stop();
      await backup.stop();
      session.requireAccountReauthentication();
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

class _SyncPolicyButton extends StatelessWidget {
  const _SyncPolicyButton({
    super.key,
    required this.title,
    required this.description,
    required this.onPressed,
  });

  final String title;
  final String description;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: OutlinedButton(
        onPressed: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title),
                    Text(
                      description,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
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
