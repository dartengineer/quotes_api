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
