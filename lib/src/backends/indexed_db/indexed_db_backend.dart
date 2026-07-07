// Conditional re-export — resolves to the real IndexedDbBackend
// implementation on web (dart:js_interop) and a throwing stub on native.

export 'indexed_db_backend_stub.dart'
    if (dart.library.js_interop) 'indexed_db_backend_web.dart';
