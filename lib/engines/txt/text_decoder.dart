import 'dart:convert';
import 'dart:typed_data';

/// Encodings the text reader can decode.
enum TextEncoding {
  utf8('UTF-8'),
  utf16le('UTF-16 LE'),
  utf16be('UTF-16 BE'),
  utf32le('UTF-32 LE'),
  utf32be('UTF-32 BE'),
  windows1252('Windows-1252');

  const TextEncoding(this.label);

  final String label;
}

class DecodedText {
  const DecodedText(this.text, this.encoding);

  final String text;
  final TextEncoding encoding;
}

/// Decodes plain-text bytes, detecting the encoding:
///
/// 1. a byte-order mark (UTF-8, UTF-16, UTF-32);
/// 2. UTF-16 without a BOM, recognised by its pattern of zero bytes;
/// 3. valid UTF-8;
/// 4. otherwise Windows-1252, the most common legacy encoding for Western
///    languages (a superset of ISO-8859-1).
///
/// The result has `\r\n` and `\r` normalised to `\n`, form feeds turned into
/// paragraph breaks and other control characters removed. Reading positions
/// are offsets into this normalised text, so this function must stay
/// deterministic.
DecodedText decodeText(Uint8List bytes) {
  final (raw, encoding) = _decode(bytes);
  return DecodedText(normalizeText(raw), encoding);
}

(String, TextEncoding) _decode(Uint8List bytes) {
  bool startsWith(List<int> prefix) {
    if (bytes.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix[i]) return false;
    }
    return true;
  }

  // UTF-32 BOMs must be checked before UTF-16 (FF FE is a prefix of both).
  if (startsWith(const [0xFF, 0xFE, 0x00, 0x00])) {
    return (_decodeUtf32(bytes, 4, littleEndian: true), TextEncoding.utf32le);
  }
  if (startsWith(const [0x00, 0x00, 0xFE, 0xFF])) {
    return (_decodeUtf32(bytes, 4, littleEndian: false), TextEncoding.utf32be);
  }
  if (startsWith(const [0xEF, 0xBB, 0xBF])) {
    return (
      utf8.decode(Uint8List.sublistView(bytes, 3), allowMalformed: true),
      TextEncoding.utf8,
    );
  }
  if (startsWith(const [0xFF, 0xFE])) {
    return (_decodeUtf16(bytes, 2, littleEndian: true), TextEncoding.utf16le);
  }
  if (startsWith(const [0xFE, 0xFF])) {
    return (_decodeUtf16(bytes, 2, littleEndian: false), TextEncoding.utf16be);
  }
  if (_utf16Endianness(bytes) case final littleEndian?) {
    return (
      _decodeUtf16(bytes, 0, littleEndian: littleEndian),
      littleEndian ? TextEncoding.utf16le : TextEncoding.utf16be,
    );
  }
  try {
    return (utf8.decode(bytes), TextEncoding.utf8);
  } on FormatException {
    return (_decodeWindows1252(bytes), TextEncoding.windows1252);
  }
}

final _lineBreaks = RegExp(r'\r\n?');
final _formFeed = RegExp(r'\f');
final _controls = RegExp(r'[\u0000-\u0008\u000B\u000E-\u001F\u007F]');

/// Normalises line endings and removes characters that should not be
/// rendered. See [decodeText].
String normalizeText(String raw) {
  return raw
      .replaceAll(_lineBreaks, '\n')
      .replaceAll(_formFeed, '\n\n')
      .replaceAll(_controls, '');
}

/// Detects BOM-less UTF-16 from zero bytes on one side of each pair (as in
/// mostly-Latin text). Returns null if the data does not look like UTF-16.
bool? _utf16Endianness(Uint8List bytes) {
  final sample = bytes.length < 4096 ? bytes.length : 4096;
  final pairs = sample ~/ 2;
  if (pairs < 8) return null;
  var evenZeros = 0;
  var oddZeros = 0;
  for (var i = 0; i + 1 < sample; i += 2) {
    if (bytes[i] == 0) evenZeros++;
    if (bytes[i + 1] == 0) oddZeros++;
  }
  final even = evenZeros / pairs;
  final odd = oddZeros / pairs;
  if (odd > 0.4 && even < 0.05) return true;
  if (even > 0.4 && odd < 0.05) return false;
  return null;
}

String _decodeUtf16(Uint8List bytes, int start, {required bool littleEndian}) {
  final count = (bytes.length - start) ~/ 2;
  final units = Uint16List(count);
  for (var i = 0, b = start; i < count; i++, b += 2) {
    units[i] = littleEndian
        ? bytes[b] | (bytes[b + 1] << 8)
        : (bytes[b] << 8) | bytes[b + 1];
  }
  // Unpaired surrogates are kept as-is; Flutter renders them as a
  // replacement glyph rather than failing.
  return String.fromCharCodes(units);
}

String _decodeUtf32(Uint8List bytes, int start, {required bool littleEndian}) {
  final buffer = StringBuffer();
  for (var b = start; b + 3 < bytes.length; b += 4) {
    final code = littleEndian
        ? bytes[b] |
              (bytes[b + 1] << 8) |
              (bytes[b + 2] << 16) |
              (bytes[b + 3] << 24)
        : (bytes[b] << 24) |
              (bytes[b + 1] << 16) |
              (bytes[b + 2] << 8) |
              bytes[b + 3];
    final valid = code <= 0x10FFFF && (code < 0xD800 || code > 0xDFFF);
    buffer.writeCharCode(valid ? code : 0xFFFD);
  }
  return buffer.toString();
}

/// Code points for bytes 0x80-0x9F in Windows-1252; the rest of the range
/// matches ISO-8859-1. Undefined bytes map to U+FFFD.
const _windows1252High = [
  0x20AC, 0xFFFD, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, //
  0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFD, 0x017D, 0xFFFD, //
  0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, //
  0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0xFFFD, 0x017E, 0x0178, //
];

String _decodeWindows1252(Uint8List bytes) {
  final units = Uint16List(bytes.length);
  for (var i = 0; i < bytes.length; i++) {
    final b = bytes[i];
    units[i] = b >= 0x80 && b <= 0x9F ? _windows1252High[b - 0x80] : b;
  }
  return String.fromCharCodes(units);
}
