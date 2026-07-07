import 'dart:convert';
import 'dart:typed_data';

import 'package:cellar/cellar.dart';

/// Trivial [FileEncryptor] for tests. NOT secure; just structured enough
/// to exercise EncryptedBackend's contract.
///
/// "Encryption" is XOR with a key-derived byte. Header carries:
///   - 4 magic bytes ("FAKE")
///   - 8 bytes original size (little-endian)
///   - 4 bytes chunk size (little-endian)
///   - 16 bytes nonce (random)
/// Per-chunk MAC: a 4-byte CRC-style sum of (nonce + chunkIndex + bytes).
class FakeEncryptor implements FileEncryptor {
  FakeEncryptor({this.streamChunkSize = 262144});
  static const _magic = [0x46, 0x41, 0x4B, 0x45]; // "FAKE"

  /// Chunk size used regardless of the per-call parameter — lets tests
  /// exercise multi-chunk framing with small payloads. The header records
  /// whatever was used, so every decrypt path stays coherent.
  final int streamChunkSize;

  @override
  int get headerSize => 32; // 4 magic + 8 size + 4 chunk + 16 nonce

  @override
  int get chunkMacSize => 4;

  Uint8List _xor(Uint8List bytes, Object key) {
    final k = _keyBytes(key);
    final out = Uint8List(bytes.length);
    for (var i = 0; i < bytes.length; i++) {
      out[i] = bytes[i] ^ k[i % k.length];
    }
    return out;
  }

  Uint8List _keyBytes(Object key) {
    if (key is List<int>) return Uint8List.fromList(key);
    return Uint8List.fromList(utf8.encode(key.toString()));
  }

  Uint8List _mac(Uint8List nonce, int chunkIndex, Uint8List bytes) {
    var sum = 0;
    for (final b in nonce) {
      sum = (sum + b) & 0xFFFFFFFF;
    }
    sum = (sum + chunkIndex) & 0xFFFFFFFF;
    for (final b in bytes) {
      sum = (sum + b) & 0xFFFFFFFF;
    }
    final mac = Uint8List(4);
    mac[0] = (sum >> 24) & 0xFF;
    mac[1] = (sum >> 16) & 0xFF;
    mac[2] = (sum >> 8) & 0xFF;
    mac[3] = sum & 0xFF;
    return mac;
  }

  Uint8List _writeHeader(int originalSize, int chunkSize, Uint8List nonce) {
    final h = Uint8List(headerSize);
    h.setRange(0, 4, _magic);
    final size = ByteData.view(h.buffer);
    // dart2js has no 64-bit accessors — write as two 32-bit halves
    // (little-endian: low word first). Self-consistent with the read.
    size.setUint32(4, originalSize % 0x100000000, Endian.little);
    size.setUint32(8, originalSize ~/ 0x100000000, Endian.little);
    size.setUint32(12, chunkSize, Endian.little);
    h.setRange(16, 32, nonce);
    return h;
  }

