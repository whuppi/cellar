import 'package:cellar/src/cellar/lifecycle.dart';

/// Configuration for a partition in `Cellar`.
///
/// A partition is a named, logically-separated section of storage. Each
/// partition may have an optional [Lifecycle] policy controlling eviction
/// and an `osBackup` flag controlling whether the OS backs it up.
///
/// ```dart
/// PartitionConfig()                                              // permanent, backed up
/// PartitionConfig(lifecycle: Lifecycle.cache(maxBytes: 100<<20)) // 100MB cache
/// PartitionConfig(lifecycle: Lifecycle.scratch())                // wipe on open
/// PartitionConfig(osBackup: false)                               // skip iCloud
/// ```
class PartitionConfig {
  /// Defaults: no lifecycle rules, participates in OS backup.
  const PartitionConfig({this.lifecycle, this.osBackup = true});

  /// Eviction rules. Null means the partition is permanent (no eviction).
  final Lifecycle? lifecycle;

  /// Whether the OS should back up this partition's contents.
  ///
  /// Default `true` — the safe default; user data ends up in iCloud
  /// backup on iOS and Time Machine on macOS as expected.
  ///
  /// Set `false` for partitions that hold regenerable data (cache,
  /// scratch, downloaded models) so they don't waste the user's iCloud
  /// quota.
  ///
  /// **Per-platform reality:**
  /// - iOS: real effect — `kCFURLIsExcludedFromBackupKey` is set on the
  ///   partition root via CFURL (in-sandbox; no
  ///   process spawning involved).
  /// - macOS: real effect — `tmutil addexclusion` on the partition root
  ///   (the supported Time Machine exclusion).
  /// - Android: no-op. Android backup is per-app via `android:allowBackup`
  ///   in the manifest; cellar can't opt one folder out from another.
  /// - Linux, Windows: no-op (no equivalent concept).
  /// - Web: no-op (IndexedDB has no concept of OS-level backup).
  /// - `Cellar.atPath`: respects this flag on iOS/macOS, no-op elsewhere.
  ///
  /// Independent of `Lifecycle.osManaged` — you can have a permanent
  /// partition (no lifecycle) that's backup-excluded, or a cache
  /// partition that IS backed up. Different axes.
  final bool osBackup;
}

/// Default partition name used when `Cellar` is constructed without a
/// `partitions:` map. Apps that don't need multi-partition storage just
/// use this implicitly.
const String defaultPartitionName = 'default';

/// Validates a partition name.
///
/// Names must match `[a-z][a-z0-9_]*`. Reserved prefix: `system_`.
/// Throws [ArgumentError] on invalid input.
void validatePartitionName(String name) {
  if (name.isEmpty) {
    throw ArgumentError.value(name, 'partitionName', 'must not be empty');
  }
  if (name.startsWith('system_')) {
    throw ArgumentError.value(
      name,
      'partitionName',
      'partition names beginning with "system_" are reserved for cellar internals',
    );
  }
  final pattern = RegExp(r'^[a-z][a-z0-9_]*$');
  if (!pattern.hasMatch(name)) {
    throw ArgumentError.value(
      name,
      'partitionName',
      'must match [a-z][a-z0-9_]* (lowercase letters, digits, underscores; '
          'must start with a letter)',
    );
  }
}
