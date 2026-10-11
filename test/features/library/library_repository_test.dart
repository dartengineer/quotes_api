import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/data/database/app_database.dart';
import 'package:lectern/features/collections/data/collection_repository.dart';
import 'package:lectern/features/library/data/library_repository.dart';
import 'package:lectern/features/library/domain/document_format.dart';
import 'package:lectern/features/library/domain/library_document.dart';
import 'package:lectern/features/library/domain/library_query.dart';
import 'package:lectern/features/library/domain/reading_status.dart';

import '../../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late LibraryRepository library;

  setUp(() {
    db = createTestDatabase();
    library = LibraryRepository(db, clock: FakeClock().call);
  });

  tearDown(() => db.close());

  Future<List<String>> titles([LibraryQuery query = const LibraryQuery()]) {
    return library
        .watchDocuments(query)
        .first
        .then((docs) => docs.map((d) => d.title).toList());
  }

  group('addDocument / find', () {
    test('stores all list fields and finds by id and hash', () async {
      final id = await library.addDocument(
        const NewDocument(
          title: 'War and Peace',
          author: 'Leo Tolstoy',
          format: DocumentFormat.epub,
          filePath: 'abc.epub',
          originalFileName: 'war-and-peace.epub',
          fileSize: 2048,
          contentHash: 'abc',
          pageCount: 1225,
        ),
      );

      final byId = await library.findById(id);
      expect(byId, isNotNull);
      expect(byId!.title, 'War and Peace');
      expect(byId.author, 'Leo Tolstoy');
      expect(byId.format, DocumentFormat.epub);
      expect(byId.fileSize, 2048);
      expect(byId.pageCount, 1225);
      expect(byId.status, ReadingStatus.unread);
      expect(byId.progress, 0);
      expect(byId.isFavorite, isFalse);
      expect(byId.lastOpenedAt, isNull);

      expect(await library.findByHash('abc'), byId);
      expect(await library.findByHash('missing'), isNull);
      expect(await library.findById(id + 100), isNull);
    });
  });

  group('search', () {
    setUp(() async {
      await addTestDocument(library, title: 'Anna Karenina', author: 'Tolstoy');
      await addTestDocument(library, title: 'Émile', author: 'Rousseau');
      await addTestDocument(
        library,
        title: 'Notes',
        fileName: 'meeting_notes_100%.txt',
        format: DocumentFormat.txt,
      );
    });

    test('matches title, author and file name, ignoring case', () async {
      expect(await titles(const LibraryQuery(search: 'karenina')), [
        'Anna Karenina',
      ]);
      expect(await titles(const LibraryQuery(search: 'TOLSTOY')), [
        'Anna Karenina',
      ]);
      expect(await titles(const LibraryQuery(search: 'meeting')), ['Notes']);
    });

    test('matches every word independently, in any order', () async {
      expect(await titles(const LibraryQuery(search: 'tolstoy anna')), [
        'Anna Karenina',
      ]);
      expect(
        await titles(const LibraryQuery(search: 'anna rousseau')),
        isEmpty,
      );
    });

    test('folds case for non-ASCII letters', () async {
      expect(await titles(const LibraryQuery(search: 'émile')), ['Émile']);
      expect(await titles(const LibraryQuery(search: 'ÉMILE')), ['Émile']);
    });

    test('treats LIKE wildcards literally', () async {
      expect(await titles(const LibraryQuery(search: '100%')), ['Notes']);
      expect(await titles(const LibraryQuery(search: '%')), ['Notes']);
      expect(await titles(const LibraryQuery(search: '_')), ['Notes']);
    });

    test('blank search returns everything', () async {
      expect(await titles(const LibraryQuery(search: '   ')), hasLength(3));
    });
  });

  group('sorting', () {
    late int zebra;
    late int apple;
    late int mango;

    setUp(() async {
      zebra = await addTestDocument(library, title: 'zebra', author: 'Cole');
      apple = await addTestDocument(library, title: 'Apple');
      mango = await addTestDocument(library, title: 'mango', author: 'adams');
    });

    test('recently added is newest first', () async {
      expect(await titles(), ['mango', 'Apple', 'zebra']);
    });

    test('title is case-insensitive A-Z', () async {
      expect(await titles(const LibraryQuery(sort: LibrarySort.title)), [
        'Apple',
        'mango',
        'zebra',
      ]);
    });

    test('author is case-insensitive with unknown authors last', () async {
      expect(await titles(const LibraryQuery(sort: LibrarySort.author)), [
        'mango',
        'zebra',
        'Apple',
      ]);
    });

    test('recently opened puts never-opened documents last', () async {
      await library.markOpened(apple);
      await library.markOpened(zebra);
      expect(
        await titles(const LibraryQuery(sort: LibrarySort.recentlyOpened)),
        ['zebra', 'Apple', 'mango'],
      );
    });

    test('progress is highest first', () async {
      await library.setStatus([mango], ReadingStatus.finished);
      expect(
        (await titles(const LibraryQuery(sort: LibrarySort.progress))).first,
        'mango',
      );
    });
  });

  group('filters', () {
    test('favourites, status and collection filters combine', () async {
      final a = await addTestDocument(library, title: 'A');
      final b = await addTestDocument(library, title: 'B');
      await addTestDocument(library, title: 'C');

      await library.setFavorite([a, b], favorite: true);
      await library.setStatus([b], ReadingStatus.finished);

      expect(await titles(const LibraryQuery(favoritesOnly: true)), ['B', 'A']);
      expect(
        await titles(
          const LibraryQuery(
            favoritesOnly: true,
            status: ReadingStatus.finished,
          ),
        ),
        ['B'],
      );

      final collections = CollectionRepository(db);
      final shelf = await collections.createCollection('Shelf');
      await collections.addDocuments(shelf, [a]);
      expect(await titles(LibraryQuery(collectionId: shelf)), ['A']);
    });
  });

  group('status and opening', () {
    test(
      'an unknown page count is filled in once, never overwritten',
      () async {
        final id = await addTestDocument(library);
        expect((await library.findById(id))!.pageCount, isNull);
        await library.recordPageCount(id, 12);
        expect((await library.findById(id))!.pageCount, 12);
        await library.recordPageCount(id, 99);
        expect((await library.findById(id))!.pageCount, 12);
      },
    );

    test('opening an unread document marks it reading', () async {
      final id = await addTestDocument(library);
      await library.markOpened(id);
      final doc = (await library.findById(id))!;
      expect(doc.status, ReadingStatus.reading);
      expect(doc.lastOpenedAt, isNotNull);
    });

    test('opening a finished document keeps it finished', () async {
      final id = await addTestDocument(library);
      await library.setStatus([id], ReadingStatus.finished);
      await library.markOpened(id);
      expect((await library.findById(id))!.status, ReadingStatus.finished);
    });

    test('finished fills progress and unread clears it', () async {
      final id = await addTestDocument(library);
      await library.setStatus([id], ReadingStatus.finished);
      expect((await library.findById(id))!.progress, 1.0);
      await library.setStatus([id], ReadingStatus.unread);
      expect((await library.findById(id))!.progress, 0.0);
    });
  });

  group('home sections', () {
    test('continue reading lists only started documents', () async {
      final unread = await addTestDocument(library, title: 'Unread');
      final reading = await addTestDocument(library, title: 'Reading');
      final finished = await addTestDocument(library, title: 'Finished');
      await library.markOpened(reading);
      await library.markOpened(finished);
      await library.setStatus([finished], ReadingStatus.finished);

      final continueReading = await library.watchContinueReading().first;
      expect(continueReading.map((d) => d.title), ['Reading']);

      final opened = await library.watchRecentlyOpened().first;
      expect(opened.map((d) => d.title), ['Finished', 'Reading']);

      final added = await library.watchRecentlyAdded(limit: 2).first;
      expect(added.map((d) => d.title), ['Finished', 'Reading']);
      expect(added.any((d) => d.id == unread), isFalse);
    });

    test('count updates when documents are added and removed', () async {
      final counts = <int>[];
      final subscription = library.watchCount().listen(counts.add);
      await pumpEventQueue();
      final id = await addTestDocument(library);
      await pumpEventQueue();
      await library.removeDocuments([id]);
      await pumpEventQueue();
      await subscription.cancel();
      expect(counts, [0, 1, 0]);
    });
  });

  group('removeDocuments', () {
    test('returns removed rows and keeps collections', () async {
      final id = await addTestDocument(library, title: 'Gone');
      final collections = CollectionRepository(db);
      final shelf = await collections.createCollection('Shelf');
      await collections.addDocuments(shelf, [id]);

      final removed = await library.removeDocuments([id, id]);
      expect(removed.map((d) => d.title), ['Gone']);
      expect(await library.findById(id), isNull);

      final remaining = await collections.watchCollections().first;
      expect(remaining.single.name, 'Shelf');
      expect(remaining.single.documentCount, 0);
    });

    test('empty input is a no-op', () async {
      expect(await library.removeDocuments(const []), isEmpty);
    });
  });

  test('buildSearchKey normalises whitespace and case', () {
    expect(
      buildSearchKey(
        title: '  The   Hobbit ',
        author: 'J.R.R. TOLKIEN',
        fileName: 'h.epub',
      ),
      'the hobbit j.r.r. tolkien h.epub',
    );
  });
}
