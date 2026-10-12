import 'dart:math' as math;

import 'package:drift/drift.dart';

import '../../../data/database/app_database.dart';
import '../../library/domain/document_format.dart';
import '../../library/domain/reading_status.dart';
import '../../reader/domain/annotation.dart';
import '../../reader/domain/locator.dart';
import '../../settings/data/settings_repository.dart';
import '../domain/reading_backup.dart';

/// Creates reading-data backups from the database and merges them back in.
///
/// Restoring only ever adds to the library or moves it forward; it never
/// deletes anything, and restoring the same backup twice changes nothing
/// the second time:
/// - Books are matched by the SHA-256 of their file; data for books that
///   are not in the library is reported, not kept.
/// - A book stays a favourite if either side says so, and keeps the
///   further reading status (not started < reading < finished) and the
///   later "last opened" date.
/// - The reading position (with the progress shown in lists) is taken from
///   the backup only if it was saved later than the library's.
/// - Bookmarks and highlights are added unless the library already has one
///   at the same place, created at the same moment. For such a highlight,
///   a note or colour the backup changed more recently is taken over.
/// - Reading sessions are added unless one started at the same moment.
/// - Collections are created by name if missing (ignoring case), and books
///   added to them.
/// - Theme and reading settings in the backup replace the current ones.
class ReadingDataBackup {
  ReadingDataBackup(this._db, this._settings, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final SettingsRepository _settings;
  final DateTime Function() _clock;

  /// Collects the reading data of every book that has some (books never
  /// opened or marked are left out), all collections and the settings.
  Future<ReadingBackup> create() => _db.transaction(() async {
    final documents = await _loadDocuments(_db);
    final positions = {
      for (final p in await _db.select(_db.readingPositions).get())
        p.documentId: p,
    };
    final bookmarks = _byDocument(
      await _ordered(_db.bookmarks, (b) => b.id),
      (b) => b.documentId,
    );
    final annotations = _byDocument(
      await _ordered(_db.annotations, (a) => a.id),
      (a) => a.documentId,
    );
    final sessions = _byDocument(
      await _ordered(_db.readingSessions, (s) => s.id),
      (s) => s.documentId,
    );
    final collections = await _ordered(_db.collections, (c) => c.id);
    final collectionNames = {for (final c in collections) c.id: c.name};
    final memberships = _byDocument(
      await _db.select(_db.documentCollections).get(),
      (m) => m.documentId,
    );

    return ReadingBackup(
      createdAt: _utc(_clock()),
      settings: await _settings.backupValues(),
      collections: [
        for (final c in collections)
          BackupCollection(name: c.name, createdAt: _utc(c.createdAt)),
      ],
      documents: [
        for (final d in documents)
          ?_backUpDocument(
            d,
            position: positions[d.id],
            bookmarks: bookmarks[d.id] ?? const [],
            annotations: annotations[d.id] ?? const [],
            sessions: sessions[d.id] ?? const [],
            collections: [
              for (final m
                  in memberships[d.id] ?? const <DocumentCollectionRow>[])
                ?collectionNames[m.collectionId],
            ],
          ),
      ],
    );
  });

  BackupDocument? _backUpDocument(
    _DocumentSummary d, {
    required ReadingPositionRow? position,
    required List<BookmarkRow> bookmarks,
    required List<AnnotationRow> annotations,
    required List<ReadingSessionRow> sessions,
    required List<String> collections,
  }) {
    final locator = Locator.decode(position?.locator);
    final backup = BackupDocument(
      contentHash: d.hash,
      title: d.title,
      status: d.status,
      favorite: d.favorite,
      progress: d.progress,
      lastOpenedAt: d.lastOpenedAt == null ? null : _utc(d.lastOpenedAt!),
      position: locator == null
          ? null
          : BackupPosition(
              locator: locator,
              updatedAt: _utc(position!.updatedAt),
            ),
      collections: collections,
      // Rows the app can no longer read could not be restored either.
      bookmarks: [
        for (final b in bookmarks)
          if (Locator.decode(b.locator) case final locator?)
            BackupBookmark(
              locator: locator,
              progress: b.progress,
              label: b.label,
              excerpt: b.excerpt,
              createdAt: _utc(b.createdAt),
            ),
      ],
      highlights: [
        for (final a in annotations)
          if (AnnotationRange.decode(a.range) case final range?)
            BackupHighlight(
              range: range,
              progress: a.progress,
              text: a.selectedText,
              note: a.note,
              color: HighlightColor.fromArgb(a.color),
              createdAt: _utc(a.createdAt),
              updatedAt: _utc(a.updatedAt),
            ),
      ],
      sessions: [
        for (final s in sessions)
          BackupSession(
            startedAt: _utc(s.startedAt),
            endedAt: _utc(s.endedAt),
            startProgress: s.startProgress,
            endProgress: s.endProgress,
          ),
      ],
    );
    final empty =
        backup.status == ReadingStatus.unread &&
        !backup.favorite &&
        backup.progress == 0 &&
        backup.lastOpenedAt == null &&
        backup.position == null &&
        backup.collections.isEmpty &&
        backup.bookmarks.isEmpty &&
        backup.highlights.isEmpty &&
        backup.sessions.isEmpty;
    return empty ? null : backup;
  }

  /// Merges [backup] into the library (see the class documentation), in
  /// one transaction: if anything fails, nothing is changed.
  Future<RestoreReport> restore(ReadingBackup backup) =>
      _db.transaction(() async {
        final restore = _Restore(_db, now: _clock());
        await restore.load();
        for (final collection in backup.collections) {
          await restore.collectionNamed(collection.name, collection.createdAt);
        }
        for (final document in backup.documents) {
          await restore.apply(document);
        }
        await restore.write();
        final settingsRestored = await _settings.restoreValues(backup.settings);
        return restore.report(
          settingsRestored: settingsRestored,
          skippedInFile: backup.skippedEntries,
        );
      });

  Future<List<R>> _ordered<T extends Table, R>(
    TableInfo<T, R> table,
    Expression<int> Function(T table) id,
  ) {
    return (_db.select(table)..orderBy([(t) => OrderingTerm.asc(id(t))])).get();
  }
}

Future<List<_DocumentSummary>> _loadDocuments(AppDatabase db) async {
  final d = db.documents;
  final query = db.selectOnly(d)
    ..addColumns([
      d.id,
      d.contentHash,
      d.title,
      d.format,
      d.isFavorite,
      d.readingStatus,
      d.progress,
      d.lastOpenedAt,
    ])
    ..orderBy([OrderingTerm.asc(d.id)]);
  return [
    for (final row in await query.get())
      (
        id: row.read(d.id)!,
        hash: row.read(d.contentHash)!,
        title: row.read(d.title)!,
        format: row.readWithConverter<DocumentFormat, String>(d.format)!,
        favorite: row.read(d.isFavorite)!,
        status: row.readWithConverter<ReadingStatus, String>(d.readingStatus)!,
        progress: row.read(d.progress)!,
        lastOpenedAt: row.read(d.lastOpenedAt),
      ),
  ];
}

typedef _DocumentSummary = ({
  int id,
  String hash,
  String title,
  DocumentFormat format,
  bool favorite,
  ReadingStatus status,
  double progress,
  DateTime? lastOpenedAt,
});

/// The state of one restore: what the library has, what to write, and
/// counts for the report.
class _Restore {
  _Restore(this._db, {required this.now});

