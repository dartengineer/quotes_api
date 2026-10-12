import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as img;
import 'package:pdfrx/pdfrx.dart';

/// Builds a valid, minimal PDF with [pages] blank pages.
Uint8List minimalPdf({int pages = 1}) {
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [${[for (var i = 0; i < pages; i++) '${i + 3} 0 R'].join(' ')}] /Count $pages >>',
    for (var i = 0; i < pages; i++)
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 300] >>',
  ];
  final buffer = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(buffer.length);
    buffer.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = buffer.length;
  buffer.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets) {
    buffer.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  buffer.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
    'startxref\n$xref\n%%EOF\n',
  );
  return Uint8List.fromList(latin1.encode(buffer.toString()));
}

/// Builds a PDF whose pages show [pages] (one string per page, lines split
/// on `\n`) in Helvetica, so PDFium can extract and search the text.
///
/// [outline] adds a table of contents: titles pointing at zero-based page
/// indices. [links] adds link areas: on page `from`, the rectangle (in PDF
/// points, origin bottom-left) leads to page index `to` (an [int]) or a
/// web address (a [String]). [pageSize] is in points.
Uint8List textPdf(
  List<String> pages, {
  List<(String, int)> outline = const [],
  List<({int from, (int, int, int, int) rect, Object to})> links = const [],
  (int, int) pageSize = (300, 400),
}) {
  final (width, height) = pageSize;
  final objects = <String>[];
  int add(String body) {
    objects.add(body);
    return objects.length;
  }

  String escape(String text) => text
      .replaceAll(r'\', r'\\')
      .replaceAll('(', r'\(')
      .replaceAll(')', r'\)');

  add('<< /Type /Catalog /Pages 2 0 R >>');
  add(''); // the page tree, filled in below
  add(
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica '
    '/Encoding /WinAnsiEncoding >>',
  );
  // Page objects first, so links and the outline can refer to any page.
  final pageIds = [for (final _ in pages) add('')];
  for (final (index, text) in pages.indexed) {
    final lines = text.split('\n');
    final content = StringBuffer('BT /F1 12 Tf 14 TL 20 ${height - 40} Td ');
    for (final (i, line) in lines.indexed) {
      if (i > 0) content.write('T* ');
      content.write('(${escape(line)}) Tj ');
    }
    content.write('ET');
    final stream = content.toString();
    final contentId = add(
      '<< /Length ${latin1.encode(stream).length} >>\nstream\n$stream\nendstream',
    );
    final annotations = [
      for (final link in links.where((l) => l.from == index))
        add(
          '<< /Type /Annot /Subtype /Link /Border [0 0 0] '
          '/Rect [${link.rect.$1} ${link.rect.$2} ${link.rect.$3} ${link.rect.$4}] '
          '${switch (link.to) {
            final int page => '/Dest [${pageIds[page]} 0 R /XYZ 0 $height 0]',
            final String url => '/A << /S /URI /URI (${escape(url)}) >>',
            _ => throw ArgumentError(link.to),
          }} >>',
        ),
    ];
    objects[pageIds[index] - 1] =
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 $width $height] '
        '/Resources << /Font << /F1 3 0 R >> >> /Contents $contentId 0 R '
        '${annotations.isEmpty ? '' : '/Annots [${annotations.map((id) => '$id 0 R').join(' ')}] '}>>';
  }
  objects[1] =
      '<< /Type /Pages /Kids [${pageIds.map((id) => '$id 0 R').join(' ')}] '
      '/Count ${pageIds.length} >>';

  if (outline.isNotEmpty) {
    final rootId = objects.length + 1;
    final firstItem = rootId + 1;
    final lastItem = rootId + outline.length;
    add(
      '<< /Type /Outlines /First $firstItem 0 R /Last $lastItem 0 R '
      '/Count ${outline.length} >>',
    );
    for (final (i, (title, pageIndex)) in outline.indexed) {
      final id = firstItem + i;
      add(
        '<< /Title (${escape(title)}) /Parent $rootId 0 R '
        '${i > 0 ? '/Prev ${id - 1} 0 R ' : ''}'
        '${id < lastItem ? '/Next ${id + 1} 0 R ' : ''}'
        '/Dest [${pageIds[pageIndex]} 0 R /XYZ 0 $height 0] >>',
      );
    }
    objects[0] =
        '<< /Type /Catalog /Pages 2 0 R /Outlines $rootId 0 R '
        '/PageMode /UseOutlines >>';
  }

  final buffer = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(latin1.encode(buffer.toString()).length);
    buffer.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = latin1.encode(buffer.toString()).length;
  buffer.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets) {
    buffer.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  buffer.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
    'startxref\n$xref\n%%EOF\n',
  );
  return Uint8List.fromList(latin1.encode(buffer.toString()));
}

