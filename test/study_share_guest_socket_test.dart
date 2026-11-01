import 'package:flutter_test/flutter_test.dart';
import 'package:program/features/share/presentation/study_share_guest_screen.dart';

void main() {
  test('terminal WebSocket close codes do not trigger endless reconnect', () {
    for (final code in [4401, 4403, 4410]) {
      expect(isTerminalShareSocketClose(code), isTrue);
    }
    for (final code in [null, 1000, 1001, 1011]) {
      expect(isTerminalShareSocketClose(code), isFalse);
    }
  });
}