  final AppDatabase _db;
  final DateTime now;

  late final Map<String, _DocumentSummary> _documents;
  late final Map<int, ReadingPositionRow> _positions;
  late final Map<int, Set<String>> _bookmarkKeys;

  /// Existing highlights by key; null for those added by this restore.
  late final Map<int, Map<String, AnnotationRow?>> _annotations;
  late final Map<int, Set<int>> _sessionStarts;
  late final Map<int, Set<int>> _memberships;
  late final Map<String, int> _collectionIds;

  final _positionWrites = <ReadingPositionsCompanion>[];
  final _documentUpdates = <(int, DocumentsCompanion)>[];
  final _bookmarkInserts = <BookmarksCompanion>[];
  final _annotationInserts = <AnnotationsCompanion>[];
  final _annotationUpdates = <(int, AnnotationsCompanion)>[];
  final _sessionInserts = <ReadingSessionsCompanion>[];
  final _membershipInserts = <DocumentCollectionsCompanion>[];

  var _matched = 0;
  var _updated = 0;
  final _missing = <String>[];
  var _positionsRestored = 0;
  var _bookmarksAdded = 0;
  var _highlightsAdded = 0;
  var _highlightsUpdated = 0;
  var _sessionsAdded = 0;
  var _collectionsCreated = 0;
  var _entriesAdded = 0;
  var _skipped = 0;