  Uint8List _randomNonce() {
    final n = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      n[i] = (DateTime.now().microsecondsSinceEpoch + i * 7) & 0xFF;
    }
    return n;
  }

  @override
  Future<Uint8List> encryptBytes(
    Uint8List plaintext,
    Object key, {
    int chunkSize = 262144,
  }) async {
    final effectiveChunk = streamChunkSize;
    final nonce = _randomNonce();
    final out = BytesBuilder();
    out.add(_writeHeader(plaintext.length, effectiveChunk, nonce));
    var offset = 0;
    var chunkIndex = 0;
    while (offset < plaintext.length) {
      final end = (offset + effectiveChunk).clamp(0, plaintext.length);
      final chunk = Uint8List.sublistView(plaintext, offset, end);
      final encrypted = _xor(chunk, key);
      out.add(encrypted);
      out.add(_mac(nonce, chunkIndex, encrypted));
      offset = end;
      chunkIndex++;
    }
    return out.takeBytes();
  }

  @override
  Stream<List<int>> encryptStream(
    Stream<List<int>> plaintext,
    Object key, {
    int chunkSize = 262144,
  }) async* {
    final effectiveChunk = streamChunkSize;
    final nonce = _randomNonce();
    // Provisional header — originalSize=0 because we don't know yet.
    yield _writeHeader(0, effectiveChunk, nonce);
    final buffer = BytesBuilder();
    var chunkIndex = 0;
    await for (final piece in plaintext) {
      buffer.add(piece);
      while (buffer.length >= effectiveChunk) {
        final all = buffer.takeBytes();
        final chunk = Uint8List.sublistView(all, 0, effectiveChunk);
        final rest = Uint8List.sublistView(all, effectiveChunk);
        final encrypted = _xor(chunk, key);
        yield encrypted;
        yield _mac(nonce, chunkIndex, encrypted);
        chunkIndex++;
        buffer.add(rest);
      }
    }
    if (buffer.isNotEmpty) {
      final tail = buffer.takeBytes();
      final encrypted = _xor(tail, key);
      yield encrypted;
      yield _mac(nonce, chunkIndex, encrypted);
    }
  }

  ({
    int chunkSize,
    int originalSize,
    Uint8List nonce,
    int headerSize,
    int chunkCount,
  })
  _parse(Uint8List header) {
    if (header.length < headerSize) {
      throw InvalidHeaderError('(unknown)', cause: 'short header');
    }
    for (var i = 0; i < 4; i++) {
      if (header[i] != _magic[i]) {
        throw InvalidHeaderError('(unknown)', cause: 'bad magic');
      }
    }
    final size = ByteData.view(header.buffer);
    final originalSize =
        size.getUint32(4, Endian.little) +
        size.getUint32(8, Endian.little) * 0x100000000;
    final chunkSize = size.getUint32(12, Endian.little);
    final nonce = Uint8List.fromList(header.sublist(16, 32));
    final chunkCount = chunkSize == 0
        ? 0
        : (originalSize + chunkSize - 1) ~/ chunkSize;
    return (
      chunkSize: chunkSize,
      originalSize: originalSize,
      nonce: nonce,
      headerSize: headerSize,
      chunkCount: chunkCount,
    );
  }

  @override
  ({
    int chunkSize,
    int originalSize,
    Uint8List nonce,
    int headerSize,
    int chunkCount,
  })
  parseHeader(Uint8List headerBytes) => _parse(headerBytes);

  @override
  Future<Uint8List> decryptChunk(
    Uint8List chunkWithMac,
    Object key,
    Uint8List nonce,
    int chunkIndex,
  ) async {
    final macStart = chunkWithMac.length - chunkMacSize;
    if (macStart <= 0) {
      throw const ChunkVerificationError('(unknown)', 0);
    }
    final body = Uint8List.sublistView(chunkWithMac, 0, macStart);
    final mac = Uint8List.sublistView(chunkWithMac, macStart);
    final expected = _mac(nonce, chunkIndex, body);
    for (var i = 0; i < chunkMacSize; i++) {
      if (mac[i] != expected[i]) {
        throw ChunkVerificationError('(unknown)', chunkIndex);
      }
    }
    return _xor(body, key);
  }

  @override
  Future<Uint8List> decryptBytes(Uint8List ciphertext, Object key) async {
    final header = _parse(Uint8List.sublistView(ciphertext, 0, headerSize));
    final out = BytesBuilder();
    var offset = headerSize;
    for (var i = 0; i < header.chunkCount; i++) {
      final remaining = header.originalSize - i * header.chunkSize;
      final chunkLen = remaining < header.chunkSize
          ? remaining
          : header.chunkSize;
      final chunkWithMac = Uint8List.sublistView(
        ciphertext,
        offset,
        offset + chunkLen + chunkMacSize,
      );
      final plain = await decryptChunk(chunkWithMac, key, header.nonce, i);
      out.add(plain);
      offset += chunkLen + chunkMacSize;
    }
    return out.takeBytes();
  }

  @override
  Stream<List<int>> decryptStream(
    Stream<List<int>> ciphertext,
    Object key,
  ) async* {
    final builder = BytesBuilder();
    await for (final chunk in ciphertext) {
      builder.add(chunk);
    }
    yield await decryptBytes(builder.takeBytes(), key);
  }

  @override
  bool isEncrypted(Uint8List bytes) {
    if (bytes.length < 4) return false;
    for (var i = 0; i < 4; i++) {
      if (bytes[i] != _magic[i]) return false;
    }
    return true;
  }
}

/// Trivial [EncryptionKeyResolver] for tests. Returns the same key for
/// every storage key. For per-key resolution tests, use [MapKeyResolver].
class FixedKeyResolver implements EncryptionKeyResolver {
  const FixedKeyResolver(this.key);
  final Object key;

  @override
  Future<Object?> resolveKey(String storageKey) async => key;

  @override
  void clearCache() {}
}

/// Per-storage-key resolver: returns `keys[storageKey]`, or null for any
/// key not in the map — models a resolver that only covers part of the
/// keyspace (locked profile, foreign tenant, missing mapping).
class MapKeyResolver implements EncryptionKeyResolver {
  const MapKeyResolver(this.keys);
  final Map<String, Object> keys;

  @override
  Future<Object?> resolveKey(String storageKey) async => keys[storageKey];

  @override
  void clearCache() {}
}
