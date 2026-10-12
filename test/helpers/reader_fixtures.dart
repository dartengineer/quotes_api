import 'dart:typed_data';

import 'package:lectern/app/dependencies.dart';
import 'package:lectern/features/library/domain/document_format.dart';

import 'test_database.dart';

/// "Line 0000" ... one line per block, easy to locate in tests.
String numberedLines(int count) => List.generate(
  count,
  (i) => 'Line ${i.toString().padLeft(4, '0')}',
).join('\n');

/// Character offset of line [n] in [numberedLines] text.
int lineOffset(int n) => n * 'Line 0000\n'.length;

int _counter = 0;

/// Adds a TXT document whose library file really exists.
Future<int> addTextFile(
  AppDependencies deps, {
  String title = 'Numbers',
  required String content,
}) async {
  final id = await addTestDocument(
    deps.library,
    title: title,
    format: DocumentFormat.txt,
    contentHash: 'txt-${_counter++}',
    fileSize: content.length,
  );
  final document = await deps.library.findById(id);
  deps.storage.resolve(document!.filePath)
    ..createSync(recursive: true)
    ..writeAsStringSync(content);
  return id;
}

/// Adds a PDF document whose library file really exists.
Future<int> addPdfFile(
  AppDependencies deps, {
  String title = 'Paper',
  required Uint8List bytes,
}) async {
  final id = await addTestDocument(
    deps.library,
    title: title,
    format: DocumentFormat.pdf,
    contentHash: 'pdf-${_counter++}',
    fileSize: bytes.length,
  );
  final document = await deps.library.findById(id);
  deps.storage.resolve(document!.filePath)
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes);
  return id;
}

/// Page `n` (zero-based) of [pagedText]: easy to search for and recognise.
String pageText(int n) =>
    'Page marker ${n.toString().padLeft(3, '0')}\nSome text on this page';

/// One [pageText] per page.
List<String> pagedText(int pages) => [
  for (var i = 0; i < pages; i++) pageText(i),
];

/// Adds an EPUB document whose library file really exists.
Future<int> addEpubFile(
  AppDependencies deps, {
  String title = 'Novel',
  required Uint8List bytes,
}) async {
  final id = await addTestDocument(
    deps.library,
    title: title,
    format: DocumentFormat.epub,
    contentHash: 'epub-${_counter++}',
    fileSize: bytes.length,
  );
  final document = await deps.library.findById(id);
  deps.storage.resolve(document!.filePath)
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes);
  return id;
}

/// Paragraph [p] of chapter [c] in [novelChapters].
String novelParagraph(int c, int p) =>
    'Chapter $c paragraph ${p.toString().padLeft(3, '0')}';

/// Chapter bodies: a heading (id `cN`) and numbered paragraphs (ids
/// `cNpM`). Chapters are numbered from 1.
List<String> novelChapters(int chapters, {int paragraphs = 60}) => [
  for (var c = 1; c <= chapters; c++)
    '<h1 id="c$c">Chapter $c</h1>'
        '${[for (var p = 0; p < paragraphs; p++) '<p id="c${c}p$p">${novelParagraph(c, p)}</p>'].join()}',
];

/// Archive path of chapter [c] in a [readerEpub] book.
String chapterPath(int c) => 'OEBPS/text/ch$c.xhtml';

/// Offset of paragraph [p] in the text of chapter [c] of [novelChapters].
int novelOffset(int c, int p) =>
    'Chapter $c'.length + 1 + p * (novelParagraph(c, 0).length + 1);
