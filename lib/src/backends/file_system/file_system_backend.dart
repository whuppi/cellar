// Conditional re-export — the import point for FileSystemBackend. Resolves
// to the native (dart:io) implementation on phones/desktops and a
// throwing stub on web.

export 'file_system_backend_stub.dart'
    if (dart.library.io) 'file_system_backend_native.dart';
