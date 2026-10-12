/// Timings for docs/PERFORMANCE.md. Skipped unless asked for:
///
///     flutter test test/benchmarks --dart-define=BENCHMARK=true
///
/// These run in the test VM (JIT, debug mode) on whatever machine runs
/// them. They are for comparing changes on the same machine, not for
/// predicting what a phone will do.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/data/database/app_database.dart';
import 'package:lectern/data/files/library_storage.dart';
import 'package:lectern/engines/epub/epub_book.dart';
import 'package:lectern/engines/txt/text_document.dart';
import 'package:lectern/features/backup/data/backup_codec.dart';
import 'package:lectern/features/backup/data/reading_data_backup.dart';
import 'package:lectern/features/library/data/library_repository.dart';
import 'package:lectern/features/library/domain/document_format.dart';
import 'package:lectern/features/reader/domain/annotation.dart';
import 'package:lectern/features/reader/domain/locator.dart';
import 'package:lectern/features/reader/presentation/epub/epub_flow.dart';
import 'package:lectern/features/settings/data/settings_repository.dart';

import '../helpers/fixtures.dart';
import '../helpers/test_database.dart';

const _enabled = bool.fromEnvironment('BENCHMARK');
const _skip = _enabled
    ? null
    : 'Benchmarks run with --dart-define=BENCHMARK=true';

/// Runs [body] once to warm up, then [runs] times; returns the median.
Future<Duration> measure(FutureOr<void> Function() body, {int runs = 5}) async {
  await body();
  final times = <Duration>[];
  for (var i = 0; i < runs; i++) {
    final watch = Stopwatch()..start();
    await body();
    times.add(watch.elapsed);
  }
  times.sort();
  return times[runs ~/ 2];
}

void report(String what, Duration time, [String extra = '']) {
  // ignore: avoid_print
  print('BENCHMARK | $what | ${time.inMilliseconds} ms | $extra');
}

/// A novel-like book: [chapters] chapters of [paragraphs] paragraphs of
/// about 500 characters, with some inline markup.
List<String> proseChapters(int chapters, int paragraphs) {
  const sentence =
      'The <i>evening</i> light fell across the river, and for a while '
      'nobody on the old bridge said anything at all. ';
  final paragraph = '<p>${sentence * 4}</p>';
  return [
    for (var c = 1; c <= chapters; c++)
      '<h1>Chapter $c</h1>${paragraph * paragraphs}',
  ];
}

