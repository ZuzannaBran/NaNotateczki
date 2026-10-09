import 'package:flutter_test/flutter_test.dart';
import 'package:program/core/storage/app_save_coordinator.dart';
import 'package:program/core/input/ink_activity_tracker.dart';

void main() {
  final coordinator = AppSaveCoordinator.instance;

  test('flush drains all pending editors and skips clean editors', () async {
    final first = Object();
    final clean = Object();
    final second = Object();
    final order = <String>[];
    var firstDirty = true;
    var secondDirty = true;
    addTearDown(() {
      coordinator.unregister(first);
      coordinator.unregister(clean);
      coordinator.unregister(second);
    });

    coordinator.register(
      first,
      hasPendingWork: () => firstDirty,
      flush: () async {
        order.add('first');
        firstDirty = false;
      },
    );
    coordinator.register(
      clean,
      hasPendingWork: () => false,
      flush: () async => order.add('unexpected'),
    );
    coordinator.register(
      second,
      hasPendingWork: () => secondDirty,
      flush: () async {
        order.add('second');
        secondDirty = false;
      },
    );

    expect(coordinator.hasPendingWork, isTrue);
    await coordinator.flushPending();
    expect(order, ['first', 'second']);
    expect(coordinator.hasPendingWork, isFalse);
    await coordinator.flushPending();
    expect(order, ['first', 'second']);
  });

  test('unregistered editor must not participate in shutdown flush', () async {
    final owner = Object();
    var ran = false;
    coordinator.register(
      owner,
      hasPendingWork: () => true,
      flush: () async => ran = true,
    );
    coordinator.unregister(owner);
    await coordinator.flushPending();
    expect(ran, isFalse);
  });

  test(
    'a failing save propagates an error rather than reporting success',
    () async {
      final owner = Object();
      addTearDown(() => coordinator.unregister(owner));
      coordinator.register(
        owner,
        hasPendingWork: () => true,
        flush: () async => throw StateError('disk unavailable'),
      );
      await expectLater(coordinator.flushPending(), throwsA(isA<StateError>()));
      expect(coordinator.hasPendingWork, isTrue);
    },
  );

  test('exit waits for every active stylus contact', () async {
    final tracker = InkActivityTracker.instance;
    tracker.beginContact();
    tracker.beginContact();
    addTearDown(() {
      while (tracker.hasActiveContacts) {
        tracker.endContact();
      }
    });

    var completed = false;
    final waiting = tracker.waitForNoActiveContacts().then((_) {
      completed = true;
    });

    tracker.endContact();
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    expect(tracker.hasActiveContacts, isTrue);

    tracker.endContact();
    await waiting;
    expect(completed, isTrue);
    expect(tracker.hasActiveContacts, isFalse);
  });
}
