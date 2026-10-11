import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/core/utils/cancellation.dart';
import 'package:lectern/data/database/app_database.dart';
import 'package:lectern/features/import/data/document_importer.dart';
import 'package:lectern/features/import/data/library_storage.dart';
import 'package:lectern/features/import/domain/import_outcome.dart';
import 'package:lectern/features/library/data/library_repository.dart';
import 'package:lectern/features/library/domain/document_format.dart';

import '../../helpers/fixtures.dart';
import '../../helpers/test_database.dart';

void main() {
  late bool pdfiumAvailable;
  late Directory base;
  late AppDatabase db;
  late LibraryRepository library;
  late LibraryStorage storage;
  late DocumentImporter importer;

  setUpAll(() async {
    pdfiumAvailable = await initializePdfiumForTests();
  });

  setUp(() async {
    base = await Directory.systemTemp.createTemp('importer');
    db = createTestDatabase();
    library = LibraryRepository(db, clock: FakeClock().call);
    storage = LibraryStorage(
      root: Directory('${base.path}/support/library'),
      temporaryDirectory: Directory('${base.path}/cache'),
    );
    await storage.ensureDirectories();
    await Directory('${base.path}/user').create();
    importer = DocumentImporter(library: library, storage: storage);
  });

  tearDown(() async {
    await db.close();
    await base.delete(recursive: true);
  });

  ImportSource userFile(String name, List<int> bytes) {
    final file = File('${base.path}/user/$name')..writeAsBytesSync(bytes);
    return ImportSource(path: file.path, displayName: name);
  }

  List<FileSystemEntity> filesIn(String dir) =>
      Directory('${storage.root.path}/$dir').listSync();

  group('EPUB', () {
    test('imports metadata and a cover thumbnail', () async {
      final outcome = await importer.importFile(
        userFile(
          'hobbit.epub',
          buildEpub(
            title: 'The Hobbit',
            authors: ['J. R. R. Tolkien'],
            description: '<p>A <i>classic</i>.</p>',
            language: 'en',
            cover: pngImage(width: 600, height: 900),
          ),
        ),
      );

      expect(outcome, isA<ImportedOutcome>());
      final doc = (await library.findById(
        (outcome as ImportedOutcome).documentId,
      ))!;
      expect(doc.title, 'The Hobbit');
      expect(doc.author, 'J. R. R. Tolkien');
      expect(doc.format, DocumentFormat.epub);
      expect(doc.originalFileName, 'hobbit.epub');
      expect(doc.coverPath, isNotNull);
      expect(storage.resolve(doc.filePath).existsSync(), isTrue);
      final cover = storage.resolve(doc.coverPath!).readAsBytesSync();
      expect(cover.sublist(0, 2), [0xFF, 0xD8], reason: 'JPEG thumbnail');

      final row = await (db.select(
        db.documents,
      )..where((d) => d.id.equals(doc.id))).getSingle();
      expect(row.description, 'A classic.');
      expect(row.language, 'en');
    });

    test('falls back to the file name when the book has no title', () async {
      final outcome = await importer.importFile(
        userFile('my_untitled_book.epub', buildEpub(title: null)),
      );
      expect((outcome as ImportedOutcome).title, 'my untitled book');
    });

    test('rejects DRM-protected and fixed-layout books', () async {
      final drm = await importer.importFile(
        userFile(
          'drm.epub',
          buildEpub(
            encryptionXml:
                '<encryption xmlns:enc="http://www.w3.org/2001/04/xmlenc#">'
                '<enc:EncryptedData><enc:EncryptionMethod '
                'Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>'
                '</enc:EncryptedData></encryption>',
          ),
        ),
      );
      expect((drm as RejectedOutcome).reason, RejectionReason.drmProtected);

      final fixed = await importer.importFile(
        userFile('comic.epub', buildEpub(fixedLayout: true)),
      );
      expect((fixed as RejectedOutcome).reason, RejectionReason.fixedLayout);

      expect(await library.watchCount().first, 0);
      expect(filesIn('files'), isEmpty);
      expect(filesIn('incoming'), isEmpty);
    });

    test('rejects a structurally damaged book', () async {
      final outcome = await importer.importFile(
        userFile('broken.epub', buildEpub(emptySpine: true)),
      );
      expect((outcome as RejectedOutcome).reason, RejectionReason.damaged);
    });
  });

  group('PDF', () {
    test('imports page count and a first-page thumbnail', () async {
      if (!pdfiumAvailable) markTestSkipped('PDFium not available');
      final outcome = await importer.importFile(
        userFile('report_2026.pdf', minimalPdf(pages: 3)),
      );
      final doc = (await library.findById(
        (outcome as ImportedOutcome).documentId,
      ))!;
      expect(doc.title, 'report 2026');
      expect(doc.pageCount, 3);
      expect(doc.coverPath, isNotNull);
      expect(outcome.needsPassword, isFalse);
    });

    test('imports a password-protected PDF without reading it', () async {
      if (!pdfiumAvailable) markTestSkipped('PDFium not available');
      final outcome = await importer.importFile(
        userFile(
          'secret.pdf',
          File('test/fixtures/password_protected.pdf').readAsBytesSync(),
        ),
      );
      expect((outcome as ImportedOutcome).needsPassword, isTrue);
      final doc = (await library.findById(outcome.documentId))!;
      expect(doc.pageCount, isNull);
      expect(doc.coverPath, isNull);
    });

    test('opens a permissions-only PDF normally', () async {
      if (!pdfiumAvailable) markTestSkipped('PDFium not available');
      final outcome = await importer.importFile(
        userFile(
          'restricted.pdf',
          File('test/fixtures/permissions_only.pdf').readAsBytesSync(),
        ),
      );
      expect((outcome as ImportedOutcome).needsPassword, isFalse);
      expect((await library.findById(outcome.documentId))!.pageCount, 3);
    });

    test('rejects a damaged PDF', () async {
      if (!pdfiumAvailable) markTestSkipped('PDFium not available');
      final outcome = await importer.importFile(
        userFile(
          'broken.pdf',
          utf8.encode('%PDF-1.7\nthis is not really a pdf'),
        ),
      );
      expect((outcome as RejectedOutcome).reason, RejectionReason.damaged);
      expect(filesIn('files'), isEmpty);
    });
  });

  group('TXT and unsupported files', () {
    test('imports text with a title from the file name', () async {
      final outcome = await importer.importFile(
        userFile('Meeting_notes.txt', utf8.encode('Agenda\n1. Coffee\n')),
      );
      final doc = (await library.findById(
        (outcome as ImportedOutcome).documentId,
      ))!;
      expect(doc.title, 'Meeting notes');
      expect(doc.format, DocumentFormat.txt);
      expect(doc.coverPath, isNull);
    });

    test('names unsupported formats and leaves nothing behind', () async {
      final outcome = await importer.importFile(
        userFile('photo.txt', pngImage()),
      );
      expect(outcome, isA<RejectedOutcome>());
      outcome as RejectedOutcome;
      expect(outcome.reason, RejectionReason.unsupportedFormat);
      expect(outcome.message, 'Not supported: image.');
      expect(filesIn('incoming'), isEmpty);
    });

    test('rejects empty files', () async {
      final outcome = await importer.importFile(
        userFile('empty.txt', const []),
      );
      expect((outcome as RejectedOutcome).reason, RejectionReason.emptyFile);
    });

    test('reports unreadable sources as failures, not crashes', () async {
      final outcome = await importer.importFile(
        ImportSource(
          path: '${base.path}/user/does-not-exist.pdf',
          displayName: 'missing.pdf',
        ),
      );
      expect(outcome, const FailedOutcome('missing.pdf'));
    });
  });

  group('duplicates and originals', () {
    test('the same content under another name is a duplicate', () async {
      final bytes = utf8.encode('Same text');
      final first = await importer.importFile(userFile('a.txt', bytes));
      final second = await importer.importFile(userFile('b.txt', bytes));

      expect(second, isA<DuplicateOutcome>());
      expect(
        (second as DuplicateOutcome).existingId,
        (first as ImportedOutcome).documentId,
      );
      expect(await library.watchCount().first, 1);
      expect(filesIn('files'), hasLength(1));
      expect(filesIn('incoming'), isEmpty);
    });

    test(
      'user originals are untouched; picker temp copies are moved',
      () async {
        final original = userFile('kept.txt', utf8.encode('keep me'));
        await importer.importFile(original);
        expect(File(original.path).readAsStringSync(), 'keep me');

        final temp = File('${base.path}/cache/file_picker/1/t.txt')
          ..createSync(recursive: true)
          ..writeAsStringSync('temporary copy');
        await importer.importFile(
          ImportSource(path: temp.path, displayName: 't.txt'),
        );
        expect(temp.existsSync(), isFalse);
        expect(await library.watchCount().first, 2);
      },
    );
  });

  group('batches', () {
    test('reports progress and a summary', () async {
      final progress = <ImportProgress>[];
      final report = await importer.importAll([
        userFile('one.txt', utf8.encode('one')),
        userFile('two.txt', utf8.encode('one')),
        userFile('three.bin', [0, 1, 2, 0, 0, 9]),
      ], onProgress: progress.add);

      expect(report.imported, hasLength(1));
      expect(report.duplicates, hasLength(1));
      expect(report.problems, hasLength(1));
      expect(report.cancelled, isFalse);
      expect(progress.map((p) => p.completed), [0, 1, 2, 3]);
      expect(progress.first.currentFileName, 'one.txt');
      expect(progress.last.currentFileName, isNull);
    });

    test('cancelling skips the remaining files', () async {
      final token = CancellationToken();
      final report = await importer.importAll(
        [
          userFile('one.txt', utf8.encode('one')),
          userFile('two.txt', utf8.encode('two')),
          userFile('three.txt', utf8.encode('three')),
        ],
        cancellation: token,
        onProgress: (p) {
          if (p.completed == 1) token.cancel();
        },
      );
      expect(report.cancelled, isTrue);
      expect(report.outcomes, hasLength(1));
      expect(report.skipped, 2);
      expect(await library.watchCount().first, 1);
      expect(filesIn('incoming'), isEmpty);
    });
  });

  test('formatAuthors abbreviates long lists', () {
    expect(formatAuthors(const []), isNull);
    expect(formatAuthors(const ['A', 'B']), 'A, B');
    expect(formatAuthors(const ['A', 'B', 'C', 'D']), 'A, B, C et al.');
  });
}
