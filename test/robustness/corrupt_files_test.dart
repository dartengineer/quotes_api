/// Damaged-input corpus. Valid samples of every format the app reads are
/// truncated, bit-flipped and partly scrambled with a fixed seed, then run
/// through import and the readers' loaders.
///
/// Every file must lead to an orderly result within a time limit: imported,
/// or rejected with a reason. Loaders may fail only with exceptions, which
/// the reader screens turn into messages; an [Error] (such as a range error
/// from indexing past malformed data) is a bug, and so is a hang.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/data/database/app_database.dart';
import 'package:lectern/data/files/library_storage.dart';
import 'package:lectern/engines/epub/epub_book.dart';
import 'package:lectern/engines/pdf/pdf_inspector.dart';
import 'package:lectern/engines/txt/text_document.dart';
import 'package:lectern/features/backup/data/backup_codec.dart';
import 'package:lectern/features/backup/domain/reading_backup.dart';
import 'package:lectern/features/import/data/document_importer.dart';
import 'package:lectern/features/import/domain/import_outcome.dart';
import 'package:lectern/features/library/data/library_repository.dart';
import 'package:lectern/features/reader/presentation/epub/epub_flow.dart';
import 'package:pdfrx/pdfrx.dart';

import '../helpers/fixtures.dart';
import '../helpers/reader_fixtures.dart';
import '../helpers/test_database.dart';

const _seed = 20261012;
const _timeLimit = Duration(seconds: 30);

/// Damaged copies of [bytes], named by what was done to them.
List<(String, Uint8List)> damagedCopies(Uint8List bytes, Random random) {
  final length = bytes.length;
  Uint8List copy() => Uint8List.fromList(bytes);
  return [
    for (final fraction in [0.02, 0.2, 0.5, 0.8, 0.98])
      (
        'cut to ${(fraction * 100).round()}%',
        bytes.sublist(0, max(1, (length * fraction).floor())),
      ),
    ('last byte missing', bytes.sublist(0, length - 1)),
    for (var i = 0; i < 6; i++)
      () {
        final flips = const [1, 8, 64][i % 3];
        final damaged = copy();
        for (var k = 0; k < flips; k++) {
          damaged[random.nextInt(length)] ^= 1 << random.nextInt(8);
        }
        return ('$flips bits flipped (#$i)', damaged);
      }(),
    for (var i = 0; i < 2; i++)
      () {
        final damaged = copy();
        final start = random.nextInt(length);
        for (var k = start; k < min(length, start + 512); k++) {
          damaged[k] = random.nextInt(256);
        }
        return ('512 bytes scrambled at $start', damaged);
      }(),
  ];
}

/// [zip] with every entry stored uncompressed, so damage lands in markup
/// rather than in compressed data.
Uint8List stored(Uint8List zip) {
  final source = ZipDecoder().decodeBytes(zip);
  final archive = Archive();
  for (final file in source.files) {
    final content = file.readBytes()!;
    archive.add(ArchiveFile.noCompress(file.name, content.length, content));
  }
  return ZipEncoder().encodeBytes(archive);
}

/// Runs [load] on a background isolate with a time limit. Returns a
/// description of the problem, or null if it succeeded or failed with an
/// exception.
Future<String?> checkLoader(Future<void> Function() load) async {
  try {
    await load().timeout(_timeLimit);
    return null;
  } on Exception catch (error) {
    if (error is TimeoutException) return 'did not finish';
    return null;
  } on Error catch (error) {
    return 'threw ${error.runtimeType}';
  }
}

/// Loads an EPUB and walks everything the reader would show.
void readEpubFully(String path) {
  final flow = EpubFlow(loadEpubBook(path), path);
  for (var i = 0; i < flow.blockCount; i++) {
    flow
      ..blockAt(i)
      ..blockText(i)
      ..locatorAt(flow.blockStart(i));
  }
  flow
    ..textBetween(0, flow.length)
    ..contents;
}

// Top-level, so the closures sent to the isolates capture only the path.
Future<void> readEpubInBackground(String path) =>
    Isolate.run(() => readEpubFully(path));

Future<void> readTextInBackground(String path) =>
    Isolate.run(() => readTextFully(path));

void readTextFully(String path) {
  final document = loadTextDocument(path);
  searchText(document.text, 'line');
}

/// Opens a PDF the way the reader does: from its file. (Not from memory:
/// on a damaged file pdfrx 2.6.5 then frees its copy twice and crashes the
/// process. The app never opens PDFs from memory.)
Future<void> readPdfFully(String path) async {
  final document = await PdfDocument.openFile(path);
  try {
    for (final page in document.pages.take(5)) {
      await page.loadText();
      final image = await page.render(width: 40, height: 60);
      image?.dispose();
    }
  } finally {
    await document.dispose();
  }
}

