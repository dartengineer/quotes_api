import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/features/import/data/format_detector.dart';
import 'package:lectern/features/import/domain/format_detection.dart';
import 'package:lectern/features/library/domain/document_format.dart';

import '../../helpers/fixtures.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('detector');
  });

  tearDown(() => dir.delete(recursive: true));

  FormatDetection detect(List<int> bytes) {
    final file = File('${dir.path}/file.bin')..writeAsBytesSync(bytes);
    return FormatDetector.detectFile(file.path);
  }

  Uint8List zipOf(Map<String, String> files) {
    final archive = Archive();
    files.forEach((n, c) => archive.add(ArchiveFile.string(n, c)));
    return ZipEncoder().encodeBytes(archive);
  }

  const pdf = SupportedFormat(DocumentFormat.pdf);
  const epub = SupportedFormat(DocumentFormat.epub);
  const txt = SupportedFormat(DocumentFormat.txt);

  group('supported formats', () {
    test('PDF, including leading junk before the header', () {
      expect(detect(minimalPdf()), pdf);
      expect(detect([...utf8.encode('junk\n'), ...minimalPdf()]), pdf);
    });

    test('EPUB with and without the canonical mimetype entry', () {
      expect(detect(buildEpub()), epub);
      expect(detect(buildEpub(includeMimetype: false)), epub);
    });

    test('UTF-8 text, with and without BOM', () {
      expect(detect(utf8.encode('Hello, world.\nПривет, мир.\n')), txt);
      expect(detect([0xEF, 0xBB, 0xBF, ...utf8.encode('Hello')]), txt);
    });

    test('legacy single-byte text (Windows-1252)', () {
      expect(
        detect(latin1.encode('Café crème brûlée, naïve façade. Ça va?\n')),
        txt,
      );
    });

    test('UTF-16 with and without BOM', () {
      final units = 'Hello, reader. This is UTF-16 text.'.codeUnits;
      final le = [
        for (final u in units) ...[u & 0xFF, u >> 8],
      ];
      final be = [
        for (final u in units) ...[u >> 8, u & 0xFF],
      ];
      expect(detect([0xFF, 0xFE, ...le]), txt);
      expect(detect([0xFE, 0xFF, ...be]), txt);
      expect(detect(le), txt);
      expect(detect(be), txt);
    });

    test('UTF-8 cut mid-character at the sample boundary is still text', () {
      // 'é' is two bytes; pad so one falls across the 64 KiB boundary.
      final bytes = <int>[
        ...List.filled(FormatDetector.sampleSize - 1, 0x61),
        ...utf8.encode('é and more text'),
      ];
      expect(detect(bytes), txt);
    });
  });

  group('unsupported formats are named', () {
    void expectUnsupported(List<int> bytes, String description) {
      expect(detect(bytes), UnsupportedFormat(description));
    }

    test('office documents and archives', () {
      expectUnsupported(
        zipOf({'[Content_Types].xml': '<x/>', 'word/document.xml': '<x/>'}),
        'Word document',
      );
      expectUnsupported(
        zipOf({'[Content_Types].xml': '<x/>', 'xl/workbook.xml': '<x/>'}),
        'Excel spreadsheet',
      );
      expectUnsupported(
        zipOf({'001.jpg': 'x', '002.png': 'y'}),
        'Comic book archive (CBZ)',
      );
      expectUnsupported(zipOf({'notes.txt': 'hi'}), 'ZIP archive');
      expectUnsupported([
        0xD0,
        0xCF,
        0x11,
        0xE0,
        0xA1,
        0xB1,
        0x1A,
        0xE1,
        0,
        0,
      ], 'Older Microsoft Office document');
    });

    test('ebook formats without a reader', () {
      final mobi = Uint8List(100)..setRange(60, 68, ascii.encode('BOOKMOBI'));
      expectUnsupported(mobi, 'Kindle (MOBI/AZW) ebook');
      expectUnsupported(ascii.encode('AT&TFORMxxxxDJVU'), 'DjVu document');
      expectUnsupported(
        utf8.encode(
          '<?xml version="1.0"?>\n<FictionBook xmlns="x"></FictionBook>',
        ),
        'FictionBook (FB2) ebook',
      );
    });

    test('markup and rich text are not shown as plain text', () {
      expectUnsupported(
        utf8.encode('  <!DOCTYPE html><html><body>x</body></html>'),
        'Web page (HTML)',
      );
      expectUnsupported(utf8.encode(r'{\rtf1\ansi Hello}'), 'RTF document');
    });

    test('images and binaries', () {
      expectUnsupported(pngImage(), 'Image');
      expectUnsupported([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3], 'Image');
      expectUnsupported([1, 2, 3, 0, 0, 5, 0, 200, 0, 7], 'Unrecognised file');
    });

    test('a truncated EPUB is reported as damaged', () {
      final bytes = buildEpub();
      expectUnsupported(bytes.sublist(0, 200), 'Damaged EPUB file');
    });
  });

  test('an empty file is reported as empty', () {
    expect(detect(const []), isA<EmptyFile>());
  });
}
