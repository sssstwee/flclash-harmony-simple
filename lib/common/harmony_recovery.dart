import 'dart:async';

enum HarmonyConnectionHealth {
  disconnected,
  checking,
  connected,
  degraded,
  reconnecting,
  offline,
  captivePortal,
  loginRequired,
  noRoute,
}

/// A successful process start is not a successful connectivity check.
class HarmonyHealthResult {
  final bool domesticHealthy;
  final bool foreignHealthy;
  final bool hasRoute;
  final bool running;
  final bool offline;
  final bool captivePortal;

  const HarmonyHealthResult({
    required this.domesticHealthy,
    required this.foreignHealthy,
    this.hasRoute = true,
    this.running = true,
    this.offline = false,
    this.captivePortal = false,
  });

  HarmonyConnectionHealth get health {
    if (captivePortal) return HarmonyConnectionHealth.captivePortal;
    if (offline) return HarmonyConnectionHealth.offline;
    if (!hasRoute) return HarmonyConnectionHealth.noRoute;
    if (running && domesticHealthy && foreignHealthy) {
      return HarmonyConnectionHealth.connected;
    }
    return HarmonyConnectionHealth.degraded;
  }
}

class HarmonyRecoverySnapshot {
  final HarmonyConnectionHealth health;
  final bool connectionRequested;
  final bool? domesticHealthy;
  final bool? foreignHealthy;
  final int recoveryAttempt;
  final DateTime? nextRetryAt;

  const HarmonyRecoverySnapshot({
    this.health = HarmonyConnectionHealth.disconnected,
    this.connectionRequested = false,
    this.domesticHealthy,
    this.foreignHealthy,
    this.recoveryAttempt = 0,
    this.nextRetryAt,
  });
}

class HarmonyRecoveryCancelled implements Exception {}

/// All awaited read-only probes can be abandoned immediately on a new epoch.
/// Mutating native calls must still be joined before a disconnect is completed.
class HarmonyRecoveryTicket {
  final bool Function() _isCurrent;
  final Future<void> cancelled;
  final Future<void> _expired;
  final bool Function() _budgetExpired;

  const HarmonyRecoveryTicket(
    this._isCurrent,
    this.cancelled,
    this._expired,
    this._budgetExpired,
  );

  bool get isCurrent => _isCurrent();
  bool get mayProbe => isCurrent && !_budgetExpired();

  void ensureCurrent() {
    if (!isCurrent) throw HarmonyRecoveryCancelled();
    if (_budgetExpired()) throw TimeoutException('Health check budget elapsed');
  }

  Future<T> wait<T>(Future<T> work) => Future.any<T>([
    work,
    cancelled.then<T>((_) => throw HarmonyRecoveryCancelled()),
    _expired.then<T>(
      (_) => throw TimeoutException('Health check budget elapsed'),
    ),
  ]);
}

/// Foreground orchestration only. The native URL-test group owns background
/// failover while its VPN service is alive; Flutter timers are not a keepalive.
class HarmonyRecoveryCoordinator {
  final Future<HarmonyHealthResult> Function(HarmonyRecoveryTicket) attempt;
  final void Function(HarmonyRecoverySnapshot) onChanged;
  final DateTime Function() now;
  final Duration debounce;
  final Duration healthyInterval;
  final Duration baseRetry;
  final Duration cooldown;
  final int burstAttempts;
  final Duration readBudget;
  Timer? _timer;
  Future<void>? _active;
  Completer<void> _cancelled = Completer<void>();
  int _epoch = 0;
  int _failures = 0;
  bool _requested = false;
  bool _foreground = true;
  bool _disposed = false;
  bool? _online;
  bool _captivePortal = false;
  bool _pending = false;
  HarmonyRecoverySnapshot _snapshot = const HarmonyRecoverySnapshot();

  HarmonyRecoveryCoordinator({
    required this.attempt,
    required this.onChanged,
    DateTime Function()? now,
    this.debounce = const Duration(milliseconds: 900),
    this.healthyInterval = const Duration(seconds: 45),
    this.baseRetry = const Duration(seconds: 3),
    this.cooldown = const Duration(minutes: 2),
    this.burstAttempts = 4,
    this.readBudget = const Duration(seconds: 35),
  }) : now = now ?? DateTime.now;

  HarmonyRecoverySnapshot get snapshot => _snapshot;
  Future<void> get idle => _active ?? Future<void>.value();
  bool get _mayRun =>
      !_disposed &&
      _requested &&
      _foreground &&
      _online != false &&
      !_captivePortal;

  void _emit(HarmonyRecoverySnapshot value) {
    _snapshot = value;
    if (!_disposed) onChanged(value);
  }

  void _invalidate() {
    _epoch++;
    _timer?.cancel();
    _timer = null;
    _pending = false;
    _cancelled.complete();
    _cancelled = Completer<void>();
  }

  Future<void> connect() {
    if (_disposed) return Future<void>.value();
    _requested = true;
    _failures = 0;
    _invalidate();
    return checkNow();
  }

