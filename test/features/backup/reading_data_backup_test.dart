import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/data/database/app_database.dart';
import 'package:lectern/features/backup/data/backup_codec.dart';
import 'package:lectern/features/backup/data/reading_data_backup.dart';
import 'package:lectern/features/backup/domain/reading_backup.dart';
import 'package:lectern/features/collections/data/collection_repository.dart';
import 'package:lectern/features/library/data/library_repository.dart';
import 'package:lectern/features/library/domain/document_format.dart';
import 'package:lectern/features/library/domain/library_layout.dart';
import 'package:lectern/features/library/domain/reading_status.dart';
import 'package:lectern/features/reader/data/annotation_repository.dart';
import 'package:lectern/features/reader/data/bookmark_repository.dart';
import 'package:lectern/features/reader/data/reading_progress_repository.dart';
import 'package:lectern/features/reader/domain/annotation.dart';
import 'package:lectern/features/reader/domain/locator.dart';
import 'package:lectern/features/reader/domain/reader_preferences.dart';
import 'package:lectern/features/settings/data/settings_repository.dart';
import 'package:lectern/features/settings/domain/app_settings.dart';

import '../../helpers/test_database.dart';

String hashOf(int n) => n.toRadixString(16).padLeft(64, '0');

/// A library database with its repositories, on one fake clock.
class TestLibrary {
  TestLibrary({SettingsRepository Function(AppDatabase db)? settings})
    : db = createTestDatabase() {
    this.settings = settings?.call(db) ?? SettingsRepository(db);
    backup = ReadingDataBackup(db, this.settings, clock: clock.call);
  }

  final AppDatabase db;
  final clock = FakeClock();
  late final library = LibraryRepository(db, clock: clock.call);
  late final progress = ReadingProgressRepository(db, clock: clock.call);
  late final bookmarks = BookmarkRepository(db, clock: clock.call);
  late final annotations = AnnotationRepository(db, clock: clock.call);
  late final collections = CollectionRepository(db, clock: clock.call);
  late final SettingsRepository settings;
  late final ReadingDataBackup backup;

  Future<int> add(int n, {DocumentFormat format = DocumentFormat.epub}) =>
      addTestDocument(
        library,
        title: 'Book $n',
        format: format,
        contentHash: hashOf(n),
      );

  Future<int> count(TableInfo<Table, Object?> table) async =>
      (await db.select(table).get()).length;

  Future<DocumentRow> document(int id) =>
      (db.select(db.documents)..where((d) => d.id.equals(id))).getSingle();

  Future<List<AnnotationRow>> annotationRows() =>
      db.select(db.annotations).get();
}

const _range = TextRangeAnchor(
  start: EpubLocator(href: 'ch1.xhtml', offset: 10),
  end: EpubLocator(href: 'ch1.xhtml', offset: 20),
);

/// Gives book 1 some of everything, and adds an untouched book 2.
Future<void> fillLibrary(TestLibrary lib) async {
  final id = await lib.add(1);
  await lib.add(2);
  await lib.library.markOpened(id);
  await lib.library.setFavorite([id], favorite: true);
  await lib.progress.savePosition(
    id,
    const EpubLocator(href: 'ch2.xhtml', offset: 40, progression: 0.5),
  );
  await lib.progress.saveProgress(id, 0.4);
  await lib.progress.recordSession(
    documentId: id,
    startedAt: DateTime.utc(2026, 1, 1, 8),
    endedAt: DateTime.utc(2026, 1, 1, 8, 45),
    startProgress: 0.1,
    endProgress: 0.4,
  );
  await lib.bookmarks.addBookmark(
    documentId: id,
    locator: const EpubLocator(href: 'ch1.xhtml', offset: 3),
    progress: 0.05,
    excerpt: 'It was night',
  );
  final highlight = await lib.annotations.addAnnotation(
    documentId: id,
    draft: const AnnotationDraft(range: _range, progress: 0.06, text: 'words'),
    color: HighlightColor.green,
  );
  await lib.annotations.updateNote(highlight, 'A private thought');
  final shelf = await lib.collections.createCollection('Shelf');
  await lib.collections.addDocuments(shelf, [id]);
  await lib.collections.createCollection('Empty');
  await lib.settings.setThemePreference(ThemePreference.dark);
  await lib.settings.setLibraryLayout(LibraryLayout.list);
}

