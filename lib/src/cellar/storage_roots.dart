/// The two native directories a default-constructed `Cellar` places
/// partitions under, resolved once per cellar.
///
/// `support` holds persistent partitions; `cache` holds partitions whose
/// `Lifecycle.osManaged` is true (iOS/Android may evict there). On web
/// the default constructor uses IndexedDB and never consults roots.
///
/// The core never guesses these — no HOME/XDG/APPDATA conventions, no
/// plugin asks. Native cellars require them explicitly: Flutter apps
/// get them resolved by `package:cellar_flutter`'s `openCellar`;
/// servers and CLIs pass their configured data directories (or use
/// `Cellar.atPath` for a single explicit root).
class StorageRoots {
  /// Both directories, absolute native paths without trailing slashes.
  const StorageRoots({required this.support, required this.cache});

  /// Root for persistent partitions.
  final String support;

  /// Root for OS-evictable partitions (`Lifecycle.osManaged`).
  final String cache;
}