  /// Cancels intent immediately. Callers join [idle] before stopping native VPN.
  Future<void> disconnect() {
    _requested = false;
    _failures = 0;
    _invalidate();
    _emit(const HarmonyRecoverySnapshot());
    return idle;
  }

  Future<void> checkNow() {
    if (_disposed || !_requested) return Future<void>.value();
    _timer?.cancel();
    _timer = null;
    if (!_mayRun) {
      _emitEnvironment();
      return idle;
    }
    _pending = true;
    if (_active != null) return _active!;
    final completion = Completer<void>();
    _active = completion.future;
    unawaited(
      _drain().whenComplete(() {
        _active = null;
        // A listener can queue a new check between drain completion and this
        // microtask. Do not strand that request without a timer.
        if (_pending && _mayRun) unawaited(checkNow());
        completion.complete();
      }),
    );
    return completion.future;
  }

  void networkChanged({required bool connected, bool captivePortal = false}) {
    if (_disposed) return;
    _online = connected;
    _captivePortal = captivePortal;
    _failures = 0;
    _invalidate();
    if (!_requested) return;
    if (!_mayRun) {
      _emitEnvironment();
    } else {
      _emit(
        const HarmonyRecoverySnapshot(
          health: HarmonyConnectionHealth.checking,
          connectionRequested: true,
        ),
      );
      _schedule(debounce);
    }
  }

  void serviceStopped() {
    _invalidate();
    if (!_requested) return;
    if (!_mayRun) {
      _emitEnvironment();
      return;
    }
    _emit(
      const HarmonyRecoverySnapshot(
        health: HarmonyConnectionHealth.checking,
        connectionRequested: true,
      ),
    );
    _schedule(debounce);
  }

  void pause() {
    _foreground = false;
    _invalidate();
    if (_requested) {
      _emit(
        const HarmonyRecoverySnapshot(
          health: HarmonyConnectionHealth.checking,
          connectionRequested: true,
        ),
      );
    }
  }

  Future<void> resume() {
    _foreground = true;
    _failures = 0;
    _invalidate();
    return checkNow();
  }

  void _emitEnvironment() {
    _emit(
      HarmonyRecoverySnapshot(
        health: _captivePortal
            ? HarmonyConnectionHealth.captivePortal
            : _online == false
            ? HarmonyConnectionHealth.offline
            : HarmonyConnectionHealth.checking,
        connectionRequested: _requested,
      ),
    );
  }

  void _schedule(Duration delay) {
    if (!_mayRun) return;
    _timer?.cancel();
    _timer = Timer(delay, () {
      _timer = null;
      unawaited(checkNow());
    });
  }

  Future<void> _drain() async {
    while (_pending && _mayRun) {
      _pending = false;
      final epoch = _epoch;
      final expired = Completer<void>();
      var budgetExpired = false;
      final deadline = Timer(readBudget, () {
        budgetExpired = true;
        expired.complete();
      });
      final ticket = HarmonyRecoveryTicket(
        () => _mayRun && epoch == _epoch,
        _cancelled.future,
        expired.future,
        () => budgetExpired,
      );
      _emit(
        HarmonyRecoverySnapshot(
          health: _failures == 0
              ? HarmonyConnectionHealth.checking
              : HarmonyConnectionHealth.reconnecting,
          connectionRequested: true,
          recoveryAttempt: _failures,
        ),
      );
      HarmonyHealthResult result;
      try {
        result = await attempt(ticket);
      } catch (_) {
        if (!ticket.isCurrent) continue;
        result = const HarmonyHealthResult(
          domesticHealthy: false,
          foreignHealthy: false,
        );
      } finally {
        deadline.cancel();
      }
      if (!ticket.isCurrent) continue;
      final healthy = result.health == HarmonyConnectionHealth.connected;
      final environmentBlocked = result.offline || result.captivePortal;
      _failures = healthy || environmentBlocked ? 0 : _failures + 1;
      // Four bounded exponential attempts, then one attempt per cooldown.
      // Network changes, explicit retry and resume reset the burst.
      final delay = healthy || environmentBlocked
          ? healthyInterval
          : _failures >= burstAttempts
          ? cooldown
          : Duration(
              milliseconds: (baseRetry.inMilliseconds * (1 << (_failures - 1)))
                  .clamp(0, cooldown.inMilliseconds)
                  .toInt(),
            );
      _emit(
        HarmonyRecoverySnapshot(
          health: result.health,
          connectionRequested: true,
          domesticHealthy: environmentBlocked ? null : result.domesticHealthy,
          foreignHealthy: environmentBlocked ? null : result.foreignHealthy,
          recoveryAttempt: _failures,
          nextRetryAt: healthy || environmentBlocked ? null : now().add(delay),
        ),
      );
      if (!_pending) _schedule(delay);
    }
  }

  void dispose() {
    _disposed = true;
    _requested = false;
    _invalidate();
  }
}
