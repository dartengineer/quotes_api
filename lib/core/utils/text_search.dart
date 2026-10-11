/// Searching extracted document text (PDF pages, EPUB chapters).
///
/// Extracted text has no reliable word or line structure: a line break may
/// come out as a line feed, `\r\n`, a space or nothing at all, and EPUB
/// paragraphs are separated by line feeds. Queries therefore match across
/// any run of whitespace, and offsets always refer to the original text.
library;

/// A match in a page's text, with one line of context for display.
class TextHit {
  const TextHit({
    required this.start,
    required this.end,
    required this.snippet,
    required this.snippetMatchStart,
  });

  /// Character range of the match in the page text.
  final int start;
  final int end;

  /// Text around the match on a single line.
  final String snippet;
  final int snippetMatchStart;

  int get length => end - start;
}

/// A case-insensitive pattern for [query] in which whitespace between words
/// matches any whitespace. Returns null if [query] has no words.
RegExp? flexibleSearchPattern(String query) {
  final words = query
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .map(RegExp.escape)
      .toList();
  if (words.isEmpty) return null;
  return RegExp(words.join(r'\s+'), caseSensitive: false, unicode: true);
}

/// Finds up to [maxHits] matches of [pattern] in [text].
List<TextHit> findTextMatches(
  String text,
  RegExp pattern, {
  int maxHits = 500,
  int context = 40,
}) {
  final hits = <TextHit>[];
  for (final match in pattern.allMatches(text)) {
    if (match.end == match.start) continue;
    final from = (match.start - context).clamp(0, text.length);
    final to = (match.end + context).clamp(0, text.length);
    hits.add(
      TextHit(
        start: match.start,
        end: match.end,
        // One-for-one replacement keeps offsets aligned with the match.
        snippet: text.substring(from, to).replaceAll(_lineBreakOrTab, ' '),
        snippetMatchStart: match.start - from,
      ),
    );
    if (hits.length >= maxHits) break;
  }
  return hits;
}

/// Readable text starting at [start], collapsed to single spaces and cut to
/// about [maxLength] characters (used for bookmark excerpts).
String excerptFrom(String text, int start, {int maxLength = 160}) {
  if (start < 0 || start >= text.length) return '';
  final end = (start + maxLength * 2).clamp(start, text.length);
  final collapsed = text
      .substring(start, end)
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return collapsed.length <= maxLength
      ? collapsed
      : collapsed.substring(0, maxLength).trimRight();
}

final _lineBreakOrTab = RegExp('[\r\n\t\f\v]');