String hashOf(int n) => n.toRadixString(16).padLeft(64, '0');

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bench');
  });

  tearDown(() => dir.delete(recursive: true));

  test('TXT: load and search a 20 MB file', skip: _skip, () async {
    final path = '${dir.path}/big.txt';
    final lines = StringBuffer();
    for (var i = 0; i < 400000; i++) {
      lines.write('Line $i of a long log file, with some padding text.\n');
    }
    File(path).writeAsStringSync(lines.toString());
    final size = File(path).lengthSync();

    late TextDocument document;
    final load = await measure(() => document = loadTextDocument(path));
    report('TXT load', load, '${(size / 1e6).toStringAsFixed(1)} MB');
    final search = await measure(
      () => searchText(document.text, 'line 399999 of'),
    );
    report('TXT search (rare term)', search);
  });

  test('EPUB: open a long novel', skip: _skip, () async {
    final path = '${dir.path}/novel.epub';
    File(path).writeAsBytesSync(readerEpub(chapters: proseChapters(40, 160)));
    late EpubBook book;
    final load = await measure(() => book = loadEpubBook(path));
    final chars = book.chapters.fold<int>(
      0,
      (sum, c) => sum + c.content.text.length,
    );
    report('EPUB load (parse all chapters)', load, '$chars characters');
    final flow = await measure(() => EpubFlow(book, path));
    report('EPUB flow document from loaded book', flow);
    final background = await measure(
      () => Isolate.run(() => loadEpubBook(path).chapters.length),
    );
    report('EPUB load on a background isolate (incl. transfer)', background);
  });

  test('import: copy and hash a 50 MB file', skip: _skip, () async {
    final source = File('${dir.path}/source.bin')
      ..writeAsBytesSync(List.filled(50 * 1024 * 1024, 7));
    final storage = LibraryStorage(
      root: Directory('${dir.path}/library'),
      temporaryDirectory: Directory('${dir.path}/cache'),
    );
    await storage.ensureDirectories();
    final stage = await measure(() async {
      final staged = await storage.stage(source.path);
      await storage.discard(staged);
    }, runs: 3);
    report('Import staging (copy + SHA-256)', stage, '50 MB');
  });

  test('backup: 1,000 books with marks and history', skip: _skip, () async {
    const books = 1000;
    Future<AppDatabase> library({required bool withData}) async {
      final db = createTestDatabase();
      final repo = LibraryRepository(db, clock: FakeClock().call);
      final ids = [
        for (var i = 0; i < books; i++)
          await addTestDocument(
            repo,
            title: 'Book $i',
            format: DocumentFormat.epub,
            contentHash: hashOf(i),
          ),
      ];
      if (!withData) return db;
      final start = DateTime.utc(2025);
      await db.batch((batch) {
        for (final id in ids) {
          batch.insert(
            db.readingPositions,
            ReadingPositionsCompanion.insert(
              documentId: Value(id),
              locator: const EpubLocator(
                href: 'ch3.xhtml',
                offset: 500,
              ).encode(),
              updatedAt: start,
            ),
          );
          for (var k = 0; k < 10; k++) {
            batch.insert(
              db.bookmarks,
              BookmarksCompanion.insert(
                documentId: id,
                locator: EpubLocator(href: 'ch$k.xhtml', offset: k).encode(),
                progress: k / 10,
                excerpt: const Value('A short excerpt of the bookmarked place'),
                createdAt: start.add(Duration(minutes: k)),
              ),
            );
          }
          for (var k = 0; k < 20; k++) {
            batch.insert(
              db.annotations,
              AnnotationsCompanion.insert(
                documentId: id,
                range: TextRangeAnchor(
                  start: EpubLocator(href: 'ch$k.xhtml', offset: 10),
                  end: EpubLocator(href: 'ch$k.xhtml', offset: 90),
                ).encode(),
                progress: k / 20,
                selectedText: 'x' * 80,
                note: Value(k.isEven ? 'A note of moderate length.' : null),
                color: HighlightColor.yellow.argb,
                createdAt: start.add(Duration(hours: k)),
                updatedAt: start.add(Duration(hours: k)),
              ),
            );
          }
          for (var k = 0; k < 50; k++) {
            batch.insert(
              db.readingSessions,
              ReadingSessionsCompanion.insert(
                documentId: id,
                startedAt: start.add(Duration(days: k)),
                endedAt: start.add(Duration(days: k, minutes: 30)),
                startProgress: k / 50,
                endProgress: (k + 1) / 50,
              ),
            );
          }
        }
      });
      return db;
    }

    final source = await library(withData: true);
    addTearDown(source.close);
    final service = ReadingDataBackup(source, SettingsRepository(source));
    final create = await measure(service.create, runs: 3);
    report('Backup: collect from database', create, '$books books');
    final backup = await service.create();
    final bytes = encodeBackup(backup);
    final encode = await measure(() => encodeBackup(backup), runs: 3);
    report(
      'Backup: encode JSON',
      encode,
      '${(bytes.length / 1e6).toStringAsFixed(1)} MB file',
    );
    final decode = await measure(() => decodeBackup(bytes), runs: 3);
    report('Backup: decode and validate', decode);

    final target = await library(withData: false);
    addTearDown(target.close);
    final restorer = ReadingDataBackup(target, SettingsRepository(target));
    final watch = Stopwatch()..start();
    final first = await restorer.restore(backup);
    report(
      'Restore into a library without the data',
      watch.elapsed,
      '${first.highlightsAdded} highlights, '
          '${first.sessionsAdded} sessions added',
    );
    watch.reset();
    final again = await restorer.restore(backup);
    report('Restore again (nothing new)', watch.elapsed);
    expect(again.changedAnything, isFalse);
    expect(jsonDecode(utf8.decode(bytes)), isA<Map<String, Object?>>());
  });
}
