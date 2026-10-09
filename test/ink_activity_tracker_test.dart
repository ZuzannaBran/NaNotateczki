import 'package:flutter_test/flutter_test.dart';
import 'package:program/core/input/ink_activity_tracker.dart';

void main() {
  test('exit wait blocks until the last active ink contact ends', () async {
    final tracker = InkActivityTracker.instance;
    expect(tracker.hasActiveContacts, isFalse);

    tracker.beginContact();
    var completed = false;
    final wait = tracker.waitForNoActiveContacts().then((_) {
      completed = true;
    });

    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    expect(tracker.hasActiveContacts, isTrue);

    tracker.endContact();
    await wait;

    expect(completed, isTrue);
    expect(tracker.hasActiveContacts, isFalse);
  });
}
