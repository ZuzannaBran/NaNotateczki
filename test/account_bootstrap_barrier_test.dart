import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:program/app/account_bootstrap_barrier.dart';

void main() {
  test(
    'startup starts current and draining invalidates it synchronously',
    () async {
      final barrier = AccountBootstrapBarrier();
      final ticket = barrier.generation;
      expect(barrier.canStart, isTrue);
      expect(barrier.isCurrent(ticket), isTrue);
      final drain = barrier.quiesce(() async {
        expect(barrier.canStart, isFalse);
        expect(barrier.isCurrent(ticket), isFalse);
      });
      expect(barrier.canStart, isFalse);
      await drain;
      expect(barrier.canStart, isTrue);
      expect(barrier.isCurrent(ticket), isFalse);
      expect(barrier.isCurrent(barrier.generation), isTrue);
    },
  );

  test('concurrent drains join once and do not rearm busy tickets', () async {
    final barrier = AccountBootstrapBarrier();
    final released = Completer<void>();
    var calls = 0;
    final first = barrier.quiesce(() {
      calls++;
      return released.future;
    });
    final busyTicket = barrier.generation;
    final second = barrier.quiesce(() async {
      calls++;
    });
    expect(identical(first, second), isTrue);
    expect(calls, 1);
    expect(barrier.isCurrent(busyTicket), isFalse);
    released.complete();
    await Future.wait([first, second]);
    expect(barrier.canStart, isTrue);
    expect(barrier.isCurrent(busyTicket), isFalse);
  });

  test(
    'an asynchronous drain failure propagates and allows an explicit retry',
    () async {
      final barrier = AccountBootstrapBarrier();
      final previous = barrier.generation;
      final failure = StateError('flush failed');
      await expectLater(
        barrier.quiesce(() async {
          throw failure;
        }),
        throwsA(same(failure)),
      );
      expect(barrier.canStart, isTrue);
      expect(barrier.isCurrent(previous), isFalse);
      var retried = false;
      await barrier.quiesce(() async {
        retried = true;
      });
      expect(retried, isTrue);
      expect(barrier.canStart, isTrue);
    },
  );

  test(
    'a synchronous drain failure is a failed Future and releases the barrier',
    () async {
      final barrier = AccountBootstrapBarrier();
      final failure = StateError('synchronous flush failure');
      final pending = barrier.quiesce(() => throw failure);
      expect(barrier.canStart, isFalse);
      await expectLater(pending, throwsA(same(failure)));
      expect(barrier.canStart, isTrue);
    },
  );

  test('disposing during a drain never reopens account startup', () async {
    final barrier = AccountBootstrapBarrier();
    final released = Completer<void>();
    final pending = barrier.quiesce(() => released.future);
    final ticket = barrier.generation;
    barrier.dispose();
    released.complete();
    await pending;
    expect(barrier.canStart, isFalse);
    expect(barrier.isCurrent(ticket), isFalse);
    expect(barrier.isCurrent(barrier.generation), isFalse);
  });

  test('a disposed barrier never invokes a new drain', () async {
    final barrier = AccountBootstrapBarrier()..dispose();
    var called = false;
    await expectLater(
      barrier.quiesce(() async {
        called = true;
      }),
      throwsStateError,
    );
    expect(called, isFalse);
  });

  test(
    'synchronous reentry joins the published barrier without running twice',
    () async {
      final barrier = AccountBootstrapBarrier();
      Future<void>? joined;
      var duplicate = false;
      final first = barrier.quiesce(() async {
        joined = barrier.quiesce(() async {
          duplicate = true;
        });
      });
      expect(identical(first, joined), isTrue);
      await first;
      expect(duplicate, isFalse);
    },
  );

  test(
    'late actor loading cannot start the same account after invalidation',
    () async {
      final barrier = AccountBootstrapBarrier();
      final actor = Completer<String>();
      final user = 'same-account';
      var currentUser = user;
      var transports = 0;
      final ticket = barrier.generation;
      final bootstrap = () async {
        await actor.future;
        if (currentUser == user && barrier.isCurrent(ticket)) {
          transports++;
        }
      }();
      final leaving = barrier.quiesce(() async {
        await bootstrap;
      });
      currentUser = 'another-account';
      currentUser = user;
      actor.complete('persistent-actor');
      await leaving;
      expect(transports, 0);
      final retryTicket = barrier.generation;
      if (currentUser == user && barrier.isCurrent(retryTicket)) {
        transports++;
      }
      expect(transports, 1);
    },
  );
}
