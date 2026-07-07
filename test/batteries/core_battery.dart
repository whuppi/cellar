/// The core vocabulary: typed errors, the key grammar, ObjectInfo —
/// pure, runs on every platform.
library;

import 'package:cellar/cellar.dart';
import 'package:test/test.dart';

void runCoreBattery() {
  _errors();
  _keyValidation();
  _objectInfo();
}

void _errors() {
  group('StorageError hierarchy', () {
    test('FileNotFoundError carries the key', () {
      const e = FileNotFoundError('photos/missing');
      expect(e.key, 'photos/missing');
      expect(e.toString(), contains('photos/missing'));
      expect(e, isA<StorageError>());
    });

    test('CorruptedFileError carries key + cause', () {
      final e = CorruptedFileError('a/b', cause: 'bad header');
      expect(e.key, 'a/b');
      expect(e.cause, 'bad header');
      expect(e.toString(), contains('bad header'));
    });

    test('ChunkVerificationError carries key + chunkIndex', () {
      const e = ChunkVerificationError('models/llama', 7);
      expect(e.key, 'models/llama');
      expect(e.chunkIndex, 7);
      expect(e.toString(), contains('chunk 7'));
    });

    test('InvalidHeaderError carries key + cause', () {
      final e = InvalidHeaderError('vault/x', cause: 'bad magic');
      expect(e.key, 'vault/x');
      expect(e.cause, 'bad magic');
    });

    test('InvalidKeyError uses reason as message', () {
      const e = InvalidKeyError('bad key!', 'spaces not allowed');
      expect(e.key, 'bad key!');
      expect(e.message, 'spaces not allowed');
      expect(e.toString(), contains('spaces not allowed'));
    });

    test('EncryptionKeyMissingError carries key', () {
      const e = EncryptionKeyMissingError('vault/secret');
      expect(e.key, 'vault/secret');
    });

    test('WriteError carries key + cause', () {
      final e = WriteError('photos/x', cause: 'disk full');
      expect(e.key, 'photos/x');
      expect(e.cause, 'disk full');
    });

    test('CorruptedMetadataError carries key + cause', () {
      final e = CorruptedMetadataError('a/b', cause: 'bad json');
      expect(e.key, 'a/b');
      expect(e.cause, 'bad json');
    });

    test('every concrete subclass extends StorageError (sealed)', () {
      const errs = <StorageError>[
        FileNotFoundError('a'),
        EncryptionKeyMissingError('a'),
        CorruptedFileError('a'),
        CorruptedMetadataError('a'),
        ChunkVerificationError('a', 0),
        InvalidHeaderError('a'),
        InvalidKeyError('a', 'reason'),
        WriteError('a'),
      ];
      for (final e in errs) {
        expect(e, isA<StorageError>());
        expect(e, isA<Exception>());
      }
    });

    test('pattern-matchable in catch chain', () {
      Object? caught;
      try {
        throw const FileNotFoundError('x');
      } on FileNotFoundError catch (e) {
        caught = e;
      } on StorageError catch (_) {
        fail('FileNotFoundError should match before StorageError');
      }
      expect(caught, isA<FileNotFoundError>());
    });
  });
}

