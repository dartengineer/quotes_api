import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/data/database/app_database.dart';
import 'package:lectern/features/library/data/library_repository.dart';
import 'package:lectern/features/reader/data/bookmark_repository.dart';
import 'package:lectern/features/reader/data/reading_progress_repository.dart';
import 'package:lectern/features/reader/domain/locator.dart';
import 'package:lectern/features/reader/domain/reader_preferences.dart';
import 'package:lectern/features/settings/data/settings_repository.dart';

import '../../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late LibraryRepository library;
  late ReadingProgressRepository progress;
  late BookmarkRepository bookmarks;
  late int doc;

  setUp(() async {
    db = createTestDatabase();
    final clock = FakeClock();
    library = LibraryRepository(db, clock: clock.call);
    progress = ReadingProgressRepository(db, clock: clock.call);
    bookmarks = BookmarkRepository(db, clock: clock.call);
    doc = await addTestDocument(library);
  });

  tearDown(() => db.close());

  group('positions and progress', () {
    test('saves, overwrites and restores the position', () async {
      expect(await progress.loadPosition(doc), isNull);
      await progress.savePosition(doc, const TextLocator(10));
      await progress.savePosition(doc, const TextLocator(20));
      expect(await progress.loadPosition(doc), const TextLocator(20));
      final rows = await db.select(db.readingPositions).get();
      expect(rows, hasLength(1));
    });

    test('an unreadable stored position is treated as none', () async {
      await db.readingPositions.insertOne(
        ReadingPositionsCompanion.insert(
          documentId: Value(doc),
          locator: '{"t":"unknown"}',
          updatedAt: DateTime.utc(2026),
        ),
      );
      expect(await progress.loadPosition(doc), isNull);
    });

    test('progress is clamped and shown in lists', () async {
      await progress.saveProgress(doc, 0.42);
      expect((await library.findById(doc))!.progress, 0.42);
      await progress.saveProgress(doc, 1.7);
      expect((await library.findById(doc))!.progress, 1.0);
    });
  });

  group('sessions', () {
    test('accumulate total reading time', () async {
      final start = DateTime.utc(2026, 3, 1, 20);
      await progress.recordSession(
        documentId: doc,
        startedAt: start,
        endedAt: start.add(const Duration(minutes: 30)),
        startProgress: 0,
        endProgress: 0.1,
      );
      await progress.recordSession(
        documentId: doc,
        startedAt: start.add(const Duration(days: 1)),
        endedAt: start.add(const Duration(days: 1, minutes: 15)),
        startProgress: 0.1,
        endProgress: 0.2,
      );
      expect(await progress.totalReadingTime(doc), const Duration(minutes: 45));
    });

    test('ignores sessions that end before they start', () async {
      final start = DateTime.utc(2026);
      await progress.recordSession(
        documentId: doc,
        startedAt: start,
        endedAt: start.subtract(const Duration(seconds: 1)),
        startProgress: 0,
        endProgress: 0,
      );
      expect(await progress.totalReadingTime(doc), Duration.zero);
    });
  });

  group('bookmarks', () {
    test('listed in reading order with cleaned excerpts', () async {
      await bookmarks.addBookmark(
        documentId: doc,
        locator: const TextLocator(900),
        progress: 0.9,
        excerpt: '  Near\nthe   end ',
      );
      await bookmarks.addBookmark(
        documentId: doc,
        locator: const TextLocator(100),
        progress: 0.1,
        excerpt: 'x' * 500,
      );
      final list = await bookmarks.watchBookmarks(doc).first;
      expect(list.map((b) => b.locator), const [
        TextLocator(100),
        TextLocator(900),
      ]);
      expect(list.last.excerpt, 'Near the end');
      expect(
        list.first.excerpt!.length,
        lessThanOrEqualTo(BookmarkRepository.maxExcerptLength),
      );
    });

    test('rows with unreadable locations are skipped', () async {
      await db.bookmarks.insertOne(
        BookmarksCompanion.insert(
          documentId: doc,
          locator: 'garbage',
          progress: 0.5,
          createdAt: DateTime.utc(2026),
        ),
      );
      await bookmarks.addBookmark(
        documentId: doc,
        locator: const TextLocator(5),
        progress: 0.01,
      );
      expect(await bookmarks.watchBookmarks(doc).first, hasLength(1));
    });

    test('delete removes one bookmark', () async {
      final id = await bookmarks.addBookmark(
        documentId: doc,
        locator: const TextLocator(5),
        progress: 0.01,
      );
      await bookmarks.deleteBookmark(id);
      expect(await bookmarks.watchBookmarks(doc).first, isEmpty);
    });

    test('are removed with their document', () async {
      await bookmarks.addBookmark(
        documentId: doc,
        locator: const TextLocator(5),
        progress: 0.01,
      );
      await progress.savePosition(doc, const TextLocator(5));
      await library.removeDocuments([doc]);
      expect(await db.select(db.bookmarks).get(), isEmpty);
      expect(await db.select(db.readingPositions).get(), isEmpty);
    });
  });

  group('reader preferences', () {
    test('defaults, round-trip and clamping', () async {
      final settings = SettingsRepository(db);
      expect(
        (await settings.load()).readerPreferences,
        const ReaderPreferences(),
      );

      const custom = ReaderPreferences(
        theme: ReaderTheme.sepia,
        font: ReaderFont.sans,
        fontSize: 24,
        lineHeight: 1.8,
        paragraphSpacing: 1,
        margin: 32,
        justify: true,
      );
      await settings.setReaderPreferences(custom);
      expect((await settings.load()).readerPreferences, custom);

      await db.preferences.insertOnConflictUpdate(
        PreferencesCompanion.insert(key: 'reader.fontSize', value: '999'),
      );
      await db.preferences.insertOnConflictUpdate(
        PreferencesCompanion.insert(key: 'reader.lineHeight', value: 'NaN'),
      );
      final loaded = (await settings.load()).readerPreferences;
      expect(loaded.fontSize, ReaderPreferences.maxFontSize);
      expect(
        loaded.lineHeight,
        ReaderPreferences.defaultLineHeight,
        reason: 'invalid values fall back to defaults',
      );
    });
  });
}
