import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../../core/theme/app_theme.dart';
import '../../../data/sync/api_client.dart';
import '../../../data/sync/study_share_service.dart';

class StudyShareGuestApp extends StatelessWidget {
  const StudyShareGuestApp({required this.sessionId, super.key});

  final String sessionId;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NaNotateczki – Study session',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: _StudyShareGuestScreen(sessionId: sessionId),
    );
  }
}

class _StudyShareGuestScreen extends StatefulWidget {
  const _StudyShareGuestScreen({required this.sessionId});

  final String sessionId;

  @override
  State<_StudyShareGuestScreen> createState() => _StudyShareGuestScreenState();
}

class _StudyShareGuestScreenState extends State<_StudyShareGuestScreen> {
  final _password = TextEditingController();
  final _client = StudyShareGuestClient();
  StreamSubscription<dynamic>? _subscription;
  WebSocketChannel? _channel;
  Timer? _pollTimer;
  Timer? _reconnectTimer;
  Timer? _clockTimer;
  Uint8List? _frame;
  String? _ticket;
  String? _title;
  String? _error;
  DateTime? _expiresAt;
  bool _loading = false;
  bool _fetching = false;
  bool _ended = false;

  @override
  void initState() {
    super.initState();
    _clockTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && _ticket != null) {
        setState(() {});
      }
    });
  }

  Future<void> _join() async {
    if (_loading || _password.text.isEmpty) {
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await _client.join(widget.sessionId, _password.text);
      if (!mounted) {
        return;
      }
      setState(() {
        _ticket = response['ticket'] as String;
        _title = response['title'] as String;
        _expiresAt = DateTime.tryParse(response['expiresAt'] as String? ?? '');
        _frame = null;
        _ended = false;
        _password.clear();
      });
      _connect();
      _pollTimer = Timer.periodic(
        const Duration(seconds: 20),
        (_) => unawaited(_fetchFrame()),
      );
      await _fetchFrame();
    } catch (error) {
      if (mounted) {
        setState(() => _error = _message(error));
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  void _connect() {
    final ticket = _ticket;
    if (!mounted || ticket == null || _ended) {
      return;
    }
    unawaited(_subscription?.cancel());
    unawaited(_channel?.sink.close());
    try {
      final channel = WebSocketChannel.connect(
        _client.eventsUri(widget.sessionId),
      );
      _channel = channel;
      _subscription = channel.stream.listen(
        (raw) {
          if (!mounted || raw is! String) {
            return;
          }
          try {
            final event = jsonDecode(raw);
            if (event is! Map<String, dynamic>) {
              return;
            }
            switch (event['type']) {
              case 'frame_changed':
                unawaited(_fetchFrame());
                break;
              case 'extended':
                final expires = event['expiresAt'];
                if (expires is String) {
                  setState(() => _expiresAt = DateTime.tryParse(expires));
                }
                break;
              case 'ended':
                _endView('The host ended this session.');
                break;
            }
          } catch (_) {
            // Ignore malformed, non-authoritative real-time notifications.
          }
        },
        onDone: _scheduleReconnect,
        onError: (_) => _scheduleReconnect(),
        cancelOnError: true,
      );
      channel.sink.add(jsonEncode({'type': 'authenticate', 'ticket': ticket}));
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (!mounted ||
        _ticket == null ||
        _ended ||
        _reconnectTimer?.isActive == true) {
      return;
    }
    _reconnectTimer = Timer(const Duration(seconds: 4), () {
      _reconnectTimer = null;
      _connect();
      unawaited(_fetchFrame());
    });
  }

  Future<void> _fetchFrame() async {
    final ticket = _ticket;
    if (ticket == null || _fetching || _ended) {
      return;
    }
    _fetching = true;
    try {
      final image = await _client.frame(widget.sessionId, ticket);
      if (mounted && _ticket == ticket && !_ended) {
        setState(() => _frame = image);
      }
    } on ApiException catch (error) {
      if (error.statusCode == 410 || error.statusCode == 401) {
        _endView('This session is no longer available.');
      } else if (error.statusCode != 404 && mounted) {
        setState(() => _error = _message(error));
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = _message(error));
      }
    } finally {
      _fetching = false;
    }
  }

  void _endView(String message) {
    if (!mounted) {
      return;
    }
    _pollTimer?.cancel();
    _reconnectTimer?.cancel();
    unawaited(_subscription?.cancel());
    unawaited(_channel?.sink.close());
    setState(() {
      _ticket = null;
      _frame = null;
      _ended = true;
      _error = message;
    });
  }

  String _message(Object error) {
    if (error is ApiException) {
      return error.message;
    }
    return 'The study session could not be reached.';
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _pollTimer?.cancel();
    _reconnectTimer?.cancel();
    unawaited(_subscription?.cancel());
    unawaited(_channel?.sink.close());
    _client.close();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final expires = _expiresAt;
    final remaining = expires?.difference(DateTime.now().toUtc());
    final warning =
        remaining != null && remaining <= const Duration(minutes: 5);
    return Scaffold(
      appBar: AppBar(
        title: Text(_title ?? 'Shared study session'),
        surfaceTintColor: Colors.transparent,
      ),
      body: Center(
        child: _ticket == null
            ? ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text('Enter the password to join the session.'),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _password,
                        autofocus: true,
                        obscureText: true,
                        onSubmitted: (_) => _join(),
                        decoration: const InputDecoration(
                          labelText: 'Session password',
                        ),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                      const SizedBox(height: 18),
                      FilledButton(
                        onPressed: _loading ? null : _join,
                        child: const Text('Join'),
                      ),
                    ],
                  ),
                ),
              )
            : Column(
                children: [
                  if (warning)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        'This session will expire soon. The host can extend it.',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(_error!),
                    ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: _frame == null
                          ? const Center(
                              child: Text(
                                'Waiting for the host to share the canvas.',
                              ),
                            )
                          : Image.memory(
                              _frame!,
                              gaplessPlayback: true,
                              fit: BoxFit.contain,
                            ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text('Live view only'),
                  ),
                ],
              ),
      ),
    );
  }
}