/// [backup] after a trip through a file.
ReadingBackup throughFile(ReadingBackup backup) =>
    decodeBackup(encodeBackup(backup));

void main() {
  late TestLibrary a;
  late TestLibrary b;

  setUp(() {
    a = TestLibrary();
    b = TestLibrary();
  });

  tearDown(() async {
    await a.db.close();
    await b.db.close();
  });

  test('a backup holds reading data, not untouched documents', () async {
    await fillLibrary(a);
    final backup = await a.backup.create();

    final document = backup.documents.single;
    expect(document.contentHash, hashOf(1));
    expect(document.title, 'Book 1');
    expect(document.status, ReadingStatus.reading);
    expect(document.favorite, isTrue);
    expect(document.progress, 0.4);
    expect(document.lastOpenedAt, isNotNull);
    expect(document.position!.locator, isA<EpubLocator>());
    expect(document.bookmarks.single.excerpt, 'It was night');
    expect(document.highlights.single.note, 'A private thought');
    expect(document.sessions.single.endProgress, 0.4);
    expect(document.collections, ['Shelf']);
    expect(backup.collections.map((c) => c.name), ['Shelf', 'Empty']);
    // Library view options stay with the device.
    expect(backup.settings, {'app.theme': 'dark'});
  });

  test('restoring into another library brings everything back', () async {
    await fillLibrary(a);
    final original = await a.backup.create();
    // The same books, added in another order, so ids differ.
    await b.add(3);
    await b.add(2);
    await b.add(1);

    final report = await b.backup.restore(throughFile(original));
    expect(
      report,
      const RestoreReport(
        matchedBooks: 1,
        updatedBooks: 1,
        positionsRestored: 1,
        bookmarksAdded: 1,
        highlightsAdded: 1,
        sessionsAdded: 1,
        collectionsCreated: 2,
        collectionEntriesAdded: 1,
        settingsRestored: true,
      ),
    );

    final restored = await b.backup.create();
    expect(restored.documents, original.documents);
    expect(restored.collections, original.collections);
    expect(restored.settings, original.settings);
  });

  test('restoring the same backup again changes nothing', () async {
    await fillLibrary(a);
    await b.add(1);
    final backup = throughFile(await a.backup.create());
    await b.backup.restore(backup);
    final before = await b.backup.create();

    final report = await b.backup.restore(backup);
    expect(report.matchedBooks, 1);
    expect(report.changedAnything, isFalse);
    expect(report, const RestoreReport(matchedBooks: 1));
    final after = await b.backup.create();
    expect(after.documents, before.documents);
    expect(await b.count(b.db.bookmarks), 1);
    expect(await b.count(b.db.annotations), 1);
    expect(await b.count(b.db.readingSessions), 1);
    expect(await b.count(b.db.collections), 2);
  });

  test('merging keeps whichever side is further along', () async {
    final id = await b.add(1);
    await b.library.markOpened(id);
    await b.progress.savePosition(
      id,
      const EpubLocator(href: 'ch9.xhtml', offset: 100),
    );
    await b.progress.saveProgress(id, 0.6);
    final highlightId = await b.annotations.addAnnotation(
      documentId: id,
      draft: const AnnotationDraft(range: _range, progress: 0.1, text: 'x'),
      color: HighlightColor.yellow,
      note: 'old note',
    );
    final existing = (await b.annotationRows()).single;
    final libraryOpened = (await b.document(id)).lastOpenedAt!;

    final report = await b.backup.restore(
      ReadingBackup(
        createdAt: DateTime.utc(2026, 6, 1),
        documents: [
          BackupDocument(
            contentHash: hashOf(1),
            title: 'Book 1',
            status: ReadingStatus.finished,
            favorite: true,
            progress: 1,
            lastOpenedAt: libraryOpened.add(const Duration(days: 30)).toUtc(),
            // Older than the library's position.
            position: BackupPosition(
              locator: const EpubLocator(href: 'ch1.xhtml', offset: 5),
              updatedAt: DateTime.utc(2025, 12, 1),
            ),
            highlights: [
              // The same highlight, edited later elsewhere.
              BackupHighlight(
                range: _range,
                progress: 0.1,
                text: 'x',
                note: 'new note',
                color: HighlightColor.blue,
                createdAt: existing.createdAt.toUtc(),
                updatedAt: DateTime.utc(2026, 6, 1),
              ),
              // Same place, made at another time: a separate highlight.
              BackupHighlight(
                range: _range,
                progress: 0.1,
                text: 'x',
                color: HighlightColor.pink,
                createdAt: DateTime.utc(2025, 5, 5),
                updatedAt: DateTime.utc(2025, 5, 5),
              ),
            ],
          ),
        ],
      ),
    );

    expect(report.positionsRestored, 0);
    expect(report.highlightsUpdated, 1);
    expect(report.highlightsAdded, 1);
    final row = await b.document(id);
    expect(row.isFavorite, isTrue);
    expect(row.readingStatus, ReadingStatus.finished);
    // A finished status brings its full progress bar.
    expect(row.progress, 1);
    expect(
      row.lastOpenedAt!.isAtSameMomentAs(
        libraryOpened.add(const Duration(days: 30)),
      ),
      isTrue,
    );
    expect(
      await b.progress.loadPosition(id),
      const EpubLocator(href: 'ch9.xhtml', offset: 100),
    );
    final updated = (await b.annotationRows()).firstWhere(
      (r) => r.id == highlightId,
    );
    expect(updated.note, 'new note');
    expect(updated.color, HighlightColor.blue.argb);
    expect(await b.count(b.db.annotations), 2);
  });

  test(
    'a newer position replaces the library one, with its progress',
    () async {
      final id = await b.add(1);
      await b.library.setFavorite([id], favorite: true);
      await b.library.setStatus([id], ReadingStatus.reading);
      await b.progress.savePosition(
        id,
        const EpubLocator(href: 'ch9.xhtml', offset: 100),
      );
      await b.progress.saveProgress(id, 0.6);
      final highlightId = await b.annotations.addAnnotation(
        documentId: id,
        draft: const AnnotationDraft(range: _range, progress: 0.1, text: 'x'),
        color: HighlightColor.yellow,
        note: 'kept',
      );
      final existing = (await b.annotationRows()).single;

      final report = await b.backup.restore(
        ReadingBackup(
          createdAt: DateTime.utc(2027),
          documents: [
            BackupDocument(
              contentHash: hashOf(1),
              title: 'Book 1',
              status: ReadingStatus.unread,
              progress: 0.2,
              position: BackupPosition(
                locator: const EpubLocator(href: 'ch1.xhtml', offset: 7),
                updatedAt: DateTime.utc(2027),
              ),
              highlights: [
                // An older edit of the same highlight does not win.
                BackupHighlight(
                  range: _range,
                  progress: 0.1,
                  text: 'x',
                  note: 'stale',
                  color: HighlightColor.pink,
                  createdAt: existing.createdAt.toUtc(),
                  updatedAt: existing.createdAt.toUtc(),
                ),
              ],
            ),
          ],
        ),
      );

      expect(report.positionsRestored, 1);
      expect(report.highlightsUpdated, 0);
      final row = await b.document(id);
      expect(row.isFavorite, isTrue);
      expect(row.readingStatus, ReadingStatus.reading);
      expect(row.progress, 0.2);
      expect(
        await b.progress.loadPosition(id),
        const EpubLocator(href: 'ch1.xhtml', offset: 7),
      );
      final kept = (await b.annotationRows()).single;
      expect(kept.id, highlightId);
      expect(kept.note, 'kept');
    },
  );

  test('documents missing from the library are reported by title', () async {
    await b.add(1);
    final report = await b.backup.restore(
      ReadingBackup(
        createdAt: DateTime.utc(2026),
        documents: [
          BackupDocument(contentHash: hashOf(1), title: 'Book 1'),
          BackupDocument(
            contentHash: hashOf(7),
            title: 'Elsewhere',
            favorite: true,
          ),
        ],
      ),
    );
    expect(report.matchedBooks, 1);
    expect(report.updatedBooks, 0);
    expect(report.missingTitles, ['Elsewhere']);
  });

  test('positions and highlights of another format are skipped', () async {
    final id = await b.add(1, format: DocumentFormat.pdf);
    final pdfArea = PdfAreaRange([
      PdfPageArea(pageIndex: 0, rects: const [NormalizedRect(0, 1, 1, 0.9)]),
    ]);
    final report = await b.backup.restore(
      ReadingBackup(
        createdAt: DateTime.utc(2026),
        skippedEntries: 2,
        documents: [
          BackupDocument(
            contentHash: hashOf(1),
            title: 'Book 1',
            position: BackupPosition(
              locator: const TextLocator(5),
              updatedAt: DateTime.utc(2026),
            ),
            bookmarks: [
              BackupBookmark(
                locator: const EpubLocator(href: 'a', offset: 0),
                progress: 0,
                createdAt: DateTime.utc(2026),
              ),
              BackupBookmark(
                locator: const PdfLocator(3),
                progress: 0.5,
                createdAt: DateTime.utc(2026),
              ),
            ],
            highlights: [
              for (final range in [_range, pdfArea])
                BackupHighlight(
                  range: range,
                  progress: 0,
                  text: 'x',
                  color: HighlightColor.yellow,
                  createdAt: DateTime.utc(2026),
                  updatedAt: DateTime.utc(2026),
                ),
            ],
          ),
        ],
      ),
    );
    expect(report.skippedEntries, 2 + 3);
    expect(report.bookmarksAdded, 1);
    expect(report.highlightsAdded, 1);
    expect(await b.progress.loadPosition(id), isNull);
    expect(
      AnnotationRange.decode((await b.annotationRows()).single.range),
      pdfArea,
    );
  });

  test('collections are matched by name, ignoring case', () async {
    final id = await b.add(1);
    final existing = await b.collections.createCollection('to read');
    final report = await b.backup.restore(
      ReadingBackup(
        createdAt: DateTime.utc(2026),
        collections: [
          BackupCollection(name: 'To Read', createdAt: DateTime.utc(2025)),
        ],
        documents: [
          BackupDocument(
            contentHash: hashOf(1),
            title: 'Book 1',
            collections: const ['TO READ', 'Later'],
          ),
        ],
      ),
    );
    expect(report.collectionsCreated, 1);
    expect(report.collectionEntriesAdded, 2);
    final names = (await b.db.select(b.db.collections).get()).map(
      (c) => c.name,
    );
    expect(names, unorderedEquals(['to read', 'Later']));
    final memberships = await b.db.select(b.db.documentCollections).get();
    expect(memberships.map((m) => m.documentId), [id, id]);
    expect(memberships.map((m) => m.collectionId), contains(existing));
  });

  test('a failed restore leaves the library unchanged', () async {
    final failing = TestLibrary(settings: _FailingSettings.new);
    addTearDown(failing.db.close);
    await fillLibrary(a);
    final id = await failing.add(1);
    final before = await failing.document(id);

    await expectLater(
      failing.backup.restore(throughFile(await a.backup.create())),
      throwsStateError,
    );
    expect(await failing.document(id), before);
    expect(await failing.count(failing.db.bookmarks), 0);
    expect(await failing.count(failing.db.annotations), 0);
    expect(await failing.count(failing.db.readingPositions), 0);
    expect(await failing.count(failing.db.collections), 0);
  });

  test('only theme and reading settings are restored, validated', () async {
    final backup = ReadingBackup(
      createdAt: DateTime.utc(2026),
      settings: const {
        'app.theme': 'dark',
        'reader.fontSize': '99',
        'reader.font': 'comic',
        'library.layout': 'list',
      },
    );
    final report = await b.backup.restore(backup);
    expect(report.settingsRestored, isTrue);

    final stored = await b.settings.load();
    expect(stored.appSettings.themePreference, ThemePreference.dark);
    expect(stored.readerPreferences.fontSize, ReaderPreferences.maxFontSize);
    expect(stored.readerPreferences.font, ReaderFont.serif);
    expect(stored.libraryLayout, LibraryLayout.grid);

    expect((await b.backup.restore(backup)).settingsRestored, isFalse);
  });
}

class _FailingSettings extends SettingsRepository {
  _FailingSettings(super.db);

  @override
  Future<bool> restoreValues(Map<String, String> values) async =>
      throw StateError('failed');
}