  Future<void> load() async {
    _documents = {for (final d in await _loadDocuments(_db)) d.hash: d};
    _positions = {
      for (final p in await _db.select(_db.readingPositions).get())
        p.documentId: p,
    };
    _bookmarkKeys = {};
    for (final b in await _db.select(_db.bookmarks).get()) {
      final locator = Locator.decode(b.locator)?.encode() ?? b.locator;
      _bookmarkKeys
          .putIfAbsent(b.documentId, () => {})
          .add(_key(locator, b.createdAt));
    }
    _annotations = {};
    for (final a in await _db.select(_db.annotations).get()) {
      final range = AnnotationRange.decode(a.range)?.encode() ?? a.range;
      _annotations.putIfAbsent(
        a.documentId,
        () => {},
      )[_key(range, a.createdAt)] = a;
    }
    _sessionStarts = {};
    for (final s in await _db.select(_db.readingSessions).get()) {
      _sessionStarts
          .putIfAbsent(s.documentId, () => {})
          .add(_seconds(s.startedAt));
    }
    _memberships = {};
    for (final m in await _db.select(_db.documentCollections).get()) {
      _memberships.putIfAbsent(m.documentId, () => {}).add(m.collectionId);
    }
    _collectionIds = {
      for (final c in await _db.select(_db.collections).get())
        c.name.toLowerCase(): c.id,
    };
  }

  /// The id of the collection called [name] (ignoring case), created if
  /// there is none.
  Future<int> collectionNamed(String name, DateTime createdAt) async {
    final key = name.toLowerCase();
    if (_collectionIds[key] case final id?) return id;
    final id = await _db.collections.insertOne(
      CollectionsCompanion.insert(name: name, createdAt: createdAt),
    );
    _collectionsCreated++;
    return _collectionIds[key] = id;
  }

  Future<void> apply(BackupDocument backup) async {
    final doc = _documents[backup.contentHash];
    if (doc == null) {
      _missing.add(backup.title);
      return;
    }
    _matched++;
    final id = doc.id;
    var changed = false;

    var progress = doc.progress;
    if (backup.position case final position?) {
      final current = _positions[id];
      if (!_fits(position.locator, doc.format)) {
        _skipped++;
      } else if (current == null ||
          position.updatedAt.isAfter(current.updatedAt)) {
        _positionWrites.add(
          ReadingPositionsCompanion.insert(
            documentId: Value(id),
            locator: position.locator.encode(),
            updatedAt: position.updatedAt,
          ),
        );
        progress = backup.progress;
        _positionsRestored++;
        changed = true;
      }
    }

    final favorite = doc.favorite || backup.favorite;
    final status =
        ReadingStatus.values[math.max(doc.status.index, backup.status.index)];
    final lastOpenedAt = _later(doc.lastOpenedAt, backup.lastOpenedAt);
    // A status taken from the backup brings at least its progress (a
    // finished book shows a full bar).
    if (status != doc.status) progress = math.max(progress, backup.progress);
    if (favorite != doc.favorite ||
        status != doc.status ||
        progress != doc.progress ||
        !_sameMoment(lastOpenedAt, doc.lastOpenedAt)) {
      _documentUpdates.add((
        id,
        DocumentsCompanion(
          isFavorite: Value(favorite),
          readingStatus: Value(status),
          progress: Value(progress),
          lastOpenedAt: Value(lastOpenedAt),
          updatedAt: Value(now),
        ),
      ));
      changed = true;
    }

    final bookmarkKeys = _bookmarkKeys.putIfAbsent(id, () => {});
    for (final b in backup.bookmarks) {
      if (!_fits(b.locator, doc.format)) {
        _skipped++;
        continue;
      }
      final locator = b.locator.encode();
      if (!bookmarkKeys.add(_key(locator, b.createdAt))) continue;
      _bookmarkInserts.add(
        BookmarksCompanion.insert(
          documentId: id,
          locator: locator,
          progress: b.progress,
          label: Value(b.label),
          excerpt: Value(b.excerpt),
          createdAt: b.createdAt,
        ),
      );
      _bookmarksAdded++;
      changed = true;
    }

    final annotations = _annotations.putIfAbsent(id, () => {});
    for (final h in backup.highlights) {
      if (!_rangeFits(h.range, doc.format)) {
        _skipped++;
        continue;
      }
      final range = h.range.encode();
      final key = _key(range, h.createdAt);
      if (!annotations.containsKey(key)) {
        _annotationInserts.add(
          AnnotationsCompanion.insert(
            documentId: id,
            range: range,
            progress: h.progress,
            selectedText: h.text,
            note: Value(h.note),
            color: h.color.argb,
            createdAt: h.createdAt,
            updatedAt: h.updatedAt,
          ),
        );
        annotations[key] = null;
        _highlightsAdded++;
        changed = true;
      } else if (annotations[key] case final existing?
          when h.updatedAt.isAfter(existing.updatedAt) &&
              (h.note != existing.note || h.color.argb != existing.color)) {
        _annotationUpdates.add((
          existing.id,
          AnnotationsCompanion(
            note: Value(h.note),
            color: Value(h.color.argb),
            updatedAt: Value(h.updatedAt),
          ),
        ));
        // Only the first matching entry of a backup applies.
        annotations[key] = null;
        _highlightsUpdated++;
        changed = true;
      }
    }

    final starts = _sessionStarts.putIfAbsent(id, () => {});
    for (final s in backup.sessions) {
      if (!starts.add(_seconds(s.startedAt))) continue;
      _sessionInserts.add(
        ReadingSessionsCompanion.insert(
          documentId: id,
          startedAt: s.startedAt,
          endedAt: s.endedAt,
          startProgress: s.startProgress,
          endProgress: s.endProgress,
        ),
      );
      _sessionsAdded++;
      changed = true;
    }

    final memberships = _memberships.putIfAbsent(id, () => {});
    for (final name in backup.collections) {
      final collectionId = await collectionNamed(name, now);
      if (!memberships.add(collectionId)) continue;
      _membershipInserts.add(
        DocumentCollectionsCompanion.insert(
          documentId: id,
          collectionId: collectionId,
          addedAt: now,
        ),
      );
      _entriesAdded++;
      changed = true;
    }

    if (changed) _updated++;
  }

