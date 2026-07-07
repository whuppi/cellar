/// Lifecycle policy attached to a partition.
///
/// Governs when stored items get evicted. Cellar runs a single background
/// timer per `Cellar` instance; on each tick it evaluates each partition's
/// lifecycle and evicts items that violate the rules.
///
/// All rules run on every backend (local, IndexedDB, custom, atPath) — the
/// same evaluation logic. This is the load-bearing eviction story; OS-level
/// eviction (when [osManaged] is true on iOS/Android) is a bonus on top.
///
/// ## Common patterns — use the factory shortcuts
///
/// ```dart
/// Lifecycle.cache(maxBytes: 100 * 1024 * 1024)
/// Lifecycle.scratch()
/// ```
///
/// For custom rules, use the base constructor directly.
class Lifecycle {
  /// A policy with no [maxBytes], [maxAge], or [wipeOnOpen] has no rules
  /// and never evicts.
  const Lifecycle({
    this.maxBytes,
    this.maxAge,
    this.wipeOnOpen = false,
    this.runInterval = const Duration(hours: 1),
    this.osManaged = false,
  });

  /// Cache-style lifecycle. Bounded by [maxBytes] and/or [maxAge]; OS may
  /// also evict on iOS/Android by default.
  ///
  /// ```dart
  /// Lifecycle.cache(maxBytes: 100 * 1024 * 1024)            // 100MB cap
  /// Lifecycle.cache(maxAge: Duration(days: 7))              // age cap
  /// Lifecycle.cache(maxBytes: 50 * 1024 * 1024, osManaged: false)  // no OS interference
  /// ```
  const Lifecycle.cache({
    this.maxBytes,
    this.maxAge,
    this.runInterval = const Duration(hours: 1),
    this.osManaged = true,
  }) : wipeOnOpen = false;

  /// Scratch-style lifecycle. Wipes the partition every time `Cellar.open`
  /// runs. For in-progress work that should never survive an app restart.
  const Lifecycle.scratch({this.osManaged = true})
    : maxBytes = null,
      maxAge = null,
      wipeOnOpen = true,
      runInterval = const Duration(hours: 1);

  /// Total bytes cap. When exceeded, oldest items are evicted until under
  /// the cap. Null means no size cap.
  final int? maxBytes;

  /// Items older than this (by `ObjectInfo.lastModified`) are evicted.
  /// Null means no age cap.
  final Duration? maxAge;

  /// Wipe the whole partition when `Cellar.open` runs. Useful for
  /// scratch / temp partitions that should never survive an app restart.
  final bool wipeOnOpen;

  /// How often the lifecycle runner checks the partition. Default: 1 hour.
  /// Multiple partitions share a single timer that fires at the shortest
  /// `runInterval` across configured partitions.
  final Duration runInterval;

  /// On iOS and Android, place the partition under a directory the OS may
  /// also evict (`getApplicationCacheDirectory()` / `getTemporaryDirectory()`).
  /// The OS *may* delete contents under storage pressure (it's a "may," not
  /// a "will" — see path_provider docs).
  ///
  /// **No-op on macOS, Linux, Windows, web, custom backends, atPath.** Those
  /// platforms either don't auto-evict (desktop, openAtPath), don't have
  /// per-partition control (web's origin-wide IndexedDB quota), or don't
  /// have an OS lifecycle concept (a remote store). The flag is accepted for API
  /// uniformity; it changes nothing on those platforms.
  ///
  /// Cellar's lifecycle rules ([maxBytes], [maxAge], [wipeOnOpen]) run on
  /// every backend regardless. OS eviction is a bonus, not a contract.
  final bool osManaged;

  /// True if any rule is configured. Used internally to skip the runner
  /// for partitions with no policy.
  bool get hasRules => maxBytes != null || maxAge != null || wipeOnOpen;
}
