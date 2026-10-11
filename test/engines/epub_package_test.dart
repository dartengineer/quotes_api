import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/core/files/safe_zip.dart';
import 'package:lectern/engines/epub/epub_package.dart';

import '../helpers/fixtures.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('epub');
  });

  tearDown(() => dir.delete(recursive: true));

  EpubPackage parse(Uint8List bytes) {
    final path = '${dir.path}/book.epub';
    File(path).writeAsBytesSync(bytes);
    final zip = SafeZip.open(path);
    try {
      return EpubPackageParser.parse(zip);
    } finally {
      zip.close();
    }
  }

  Matcher throwsProblem(EpubProblem problem) => throwsA(
    isA<EpubException>().having((e) => e.problem, 'problem', problem),
  );

  /// An EPUB whose OPF is replaced verbatim by [opf].
  Uint8List epubWithOpf(String opf) {
    final archive = ZipDecoder().decodeBytes(buildEpub());
    final rebuilt = Archive();
    for (final file in archive.files) {
      if (file.name == 'OEBPS/content.opf') {
        rebuilt.add(ArchiveFile.string(file.name, opf));
      } else {
        rebuilt.add(ArchiveFile.bytes(file.name, file.content));
      }
    }
    return ZipEncoder().encodeBytes(rebuilt);
  }

  group('metadata', () {
    test('reads title, authors, language and description', () {
      final package = parse(
        buildEpub(
          title: '  The   Hobbit ',
          authors: ['J. R. R. Tolkien', 'Christopher Tolkien'],
          language: 'en-GB',
          description: '<p>There and <b>back</b> again &amp; more.</p>',
        ),
      );
      expect(package.metadata.title, 'The Hobbit');
      expect(package.metadata.authors, [
        'J. R. R. Tolkien',
        'Christopher Tolkien',
      ]);
      expect(package.metadata.language, 'en-GB');
      expect(package.metadata.description, 'There and back again & more.');
      expect(package.spine, hasLength(1));
      expect(package.spine.single.item.path, 'OEBPS/text/ch1.xhtml');
      expect(package.isFixedLayout, isFalse);
    });

    test('prefers authors over other contributor roles', () {
      final package = parse(
        epubWithOpf('''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:title id="t1">Subtitle first</dc:title>
    <dc:title id="t2">Main Title</dc:title>
    <meta refines="#t2" property="title-type">main</meta>
    <dc:creator id="ed">An Editor</dc:creator>
    <meta refines="#ed" property="role">edt</meta>
    <dc:creator opf:role="aut">The Author</dc:creator>
    <dc:creator opf:role="trl">A Translator</dc:creator>
  </metadata>
  <manifest><item id="ch1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/></manifest>
  <spine><itemref idref="ch1"/></spine>
</package>'''),
      );
      expect(package.metadata.title, 'Main Title');
      expect(package.metadata.authors, ['The Author']);
    });

    test('accepts HTML entities that are not valid XML', () {
      final package = parse(
        epubWithOpf('''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Caf&eacute;&nbsp;Society</dc:title>
  </metadata>
  <manifest><item id="ch1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/></manifest>
  <spine><itemref idref="ch1"/></spine>
</package>'''),
      );
      expect(package.metadata.title, 'Café Society');
    });

    test('missing title is reported as null, not invented', () {
      expect(parse(buildEpub(title: null)).metadata.title, isNull);
    });
  });

  group('cover', () {
    test('EPUB 3 cover-image property', () {
      final package = parse(buildEpub(cover: pngImage()));
      expect(package.coverImage?.path, 'OEBPS/images/front.png');
    });

    test('EPUB 2 meta name="cover"', () {
      final package = parse(buildEpub(cover: pngImage(), coverStyle: 'epub2'));
      expect(package.coverImage?.path, 'OEBPS/images/front.png');
    });

    test('image on the first page when nothing is declared', () {
      final package = parse(buildEpub(cover: pngImage(), coverStyle: 'page'));
      expect(package.coverImage?.path, 'OEBPS/images/front.png');
    });

    test('no cover when the book has none', () {
      expect(parse(buildEpub()).coverImage, isNull);
    });
  });

  test('detects fixed-layout books', () {
    expect(parse(buildEpub(fixedLayout: true)).isFixedLayout, isTrue);
  });

  group('protection', () {
    String encryption(String algorithm) =>
        '<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" '
        'xmlns:enc="http://www.w3.org/2001/04/xmlenc#"><enc:EncryptedData>'
        '<enc:EncryptionMethod Algorithm="$algorithm"/>'
        '<enc:CipherData><enc:CipherReference URI="OEBPS/text/ch1.xhtml"/>'
        '</enc:CipherData></enc:EncryptedData></encryption>';

    test('DRM-encrypted content is rejected', () {
      expect(
        () => parse(
          buildEpub(
            encryptionXml: encryption(
              'http://www.w3.org/2001/04/xmlenc#aes128-cbc',
            ),
          ),
        ),
        throwsProblem(EpubProblem.drmProtected),
      );
    });

    test('font obfuscation alone is fine', () {
      expect(
        parse(
          buildEpub(
            encryptionXml: encryption('http://www.idpf.org/2008/embedding'),
          ),
        ).metadata.title,
        'A Test Book',
      );
    });

    test('an unreadable encryption declaration is treated as DRM', () {
      expect(
        () => parse(buildEpub(encryptionXml: '<not-closed')),
        throwsProblem(EpubProblem.drmProtected),
      );
    });
  });

  group('damaged books', () {
    test('missing container falls back to the only OPF', () {
      expect(
        parse(buildEpub(includeContainer: false)).metadata.title,
        'A Test Book',
      );
    });

    test('missing container and ambiguous OPFs is damaged', () {
      expect(
        () => parse(
          buildEpub(
            includeContainer: false,
            extraFiles: {'other.opf': utf8.encode('<package/>')},
          ),
        ),
        throwsProblem(EpubProblem.damaged),
      );
    });

    test('empty spine is damaged', () {
      expect(
        () => parse(buildEpub(emptySpine: true)),
        throwsProblem(EpubProblem.damaged),
      );
    });

    test('malformed package document is damaged', () {
      expect(
        () => parse(epubWithOpf('<package><metadata>')),
        throwsProblem(EpubProblem.damaged),
      );
    });

    test('oversized package document is rejected without reading it', () {
      final huge = '<package>${'x' * (EpubLimits.packageBytes + 10)}</package>';
      expect(
        () => parse(epubWithOpf(huge)),
        throwsProblem(EpubProblem.damaged),
      );
    });

    test('manifest entries escaping the archive are ignored', () {
      final package = parse(
        epubWithOpf('''<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>T</dc:title></metadata>
  <manifest>
    <item id="evil" href="../../../etc/passwd" media-type="application/xhtml+xml"/>
    <item id="ch1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="evil"/><itemref idref="ch1"/></spine>
</package>'''),
      );
      expect(package.manifest.containsKey('evil'), isFalse);
      expect(package.spine.map((s) => s.item.id), ['ch1']);
    });
  });
}