  Future<void> write() => _db.batch((batch) {
    batch.insertAllOnConflictUpdate(_db.readingPositions, _positionWrites);
    for (final (id, update) in _documentUpdates) {
      batch.update(_db.documents, update, where: (d) => d.id.equals(id));
    }
    batch.insertAll(_db.bookmarks, _bookmarkInserts);
    batch.insertAll(_db.annotations, _annotationInserts);
    for (final (id, update) in _annotationUpdates) {
      batch.update(_db.annotations, update, where: (a) => a.id.equals(id));
    }
    batch.insertAll(_db.readingSessions, _sessionInserts);
    batch.insertAll(_db.documentCollections, _membershipInserts);
  });

  RestoreReport report({
    required bool settingsRestored,
    required int skippedInFile,
  }) => RestoreReport(
    matchedBooks: _matched,
    updatedBooks: _updated,
    missingTitles: _missing,
    positionsRestored: _positionsRestored,
    bookmarksAdded: _bookmarksAdded,
    highlightsAdded: _highlightsAdded,
    highlightsUpdated: _highlightsUpdated,
    sessionsAdded: _sessionsAdded,
    collectionsCreated: _collectionsCreated,
    collectionEntriesAdded: _entriesAdded,
    settingsRestored: settingsRestored,
    skippedEntries: skippedInFile + _skipped,
  );
}

/// Whether [locator] is a position in a document of [format]. A backup
/// is untrusted, and a reader handed another format's position would not
/// know what to do with it.
bool _fits(Locator locator, DocumentFormat format) =>
    switch ((locator, format)) {
      (TextLocator(), DocumentFormat.txt) ||
      (PdfLocator(), DocumentFormat.pdf) ||
      (EpubLocator(), DocumentFormat.epub) => true,
      _ => false,
    };

bool _rangeFits(AnnotationRange range, DocumentFormat format) =>
    switch (range) {
      TextRangeAnchor(:final start) =>
        format != DocumentFormat.pdf && _fits(start, format),
      PdfAreaRange() => format == DocumentFormat.pdf,
    };

/// Identifies a bookmark or highlight: where it is and when it was made.
String _key(String place, DateTime createdAt) =>
    '${_seconds(createdAt)} $place';

int _seconds(DateTime date) => date.millisecondsSinceEpoch ~/ 1000;

DateTime _utc(DateTime date) =>
    DateTime.fromMillisecondsSinceEpoch(_seconds(date) * 1000, isUtc: true);

DateTime? _later(DateTime? a, DateTime? b) {
  if (a == null) return b;
  if (b == null) return a;
  return b.isAfter(a) ? b : a;
}

bool _sameMoment(DateTime? a, DateTime? b) =>
    a == null ? b == null : b != null && a.isAtSameMomentAs(b);

Map<int, List<T>> _byDocument<T>(List<T> rows, int Function(T row) document) {
  final result = <int, List<T>>{};
  for (final row in rows) {
    result.putIfAbsent(document(row), () => []).add(row);
  }
  return result;
}