void main() {
  late bool pdfiumAvailable;
  late Directory base;
  late AppDatabase db;
  late DocumentImporter importer;

  setUpAll(() async {
    pdfiumAvailable = await initializePdfiumForTests();
  });

  setUp(() async {
    base = await Directory.systemTemp.createTemp('corpus');
    db = createTestDatabase();
    final storage = LibraryStorage(
      root: Directory('${base.path}/library'),
      temporaryDirectory: Directory('${base.path}/cache'),
    );
    await storage.ensureDirectories();
    await Directory('${base.path}/user').create();
    importer = DocumentImporter(
      library: LibraryRepository(db, clock: FakeClock().call),
      storage: storage,
      pdfInspector: PdfrxInspector(initialize: () async {}),
    );
  });

  tearDown(() async {
    await db.close();
    await base.delete(recursive: true);
  });

  /// Imports and loads every damaged copy of [sample]; returns the
  /// problems found, and the outcomes for a sanity check.
  Future<(List<String>, List<ImportOutcome>)> runCorpus(
    String name,
    Uint8List sample, {
    Future<String?> Function(String path, Uint8List bytes)? load,
  }) async {
    final problems = <String>[];
    final outcomes = <ImportOutcome>[];
    // Seeded from the name's characters: String.hashCode may change
    // between SDK versions.
    final random = Random(_seed + name.codeUnits.fold(0, (a, b) => a * 31 + b));
    for (final (i, (damage, bytes)) in damagedCopies(sample, random).indexed) {
      final label = '$name, $damage';
      final file = File('${base.path}/user/$i-$name')..writeAsBytesSync(bytes);
      try {
        final outcome = await importer
            .importFile(ImportSource(path: file.path, displayName: name))
            .timeout(_timeLimit);
        outcomes.add(outcome);
        // An unexpected exception during import is reported as a generic
        // failure; damage should be recognised as such.
        if (outcome is FailedOutcome) problems.add('$label: import failed');
      } on TimeoutException {
        problems.add('$label: import did not finish');
      }
      if (load != null) {
        if (await load(file.path, bytes) case final problem?) {
          problems.add('$label: $problem');
        }
      }
    }
    return (problems, outcomes);
  }

  final chapters = novelChapters(3, paragraphs: 12);

  test('damaged EPUBs are rejected or read, never crash', () async {
    final samples = {
      'book.epub': readerEpub(
        chapters: chapters,
        toc: [('One', 'ch1.xhtml'), ('Two', 'ch2.xhtml#p3')],
      ),
      'stored.epub': stored(
        readerEpub(chapters: chapters, toc: [('One', 'ch1.xhtml')], ncx: true),
      ),
      'cover.epub': stored(
        buildEpub(
          cover: pngImage(),
          description: '<p>About <b>this</b> book.</p>',
        ),
      ),
    };
    final problems = <String>[];
    final outcomes = <ImportOutcome>[];
    for (final MapEntry(key: name, value: sample) in samples.entries) {
      final (found, results) = await runCorpus(
        name,
        sample,
        load: (path, _) => checkLoader(() => readEpubInBackground(path)),
      );
      problems.addAll(found);
      outcomes.addAll(results);
    }
    expect(problems, isEmpty);
    // The corpus is not trivially rejected wholesale: some damage is
    // survivable (e.g. a flipped bit in text), some is not.
    expect(outcomes.whereType<RejectedOutcome>(), isNotEmpty);
    expect(outcomes.whereType<ImportedOutcome>(), isNotEmpty);
  });

  test('damaged PDFs are rejected or read, never crash', () async {
    if (!pdfiumAvailable) {
      markTestSkipped('PDFium is not available');
      return;
    }
    final sample = textPdf(
      ['First page text', 'Second page text', 'Third'],
      outline: [('Start', 0), ('End', 2)],
    );
    final (problems, outcomes) = await runCorpus(
      'doc.pdf',
      sample,
      load: (path, _) => checkLoader(() => readPdfFully(path)),
    );
    expect(problems, isEmpty);
    expect(outcomes.whereType<ImportedOutcome>(), isNotEmpty);
  });

  test('damaged text files are imported or rejected, and read', () async {
    final text = numberedLines(400);
    final samples = {
      'utf8.txt': utf8.encode('Café — naïve\n$text'),
      'utf16.txt': Uint8List.fromList([
        0xFF,
        0xFE,
        for (final unit in 'Café\n$text'.codeUnits) ...[unit & 0xFF, unit >> 8],
      ]),
    };
    final problems = <String>[];
    for (final MapEntry(key: name, value: sample) in samples.entries) {
      final (found, _) = await runCorpus(
        name,
        sample,
        load: (path, _) => checkLoader(() => readTextInBackground(path)),
      );
      problems.addAll(found);
    }
    expect(problems, isEmpty);
  });

  test('damaged zip archives that are not books are turned away', () async {
    final archive = Archive()
      ..add(ArchiveFile.string('notes/readme.txt', 'Not a book\n' * 50))
      ..add(ArchiveFile.string('data.json', '{"a": 1}'));
    final (problems, outcomes) = await runCorpus(
      'archive.zip',
      ZipEncoder().encodeBytes(archive),
    );
    expect(problems, isEmpty);
    expect(outcomes.whereType<ImportedOutcome>(), isEmpty);
  });

  test('damaged backups are rejected or read, never crash', () {
    final sample = encodeBackup(
      ReadingBackup(
        createdAt: DateTime.utc(2026),
        settings: const {'app.theme': 'dark'},
        collections: [
          BackupCollection(name: 'Shelf', createdAt: DateTime.utc(2026)),
        ],
        documents: [
          BackupDocument(
            contentHash: 'ab' * 32,
            title: 'Book',
            progress: 0.5,
            collections: const ['Shelf'],
          ),
        ],
      ),
    );
    final problems = <String>[];
    var read = 0;
    for (final (damage, bytes) in damagedCopies(sample, Random(_seed))) {
      try {
        decodeBackup(bytes);
        read++;
      } on BackupFormatException {
        // Expected for most damage.
      } on Object catch (error) {
        problems.add('$damage: threw ${error.runtimeType}');
      }
    }
    expect(problems, isEmpty);
    expect(read, greaterThan(0));
  });
}
