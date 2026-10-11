import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Content hash and size of a file.
class HashedFile {
  const HashedFile({required this.sha256, required this.size});

  /// Lower-case hex SHA-256.
  final String sha256;
  final int size;
}

const _chunkSize = 1024 * 1024;

/// Hashes [path] in fixed-size chunks (constant memory). Synchronous: run on
/// a background isolate.
HashedFile hashFileSync(String path) {
  final input = File(path).openSync();
  final digest = _DigestSink();
  final hasher = sha256.startChunkedConversion(digest);
  final buffer = Uint8List(_chunkSize);
  var total = 0;
  try {
    while (true) {
      final read = input.readIntoSync(buffer);
      if (read == 0) break;
      hasher.add(Uint8List.sublistView(buffer, 0, read));
      total += read;
    }
  } finally {
    input.closeSync();
  }
  hasher.close();
  return HashedFile(sha256: digest.value.toString(), size: total);
}

/// Copies [source] to [destination] while hashing it, reading the source only
/// once. The copy is flushed to disk before returning. Synchronous: run on a
/// background isolate.
HashedFile copyAndHashSync(String source, String destination) {
  final input = File(source).openSync();
  final RandomAccessFile output;
  try {
    output = File(destination).openSync(mode: FileMode.writeOnly);
  } catch (_) {
    input.closeSync();
    rethrow;
  }
  final digest = _DigestSink();
  final hasher = sha256.startChunkedConversion(digest);
  final buffer = Uint8List(_chunkSize);
  var total = 0;
  try {
    while (true) {
      final read = input.readIntoSync(buffer);
      if (read == 0) break;
      hasher.add(Uint8List.sublistView(buffer, 0, read));
      output.writeFromSync(buffer, 0, read);
      total += read;
    }
    output.flushSync();
  } finally {
    input.closeSync();
    output.closeSync();
  }
  hasher.close();
  return HashedFile(sha256: digest.value.toString(), size: total);
}

class _DigestSink implements Sink<Digest> {
  Digest? _value;

  Digest get value => _value!;

  @override
  void add(Digest data) => _value = data;

  @override
  void close() {}
}
