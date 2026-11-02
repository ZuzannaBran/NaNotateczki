import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/widgets/app_labeled_field.dart';
import '../../../data/sync/api_client.dart';

String currentSystemName() {
  if (kIsWeb) {
    return 'Web';
  }
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => 'Android',
    TargetPlatform.iOS => 'iOS',
    TargetPlatform.linux => 'Linux',
    TargetPlatform.macOS => 'macOS',
    TargetPlatform.windows => 'Windows',
    TargetPlatform.fuchsia => 'Other',
  };
}

class ContactCreatorTab extends StatefulWidget {
  const ContactCreatorTab({super.key});

  @override
  State<ContactCreatorTab> createState() => _ContactCreatorTabState();
}

class _ContactCreatorTabState extends State<ContactCreatorTab> {
  static const _systems = [
    'Linux',
    'Web',
    'Android',
    'iOS',
    'macOS',
    'Windows',
    'Other',
  ];

  final _formKey = GlobalKey<FormState>();
  final _issueController = TextEditingController();
  late String _system = currentSystemName();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _issueController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_sending || !(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await context.read<ApiClient>().postJson('/v1/reports/feedback', {
        'system': _system,
        'issue': _issueController.text.trim(),
      }, authenticated: false);
      if (!mounted) {
        return;
      }
      _issueController.clear();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Report sent. Thank you.')));
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Could not send the report. Check your connection.';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Contact the creator',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Report a bug or describe a problem with NaNotateczki.',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  AppLabeledField(
                    label: 'System',
                    child: DropdownButtonFormField<String>(
                      key: const ValueKey('contact-system'),
                      initialValue: _system,
                      isExpanded: true,
                      decoration: appFormFieldDecoration(),
                      items: [
                        for (final system in _systems)
                          DropdownMenuItem(value: system, child: Text(system)),
                      ],
                      onChanged: _sending
                          ? null
                          : (value) {
                              if (value != null) {
                                setState(() => _system = value);
                              }
                            },
                    ),
                  ),
                  const SizedBox(height: 20),
                  AppLabeledField(
                    label: 'Describe the issue',
                    child: TextFormField(
                      key: const ValueKey('contact-issue'),
                      controller: _issueController,
                      enabled: !_sending,
                      decoration: appFormFieldDecoration(),
                      minLines: 5,
                      maxLines: 8,
                      maxLength: 5000,
                      validator: (text) => (text?.trim().length ?? 0) < 5
                          ? 'Please describe the issue.'
                          : null,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_error != null) ...[
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  FilledButton(
                    key: const ValueKey('contact-send'),
                    onPressed: _sending ? null : _submit,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    child: Text(_sending ? 'Sending...' : 'Send report'),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Reports are stored privately on the project server. '
                    'When signed in, diagnostic logs are also updated '
                    'automatically and may contain device paths or stack traces.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
