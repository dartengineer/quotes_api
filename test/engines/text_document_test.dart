import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/engines/txt/text_decoder.dart';
import 'package:lectern/engines/txt/text_document.dart';

void main() {
  group('decodeText', () {
    DecodedText decode(List<int> bytes) =>
        decodeText(Uint8List.fromList(bytes));

    test('UTF-8 with and without BOM', () {
      final plain = decode(utf8.encode('Привет, мир'));
      expect(plain.text, 'Привет, мир');
      expect(plain.encoding, TextEncoding.utf8);

      final bom = decode([0xEF, 0xBB, 0xBF, ...utf8.encode('Hi')]);
      expect(bom.text, 'Hi', reason: 'BOM is not part of the text');
    });

    test('UTF-16 and UTF-32 by BOM', () {
      List<int> le16(String s) => [
        for (final u in s.codeUnits) ...[u & 0xFF, u >> 8],
      ];
      List<int> be16(String s) => [
        for (final u in s.codeUnits) ...[u >> 8, u & 0xFF],
      ];
      expect(decode([0xFF, 0xFE, ...le16('Ünïcode 😀')]).text, 'Ünïcode 😀');
      expect(decode([0xFE, 0xFF, ...be16('Ünïcode')]).text, 'Ünïcode');

      final utf32 = [0xFF, 0xFE, 0, 0];
      for (final rune in 'A😀'.runes) {
        utf32.addAll([
          rune & 0xFF,
          (rune >> 8) & 0xFF,
          (rune >> 16) & 0xFF,
          rune >> 24,
        ]);
      }
      final decoded = decode(utf32);
      expect(decoded.text, 'A😀');
      expect(decoded.encoding, TextEncoding.utf32le);
    });

    test('UTF-16 without BOM is recognised', () {
      final text = 'A plain English sentence in UTF-16.';
      final le = [
        for (final u in text.codeUnits) ...[u & 0xFF, u >> 8],
      ];
      final decoded = decode(le);
      expect(decoded.text, text);
      expect(decoded.encoding, TextEncoding.utf16le);
    });

    test('invalid UTF-8 falls back to Windows-1252', () {
      // "Café “quoted” – 5€" in Windows-1252.
      final decoded = decode([
        0x43, 0x61, 0x66, 0xE9, 0x20, 0x93, 0x71, 0x75, 0x6F, 0x74, //
        0x65, 0x64, 0x94, 0x20, 0x96, 0x20, 0x35, 0x80,
      ]);
      expect(decoded.encoding, TextEncoding.windows1252);
      expect(decoded.text, 'Café “quoted” – 5€');
    });

    test('normalises line endings and strips control characters', () {
      final decoded = decode(utf8.encode('a\r\nb\rc\nd\fe\u0000f\u0007g\th'));
      expect(
        decoded.text,
        'a\nb\nc\nd\n\ne'
        'fg\th',
      );
    });
  });

  group('TextDocument', () {
    test('one block per line, including empty lines', () {
      final doc = TextDocument.fromText('First\n\nThird line\n');
      expect(doc.blockCount, 4);
      expect(
        [for (var i = 0; i < doc.blockCount; i++) doc.blockText(i)],
        ['First', '', 'Third line', ''],
      );
    });

    test('splits very long lines at whitespace without losing text', () {
      final words = List.generate(2000, (i) => 'word$i').join(' ');
      final doc = TextDocument.fromText(words);
      expect(doc.blockCount, greaterThan(1));
      final rebuilt = StringBuffer();
      for (var i = 0; i < doc.blockCount; i++) {
        final block = doc.blockText(i);
        expect(block.length, lessThanOrEqualTo(TextDocument.maxBlockLength));
        rebuilt.write(block);
        if (i < doc.blockCount - 1) {
          expect(
            doc.blockText(i).endsWith(' '),
            isTrue,
            reason: 'splits fall after a space',
          );
        }
      }
      expect(rebuilt.toString(), words);
    });

    test('hard-splits text without spaces but never inside a pair', () {
      final text = '😀' * 3000; // 6000 code units, no spaces
      final doc = TextDocument.fromText(text);
      for (var i = 0; i < doc.blockCount; i++) {
        final block = doc.blockText(i);
        final first = block.codeUnitAt(0);
        expect(first >= 0xDC00 && first <= 0xDFFF, isFalse);
      }
    });

    test('maps offsets to blocks and progress', () {
      final doc = TextDocument.fromText('aaaa\nbbbb\ncccc');
      expect(doc.blockIndexAt(0), 0);
      expect(doc.blockIndexAt(3), 0);
      expect(doc.blockIndexAt(4), 0, reason: 'the line break itself');
      expect(doc.blockIndexAt(5), 1);
      expect(doc.blockIndexAt(13), 2);
      expect(doc.blockIndexAt(999), 2);
      expect(doc.progressAt(7), closeTo(0.5, 0.001));
      expect(doc.offsetAt(0.5), 7);
      expect(doc.offsetAt(2), doc.length);
    });

    test('empty text has one empty block', () {
      final doc = TextDocument.fromText('');
      expect(doc.blockCount, 1);
      expect(doc.blockIndexAt(10), 0);
      expect(doc.progressAt(0), 0);
    });

    test('excerpts are single-line', () {
      final doc = TextDocument.fromText('Line one\nLine two');
      expect(doc.excerptAt(5), 'one Line two');
    });
  });

  group('loadTextDocument', () {
    late Directory dir;

    setUp(() async => dir = await Directory.systemTemp.createTemp('txt'));
    tearDown(() => dir.delete(recursive: true));

    test('loads and decodes a file', () {
      final file = File('${dir.path}/a.txt')
        ..writeAsBytesSync(utf8.encode('Hello\r\nworld'));
      final doc = loadTextDocument(file.path);
      expect(doc.text, 'Hello\nworld');
      expect(doc.blockCount, 2);
    });

    test('refuses files over the size limit', () {
      final file = File('${dir.path}/big.txt');
      final handle = file.openSync(mode: FileMode.write)
        ..setPositionSync(TextDocument.maxFileBytes)
        ..writeByteSync(0x41);
      handle.closeSync();
      expect(
        () => loadTextDocument(file.path),
        throwsA(isA<TextTooLargeException>()),
      );
    });
  });

  group('searchText', () {
    const text = 'The cat sat.\nA CAT and a Cat.\nConcatenate!';

    test('finds all matches ignoring case, with context', () {
      final matches = searchText(text, 'cat');
      expect(matches.map((m) => m.offset), [4, 15, 25, 33]);
      final second = matches[1];
      expect(
        second.snippet.substring(
          second.snippetMatchStart,
          second.snippetMatchStart + second.length,
        ),
        'CAT',
      );
      expect(second.snippet, isNot(contains('\n')));
    });

    test('treats regex characters literally and limits results', () {
      expect(searchText('a.b a+b', 'a+b').single.offset, 4);
      expect(searchText('aaaa', 'a', maxResults: 2), hasLength(2));
      expect(searchText(text, '   '), isEmpty);
    });

    test('offsets stay correct when case folding changes length', () {
      // 'İ' lower-cases to two code units; offsets must not drift.
      const turkish = 'İİİ target';
      expect(searchText(turkish, 'target').single.offset, 4);
    });
  });
}
