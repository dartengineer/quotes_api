import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/engines/epub/epub_book.dart';
import 'package:lectern/engines/epub/epub_content.dart';
import 'package:lectern/engines/epub/epub_navigation.dart';
import 'package:lectern/engines/epub/epub_package.dart';

import '../helpers/fixtures.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('epub_book');
  });

  tearDown(() => dir.delete(recursive: true));

  String write(List<int> bytes, [String name = 'book.epub']) =>
      (File('${dir.path}/$name')..writeAsBytesSync(bytes)).path;

  group('table of contents', () {
    test('EPUB 3 navigation, nested, with fragments', () {
      final items = parseNavDocument(
        '<html xmlns="http://www.w3.org/1999/xhtml" '
        'xmlns:epub="http://www.idpf.org/2007/ops"><body>'
        '<nav epub:type="landmarks"><ol><li><a href="x.xhtml">No</a></li></ol></nav>'
        '<nav epub:type="toc"><ol>'
        '<li><a href="text/one.xhtml">One</a>'
        '<ol><li><a href="text/one.xhtml#s%201">  Part\n A </a></li></ol></li>'
        '<li><span>Heading only</span><ol>'
        '<li><a href="text/two.xhtml">Two</a></li></ol></li>'
        '<li><a href="https://example.com">Web</a></li>'
        '</ol></nav></body></html>',
        navPath: 'OEBPS/nav.xhtml',
      );
      expect(items, const [
        EpubTocItem(title: 'One', path: 'OEBPS/text/one.xhtml'),
        EpubTocItem(
          title: 'Part A',
          path: 'OEBPS/text/one.xhtml',
          fragment: 's 1',
          depth: 1,
        ),
        EpubTocItem(title: 'Two', path: 'OEBPS/text/two.xhtml'),
      ]);
    });

    test('EPUB 2 NCX', () {
      final items = parseNcx(
        '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap>'
        '<navPoint><navLabel><text>First</text></navLabel>'
        '<content src="a.xhtml"/>'
        '<navPoint><navLabel><text>Inner</text></navLabel>'
        '<content src="a.xhtml#in"/></navPoint></navPoint>'
        '<navPoint><navLabel><text>Second</text></navLabel>'
        '<content src="b.xhtml"/></navPoint>'
        '</navMap></ncx>',
        ncxPath: 'OEBPS/toc.ncx',
      );
      expect(items.map((i) => (i.title, i.path, i.fragment, i.depth)), [
        ('First', 'OEBPS/a.xhtml', null, 0),
        ('Inner', 'OEBPS/a.xhtml', 'in', 1),
        ('Second', 'OEBPS/b.xhtml', null, 0),
      ]);
    });

    test('malformed or missing contents yield nothing', () {
      expect(parseNavDocument('<nav><ol>', navPath: 'n.xhtml'), isEmpty);
      expect(parseNcx('<ncx/>', ncxPath: 't.ncx'), isEmpty);
    });

    test('deep nesting is bounded', () {
      final nested = StringBuffer(
        '<nav epub:type="toc" '
        'xmlns:epub="http://www.idpf.org/2007/ops">',
      );
      for (var i = 0; i < 50; i++) {
        nested.write('<ol><li><a href="c.xhtml#$i">L$i</a>');
      }
      for (var i = 0; i < 50; i++) {
        nested.write('</li></ol>');
      }
      nested.write('</nav>');
      final items = parseNavDocument(
        '<html><body>$nested</body></html>',
        navPath: 'n.xhtml',
      );
      expect(items, hasLength(8));
    });
  });

  group('loadEpubBook', () {
    test('reads linear chapters in order, with contents', () {
      final path = write(
        readerEpub(
          chapters: [
            '<p>One</p>',
            '<p>Notes</p>',
            '<h1 id="t">Two</h1><p>Text</p>',
          ],
          nonLinear: {1},
          toc: [('Chapter 1', 'ch1.xhtml'), ('Chapter 2', 'ch3.xhtml#t')],
        ),
      );
      final book = loadEpubBook(path);
      expect(book.chapters.map((c) => c.path), [
        'OEBPS/text/ch1.xhtml',
        'OEBPS/text/ch3.xhtml',
      ]);
      expect(book.chapters.last.content.text, 'Two\nText');
      expect(book.toc.map((t) => (t.title, t.path, t.fragment)), [
        ('Chapter 1', 'OEBPS/text/ch1.xhtml', null),
        ('Chapter 2', 'OEBPS/text/ch3.xhtml', 't'),
      ]);
      expect(book.truncated, isFalse);
    });

    test('falls back to the NCX', () {
      final path = write(
        readerEpub(
          chapters: ['<p>One</p>'],
          toc: [('Only', 'ch1.xhtml')],
          ncx: true,
        ),
      );
      expect(loadEpubBook(path).toc.single.title, 'Only');
    });

    test('blank chapters are left out; a book with none is damaged', () {
      final path = write(readerEpub(chapters: ['<p>  </p>', '<p>Text</p>']));
      expect(loadEpubBook(path).chapters, hasLength(1));

      final empty = write(readerEpub(chapters: ['<div/>']), 'empty.epub');
      expect(
        () => loadEpubBook(empty),
        throwsA(
          isA<EpubException>().having(
            (e) => e.problem,
            'problem',
            EpubProblem.damaged,
          ),
        ),
      );
    });

    test('DRM-protected and non-zip files are refused', () {
      final drm = write(
        buildEpub(
          encryptionXml:
              '<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" '
              'xmlns:enc="http://www.w3.org/2001/04/xmlenc#">'
              '<enc:EncryptedData><enc:EncryptionMethod '
              'Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>'
              '<enc:CipherData><enc:CipherReference URI="OEBPS/text/ch1.xhtml"/>'
              '</enc:CipherData></enc:EncryptedData></encryption>',
        ),
      );
      expect(
        () => loadEpubBook(drm),
        throwsA(
          isA<EpubException>().having(
            (e) => e.problem,
            'problem',
            EpubProblem.drmProtected,
          ),
        ),
      );
      final text = write('not a zip'.codeUnits, 'x.epub');
      expect(() => loadEpubBook(text), throwsFormatException);
    });

    test('a book past the size limit ends with a notice', () {
      final big = List.generate(5, (i) => '<p>${'x' * 1000} $i</p>').join();
      final path = write(readerEpub(chapters: [big, big, big]), 'big.epub');
      final book = loadEpubBook(path, maxChars: 4000);
      expect(book.truncated, isTrue);
      expect(book.chapters.last.path, truncatedNoticePath);
      expect(
        book.chapters.last.content.text,
        'The rest of this book is too large to display.',
      );
    });

    test('images are read on demand, within limits', () {
      final png = pngImage();
      final path = write(
        readerEpub(
          chapters: ['<p><img src="../images/a.png" alt="A"/></p>'],
          images: {'images/a.png': png},
        ),
      );
      final block = loadEpubBook(path).chapters.single.content.blocks.single;
      expect(block.kind, BlockKind.image);
      expect(readEpubResource(path, block.imagePath!), png);
      expect(readEpubResource(path, block.imagePath!, maxBytes: 10), isNull);
      expect(readEpubResource(path, 'OEBPS/missing.png'), isNull);
    });
  });
}
