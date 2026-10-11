import 'package:drift/drift.dart';

import '../../../data/database/app_database.dart';
import '../domain/library_document.dart';
import '../domain/library_query.dart';
import '../domain/reading_status.dart';

/// Reads and updates library metadata. Knows nothing about files on disk;
/// copying and deleting library files is the import/storage layer's job.
class LibraryRepository {
  LibraryRepository(this._db, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final DateTime Function() _clock;

  $DocumentsTable get _docs => _db.documents;

  /// Watches documents matching [query]. Emits a new list whenever the
  /// underlying rows change.
  Stream<List<LibraryDocument>> watchDocuments(LibraryQuery query) {
    final select = _listSelect();

    final conditions = <Expression<bool>>[];
    // Every word must appear somewhere in title, author or file name, in any
    // order ("tolstoy karenina" finds "Anna Karenina" by Leo Tolstoy).
    final words = normalizeSearchText(query.search).split(' ');
    for (final word in words.where((w) => w.isNotEmpty)) {
      conditions.add(
        _docs.searchKey.like('%${_escapeLike(word)}%', escapeChar: r'\'),
      );
    }
    if (query.favoritesOnly) {
      conditions.add(_docs.isFavorite.equals(true));
    }
    if (query.status case final status?) {
      conditions.add(_docs.readingStatus.equalsValue(status));
    }
    if (query.collectionId case final collectionId?) {
      final members = _db.documentCollections;
      conditions.add(
        _docs.id.isInQuery(
          _db.selectOnly(members)
            ..addColumns([members.documentId])
            ..where(members.collectionId.equals(collectionId)),
        ),
      );
    }
    if (conditions.isNotEmpty) {
      select.where(Expression.and(conditions));
    }

    select.orderBy(_ordering(query.sort));
    return _watchList(select);
  }

  /// Documents the user has started but not finished, most recent first.
  Stream<List<LibraryDocument>> watchContinueReading({int limit = 10}) {
    final select = _listSelect()
      ..where(
        _docs.readingStatus.equalsValue(ReadingStatus.reading) &
            _docs.lastOpenedAt.isNotNull(),
      )
      ..orderBy([
        OrderingTerm.desc(_docs.lastOpenedAt),
        OrderingTerm.desc(_docs.id),
      ])
      ..limit(limit);
    return _watchList(select);
  }

  /// Most recently imported documents.
  Stream<List<LibraryDocument>> watchRecentlyAdded({int limit = 10}) {
    final select = _listSelect()
      ..orderBy([OrderingTerm.desc(_docs.addedAt), OrderingTerm.desc(_docs.id)])
      ..limit(limit);
    return _watchList(select);
  }

  /// Most recently opened documents, regardless of reading status.
  Stream<List<LibraryDocument>> watchRecentlyOpened({int limit = 10}) {
    final select = _listSelect()
      ..where(_docs.lastOpenedAt.isNotNull())
      ..orderBy([
        OrderingTerm.desc(_docs.lastOpenedAt),
        OrderingTerm.desc(_docs.id),
      ])
      ..limit(limit);
    return _watchList(select);
  }

  /// Total number of documents in the library.
  Stream<int> watchCount() {
    final count = countAll();
    final select = _db.selectOnly(_docs)..addColumns([count]);
    return select.map((row) => row.read(count) ?? 0).watchSingle();
  }

  /// Watches one document; emits null once it has been removed.
  Stream<LibraryDocument?> watchDocument(int id) {
    final select = _listSelect()..where(_docs.id.equals(id));
    return select.watchSingleOrNull().map(
      (row) => row == null ? null : _mapRow(row),
    );
  }

  /// Rarely needed, potentially large metadata, loaded separately from
  /// [LibraryDocument].
  Future<DocumentDetails?> getDetails(int id) async {
    final select = _db.selectOnly(_docs)
      ..addColumns([_docs.description, _docs.publisher, _docs.language])
      ..where(_docs.id.equals(id));
    final row = await select.getSingleOrNull();
    if (row == null) return null;
    return DocumentDetails(
      description: row.read(_docs.description),
      publisher: row.read(_docs.publisher),
      language: row.read(_docs.language),
    );
  }

  Future<LibraryDocument?> findById(int id) async {
    final select = _listSelect()..where(_docs.id.equals(id));
    final row = await select.getSingleOrNull();
    return row == null ? null : _mapRow(row);
  }

  /// Looks up a document by the SHA-256 of its contents.
  Future<LibraryDocument?> findByHash(String contentHash) async {
    final select = _listSelect()..where(_docs.contentHash.equals(contentHash));
    final row = await select.getSingleOrNull();
    return row == null ? null : _mapRow(row);
  }

  /// Registers a document and returns its id.
  ///
  /// Throws a database exception if a document with the same content hash
  /// already exists; callers should check [findByHash] first.
  Future<int> addDocument(NewDocument document) {
    final now = _clock();
    return _docs.insertOne(
      DocumentsCompanion.insert(
        title: document.title,
        author: Value(document.author),
        format: document.format,
        filePath: document.filePath,
        originalFileName: document.originalFileName,
        fileSize: document.fileSize,
        contentHash: document.contentHash,
        pageCount: Value(document.pageCount),
        coverPath: Value(document.coverPath),
        language: Value(document.language),
        publisher: Value(document.publisher),
        description: Value(document.description),
        searchKey: buildSearchKey(
          title: document.title,
          author: document.author,
          fileName: document.originalFileName,
        ),
        addedAt: now,
        updatedAt: now,
      ),
    );
  }

  Future<void> setFavorite(Iterable<int> ids, {required bool favorite}) {
    return _updateWhereIdIn(
      ids,
      DocumentsCompanion(isFavorite: Value(favorite)),
    );
  }

  Future<void> setStatus(Iterable<int> ids, ReadingStatus status) {
    return _updateWhereIdIn(
      ids,
      DocumentsCompanion(
        readingStatus: Value(status),
        // Marking a book finished fills the progress bar; resetting it to
        // unread clears it. "Reading" keeps whatever progress exists.
        progress: switch (status) {
          ReadingStatus.finished => const Value(1.0),
          ReadingStatus.unread => const Value(0.0),
          ReadingStatus.reading => const Value.absent(),
        },
      ),
    );
  }

  /// Records that a document was opened now. An unread document becomes
  /// "reading".
  Future<void> markOpened(int id) async {
    final now = _clock();
    await _db.transaction(() async {
      await (_db.update(_docs)..where((d) => d.id.equals(id))).write(
        DocumentsCompanion(lastOpenedAt: Value(now), updatedAt: Value(now)),
      );
      await (_db.update(_docs)..where(
            (d) =>
                d.id.equals(id) &
                d.readingStatus.equalsValue(ReadingStatus.unread),
          ))
          .write(
            const DocumentsCompanion(
              readingStatus: Value(ReadingStatus.reading),
            ),
          );
    });
  }

  /// Removes documents from the library and returns the removed rows so the
  /// caller can clean up the app's private copies.
  ///
  /// Bookmarks, annotations, positions, sessions and collection memberships
  /// are removed by cascading foreign keys. Collections themselves are kept.
  Future<List<LibraryDocument>> removeDocuments(Iterable<int> ids) {
    final idList = ids.toSet().toList();
    if (idList.isEmpty) return Future.value(const []);
    return _db.transaction(() async {
      final select = _listSelect()..where(_docs.id.isIn(idList));
      final removed = (await select.get()).map(_mapRow).toList();
      await (_db.delete(_docs)..where((d) => d.id.isIn(idList))).go();
      return removed;
    });
  }

  Future<void> _updateWhereIdIn(
    Iterable<int> ids,
    DocumentsCompanion changes,
  ) async {
    final idList = ids.toSet().toList();
    if (idList.isEmpty) return;
    await (_db.update(_docs)..where((d) => d.id.isIn(idList))).write(
      changes.copyWith(updatedAt: Value(_clock())),
    );
  }

  /// Selects only the columns needed by [LibraryDocument], leaving out
  /// large metadata such as the description.
  JoinedSelectStatement<$DocumentsTable, DocumentRow> _listSelect() {
    return _db.selectOnly(_docs)..addColumns([
      _docs.id,
      _docs.title,
      _docs.author,
      _docs.format,
      _docs.filePath,
      _docs.originalFileName,
      _docs.fileSize,
      _docs.contentHash,
      _docs.pageCount,
      _docs.coverPath,
      _docs.isFavorite,
      _docs.readingStatus,
      _docs.progress,
      _docs.addedAt,
      _docs.lastOpenedAt,
    ]);
  }

  Stream<List<LibraryDocument>> _watchList(
    JoinedSelectStatement<$DocumentsTable, DocumentRow> select,
  ) {
    return select.watch().map(
      (rows) => rows.map(_mapRow).toList(growable: false),
    );
  }

  LibraryDocument _mapRow(TypedResult row) {
    return LibraryDocument(
      id: row.read(_docs.id)!,
      title: row.read(_docs.title)!,
      author: row.read(_docs.author),
      format: row.readWithConverter(_docs.format)!,
      filePath: row.read(_docs.filePath)!,
      originalFileName: row.read(_docs.originalFileName)!,
      fileSize: row.read(_docs.fileSize)!,
      contentHash: row.read(_docs.contentHash)!,
      pageCount: row.read(_docs.pageCount),
      coverPath: row.read(_docs.coverPath),
      isFavorite: row.read(_docs.isFavorite)!,
      status: row.readWithConverter(_docs.readingStatus)!,
      progress: row.read(_docs.progress)!,
      addedAt: row.read(_docs.addedAt)!,
      lastOpenedAt: row.read(_docs.lastOpenedAt),
    );
  }

  List<OrderingTerm> _ordering(LibrarySort sort) {
    final titleNoCase = _docs.title.collate(Collate.noCase);
    return switch (sort) {
      LibrarySort.recentlyAdded => [
        OrderingTerm.desc(_docs.addedAt),
        OrderingTerm.desc(_docs.id),
      ],
      LibrarySort.recentlyOpened => [
        OrderingTerm.desc(_docs.lastOpenedAt, nulls: NullsOrder.last),
        OrderingTerm.desc(_docs.addedAt),
        OrderingTerm.desc(_docs.id),
      ],
      LibrarySort.title => [
        OrderingTerm.asc(titleNoCase),
        OrderingTerm.asc(_docs.id),
      ],
      LibrarySort.author => [
        OrderingTerm.asc(
          _docs.author.collate(Collate.noCase),
          nulls: NullsOrder.last,
        ),
        OrderingTerm.asc(titleNoCase),
        OrderingTerm.asc(_docs.id),
      ],
      LibrarySort.progress => [
        OrderingTerm.desc(_docs.progress),
        OrderingTerm.asc(titleNoCase),
        OrderingTerm.asc(_docs.id),
      ],
    };
  }
}

/// Normalises user-entered search text: trims, collapses whitespace and
/// lower-cases with Unicode-aware rules.
String normalizeSearchText(String input) {
  return input.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
}

/// Builds the value stored in the `search_key` column.
String buildSearchKey({
  required String title,
  required String fileName,
  String? author,
}) {
  return normalizeSearchText([title, ?author, fileName].join(' '));
}

String _escapeLike(String input) {
  return input
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');
}
