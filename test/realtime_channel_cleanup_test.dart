import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:program/data/sync/realtime_channel_cleanup.dart';
import 'package:web_socket_channel/io.dart';

void main() {
  test(
    'cleanup returns while a failed handshake leaves close pending',
    () async {
      final handshake = Completer<WebSocket>();
      final channel = IOWebSocketChannel(handshake.future);
      final subscription = channel.stream.listen(
        (_) {},
        onError: (Object _) {},
      );
      final ready = expectLater(channel.ready, throwsA(isA<Exception>()));
      await subscription.cancel();
      var closed = false;
      requestRealtimeChannelClose(channel);
      unawaited(channel.sink.close().then((_) => closed = true));
      handshake.completeError(
        const SocketException('Injected handshake failure'),
      );
      await ready;
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      requestRealtimeChannelClose(channel);
    },
  );

  test('a connection completing after cleanup is immediately closed', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final peerClosed = Completer<void>();
    final peers = <WebSocket>[];
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      peers.add(socket);
      socket.listen(
        (_) => fail('A cancelled channel sent data.'),
        onDone: () {
          if (!peerClosed.isCompleted) {
            peerClosed.complete();
          }
        },
      );
    });
    addTearDown(() async {
      for (final peer in peers) {
        await peer.close();
      }
      await server.close(force: true);
    });
    final handshake = Completer<WebSocket>();
    final channel = IOWebSocketChannel(handshake.future);
    final subscription = channel.stream.listen((_) {}, onError: (Object _) {});
    await subscription.cancel();
    requestRealtimeChannelClose(channel);
    final socket = await WebSocket.connect('ws://127.0.0.1:${server.port}');
    handshake.complete(socket);
    await channel.ready;
    await peerClosed.future.timeout(const Duration(seconds: 2));
    await channel.sink.close().timeout(const Duration(seconds: 2));
  });

  test('a synchronous close error stays isolated from shutdown', () async {
    final handshake = Completer<WebSocket>();
    final channel = IOWebSocketChannel(handshake.future);
    final ready = expectLater(channel.ready, throwsA(isA<Exception>()));
    final subscription = channel.stream.listen((_) {}, onError: (Object _) {});
    final messages = StreamController<Object?>();
    final forwarding = channel.sink.addStream(messages.stream);
    // StreamChannel rejects close while addStream is in progress.
    requestRealtimeChannelClose(channel);
    await messages.close();
    await forwarding;
    await subscription.cancel();
    requestRealtimeChannelClose(channel);
    handshake.completeError(const SocketException('Test cleanup'));
    await ready;
  });
}
