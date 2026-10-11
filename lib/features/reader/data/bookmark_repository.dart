import 'package:drift/drift.dart';

import '../../../core/utils/text_cleanup.dart';
import '../../../data/database/app_database.dart';
import '../domain/bookmark.dart';
import '../domain/locator.dart';

class BookmarkRepository {
  BookmarkRepository(this._db, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  static const maxExcerptLength = 160;

  final AppDatabase _db;
  final DateTime Function() _clock;

  /// Watches a document's bookmarks in reading order. Rows whose location
  /// can no longer be understood are skipped rather than failing the list.
  Stream<List<Bookmark>> watchBookmarks(int documentId) {
    final query = _db.select(_db.bookmarks)
      ..where((b) => b.documentId.equals(documentId))
      ..orderBy([
        (b) => OrderingTerm.asc(b.progress),
        (b) => OrderingTerm.asc(b.createdAt),
      ]);
    return query.watch().map(
      (rows) => [
        for (final row in rows)
          if (Locator.decode(row.locator) case final locator?)
            Bookmark(
              id: row.id,
              documentId: row.documentId,
              locator: locator,
              progress: row.progress,
              excerpt: row.excerpt,
              label: row.label,
              createdAt: row.createdAt,
            ),
      ],
    );
  }

  Future<int> addBookmark({
    required int documentId,
    required Locator locator,
    required double progress,
    String? excerpt,
  }) {
    return _db.bookmarks.insertOne(
      BookmarksCompanion.insert(
        documentId: documentId,
        locator: locator.encode(),
        progress: progress.clamp(0.0, 1.0),
        excerpt: Value(cleanMetadataText(excerpt, maxLength: maxExcerptLength)),
        createdAt: _clock(),
      ),
    );
  }

  Future<void> deleteBookmark(int id) async {
    await _db.bookmarks.deleteWhere((b) => b.id.equals(id));
  }
}
