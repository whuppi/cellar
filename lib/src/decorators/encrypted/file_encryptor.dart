import 'dart:typed_data';

/// Bring-your-own encryption interface for `EncryptedBackend`.
///
/// Cellar ships no encryption implementation — encryption is fully
/// optional. If you want it, implement this interface over the crypto
/// library of your choice (AES via Web Crypto, libsodium, a Flutter
/// crypto plugin, etc.) and pass the implementation in via
/// `CellarEncryption`.
///
/// ## File format the implementation must produce
///
/// ```
/// [header][chunk0 + mac][chunk1 + mac]...[final chunk + mac]
/// ```
///
/// Each chunk carries its own MAC. That's what makes the rest work:
/// - **Streaming encrypt**: emit one chunk at a time; never buffer more.
/// - **Streaming decrypt**: read and verify one chunk at a time.
/// - **Chunk-aware range reads**: decrypt only the chunks overlapping
///   the requested byte range.
/// - **Early corruption detection**: a bad chunk surfaces at read time,
///   not after the whole file has been loaded.
//
// DESIGN NOTE — interface, not implementation.
//
// Cellar declares what it needs from a file encryptor and nothing more.
// The `key` parameter is `Object` on purpose: cellar doesn't care
// whether your key is a SecretKey, raw bytes, a handle from a hardware
// keystore, or anything else. Whoever implements FileEncryptor knows.
abstract interface class FileEncryptor {
  /// Default encryption chunk size — 256 KiB. Balances per-chunk MAC
  /// overhead against memory per chunk in flight.
  static const int defaultChunkSize = 256 * 1024;

  /// Size of the file header in bytes.
  int get headerSize;

  /// Size of per-chunk MAC in bytes (appended after each encrypted chunk).
  int get chunkMacSize;

  /// True streaming encrypt.
  ///
  /// Yields: `[header bytes]`, `[chunk0 + mac]`, `[chunk1 + mac]`, ...
  ///
  /// Never buffers more than one chunk in memory. Safe for arbitrarily
  /// large files (7GB model files, FLAC audio, video).
  ///
  /// [chunkSize] is the plaintext chunk size in bytes (default 256KB).
  Stream<List<int>> encryptStream(
    Stream<List<int>> plaintext,
    Object key, {
    int chunkSize = FileEncryptor.defaultChunkSize,
  });

  /// Encrypt a byte buffer. Convenience wrapper for small files.
  ///
  /// Internally wraps [plaintext] as a single-element stream and collects
  /// the result. For large files, use [encryptStream] directly.
  Future<Uint8List> encryptBytes(
    Uint8List plaintext,
    Object key, {
    int chunkSize = FileEncryptor.defaultChunkSize,
  });

  /// True streaming decrypt.
  ///
  /// Takes the raw ciphertext stream (header + encrypted chunks with MACs),
  /// yields plaintext chunks. Each chunk's MAC is verified before yielding.
  ///
  /// Throws if any chunk fails MAC verification (tampered data).
  Stream<List<int>> decryptStream(Stream<List<int>> ciphertext, Object key);

  /// Decrypt a single chunk and verify its MAC.
  ///
  /// [chunkWithMac] contains the encrypted data followed by the MAC.
  /// [nonce] is the base nonce from the file header.
  /// [chunkIndex] is the 0-based chunk position (for counter derivation).
  ///
  /// Throws if MAC verification fails.
  Future<Uint8List> decryptChunk(
    Uint8List chunkWithMac,
    Object key,
    Uint8List nonce,
    int chunkIndex,
  );

  /// Decrypt an entire file from bytes. Convenience wrapper.
  ///
  /// Reads header, decrypts all chunks, verifies all MACs, returns plaintext.
  /// For large files, use [decryptStream] instead.
  Future<Uint8List> decryptBytes(Uint8List ciphertext, Object key);

  /// Parse the file header.
  ///
  /// Returns all fields needed for random-access chunk decryption.
  ///
  /// Streaming-write contract: `chunkSize` and `nonce` MUST be final the
  /// moment the header is emitted at stream start — only `originalSize`
  /// and `chunkCount` may be provisional (0) until the stream ends.
  /// Readers reconstruct a crashed streamed write's geometry from the
  /// ciphertext length + these two fields; a chunk size that changed
  /// mid-stream would make that reconstruction (and random access) wrong.
  ({
    int chunkSize,
    int originalSize,
    Uint8List nonce,
    int headerSize,
    int chunkCount,
  })
  parseHeader(Uint8List headerBytes);

  /// Check if bytes start with the encryption magic header.
  bool isEncrypted(Uint8List bytes);
}
