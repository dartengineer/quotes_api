import 'package:drift/drift.dart';

import '../../features/library/domain/document_format.dart';
import '../../features/library/domain/reading_status.dart';

/// A document registered in the library.
///
/// The file itself lives in app-private storage; [filePath] and [coverPath]
/// are stored relative to the app's library directory so the database stays
/// valid if the absolute data directory changes (e.g. app restore).
@DataClassName('DocumentRow')
@TableIndex(name: 'idx_documents_added_at', columns: {#addedAt})
@TableIndex(name: 'idx_documents_last_opened_at', columns: {#lastOpenedAt})
@TableIndex(name: 'idx_documents_status', columns: {#readingStatus})
@TableIndex(name: 'idx_documents_favorite', columns: {#isFavorite})
@TableIndex.sql(
  'CREATE INDEX idx_documents_title ON documents (title COLLATE NOCASE)',
)
class Documents extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get title => text().withLength(min: 1, max: 1024)();
  TextColumn get author => text().nullable()();
  TextColumn get format => textEnum<DocumentFormat>()();
  TextColumn get filePath => text()();
  TextColumn get originalFileName => text()();
  IntColumn get fileSize => integer()();

  /// SHA-256 of the file contents, used for duplicate detection.
  TextColumn get contentHash => text().unique()();
  IntColumn get pageCount => integer().nullable()();
  TextColumn get coverPath => text().nullable()();
  TextColumn get language => text().nullable()();
  TextColumn get publisher => text().nullable()();
  TextColumn get description => text().nullable()();

  /// Lower-cased title, author and file name, maintained by the repository.
  /// SQLite's `LIKE` only folds ASCII case, so search runs against this
  /// Unicode-lower-cased copy instead.
  TextColumn get searchKey => text()();
  BoolColumn get isFavorite => boolean().withDefault(const Constant(false))();
  TextColumn get readingStatus => textEnum<ReadingStatus>().withDefault(
    Constant(ReadingStatus.unread.name),
  )();

  /// Overall progress in `[0, 1]`, denormalised from the reading position for
  /// cheap sorting and display in lists.
  RealColumn get progress => real().withDefault(const Constant(0.0))();
  DateTimeColumn get addedAt => dateTime()();
  DateTimeColumn get lastOpenedAt => dateTime().nullable()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  List<String> get customConstraints => [
    'CHECK (file_size >= 0)',
    'CHECK (progress BETWEEN 0.0 AND 1.0)',
  ];
}

/// The last reading location of a document (at most one row per document).
///
/// [locator] is a format-specific JSON location that does not depend on font
/// size or screen layout.
@DataClassName('ReadingPositionRow')
class ReadingPositions extends Table {
  IntColumn get documentId =>
      integer().references(Documents, #id, onDelete: KeyAction.cascade)();
  TextColumn get locator => text()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {documentId};
}

/// A user-defined group of documents. Deleting a collection removes only the
/// memberships, never the documents.
@DataClassName('CollectionRow')
@TableIndex.sql(
  'CREATE UNIQUE INDEX idx_collections_name ON collections (name COLLATE NOCASE)',
)
class Collections extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().withLength(min: 1, max: 200)();
  DateTimeColumn get createdAt => dateTime()();
}

@DataClassName('DocumentCollectionRow')
@TableIndex(
  name: 'idx_document_collections_collection',
  columns: {#collectionId},
)
class DocumentCollections extends Table {
  IntColumn get documentId =>
      integer().references(Documents, #id, onDelete: KeyAction.cascade)();
  IntColumn get collectionId =>
      integer().references(Collections, #id, onDelete: KeyAction.cascade)();
  DateTimeColumn get addedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {documentId, collectionId};
}

@DataClassName('BookmarkRow')
@TableIndex(name: 'idx_bookmarks_document', columns: {#documentId})
class Bookmarks extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get documentId =>
      integer().references(Documents, #id, onDelete: KeyAction.cascade)();
  TextColumn get locator => text()();

  /// Position in `[0, 1]`, used to order bookmarks within a document.
  RealColumn get progress => real()();
  TextColumn get label => text().nullable()();

  /// Short text near the bookmark, shown in the bookmark list.
  TextColumn get excerpt => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  List<String> get customConstraints => [
    'CHECK (progress BETWEEN 0.0 AND 1.0)',
  ];
}

/// A highlighted text range, optionally with a note.
@DataClassName('AnnotationRow')
@TableIndex(name: 'idx_annotations_document', columns: {#documentId})
class Annotations extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get documentId =>
      integer().references(Documents, #id, onDelete: KeyAction.cascade)();

  /// Format-specific JSON describing the start and end of the range.
  TextColumn get range => text()();
  RealColumn get progress => real()();
  TextColumn get selectedText => text()();
  TextColumn get note => text().nullable()();

  /// ARGB colour of the highlight.
  IntColumn get color => integer()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  List<String> get customConstraints => [
    'CHECK (progress BETWEEN 0.0 AND 1.0)',
  ];
}

/// One continuous period of reading, used for history and statistics.
@DataClassName('ReadingSessionRow')
@TableIndex(name: 'idx_reading_sessions_document', columns: {#documentId})
@TableIndex(name: 'idx_reading_sessions_started_at', columns: {#startedAt})
class ReadingSessions extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get documentId =>
      integer().references(Documents, #id, onDelete: KeyAction.cascade)();
  DateTimeColumn get startedAt => dateTime()();
  DateTimeColumn get endedAt => dateTime()();
  RealColumn get startProgress => real()();
  RealColumn get endProgress => real()();

  @override
  List<String> get customConstraints => [
    'CHECK (start_progress BETWEEN 0.0 AND 1.0)',
    'CHECK (end_progress BETWEEN 0.0 AND 1.0)',
    'CHECK (ended_at >= started_at)',
  ];
}

/// Simple key-value store for user preferences.
@DataClassName('PreferenceRow')
class Preferences extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}