void _keyValidation() {
  group('validateKey', () {
    group('accepts valid keys', () {
      for (final k in [
        'a',
        'photos',
        'photos/sunset',
        'user/u1/photos/sunset.png',
        'a-b_c.d',
        '123/456',
        'a' * 200,
      ]) {
        test('"$k"', () {
          expect(() => validateKey(k), returnsNormally);
        });
      }
    });

    test('accepts a long multi-segment key', () {
      // No arbitrary length cap at the validation layer — segment
      // grammar is the contract; backends own their own path limits.
      final longKey = List.generate(40, (i) => 'segment$i').join('/');
      expect(() => validateKey(longKey), returnsNormally);
    });

    group('rejects invalid keys', () {
      final cases = <String, String>{
        '': 'empty',
        '/photos': 'leading slash',
        'photos/': 'trailing slash',
        'photos//sunset': 'consecutive slashes',
        '../secrets': 'path traversal (..)',
        './secrets': 'path traversal (.)',
        'a/../b': 'embedded ..',
        'a/./b': 'embedded .',
        'my file.txt': 'space',
        'a:b': 'colon (Windows)',
        'a*b': 'asterisk',
        'a?b': 'question mark',
        'a"b': 'double quote',
        'a<b': 'angle bracket',
        'a|b': 'pipe',
        '\u0000': 'null byte',
        '_starts_with_underscore': 'underscore start',
        '-starts-with-dash': 'dash start',
        '.starts.with.dot': 'dot start',
        '写真/夕日': 'non-ASCII (CJK)',
        'photos/café': 'non-ASCII (diacritic)',
        'pix/🌅': 'non-ASCII (emoji)',
      };
      for (final entry in cases.entries) {
        test('"${entry.key}" (${entry.value})', () {
          expect(() => validateKey(entry.key), throwsA(isA<InvalidKeyError>()));
        });
      }
    });
  });

  group('validatePrefix', () {
    test('accepts empty (list-everything)', () {
      expect(() => validatePrefix(''), returnsNormally);
    });

    test('accepts trailing slash', () {
      expect(() => validatePrefix('photos/'), returnsNormally);
      expect(() => validatePrefix('user/u1/'), returnsNormally);
    });

    test('accepts no trailing slash (treated as a key prefix)', () {
      expect(() => validatePrefix('photos'), returnsNormally);
    });

    test('rejects path traversal', () {
      expect(() => validatePrefix('../foo'), throwsA(isA<InvalidKeyError>()));
    });

    test('rejects null bytes', () {
      expect(
        () => validatePrefix('foo\u0000bar'),
        throwsA(isA<InvalidKeyError>()),
      );
    });
  });
}

void _objectInfo() {
  group('ObjectInfo', () {
    final now = DateTime.utc(2026, 1, 1, 12, 0, 0);

    test('constructs with all fields', () {
      final info = ObjectInfo(
        key: 'photos/sunset',
        size: 1024,
        contentType: 'image/png',
        metadata: const {'photographer': 'alice'},
        lastModified: now,
      );
      expect(info.key, 'photos/sunset');
      expect(info.size, 1024);
      expect(info.contentType, 'image/png');
      expect(info.metadata['photographer'], 'alice');
      expect(info.lastModified, now);
    });

    test('lastModified is required (non-null contract)', () {
      // The constructor requires it; passing null is a compile error.
      // This test just documents the invariant.
      final info = ObjectInfo(key: 'k', size: 0, lastModified: now);
      expect(info.lastModified, isNotNull);
    });

    test('copyWith replaces fields', () {
      final original = ObjectInfo(
        key: 'a',
        size: 10,
        contentType: 'text/plain',
        metadata: const {'k': 'v'},
        lastModified: now,
      );
      final later = now.add(const Duration(hours: 1));
      final updated = original.copyWith(size: 20, lastModified: later);
      expect(updated.key, 'a');
      expect(updated.size, 20);
      expect(updated.contentType, 'text/plain');
      expect(updated.metadata['k'], 'v');
      expect(updated.lastModified, later);
    });

    test('copyWith with no args returns equivalent object', () {
      final original = ObjectInfo(key: 'a', size: 10, lastModified: now);
      final copy = original.copyWith();
      expect(copy.key, original.key);
      expect(copy.size, original.size);
      expect(copy.lastModified, original.lastModified);
    });

    test('equality compares key + size + contentType', () {
      final a = ObjectInfo(
        key: 'k',
        size: 1,
        contentType: 'text/plain',
        lastModified: now,
      );
      final b = ObjectInfo(
        key: 'k',
        size: 1,
        contentType: 'text/plain',
        lastModified: now.add(const Duration(hours: 1)),
      );
      // lastModified isn't part of equality — same key/size/contentType wins.
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('equality fails on different key', () {
      final a = ObjectInfo(key: 'a', size: 1, lastModified: now);
      final b = ObjectInfo(key: 'b', size: 1, lastModified: now);
      expect(a, isNot(equals(b)));
    });

    test('toString includes key and size', () {
      final info = ObjectInfo(
        key: 'photos/sunset',
        size: 1024,
        contentType: 'image/png',
        lastModified: now,
      );
      final s = info.toString();
      expect(s, contains('photos/sunset'));
      expect(s, contains('1024'));
      expect(s, contains('image/png'));
    });

    test('metadata defaults to empty map', () {
      final info = ObjectInfo(key: 'k', size: 0, lastModified: now);
      expect(info.metadata, isEmpty);
    });
  });
}
