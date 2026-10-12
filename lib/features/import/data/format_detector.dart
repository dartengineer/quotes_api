import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../../core/files/safe_zip.dart';
import '../../library/domain/document_format.dart';
import '../domain/format_detection.dart';

/// Identifies document formats from file contents, never from the file name
/// or the MIME type a document provider reports (both are often wrong).
///
/// Synchronous: call from a background isolate.
abstract final class FormatDetector {
  /// How much of the file is inspected for signatures and text heuristics.
  static const sampleSize = 64 * 1024;

  static FormatDetection detectFile(String path) {
    final file = File(path);
    final length = file.lengthSync();
    if (length == 0) return const EmptyFile();

    final handle = file.openSync();
    final Uint8List head;
    try {
      head = handle.readSync(math.min(length, sampleSize));
    } finally {
      handle.closeSync();
    }

    final detection = _detectHeader(head, truncated: length > head.length);
    if (detection != _zipMarker) return detection;
    return _detectZip(path, epubSignature: _hasEpubSignature(head));
  }

  /// Classifies a file from its first bytes. Returns [_zipMarker] for zip
  /// files, whose directory must be inspected to tell EPUB from others.
  static FormatDetection _detectHeader(
    Uint8List head, {
    bool truncated = false,
  }) {
    if (head.isEmpty) return const EmptyFile();

    if (_indexOf(head, _pdf, limit: 1024) >= 0) {
      return const SupportedFormat(DocumentFormat.pdf);
    }
    if (_startsWith(head, _zipLocal) || _startsWith(head, _zipEmpty)) {
      return _zipMarker;
    }
    if (_startsWith(head, _ole)) {
      return const UnsupportedFormat('Older Microsoft Office document');
    }
    if (_matchesAt(head, 60, _mobi) || _matchesAt(head, 60, _palmText)) {
      return const UnsupportedFormat('Kindle (MOBI/AZW) ebook');
    }
    if (_startsWith(head, _djvu)) {
      return const UnsupportedFormat('DjVu document');
    }
    if (_startsWith(head, _jpeg) ||
        _startsWith(head, _png) ||
        _startsWith(head, _gif) ||
        (_startsWith(head, _riff) && _matchesAt(head, 8, _webp))) {
      return const UnsupportedFormat('Image');
    }
    if (_startsWith(head, _rar) || _startsWith(head, _sevenZip)) {
      return const UnsupportedFormat('Compressed archive');
    }
    if (_startsWith(head, _gzip)) {
      return const UnsupportedFormat('Compressed file');
    }

    if (_startsWith(head, _utf8Bom)) {
      return _classifyText(head.sublist(_utf8Bom.length));
    }
    if (_startsWith(head, _utf16LeBom) || _startsWith(head, _utf16BeBom)) {
      return const SupportedFormat(DocumentFormat.txt);
    }
    if (_looksLikeUtf16WithoutBom(head)) {
      return const SupportedFormat(DocumentFormat.txt);
    }
    if (head.contains(0)) {
      return const UnsupportedFormat('Unrecognised file');
    }
    if (_isValidUtf8(head, truncated: truncated) ||
        _controlCharacterRatio(head) < 0.01) {
      return _classifyText(head);
    }
    return const UnsupportedFormat('Unrecognised file');
  }

  /// Distinguishes plain text from markup that should not be shown as text.
  static FormatDetection _classifyText(Uint8List bytes) {
    final start = latin1
        .decode(bytes.sublist(0, math.min(bytes.length, 2048)))
        .trimLeft()
        .toLowerCase();
    if (start.startsWith(r'{\rtf')) {
      return const UnsupportedFormat('RTF document');
    }
    if (start.startsWith('<?xml')) {
      if (start.contains('<fictionbook')) {
        return const UnsupportedFormat('FictionBook (FB2) ebook');
      }
      if (start.contains('<html')) {
        return const UnsupportedFormat('Web page (HTML)');
      }
      return const UnsupportedFormat('XML file');
    }
    if (start.startsWith('<!doctype html') || start.startsWith('<html')) {
      return const UnsupportedFormat('Web page (HTML)');
    }
    return const SupportedFormat(DocumentFormat.txt);
  }

  static FormatDetection _detectZip(
    String path, {
    required bool epubSignature,
  }) {
    final SafeZip zip;
    try {
      zip = SafeZip.open(path);
    } catch (_) {
      return epubSignature
          ? const DamagedFile(DocumentFormat.epub)
          : const UnsupportedFormat('Damaged ZIP archive');
    }
    try {
      String? mimetype;
      try {
        final bytes = zip.readPath('mimetype', maxBytes: 256);
        if (bytes != null) mimetype = latin1.decode(bytes).trim();
      } catch (_) {
        // Ignore: fall back to the directory listing below.
      }

      final names = zip.fileNames.toList();
      if (mimetype == 'application/epub+zip' ||
          zip.contains('META-INF/container.xml')) {
        return const SupportedFormat(DocumentFormat.epub);
      }
      if (mimetype != null &&
          mimetype.startsWith('application/vnd.oasis.opendocument')) {
        return const UnsupportedFormat('OpenDocument file');
      }
      if (names.contains('[Content_Types].xml')) {
        if (names.any((n) => n.startsWith('word/'))) {
          return const UnsupportedFormat('Word document');
        }
        if (names.any((n) => n.startsWith('xl/'))) {
          return const UnsupportedFormat('Excel spreadsheet');
        }
        if (names.any((n) => n.startsWith('ppt/'))) {
          return const UnsupportedFormat('PowerPoint presentation');
        }
        return const UnsupportedFormat('Microsoft Office document');
      }
      if (names.isNotEmpty && names.every(_isImageName)) {
        return const UnsupportedFormat('Comic book archive (CBZ)');
      }
      return const UnsupportedFormat('ZIP archive');
    } finally {
      zip.close();
    }
  }

