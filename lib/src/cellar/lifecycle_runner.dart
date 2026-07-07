import 'dart:async';

import 'package:cellar/src/cellar/storage_scope.dart';
import 'package:cellar/src/cellar/lifecycle.dart';

/// Callback for eviction failures. [key] is the victim that could not be
/// deleted, or null when the partition pass itself failed (e.g. the
/// listing errored). Without an observer, a permanently failing delete
/// retries forever with zero visibility.
typedef EvictionErrorCallback =
    void Function(String partition, String? key, Object error);

/// Background runner that evaluates partition lifecycle policies and
/// evicts items.
///
/// One runner per `Cellar` instance. Holds a Map of partition → scope
/// + lifecycle, fires a single periodic timer at the shortest configured
/// `runInterval`, walks each partition with rules and evicts.
///
/// Eviction is best-effort and resilient: a victim that fails to delete
/// is reported via [onEvictionError] and SKIPPED — one stuck object must
/// not shield everything newer from the size cap. Failed victims retry
/// on the next tick.
class LifecycleRunner {
  /// [now] injects the clock for age-eviction tests; production uses the
  /// real one.
  LifecycleRunner({
    DateTime Function() now = DateTime.now,
    this.onEvictionError,
  }) : _now = now;

  final Map<String, _PartitionLifecycle> _partitions = {};

  /// Injectable clock — age eviction is testable at exact boundaries
  /// without real waits.
  final DateTime Function() _now;

  /// Invoked once per eviction failure. Null = failures are silent
  /// (still retried next tick).
  final EvictionErrorCallback? onEvictionError;

  Timer? _timer;
  Duration? _interval;

  /// Register a partition for lifecycle evaluation. Called by `Cellar`
  /// on each partition that has a non-null [Lifecycle].
  void register(String name, StorageScope scope, Lifecycle lifecycle) {
    _partitions[name] = _PartitionLifecycle(name, scope, lifecycle);
    _restartTimer();
  }

  /// Stop the timer and clear state. Called by `Cellar.close`.
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _partitions.clear();
  }

  /// Run evaluation immediately for every registered partition. Useful
  /// for tests; production code lets the timer fire it.
  Future<void> evaluateNow() async {
    for (final p in _partitions.values) {
      await _evaluate(p);
    }
  }

  /// Run wipeOnOpen across all partitions whose lifecycle requests it.
  /// Called by `Cellar.open` before any user calls happen.
  Future<void> runWipeOnOpen() async {
    for (final p in _partitions.values) {
      if (p.lifecycle.wipeOnOpen) {
        await p.scope.deletePrefix('');
      }
    }
  }

  void _restartTimer() {
    _timer?.cancel();
    _timer = null;

    Duration? shortest;
    for (final p in _partitions.values) {
      if (!p.lifecycle.hasRules) continue;
      final candidate = p.lifecycle.runInterval;
      if (shortest == null || candidate < shortest) shortest = candidate;
    }
    if (shortest == null) return;

    _interval = shortest;
    _timer = Timer.periodic(shortest, (_) => _tick());
  }

  Future<void> _tick() async {
    for (final p in _partitions.values) {
      try {
        await _evaluate(p);
      } catch (e) {
        // The pass itself failed (listing errored, backend down). Report
        // and move to the next partition; this one retries next tick.
        onEvictionError?.call(p.name, null, e);
      }
    }
  }

  Future<void> _evaluate(_PartitionLifecycle p) async {
    if (!p.lifecycle.hasRules || p.lifecycle.wipeOnOpen) {
      // wipeOnOpen handled at open time, not on every tick.
      if (p.lifecycle.maxBytes == null && p.lifecycle.maxAge == null) return;
    }

    final all = await p.scope.list('');
    if (all.isEmpty) return;

    // Sort oldest first.
    final sorted = [...all]
      ..sort((a, b) => a.lastModified.compareTo(b.lastModified));

    final now = _now().toUtc();
    final maxAge = p.lifecycle.maxAge;
    final maxBytes = p.lifecycle.maxBytes;

    // Pass 1: age-based eviction.
    if (maxAge != null) {
      final cutoff = now.subtract(maxAge);
      for (final info in [...sorted]) {
        if (!info.lastModified.isBefore(cutoff)) continue;
        try {
          await p.scope.delete(info.key);
          sorted.remove(info);
        } catch (e) {
          onEvictionError?.call(p.name, info.key, e);
          // Retries next tick; keep walking the rest.
        }
      }
    }

    // Pass 2: size-based eviction, oldest first. A failed victim is
    // skipped WITHOUT subtracting its size — it still occupies the cap,
    // so the pass keeps evicting newer objects until under the limit.
    if (maxBytes != null) {
      var total = sorted.fold<int>(0, (a, b) => a + b.size);
      var i = 0;
      while (total > maxBytes && i < sorted.length) {
        final victim = sorted[i];
        try {
          await p.scope.delete(victim.key);
          total -= victim.size;
          sorted.removeAt(i);
        } catch (e) {
          onEvictionError?.call(p.name, victim.key, e);
          i++; // skip the stuck victim, keep evicting
        }
      }
    }
  }

  /// The currently-active timer interval, for diagnostics. Null if no
  /// partition has rules.
  Duration? get currentInterval => _interval;
}

class _PartitionLifecycle {
  _PartitionLifecycle(this.name, this.scope, this.lifecycle);
  final String name;
  final StorageScope scope;
  final Lifecycle lifecycle;
}
