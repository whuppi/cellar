/// Standard dispose bookkeeping for [StorageBackend] implementations.
///
/// The contract every backend honors: `dispose()` is idempotent, and every
/// other method throws [StateError] afterwards. Mix this in, call
/// `checkNotDisposed` as the first statement of every public method, and
/// call `markDisposed` from `dispose()`:
///
/// ```dart
/// class MyBackend with DisposeGuard implements StorageBackend {
///   @override
///   String get disposeLabel => 'MyBackend';
///
///   @override
///   Future<Uint8List> read(String key) async {
///     checkNotDisposed();
///     // ...
///   }
///
///   @override
///   Future<void> dispose() async {
///     markDisposed();
///     // release owned resources here
///   }
/// }
/// ```
library;

import 'package:cellar/src/core/storage_backend.dart';

/// Mixin providing the disposed flag, the idempotent marker, and the
/// post-dispose [StateError] check shared by every [StorageBackend].
mixin DisposeGuard {
  bool _disposed = false;

  /// Short class name used in the post-dispose error, e.g. `'FileSystemBackend'`.
  String get disposeLabel;

  /// True once [markDisposed] has run.
  bool get isDisposed => _disposed;

  /// Record disposal. Idempotent.
  void markDisposed() {
    _disposed = true;
  }

  /// Throws [StateError] when this object has been disposed. Call as the
  /// first statement of every public method.
  void checkNotDisposed() {
    if (_disposed) {
      throw StateError('$disposeLabel has been disposed');
    }
  }
}
