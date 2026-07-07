/// iOS quirk: everything under the app sandbox is uploaded to iCloud
/// backup unless the item carries the exclusion resource property. The
/// supported mechanism is `NSURLIsExcludedFromBackupKey`, set here
/// through its C face — `CFURLSetResourcePropertyForKey` with
/// `kCFURLIsExcludedFromBackupKey` — via dart:ffi (the sandbox forbids
/// spawning an `xattr` CLI, and the raw `com.apple.MobileBackup` xattr
/// was deprecated in iOS 5.1 with an explicit removal warning; do not
/// regress to it).
///
/// [IosFileSystemOs.isExcludedFromBackup] reads the same property back
/// through `CFURLCopyResourcePropertyForKey` — asking the system's own
/// resource layer, the state the backup engine consults. Tests and the
/// integration smoke assert it on the real runtime.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'package:cellar/src/backends/file_system/os/file_system_os.dart';

typedef _CFURLCreateC =
    Pointer<Void> Function(
      Pointer<Void> allocator,
      Pointer<Utf8> buffer,
      Long bufLen,
      Uint8 isDirectory,
    );
typedef _CFURLCreateDart =
    Pointer<Void> Function(
      Pointer<Void> allocator,
      Pointer<Utf8> buffer,
      int bufLen,
      int isDirectory,
    );

typedef _CFURLSetPropC =
    Uint8 Function(
      Pointer<Void> url,
      Pointer<Void> key,
      Pointer<Void> value,
      Pointer<Void> errorOut,
    );
typedef _CFURLSetPropDart =
    int Function(
      Pointer<Void> url,
      Pointer<Void> key,
      Pointer<Void> value,
      Pointer<Void> errorOut,
    );

typedef _CFURLCopyPropC =
    Uint8 Function(
      Pointer<Void> url,
      Pointer<Void> key,
      Pointer<Pointer<Void>> valueOut,
      Pointer<Void> errorOut,
    );
typedef _CFURLCopyPropDart =
    int Function(
      Pointer<Void> url,
      Pointer<Void> key,
      Pointer<Pointer<Void>> valueOut,
      Pointer<Void> errorOut,
    );

typedef _CFBooleanGetC = Uint8 Function(Pointer<Void> boolean);
typedef _CFBooleanGetDart = int Function(Pointer<Void> boolean);

typedef _CFReleaseC = Void Function(Pointer<Void> cf);
typedef _CFReleaseDart = void Function(Pointer<Void> cf);

/// Lazy lookups in the process image (CoreFoundation is always loaded
/// on Apple platforms) — top-level finals initialize on first read, so
/// merely importing this file on an OS without the symbols can never
/// fail; the lookups only run when [IosFileSystemOs] is actually
/// selected (or a test exercises it on a macOS host, where the same
/// CoreFoundation symbols exist).
final DynamicLibrary _process = DynamicLibrary.process();

final _CFURLCreateDart _cfUrlCreate = _process
    .lookupFunction<_CFURLCreateC, _CFURLCreateDart>(
      'CFURLCreateFromFileSystemRepresentation',
    );

final _CFURLSetPropDart _cfUrlSetProperty = _process
    .lookupFunction<_CFURLSetPropC, _CFURLSetPropDart>(
      'CFURLSetResourcePropertyForKey',
    );

final _CFURLCopyPropDart _cfUrlCopyProperty = _process
    .lookupFunction<_CFURLCopyPropC, _CFURLCopyPropDart>(
      'CFURLCopyResourcePropertyForKey',
    );

final _CFBooleanGetDart _cfBooleanGetValue = _process
    .lookupFunction<_CFBooleanGetC, _CFBooleanGetDart>('CFBooleanGetValue');

final _CFReleaseDart _cfRelease = _process
    .lookupFunction<_CFReleaseC, _CFReleaseDart>('CFRelease');

/// Exported CFStringRef constants — the symbols are variables holding
/// a pointer, so the lookup dereferences one level.
final Pointer<Void> _kIsExcludedFromBackupKey = _process
    .lookup<Pointer<Void>>('kCFURLIsExcludedFromBackupKey')
    .value;

final Pointer<Void> _kCFBooleanTrue = _process
    .lookup<Pointer<Void>>('kCFBooleanTrue')
    .value;

/// See library doc — the backup-exclusion override.
class IosFileSystemOs extends DefaultFileSystemOs {
  /// Run [body] with a CFURL for [directoryPath], releasing it after.
  /// Returns null (callers degrade to the safe backed-up state) when
  /// the URL can't be created.
  T? _withUrl<T>(String directoryPath, T Function(Pointer<Void> url) body) {
    final pathPtr = directoryPath.toNativeUtf8();
    try {
      final url = _cfUrlCreate(nullptr, pathPtr, pathPtr.length, 1);
      if (url == nullptr) return null;
      try {
        return body(url);
      } finally {
        _cfRelease(url);
      }
    } finally {
      calloc.free(pathPtr);
    }
  }

  @override
  Future<bool> excludeFromBackup(String directoryPath) async =>
      _withUrl(
        directoryPath,
        (url) =>
            _cfUrlSetProperty(
              url,
              _kIsExcludedFromBackupKey,
              _kCFBooleanTrue,
              nullptr,
            ) !=
            0,
      ) ??
      false;

  /// Read the exclusion state back through the system's own resource
  /// layer — the observation half of the mechanism.
  Future<bool> isExcludedFromBackup(String directoryPath) async =>
      _withUrl(directoryPath, (url) {
        final valueOut = calloc<Pointer<Void>>();
        try {
          final ok = _cfUrlCopyProperty(
            url,
            _kIsExcludedFromBackupKey,
            valueOut,
            nullptr,
          );
          final value = valueOut.value;
          if (ok == 0 || value == nullptr) return false;
          final excluded = _cfBooleanGetValue(value) != 0;
          _cfRelease(value);
          return excluded;
        } finally {
          calloc.free(valueOut);
        }
      }) ??
      false;
}
