import 'package:path/path.dart' as p;

final _controlChars = RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]');
final _whitespace = RegExp(r'\s+');

/// Normalises a short metadata value from an untrusted document: removes
/// control characters, collapses whitespace and limits the length.
/// Returns null when nothing meaningful remains.
String? cleanMetadataText(String? input, {int maxLength = 512}) {
  if (input == null) return null;
  final cleaned = input
      .replaceAll(_controlChars, '')
      .replaceAll(_whitespace, ' ')
      .trim();
  if (cleaned.isEmpty) return null;
  return truncateText(cleaned, maxLength);
}

/// Truncates [input] to at most [maxLength] UTF-16 code units without
/// splitting a surrogate pair, adding an ellipsis when shortened.
String truncateText(String input, int maxLength) {
  if (input.length <= maxLength) return input;
  var end = maxLength - 1;
  final lastUnit = input.codeUnitAt(end - 1);
  if (lastUnit >= 0xD800 && lastUnit <= 0xDBFF) end--;
  return '${input.substring(0, end).trimRight()}…';
}

/// Derives a readable title from a file name: drops the extension and
/// turns separators into spaces.
String titleFromFileName(String fileName) {
  final base = p.basenameWithoutExtension(fileName);
  final spaced = base.replaceAll(RegExp(r'[_]+'), ' ');
  return cleanMetadataText(spaced, maxLength: 1024) ??
      cleanMetadataText(fileName, maxLength: 1024) ??
      'Untitled';
}

final _tags = RegExp(r'<[^>]*>');
final _blockBreaks = RegExp(
  r'<\s*(br|/p|/div|/li|/h[1-6])\b[^>]*>',
  caseSensitive: false,
);
final _entity = RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);');
final _blankLines = RegExp(r'\n{3,}');

/// Converts a fragment of HTML (as found in EPUB descriptions) to plain text.
/// Markup is discarded, never interpreted.
String? plainTextFromHtml(String? html, {int maxLength = 5000}) {
  if (html == null) return null;
  var text = html.replaceAll(_blockBreaks, '\n').replaceAll(_tags, '');
  text = text.replaceAllMapped(_entity, (m) => _decodeEntity(m[1]!) ?? m[0]!);
  final lines = text
      .split('\n')
      .map(
        (line) => line
            .replaceAll(_controlChars, '')
            .replaceAll(RegExp(r'[ \t\r\f]+'), ' ')
            .trim(),
      )
      .join('\n')
      .replaceAll(_blankLines, '\n\n')
      .trim();
  if (lines.isEmpty) return null;
  return truncateText(lines, maxLength);
}

String? _decodeEntity(String body) {
  if (body.startsWith('#x') || body.startsWith('#X')) {
    return _fromCodePoint(int.tryParse(body.substring(2), radix: 16));
  }
  if (body.startsWith('#')) {
    return _fromCodePoint(int.tryParse(body.substring(1)));
  }
  return const {
    'amp': '&',
    'lt': '<',
    'gt': '>',
    'quot': '"',
    'apos': "'",
    'nbsp': ' ',
    'mdash': '—',
    'ndash': '–',
    'hellip': '…',
    'lsquo': '‘',
    'rsquo': '’',
    'ldquo': '“',
    'rdquo': '”',
  }[body.toLowerCase()];
}

String? _fromCodePoint(int? value) {
  if (value == null || value <= 0 || value > 0x10FFFF) return null;
  if (value >= 0xD800 && value <= 0xDFFF) return null;
  return String.fromCharCode(value);
}
