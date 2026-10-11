import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/data/database/app_database.dart';
import 'package:lectern/features/library/data/library_repository.dart';

import '../../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late LibraryRepository library;

  setUp(() {
    db = createTestDatabase();
    library = LibraryRepository(db, clock: FakeClock().call);
  });

  tearDown(() => db.close());

  Future<int> insertBookmark(int documentId, {double progress = 0.5}) {
    return db.bookmarks.insertOne(
      BookmarksCompanion.insert(
        documentId: documentId,
        locator: '{"t":"txt","offset":10}',
        progress: progress,
        createdAt: DateTime.utc(2026),
      ),
    );
  }

  test('foreign keys are enforced', () async {
    final result = await db.customSelect('PRAGMA foreign_keys').getSingle();
    expect(result.data.values.single, 1);

    // A bookmark for a document that does not exist is rejected.
    await expectLater(
      () => insertBookmark(999),
      throwsA(isA<SqliteException>()),
    );
  });

  test('expected indexes exist', () async {
    final rows = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'index' "
          "AND name LIKE 'idx_%'",
        )
        .get();
    final names = rows.map((r) => r.read<String>('name')).toSet();
    expect(
      names,
      containsAll(<String>{
        'idx_documents_added_at',
        'idx_documents_last_opened_at',
        'idx_documents_status',
        'idx_documents_favorite',
        'idx_documents_title',
        'idx_collections_name',
        'idx_document_collections_collection',
        'idx_bookmarks_document',
        'idx_annotations_document',
        'idx_reading_sessions_document',
        'idx_reading_sessions_started_at',
      }),
    );
  });

  test('content hash must be unique', () async {
    await addTestDocument(library, title: 'A', contentHash: 'same');
    await expectLater(
      () => addTestDocument(library, title: 'B', contentHash: 'same'),
      throwsA(isA<SqliteException>()),
    );
  });

  test('progress outside [0, 1] is rejected', () async {
    final id = await addTestDocument(library);
    await expectLater(
      () => (db.update(db.documents)..where((d) => d.id.equals(id))).write(
        const DocumentsCompanion(progress: Value(1.5)),
      ),
      throwsA(isA<SqliteException>()),
    );
    await expectLater(
      () => insertBookmark(id, progress: -0.1),
      throwsA(isA<SqliteException>()),
    );
  });

  test('a reading session cannot end before it starts', () async {
    final id = await addTestDocument(library);
    await expectLater(
      () => db.readingSessions.insertOne(
        ReadingSessionsCompanion.insert(
          documentId: id,
          startedAt: DateTime.utc(2026, 1, 2),
          endedAt: DateTime.utc(2026, 1, 1),
          startProgress: 0,
          endProgress: 0.1,
        ),
      ),
      throwsA(isA<SqliteException>()),
    );
  });

  test('deleting a document cascades to its dependent rows', () async {
    final keep = await addTestDocument(library, title: 'Keep');
    final remove = await addTestDocument(library, title: 'Remove');
    final now = DateTime.utc(2026);

    for (final id in [keep, remove]) {
      await insertBookmark(id);
      await db.readingPositions.insertOne(
        ReadingPositionsCompanion.insert(
          documentId: Value(id),
          locator: '{}',
          updatedAt: now,
        ),
      );
      await db.annotations.insertOne(
        AnnotationsCompanion.insert(
          documentId: id,
          range: '{}',
          progress: 0.2,
          selectedText: 'text',
          color: 0xFFFFEB3B,
          createdAt: now,
          updatedAt: now,
        ),
      );
      await db.readingSessions.insertOne(
        ReadingSessionsCompanion.insert(
          documentId: id,
          startedAt: now,
          endedAt: now.add(const Duration(minutes: 5)),
          startProgress: 0,
          endProgress: 0.1,
        ),
      );
    }

    await library.removeDocuments([remove]);

    Future<List<int>> documentIdsIn(String table) async {
      final rows = await db
          .customSelect('SELECT document_id FROM $table')
          .get();
      return rows.map((r) => r.read<int>('document_id')).toList();
    }

    for (final table in [
      'bookmarks',
      'reading_positions',
      'annotations',
      'reading_sessions',
    ]) {
      expect(await documentIdsIn(table), [keep], reason: table);
    }
  });
}
