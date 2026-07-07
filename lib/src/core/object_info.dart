/// Metadata about a stored object.
///
/// Returned by `StorageBackend.head` and `StorageBackend.list`. Contains
/// everything needed to decide what to do with an object without reading
/// its body.
///
/// ## Field guarantees (do NOT loosen these casually)
///
/// Every field below has a contract that holds **on every backend cellar
/// ships with** (Local, IndexedDB, Cellar.atPath). If you add a backend
/// that can't honor a field, you have two choices:
///
/// 1. Change the backend so it CAN honor the field (preferred — usually
///    means cellar-side bookkeeping, e.g. IndexedDB stores [lastModified]
///    in its own record because IDB has no native timestamp).
/// 2. Reject the backend. If a substrate genuinely cannot deliver one of
///    these fields, it is not eligible to be a cellar backend.
///
/// **Do NOT make a field nullable to "support" a backend that can't deliver
/// it.** Nullable fields here have a real reason (see per-field notes
/// below); adding more nullable fields silently breaks the cross-backend
/// contract callers depend on.
///
/// If you find yourself wanting to add an optional field "for one
/// backend," stop and re-read the architecture doc — the answer is
/// almost always "the backend stores it itself" not "the contract bends."
class ObjectInfo {
  /// All fields are required except the nullable [contentType].
  const ObjectInfo({
    required this.key,
    required this.size,
    required this.lastModified,
    this.contentType,
    this.metadata = const {},
  });

  /// The storage key (e.g. `"user/u1/photos/sunset"`).
  ///
  /// **Always non-null.** Universal across all backends — every storage
  /// substrate has the concept of a key.
  final String key;

  /// Size of the object body in bytes.
  ///
  /// **Always non-null.** Universal — every backend reports byte counts.
  /// For chunked objects, this is the logical (assembled) size, not the
  /// sum of chunk record sizes.
  final int size;

  /// MIME type (e.g. `"audio/mpeg"`, `"image/png"`).
  ///
  /// Null only when the writer didn't set one — cellar never strips it.
  /// Per-backend storage:
  ///   - Local: `.meta.json` sidecar
  ///   - IndexedDB: record field
  /// All backends round-trip this faithfully.
  final String? contentType;

  /// Custom key-value metadata.
  ///
  /// Used for encryption envelope, app-specific tags, etc. All values
  /// are strings (no nesting, no typed values — keep it simple,
  /// portable across substrates).
  ///
  /// Empty map means "no metadata," not "metadata unavailable" — every
  /// backend can store and retrieve metadata.
  final Map<String, String> metadata;

  /// Last modification timestamp (UTC).
  ///
  /// **Always non-null. No exceptions, no fallbacks.**
  ///
  /// Per-backend source:
  ///   - Local: filesystem `stat.modified`
  ///   - IndexedDB: `writtenAt` field cellar writes on every put
  ///     (IDB has no native timestamp; cellar maintains it)
  ///
  /// If a backend cannot deliver this, the backend is broken — fix it.
  /// Don't make this nullable to "support" the broken backend.
  final DateTime lastModified;

  /// Create a copy with some fields replaced.
  ObjectInfo copyWith({
    String? key,
    int? size,
    String? contentType,
    Map<String, String>? metadata,
    DateTime? lastModified,
  }) => ObjectInfo(
    key: key ?? this.key,
    size: size ?? this.size,
    contentType: contentType ?? this.contentType,
    metadata: metadata ?? this.metadata,
    lastModified: lastModified ?? this.lastModified,
  );

  /// Identity equality: key + size + contentType only. [metadata] and
  /// [lastModified] are deliberately excluded — a metadata edit or a
  /// timestamp refresh describes the SAME object, and set/dedup logic
  /// relies on that. Compare those fields explicitly when they matter.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ObjectInfo &&
          runtimeType == other.runtimeType &&
          key == other.key &&
          size == other.size &&
          contentType == other.contentType;

  @override
  int get hashCode => Object.hash(key, size, contentType);

  @override
  String toString() =>
      'ObjectInfo($key, ${size}B${contentType != null ? ', $contentType' : ''})';
}
