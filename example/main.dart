// Pure-Dart cellar demo — runs anywhere `dart run` runs (server, CLI,
// desktop). Flutter apps: see package:cellar_flutter instead.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cellar/cellar.dart';

Future<void> main() async {
  // A throwaway root so the demo cleans up after itself; real tools
  // use Cellar(name: ...) (OS-convention roots) or a path they own.
  final root = Directory.systemTemp.createTempSync('cellar_demo_');
  final cellar = Cellar.atPath(
    root.path,
    name: 'demo',
    partitions: {
      'main': const PartitionConfig(),
      'cache': const PartitionConfig(
        lifecycle: Lifecycle(maxBytes: 1024, runInterval: Duration(hours: 1)),
      ),
    },
    defaultPartition: 'main',
  );
  await cellar.open();

  // Write / read / head.
  await cellar.write(
    'notes/hello',
    Uint8List.fromList(utf8.encode('Hello from cellar!')),
    contentType: 'text/plain',
  );
  print('read: ${utf8.decode(await cellar.read('notes/hello'))}');
  print('head: ${await cellar.head('notes/hello')}');

  // Streaming + range.
  await cellar.writeStream(
    'big/data',
    Stream.value(List<int>.filled(64 * 1024, 7)),
  );
  final slice = await cellar.readRange('big/data', start: 100, length: 4);
  print('range: $slice');

  // Partitions + lifecycle.
  await cellar.write('junk/a', Uint8List(2048), partition: 'cache');
  await cellar.runLifecycleNow();
  print('evicted: ${!await cellar.exists('junk/a', partition: 'cache')}');

  // Typed errors.
  try {
    await cellar.read('missing');
  } on FileNotFoundError catch (e) {
    print('typed error: $e');
  }

  await cellar.close();
  root.deleteSync(recursive: true);
}
