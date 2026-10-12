import 'dart:convert';
import 'dart:typed_data';

/// Decodes XML bytes honouring a byte-order mark or a declared single-byte
/// encoding; defaults to UTF-8 (malformed sequences are replaced, not
/// fatal).
String decodeXml(Uint8List bytes) {
  if (bytes.length >= 2) {
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return _decodeUtf16(bytes.sublist(2), littleEndian: true);
    }
    if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return _decodeUtf16(bytes.sublist(2), littleEndian: false);
    }
  }
  final start =
      bytes.length >= 3 &&
          bytes[0] == 0xEF &&
          bytes[1] == 0xBB &&
          bytes[2] == 0xBF
      ? 3
      : 0;
  final body = bytes.sublist(start);
  final declaration = latin1
      .decode(body.sublist(0, body.length < 200 ? body.length : 200))
      .toLowerCase();
  final encoding = RegExp(r'''encoding\s*=\s*["']([^"']+)["']''')
      .firstMatch(declaration)?[1];
  if (encoding == 'iso-8859-1' ||
      encoding == 'latin1' ||
      encoding == 'windows-1252') {
    return latin1.decode(body);
  }
  return utf8.decode(body, allowMalformed: true);
}

String _decodeUtf16(Uint8List bytes, {required bool littleEndian}) {
  final units = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    units.add(
      littleEndian
          ? bytes[i] | (bytes[i + 1] << 8)
          : (bytes[i] << 8) | bytes[i + 1],
    );
  }
  return String.fromCharCodes(units);
}

/// The local part of a possibly prefixed XML name (`epub:type` -> `type`),
/// lower-cased: XHTML in the wild is not always lower case.
String localName(String qualified) {
  final colon = qualified.lastIndexOf(':');
  return (colon < 0 ? qualified : qualified.substring(colon + 1)).toLowerCase();
}
