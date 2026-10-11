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
