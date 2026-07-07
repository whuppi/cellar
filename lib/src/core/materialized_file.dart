/// A handle to a stored object made available for non-Dart consumers.
///
/// Returned by `StorageBackend.materialize`. The [localPath] is whatever
/// the platform's notion of "a usable handle" is:
///
/// - **Native** (iOS, Android, macOS, Linux, Windows): a filesystem path.
///   Pass it to FFI, platform channels, native plugins that take a `File`
///   or path, OS file pickers, mmap, etc.
/// - **Web**: a Blob URL (`blob:https://app.example.com/uuid`). Pass it to
///   any browser API that takes a URL — `<audio src>`, `<img src>`,
///   `<video src>`, anchor downloads, `fetch()`, Web Workers.
///
/// The path / URL is local to this device and this session. It MUST NOT
/// be persisted, synced across devices, or cached beyond the scope of
/// the current operation. The exact substrate may be the original
/// stored file (when `exclusive: false` on a local backend), a freshly
/// remote store's cache entry, a private temp copy (`exclusive: true`),
/// or a Blob URL.
///
/// ## Lifecycle
///
/// Valid until [release] is called. The caller MUST call [release] when
/// done. The exact effect depends on the backend and how this handle
/// was created — see `StorageBackend.materialize`'s behavior matrix.
class MaterializedFile {
  /// Bundle a [localPath] handle with its [release] cleanup.
  MaterializedFile({
    required this.localPath,
    required this.key,
    required Future<void> Function() release,
  }) : _release = release;

  /// The platform-local handle. A filesystem path on native, a Blob URL
  /// on web. Valid until [release] is called.
  final String localPath;

  /// The storage key this handle was materialized from.
  final String key;

  final Future<void> Function() _release;

  /// Release this handle.
  ///
  /// What this does depends on how the handle was made:
  /// - Local + `exclusive: false` + unencrypted: no-op (the original
  ///   file is what was returned).
  /// - Local + `exclusive: true`: deletes the temp copy.
  /// - Local + decrypted-cache: cache entry remains; cleaned on the
  ///   next eviction sweep.
  /// - Web (IndexedDB): revokes the Blob URL.
  Future<void> release() => _release();
}
