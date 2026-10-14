import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:fl_clash/common/harmony_recovery.dart';
import 'package:flutter_test/flutter_test.dart';

const _healthy = HarmonyHealthResult(
  domesticHealthy: true,
  foreignHealthy: true,
);
const _failed = HarmonyHealthResult(
  domesticHealthy: true,
  foreignHealthy: false,
);

void main() {
  test('only both strict checks and a running service mean connected', () {
    expect(_healthy.health, HarmonyConnectionHealth.connected);
    for (final result in [
      _failed,
      const HarmonyHealthResult(domesticHealthy: false, foreignHealthy: true),
      const HarmonyHealthResult(domesticHealthy: false, foreignHealthy: false),
      const HarmonyHealthResult(
        domesticHealthy: true,
        foreignHealthy: true,
        running: false,
      ),
    ]) {
      expect(result.health, HarmonyConnectionHealth.degraded);
    }
    expect(
      const HarmonyHealthResult(
        domesticHealthy: true,
        foreignHealthy: false,
        hasRoute: false,
      ).health,
      HarmonyConnectionHealth.noRoute,
    );
  });

  test(
    'network storms debounce, invalidate health, and serialize attempts',
    () {
      fakeAsync((async) {
        var calls = 0;
        final pending = <Completer<HarmonyHealthResult>>[];
        final coordinator = HarmonyRecoveryCoordinator(
          attempt: (_) {
            calls++;
            final value = Completer<HarmonyHealthResult>();
            pending.add(value);
            return value.future;
          },
          onChanged: (_) {},
        );
        unawaited(coordinator.connect());
        expect(calls, 1);
        for (var i = 0; i < 10; i++) {
          coordinator.networkChanged(connected: true);
          async.elapse(const Duration(milliseconds: 100));
        }
        async.elapse(const Duration(seconds: 1));
        expect(calls, 1, reason: 'A still-running attempt is joined');
        pending.first.complete(_healthy);
        async.flushMicrotasks();
        expect(calls, 2);
        expect(coordinator.snapshot.health, HarmonyConnectionHealth.checking);
        pending.last.complete(_healthy);
        async.flushMicrotasks();
        expect(coordinator.snapshot.health, HarmonyConnectionHealth.connected);
        coordinator.dispose();
      });
    },
  );

  test('a cancelled wait releases promptly and ignores a late success', () {
    fakeAsync((async) {
      final pending = Completer<HarmonyHealthResult>();
      final coordinator = HarmonyRecoveryCoordinator(
        attempt: (ticket) => ticket.wait(pending.future),
        onChanged: (_) {},
      );
      unawaited(coordinator.connect());
      unawaited(coordinator.disconnect());
      async.flushMicrotasks();
      expect(coordinator.snapshot.health, HarmonyConnectionHealth.disconnected);
      pending.complete(_healthy);
      async.flushMicrotasks();
      expect(coordinator.snapshot.connectionRequested, isFalse);
      expect(coordinator.snapshot.health, HarmonyConnectionHealth.disconnected);
      expect(async.pendingTimers, isEmpty);
      coordinator.dispose();
    });
  });

  test(
    'offline and confirmed captive pause probes without inferring a portal',
    () {
      fakeAsync((async) {
        var calls = 0;
        final coordinator = HarmonyRecoveryCoordinator(
          attempt: (_) async {
            calls++;
            return _failed;
          },
          onChanged: (_) {},
        );
        coordinator.networkChanged(connected: false);
        unawaited(coordinator.connect());
        async.elapse(const Duration(minutes: 10));
        expect(calls, 0);
        expect(coordinator.snapshot.health, HarmonyConnectionHealth.offline);
        coordinator.networkChanged(connected: true, captivePortal: true);
        async.elapse(const Duration(minutes: 10));
        expect(calls, 0);
        expect(
          coordinator.snapshot.health,
          HarmonyConnectionHealth.captivePortal,
        );
        coordinator.networkChanged(connected: true);
        async.elapse(const Duration(seconds: 1));
        expect(calls, 1);
        expect(coordinator.snapshot.health, HarmonyConnectionHealth.degraded);
        coordinator.dispose();
      });
    },
  );

  test(
    'retries are exponentially bounded then continue at cooldown cadence',
    () {
      fakeAsync((async) {
        var calls = 0;
        final coordinator = HarmonyRecoveryCoordinator(
          attempt: (_) async {
            calls++;
            return _failed;
          },
          now: () => DateTime(2026).add(async.elapsed),
          onChanged: (_) {},
        );
        unawaited(coordinator.connect());
        async.flushMicrotasks();
        expect(calls, 1);
        expect(
          coordinator.snapshot.nextRetryAt,
          DateTime(2026).add(const Duration(seconds: 3)),
        );
        async.elapse(const Duration(seconds: 3));
        expect(calls, 2);
        async.elapse(const Duration(seconds: 6));
        expect(calls, 3);
        async.elapse(const Duration(seconds: 12));
        expect(calls, 4);
        async.elapse(const Duration(seconds: 119));
        expect(calls, 4);
        async.elapse(const Duration(seconds: 1));
        expect(calls, 5);
        async.elapse(const Duration(minutes: 2));
        expect(calls, 6);
        unawaited(coordinator.connect());
        async.flushMicrotasks();
        expect(coordinator.snapshot.recoveryAttempt, 1);
        coordinator.dispose();
      });
    },
  );

  test('suspension stops Flutter work; resume requires new checks', () {
    fakeAsync((async) {
      var calls = 0;
      final coordinator = HarmonyRecoveryCoordinator(
        attempt: (_) async {
          calls++;
          return _healthy;
        },
        onChanged: (_) {},
      );
      unawaited(coordinator.connect());
      async.flushMicrotasks();
      coordinator.pause();
      async.elapse(const Duration(hours: 1));
      expect(calls, 1);
      expect(async.pendingTimers, isEmpty);
      unawaited(coordinator.resume());
      expect(coordinator.snapshot.health, HarmonyConnectionHealth.checking);
      async.flushMicrotasks();
      expect(calls, 2);
      expect(coordinator.snapshot.health, HarmonyConnectionHealth.connected);
      unawaited(coordinator.disconnect());
      unawaited(coordinator.resume());
      async.elapse(const Duration(hours: 1));
      expect(calls, 2, reason: 'Resume never reverses a manual disconnect');
      coordinator.dispose();
    });
  });

  test(
    'a new network cancels an old healthy result and offline stays offline',
    () {
      fakeAsync((async) {
        final pending = Completer<HarmonyHealthResult>();
        final coordinator = HarmonyRecoveryCoordinator(
          attempt: (ticket) => ticket.wait(pending.future),
          onChanged: (_) {},
        );
        unawaited(coordinator.connect());
        coordinator.networkChanged(connected: false);
        pending.complete(_healthy);
        async.flushMicrotasks();
        expect(coordinator.snapshot.health, HarmonyConnectionHealth.offline);
        expect(coordinator.snapshot.domesticHealthy, isNull);
        expect(coordinator.snapshot.foreignHealthy, isNull);
        expect(coordinator.snapshot.connectionRequested, isTrue);
        coordinator.dispose();
      });
    },
  );

  test(
    'one aggregate deadline bounds sequential reads and ignores late probes',
    () {
      fakeAsync((async) {
        final late = Completer<HarmonyHealthResult>();
        var reads = 0;
        final coordinator = HarmonyRecoveryCoordinator(
          readBudget: const Duration(seconds: 10),
          attempt: (ticket) async {
            reads++;
            await ticket.wait(Future<void>.delayed(const Duration(seconds: 7)));
            ticket.ensureCurrent();
            reads++;
            return ticket.wait(late.future);
          },
          onChanged: (_) {},
        );
        unawaited(coordinator.connect());
        async.elapse(const Duration(seconds: 9));
        expect(reads, 2);
        expect(coordinator.snapshot.health, HarmonyConnectionHealth.checking);
        async.elapse(const Duration(seconds: 1));
        expect(coordinator.snapshot.health, HarmonyConnectionHealth.degraded);
        expect(coordinator.snapshot.nextRetryAt, isNotNull);
        late.complete(_healthy);
        async.flushMicrotasks();
        expect(coordinator.snapshot.health, HarmonyConnectionHealth.degraded);
        coordinator.dispose();
      });
    },
  );

  test(
    'deadline does not abandon a submitted native mutation before disconnect',
    () {
      fakeAsync((async) {
        final submitted = Completer<void>();
        var stopped = false;
        final coordinator = HarmonyRecoveryCoordinator(
          readBudget: const Duration(seconds: 2),
          attempt: (ticket) async {
            await submitted.future; // Deliberately not a cancellable read.
            ticket.ensureCurrent();
            return _healthy;
          },
          onChanged: (_) {},
        );
        unawaited(coordinator.connect());
        async.elapse(const Duration(seconds: 3));
        unawaited(coordinator.disconnect().then((_) => stopped = true));
        async.flushMicrotasks();
        expect(stopped, isFalse);
        submitted.complete();
        async.flushMicrotasks();
        expect(stopped, isTrue);
        expect(
          coordinator.snapshot.health,
          HarmonyConnectionHealth.disconnected,
        );
        expect(async.pendingTimers, isEmpty);
        coordinator.dispose();
      });
    },
  );
}
