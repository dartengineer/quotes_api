import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// Thrown when a zip entry would decompress to more than the allowed size.
class ZipEntryTooLargeException implements Exception {
  const ZipEntryTooLargeException(this.name, this.limit);

  final String name;
  final int limit;

  @override
  String toString() => 'ZipEntryTooLargeException($name > $limit bytes)';
}

/// Read-only access to a zip archive (such as an EPUB) that treats its
/// contents as untrusted.
///
/// * Entries are decompressed on demand, never all at once.
/// * Every read has a byte limit that is enforced *while* decompressing, so a
///   "zip bomb" whose headers understate its size cannot exhaust memory.
/// * Lookups normalise paths and fall back to a case-insensitive match,
///   because real-world EPUBs often reference files with the wrong case.
class SafeZip {
  SafeZip._(this._input, this._archive)
    : _lowerCaseIndex = {
        for (final file in _archive.files)
          if (file.isFile) _normalize(file.name).toLowerCase(): file,
      };

  /// Opens the zip at [path] by reading its central directory only.
  ///
  /// Throws a [FormatException] if the file is not a readable zip archive
  /// or contains no files. (The underlying decoder returns an empty archive
  /// rather than failing for non-zip input, so emptiness is the signal.)
  factory SafeZip.open(String path) {
    final input = InputFileStream(path);
    try {
      final archive = ZipDecoder().decodeStream(input);
      if (!archive.files.any((f) => f.isFile)) {
        throw const FormatException('Not a zip archive, or an empty one');
      }
      return SafeZip._(input, archive);
    } catch (_) {
      input.closeSync();
      rethrow;
    }
  }

  final InputFileStream _input;
  final Archive _archive;
  final Map<String, ArchiveFile> _lowerCaseIndex;

  /// Names of all file entries (directories excluded).
  Iterable<String> get fileNames =>
      _archive.files.where((f) => f.isFile).map((f) => f.name);

  /// Finds a file entry by path, tolerating `./`, `../` segments, leading
  /// slashes and case differences.
  ArchiveFile? find(String path) {
    final normalized = _normalize(path);
    if (normalized.isEmpty) return null;
    final exact = _archive.find(normalized);
    if (exact != null && exact.isFile) return exact;
    return _lowerCaseIndex[normalized.toLowerCase()];
  }

  bool contains(String path) => find(path) != null;

  /// Decompresses [entry], failing with [ZipEntryTooLargeException] as soon
  /// as more than [maxBytes] would be produced.
  Uint8List read(ArchiveFile entry, {required int maxBytes}) {
    if (entry.size > maxBytes) {
      throw ZipEntryTooLargeException(entry.name, maxBytes);
    }
    final output = _CappedOutput(entry.name, maxBytes);
    entry.decompress(output);
    return Uint8List.fromList(output.getBytes());
  }

  /// Reads [path] if it exists, otherwise returns null.
  Uint8List? readPath(String path, {required int maxBytes}) {
    final entry = find(path);
    return entry == null ? null : read(entry, maxBytes: maxBytes);
  }

  void close() {
    _archive.clearSync();
    _input.closeSync();
  }

  /// Resolves [href] (as found inside a document at [basePath]) to an archive
  /// path. Strips fragments and query strings and decodes percent-escapes.
  static String resolve(String basePath, String href) {
    var target = href;
    final hash = target.indexOf('#');
    if (hash >= 0) target = target.substring(0, hash);
    final query = target.indexOf('?');
    if (query >= 0) target = target.substring(0, query);
    try {
      target = Uri.decodeFull(target);
    } on ArgumentError {
      // Malformed escape sequence: use the raw value.
    }
    if (target.startsWith('/')) return _normalize(target);
    return _normalize(p.posix.join(p.posix.dirname(basePath), target));
  }

  static String _normalize(String path) {
    final cleaned = path.replaceAll(r'\', '/');
    final normalized = p.posix.normalize(cleaned);
    var result = normalized;
    while (result.startsWith('/')) {
      result = result.substring(1);
    }
    // Paths that try to escape the archive root resolve to nothing.
    if (result == '.' || result == '..' || result.startsWith('../')) {
      return '';
    }
    return result;
  }
}

class _CappedOutput extends OutputMemoryStream {
  _CappedOutput(this._name, this._limit);

  final String _name;
  final int _limit;

  void _check(int additional) {
    if (length + additional > _limit) {
      throw ZipEntryTooLargeException(_name, _limit);
    }
  }

  @override
  void writeByte(int value) {
    _check(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _check(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _check(stream.length);
    super.writeStream(stream);
  }
}
