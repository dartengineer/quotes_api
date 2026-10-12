import 'dart:io';
import 'dart:typed_data';

import 'text_decoder.dart';

/// Thrown when a text file is too large to open safely.
class TextTooLargeException implements Exception {
  const TextTooLargeException(this.size);

  final int size;

  @override
  String toString() => 'TextTooLargeException($size bytes)';
}

/// A decoded plain-text document split into blocks for lazy rendering.
///
/// Blocks are lines (paragraphs), with very long lines split further so no
/// single block is expensive to lay out. Block boundaries are stored as
/// offsets into [text], not as separate strings, to keep memory use close
/// to the size of the text itself.
class TextDocument {
  TextDocument._(this.text, this.encoding, this._starts, this._ends);

  /// Files larger than this are refused instead of risking running out of
  /// memory on low-end devices.
  static const maxFileBytes = 50 * 1024 * 1024;

  /// Upper bound on characters per block.
  static const maxBlockLength = 2000;

  factory TextDocument.fromText(
    String text, {
    TextEncoding encoding = TextEncoding.utf8,
  }) {
    final starts = <int>[];
    final ends = <int>[];
    var lineStart = 0;
    while (lineStart <= text.length) {
      var lineEnd = text.indexOf('\n', lineStart);
      if (lineEnd < 0) lineEnd = text.length;
      _addLine(text, lineStart, lineEnd, starts, ends);
      lineStart = lineEnd + 1;
    }
    return TextDocument._(
      text,
      encoding,
      Int32List.fromList(starts),
      Int32List.fromList(ends),
    );
  }

  final String text;
  final TextEncoding encoding;
  final Int32List _starts;
  final Int32List _ends;

  int get length => text.length;
  int get blockCount => _starts.length;

  int blockStart(int index) => _starts[index];
  int blockEnd(int index) => _ends[index];
  String blockText(int index) => text.substring(_starts[index], _ends[index]);

  /// The block containing [offset] (or the nearest one before it, for
  /// offsets that fall on a line break).
  int blockIndexAt(int offset) {
    final target = offset.clamp(0, length);
    var low = 0;
    var high = _starts.length - 1;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (_starts[mid] <= target) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low;
  }

  /// Overall progress in `[0, 1]` for a character offset.
  double progressAt(int offset) =>
      length == 0 ? 0 : (offset / length).clamp(0.0, 1.0);

  /// Character offset for overall progress in `[0, 1]`.
  int offsetAt(double progress) =>
      (progress.clamp(0.0, 1.0) * length).round().clamp(0, length);

  /// A short excerpt starting at [offset], for bookmark lists.
  String excerptAt(int offset, {int maxLength = 120}) {
    final start = offset.clamp(0, length);
    final end = (start + maxLength).clamp(0, length);
    return text.substring(start, end).replaceAll('\n', ' ').trim();
  }

  static void _addLine(
    String text,
    int start,
    int end,
    List<int> starts,
    List<int> ends,
  ) {
    var blockStart = start;
    while (end - blockStart > maxBlockLength) {
      // Prefer to split after whitespace near the limit; fall back to a hard
      // split for text without spaces. Never split a surrogate pair.
      var split = blockStart + maxBlockLength;
      final searchFrom = blockStart + maxBlockLength ~/ 2;
      var space = split;
      while (space > searchFrom && !_isSpace(text.codeUnitAt(space - 1))) {
        space--;
      }
      if (space > searchFrom) split = space;
      if (_isLowSurrogate(text.codeUnitAt(split))) split--;
      starts.add(blockStart);
      ends.add(split);
      blockStart = split;
    }
    starts.add(blockStart);
    ends.add(end);
  }

  static bool _isSpace(int unit) =>
      unit == 0x20 || unit == 0x09 || unit == 0x3000 || unit == 0xA0;

  static bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;
}

/// Reads and decodes a text file. Synchronous: run on a background isolate.
TextDocument loadTextDocument(String path) {
  final file = File(path);
  final size = file.lengthSync();
  if (size > TextDocument.maxFileBytes) throw TextTooLargeException(size);
  final decoded = decodeText(file.readAsBytesSync());
  return TextDocument.fromText(decoded.text, encoding: decoded.encoding);
}

/// One match of a search in a text.
class TextMatch {
  const TextMatch({
    required this.offset,
    required this.length,
    required this.snippet,
    required this.snippetMatchStart,
  });

  final int offset;
  final int length;

  /// Surrounding text, on one line.
  final String snippet;

  /// Where the match starts inside [snippet].
  final int snippetMatchStart;
}

/// Finds [query] in [text], ignoring case. Synchronous: run on a background
/// isolate for large texts.
List<TextMatch> searchText(
  String text,
  String query, {
  int maxResults = 500,
  int context = 40,
}) {
  final needle = query.trim();
  if (needle.isEmpty) return const [];
  // A case-insensitive pattern keeps offsets in the original text (lower-
  // casing the text first could change its length).
  final pattern = RegExp(
    RegExp.escape(needle),
    caseSensitive: false,
    unicode: true,
  );
  final results = <TextMatch>[];
  for (final match in pattern.allMatches(text)) {
    final from = (match.start - context).clamp(0, text.length);
    final to = (match.end + context).clamp(0, text.length);
    final raw = text.substring(from, to);
    final snippet = raw.replaceAll('\n', ' ');
    results.add(
      TextMatch(
        offset: match.start,
        length: match.end - match.start,
        snippet: snippet,
        snippetMatchStart: match.start - from,
      ),
    );
    if (results.length >= maxResults) break;
  }
  return results;
}
