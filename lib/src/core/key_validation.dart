import 'package:cellar/src/core/errors.dart';

/// Valid characters for a single key segment.
///
/// Must start with alphanumeric. May contain alphanumeric, hyphen,
/// underscore, or dot. This matches the safe intersection across:
/// - Local filesystem (macOS APFS, Windows NTFS, Linux ext4)
/// - IndexedDB (web)
/// - S3-compatible object storage
///
/// `/` is NOT part of a segment — it's the separator between segments.
final _validSegment = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]*$');

/// Validate a storage key.
///
/// Keys are relative paths with `/` as the separator. Each segment
/// between slashes must match `[a-zA-Z0-9][a-zA-Z0-9._-]*`.
///
/// ## Valid examples
/// ```
/// 'photos/sunset'
/// 'user/u1/avatar'
/// 'models/abc123/content'
/// 'a'
/// ```
///
/// ## Invalid examples
/// ```
/// ''                  ← empty
/// '/photos'           ← leading slash
/// 'photos/'           ← trailing slash
/// 'photos//sunset'    ← consecutive slashes
/// '../secrets'        ← path traversal
/// 'my file.txt'       ← space in segment
/// 'a:b'               ← colon (Windows-unsafe)
/// ```
///
/// Throws [InvalidKeyError] with a clear message on invalid keys.
void validateKey(String key) {
  if (key.isEmpty) {
    throw InvalidKeyError(key, 'Key cannot be empty');
  }
  if (key.startsWith('/')) {
    throw InvalidKeyError(key, 'Key cannot start with /');
  }
  if (key.endsWith('/')) {
    throw InvalidKeyError(key, 'Key cannot end with /');
  }
  if (key.contains('//')) {
    throw InvalidKeyError(key, 'Key cannot contain consecutive slashes');
  }
  if (key.contains('\x00')) {
    throw InvalidKeyError(key, 'Key cannot contain null bytes');
  }

  final segments = key.split('/');
  for (final segment in segments) {
    if (segment == '.' || segment == '..') {
      throw InvalidKeyError(key, 'Path traversal not allowed: $segment');
    }
    if (segment.isEmpty) {
      throw InvalidKeyError(key, 'Key contains empty segment');
    }
    if (!_validSegment.hasMatch(segment)) {
      throw InvalidKeyError(key, 'Invalid characters in segment: $segment');
    }
  }
}

/// Validate a prefix used for listing/deleting.
///
/// Same rules as [validateKey] but allows trailing `/` (required for
/// prefix operations) and allows empty string (list everything).
void validatePrefix(String prefix) {
  if (prefix.isEmpty) return;

  // Strip trailing slash for validation, then validate as key
  final normalized = prefix.endsWith('/')
      ? prefix.substring(0, prefix.length - 1)
      : prefix;
  if (normalized.isEmpty) return;

  validateKey(normalized);
}
