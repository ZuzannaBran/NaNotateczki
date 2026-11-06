import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

/// Requests transport cleanup without blocking authoritative REST shutdown.
/// A channel closed before a failed handshake may never complete sink.close.
void requestRealtimeChannelClose(WebSocketChannel channel) {
  unawaited(_close(channel));
}

Future<void> _close(WebSocketChannel channel) async {
  try {
    await channel.sink.close();
  } catch (_) {
    // Hint transport cleanup cannot revoke or prevent a durable shutdown.
  }
}
