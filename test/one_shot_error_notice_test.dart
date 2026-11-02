import 'package:flutter_test/flutter_test.dart';
import 'package:program/core/error/one_shot_error_notice.dart';

void main() {
  test('one error appears once and re-arms after service recovery', () {
    final notices = OneShotErrorNotice();
    final service = Object();
    expect(notices.shouldPresent(service, 'Offline'), isTrue);
    expect(notices.shouldPresent(service, 'Offline'), isFalse);
    expect(notices.shouldPresent(service, null), isFalse);
    expect(notices.shouldPresent(service, 'Offline'), isTrue);
  });

  test('opening a dialog does not replay a previous service error', () {
    final notices = OneShotErrorNotice();
    final service = Object();
    notices.acknowledge(service, 'Previous network error');
    expect(notices.shouldPresent(service, 'Previous network error'), isFalse);
    expect(notices.shouldPresent(service, 'New network error'), isTrue);
    expect(notices.shouldPresent(service, 'New network error'), isFalse);
  });
}