  static bool _isImageName(String name) {
    final lower = name.toLowerCase();
    return const ['.jpg', '.jpeg', '.png', '.gif', '.webp'].any(lower.endsWith);
  }

  /// A well-formed EPUB starts with an uncompressed `mimetype` entry, so the
  /// local header is followed by the name and the MIME type.
  static bool _hasEpubSignature(Uint8List head) =>
      _matchesAt(head, 30, ascii.encode('mimetypeapplication/epub+zip'));

  static bool _looksLikeUtf16WithoutBom(Uint8List head) {
    final pairs = head.length ~/ 2;
    if (pairs < 8) return false;
    var evenZeros = 0;
    var oddZeros = 0;
    for (var i = 0; i + 1 < head.length; i += 2) {
      if (head[i] == 0) evenZeros++;
      if (head[i + 1] == 0) oddZeros++;
    }
    final even = evenZeros / pairs;
    final odd = oddZeros / pairs;
    return (even > 0.4 && odd < 0.05) || (odd > 0.4 && even < 0.05);
  }

  /// Validates UTF-8. When [truncated], a multi-byte sequence cut off by the
  /// end of the sample is accepted.
  static bool _isValidUtf8(Uint8List bytes, {required bool truncated}) {
    var i = 0;
    while (i < bytes.length) {
      final b = bytes[i];
      final int continuation;
      if (b < 0x80) {
        i++;
        continue;
      } else if (b >= 0xC2 && b <= 0xDF) {
        continuation = 1;
      } else if (b >= 0xE0 && b <= 0xEF) {
        continuation = 2;
      } else if (b >= 0xF0 && b <= 0xF4) {
        continuation = 3;
      } else {
        return false;
      }
      if (i + continuation >= bytes.length) return truncated;
      for (var k = 1; k <= continuation; k++) {
        if (bytes[i + k] & 0xC0 != 0x80) return false;
      }
      i += continuation + 1;
    }
    return true;
  }

  /// Share of bytes that are control characters other than common
  /// whitespace. Legacy 8-bit text encodings score near zero.
  static double _controlCharacterRatio(Uint8List bytes) {
    var count = 0;
    for (final b in bytes) {
      final isWhitespace = b == 0x09 || b == 0x0A || b == 0x0C || b == 0x0D;
      if ((b < 0x20 && !isWhitespace) || b == 0x7F) count++;
    }
    return count / bytes.length;
  }

  static bool _startsWith(Uint8List data, List<int> prefix) =>
      _matchesAt(data, 0, prefix);

  static bool _matchesAt(Uint8List data, int offset, List<int> pattern) {
    if (data.length < offset + pattern.length) return false;
    for (var i = 0; i < pattern.length; i++) {
      if (data[offset + i] != pattern[i]) return false;
    }
    return true;
  }

  static int _indexOf(Uint8List data, List<int> pattern, {required int limit}) {
    final end = math.min(data.length - pattern.length, limit);
    for (var i = 0; i <= end; i++) {
      if (_matchesAt(data, i, pattern)) return i;
    }
    return -1;
  }

  static const _zipMarker = UnsupportedFormat('\u0000zip');

  static final _pdf = ascii.encode('%PDF-');
  static const _zipLocal = [0x50, 0x4B, 0x03, 0x04];
  static const _zipEmpty = [0x50, 0x4B, 0x05, 0x06];
  static const _ole = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
  static final _mobi = ascii.encode('BOOKMOBI');
  static final _palmText = ascii.encode('TEXtREAd');
  static final _djvu = ascii.encode('AT&TFORM');
  static const _jpeg = [0xFF, 0xD8, 0xFF];
  static const _png = [0x89, 0x50, 0x4E, 0x47];
  static final _gif = ascii.encode('GIF8');
  static final _riff = ascii.encode('RIFF');
  static final _webp = ascii.encode('WEBP');
  static final _rar = ascii.encode('Rar!');
  static const _sevenZip = [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C];
  static const _gzip = [0x1F, 0x8B];
  static const _utf8Bom = [0xEF, 0xBB, 0xBF];
  static const _utf16LeBom = [0xFF, 0xFE];
  static const _utf16BeBom = [0xFE, 0xFF];
}