/// A small solid-colour PNG.
Uint8List pngImage({int width = 60, int height = 90}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(200, 40, 40));
  return img.encodePng(image);
}

/// Builds an EPUB in memory. Every structural part can be varied to produce
/// broken or unusual books.
Uint8List buildEpub({
  String? title = 'A Test Book',
  List<String> authors = const ['Ada Author'],
  String? description,
  String language = 'en',
  String version = '3.0',
  bool fixedLayout = false,
  Uint8List? cover,
  String coverStyle = 'epub3',
  String? encryptionXml,
  bool includeContainer = true,
  bool includeMimetype = true,
  bool emptySpine = false,
  String opfPath = 'OEBPS/content.opf',
  Map<String, List<int>> extraFiles = const {},
}) {
  final archive = Archive();
  if (includeMimetype) {
    final mimetype = utf8.encode('application/epub+zip');
    archive.add(ArchiveFile.noCompress('mimetype', mimetype.length, mimetype));
  }
  if (includeContainer) {
    archive.add(
      ArchiveFile.string(
        'META-INF/container.xml',
        '<?xml version="1.0"?>'
            '<container version="1.0" '
            'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
            '<rootfiles><rootfile full-path="$opfPath" '
            'media-type="application/oebps-package+xml"/></rootfiles>'
            '</container>',
      ),
    );
  }
  if (encryptionXml != null) {
    archive.add(ArchiveFile.string('META-INF/encryption.xml', encryptionXml));
  }

  final manifest = StringBuffer(
    '<item id="ch1" href="text/ch1.xhtml" '
    'media-type="application/xhtml+xml"/>',
  );
  final meta = StringBuffer();
  if (cover != null) {
    switch (coverStyle) {
      case 'epub3':
        manifest.write(
          '<item id="img" href="images/front.png" media-type="image/png" '
          'properties="cover-image"/>',
        );
      case 'epub2':
        manifest.write(
          '<item id="img" href="images/front.png" media-type="image/png"/>',
        );
        meta.write('<meta name="cover" content="img"/>');
      case 'page':
        // Only reachable through the first spine page's <img>.
        manifest.write(
          '<item id="img" href="images/front.png" media-type="image/png"/>',
        );
    }
    archive.add(ArchiveFile.bytes('OEBPS/images/front.png', cover));
  }
  if (fixedLayout) {
    meta.write('<meta property="rendition:layout">pre-paginated</meta>');
  }

  final creators = [
    for (final (i, author) in authors.indexed)
      '<dc:creator id="c$i">${const HtmlEscape().convert(author)}</dc:creator>',
  ].join();

  archive.add(
    ArchiveFile.string(
      opfPath,
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<package xmlns="http://www.idpf.org/2007/opf" version="$version" '
      'unique-identifier="id">'
      '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
      '${title == null ? '' : '<dc:title>${const HtmlEscape().convert(title)}</dc:title>'}'
      '$creators'
      '<dc:language>$language</dc:language>'
      '${description == null ? '' : '<dc:description>${const HtmlEscape().convert(description)}</dc:description>'}'
      '$meta'
      '</metadata>'
      '<manifest>$manifest</manifest>'
      '<spine>${emptySpine ? '' : '<itemref idref="ch1"/>'}</spine>'
      '</package>',
    ),
  );
  archive.add(
    ArchiveFile.string(
      'OEBPS/text/ch1.xhtml',
      '<html xmlns="http://www.w3.org/1999/xhtml"><body>'
          '${coverStyle == 'page' ? '<img src="../images/front.png" alt=""/>' : ''}'
          '<p>Hello.</p></body></html>',
    ),
  );
  for (final entry in extraFiles.entries) {
    archive.add(ArchiveFile.bytes(entry.key, entry.value));
  }
  return ZipEncoder().encodeBytes(archive);
}

