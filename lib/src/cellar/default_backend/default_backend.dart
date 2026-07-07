// Conditional re-export — picks the platform-correct implementation at
// compile time. Native gets dart:io; web gets dart:js_interop; the stub
// catches anything else and throws on first use.
//
// [Cellar.open] uses [initBackendForPartition] to build per-partition
// raw backends; [initDefaultBackend] is the lower-level helper exposed
// via `package:cellar/cellar_lowlevel.dart` for callers composing their
// own backend stacks (e.g. a remote store + local cache).

export 'default_backend_stub.dart'
    if (dart.library.io) 'default_backend_native.dart'
    if (dart.library.js_interop) 'default_backend_web.dart';
