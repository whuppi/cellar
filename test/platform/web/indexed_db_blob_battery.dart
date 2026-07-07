/// IndexedDB Blob-URL materialization — browser-only by nature: the
/// handles are Blob URLs served by the real browser, verified through
/// actual fetch(). Invoked ONLY by the web runner.
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:cellar/cellar_lowlevel.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

void runIndexedDbBlobBattery() {
  group('IndexedDbBackend materialize (Blob URL)', () {
    test('multi-chunk object round-trips through fetch()', () async {
      final backend = IndexedDbBackend(dbName: 'cellar_blob_roundtrip');
      addTearDown(backend.dispose);

      // 200 KiB at the 64 KiB default chunk size — four chunk records
      // assembled into one Blob.
      final data = Uint8List.fromList(
        List<int>.generate(200 * 1024, (i) => i & 0xFF),
      );
      await backend.write(
        'media/clip',
        data,
        const WriteOptions(contentType: 'application/octet-stream'),
      );

      final handle = await backend.materialize('media/clip');
      expect(handle.localPath, startsWith('blob:'));

      // Fetch the Blob URL back — proves the browser can actually serve
      // the assembled bytes, not just that a URL string exists.
      final response = await web.window.fetch(handle.localPath.toJS).toDart;
      final buffer = await response.arrayBuffer().toDart;
      expect(buffer.toDart.asUint8List(), equals(data));

      await handle.release();
    });

    test('release revokes the Blob URL', () async {
      final backend = IndexedDbBackend(dbName: 'cellar_blob_revoke');
      addTearDown(backend.dispose);
      await backend.write('k', Uint8List.fromList([1, 2, 3]));

      final handle = await backend.materialize('k');
      await handle.release();

      // A revoked object URL fails to fetch.
      await expectLater(
        web.window.fetch(handle.localPath.toJS).toDart,
        throwsA(anything),
      );
    });
  });
}