/// An EPUB for reader tests: one XHTML document per entry of [chapters]
/// (body markup, saved as `OEBPS/text/chN.xhtml`, N from 1), with a table
/// of contents listing [toc] entries (title, href relative to
/// `OEBPS/text/`), as an EPUB 3 navigation document or, with [ncx], an
/// EPUB 2 NCX. [images] are stored under `OEBPS/` by path. Chapters listed
/// in [nonLinear] (zero-based) are excluded from the reading order.
Uint8List readerEpub({
  required List<String> chapters,
  List<(String, String)> toc = const [],
  bool ncx = false,
  Map<String, List<int>> images = const {},
  Set<int> nonLinear = const {},
}) {
  final archive = Archive();
  final mimetype = utf8.encode('application/epub+zip');
  archive.add(ArchiveFile.noCompress('mimetype', mimetype.length, mimetype));
  archive.add(
    ArchiveFile.string(
      'META-INF/container.xml',
      '<?xml version="1.0"?>'
          '<container version="1.0" '
          'xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
          '<rootfiles><rootfile full-path="OEBPS/content.opf" '
          'media-type="application/oebps-package+xml"/></rootfiles>'
          '</container>',
    ),
  );
  final manifest = StringBuffer();
  final spine = StringBuffer();
  for (final (i, body) in chapters.indexed) {
    final n = i + 1;
    manifest.write(
      '<item id="ch$n" href="text/ch$n.xhtml" '
      'media-type="application/xhtml+xml"/>',
    );
    spine.write(
      '<itemref idref="ch$n"${nonLinear.contains(i) ? ' linear="no"' : ''}/>',
    );
    archive.add(
      ArchiveFile.string(
        'OEBPS/text/ch$n.xhtml',
        '<?xml version="1.0" encoding="utf-8"?>'
            '<html xmlns="http://www.w3.org/1999/xhtml" '
            'xmlns:epub="http://www.idpf.org/2007/ops">'
            '<head><title>Chapter $n</title></head><body>$body</body></html>',
      ),
    );
  }
  for (final (i, entry) in images.entries.indexed) {
    manifest.write(
      '<item id="img$i" href="${entry.key}" media-type="image/png"/>',
    );
    archive.add(ArchiveFile.bytes('OEBPS/${entry.key}', entry.value));
  }
  var spineAttributes = '';
  if (toc.isNotEmpty && ncx) {
    manifest.write(
      '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
    );
    spineAttributes = ' toc="ncx"';
    final points = [
      for (final (i, (title, href)) in toc.indexed)
        '<navPoint id="p$i" playOrder="${i + 1}"><navLabel><text>'
            '${const HtmlEscape().convert(title)}</text></navLabel>'
            '<content src="text/$href"/></navPoint>',
    ].join();
    archive.add(
      ArchiveFile.string(
        'OEBPS/toc.ncx',
        '<?xml version="1.0"?>'
            '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">'
            '<navMap>$points</navMap></ncx>',
      ),
    );
  } else if (toc.isNotEmpty) {
    manifest.write(
      '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" '
      'properties="nav"/>',
    );
    final items = [
      for (final (title, href) in toc)
        '<li><a href="text/$href">${const HtmlEscape().convert(title)}</a></li>',
    ].join();
    archive.add(
      ArchiveFile.string(
        'OEBPS/nav.xhtml',
        '<?xml version="1.0" encoding="utf-8"?>'
            '<html xmlns="http://www.w3.org/1999/xhtml" '
            'xmlns:epub="http://www.idpf.org/2007/ops"><body>'
            '<nav epub:type="toc"><ol>$items</ol></nav></body></html>',
      ),
    );
  }
  archive.add(
    ArchiveFile.string(
      'OEBPS/content.opf',
      '<?xml version="1.0" encoding="UTF-8"?>'
          '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
          'unique-identifier="id">'
          '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
          '<dc:title>Reader Test</dc:title><dc:language>en</dc:language>'
          '</metadata>'
          '<manifest>$manifest</manifest>'
          '<spine$spineAttributes>$spine</spine>'
          '</package>',
    ),
  );
  return ZipEncoder().encodeBytes(archive);
}

/// Points pdfrx at the PDFium library that its build hook downloaded for
/// the host, so PDF tests exercise the real engine.
///
/// Returns false (and the caller should skip) if the library is not present.
Future<bool> initializePdfiumForTests() async {
  final buildDir = Directory(
    '.dart_tool/hooks_runner/shared/pdfium_dart/build',
  );
  if (!buildDir.existsSync()) return false;
  final library = buildDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('/libpdfium.so'))
      .firstOrNull;
  if (library == null) return false;
  Pdfrx.pdfiumModulePath = library.absolute.path;
  await pdfrxInitialize(tmpPath: Directory.systemTemp.path);
  return true;
}
