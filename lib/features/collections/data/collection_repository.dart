import 'package:drift/drift.dart';

import '../../../data/database/app_database.dart';
import '../domain/library_collection.dart';

/// Manages collections and document membership.
///
/// Deleting a collection only removes memberships; documents are never
/// deleted through this repository.
class CollectionRepository {
  CollectionRepository(this._db, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  static const maxNameLength = 200;

  final AppDatabase _db;
  final DateTime Function() _clock;

  /// Watches all collections with their document counts, ordered by name.
  Stream<List<LibraryCollection>> watchCollections() {
    final c = _db.collections;
    final m = _db.documentCollections;
    final count = m.documentId.count();
    final query =
        _db.select(c).join([
            leftOuterJoin(m, m.collectionId.equalsExp(c.id), useColumns: false),
          ])
          ..addColumns([count])
          ..groupBy([c.id])
          ..orderBy([
            OrderingTerm.asc(c.name.collate(Collate.noCase)),
            OrderingTerm.asc(c.id),
          ]);

    return query.watch().map(
      (rows) => [
        for (final row in rows)
          _map(row.readTable(c), documentCount: row.read(count) ?? 0),
      ],
    );
  }

  /// Watches one collection; emits null once it has been deleted.
  Stream<LibraryCollection?> watchCollection(int id) {
    return watchCollections().map(
      (all) => all.where((c) => c.id == id).firstOrNull,
    );
  }

  /// Watches the ids of the collections containing [documentId].
  Stream<Set<int>> watchCollectionIdsFor(int documentId) {
    final m = _db.documentCollections;
    final query = _db.selectOnly(m)
      ..addColumns([m.collectionId])
      ..where(m.documentId.equals(documentId));
    return query
        .map((row) => row.read(m.collectionId)!)
        .watch()
        .map((ids) => ids.toSet());
  }

  /// Creates a collection and returns its id.
  ///
  /// Throws [InvalidCollectionNameException] for empty, overlong or duplicate
  /// (case-insensitive) names.
  Future<int> createCollection(String name) {
    final clean = _validate(name);
    return _db.transaction(() async {
      await _ensureUnique(clean);
      return _db.collections.insertOne(
        CollectionsCompanion.insert(name: clean, createdAt: _clock()),
      );
    });
  }

  Future<void> renameCollection(int id, String name) {
    final clean = _validate(name);
    return _db.transaction(() async {
      await _ensureUnique(clean, exceptId: id);
      await (_db.update(_db.collections)..where((c) => c.id.equals(id))).write(
        CollectionsCompanion(name: Value(clean)),
      );
    });
  }

  /// Deletes a collection. Its documents stay in the library.
  Future<void> deleteCollection(int id) async {
    await _db.collections.deleteWhere((c) => c.id.equals(id));
  }

  /// Adds documents to a collection. Documents already in it are ignored.
  Future<void> addDocuments(int collectionId, Iterable<int> documentIds) {
    final now = _clock();
    return _db.batch((batch) {
      batch.insertAll(_db.documentCollections, [
        for (final documentId in documentIds.toSet())
          DocumentCollectionsCompanion.insert(
            documentId: documentId,
            collectionId: collectionId,
            addedAt: now,
          ),
      ], mode: InsertMode.insertOrIgnore);
    });
  }

  Future<void> removeDocuments(
    int collectionId,
    Iterable<int> documentIds,
  ) async {
    final ids = documentIds.toSet().toList();
    if (ids.isEmpty) return;
    await _db.documentCollections.deleteWhere(
      (m) => m.collectionId.equals(collectionId) & m.documentId.isIn(ids),
    );
  }

  String _validate(String name) {
    final clean = name.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (clean.isEmpty) {
      throw const InvalidCollectionNameException(CollectionNameProblem.empty);
    }
    if (clean.length > maxNameLength) {
      throw const InvalidCollectionNameException(CollectionNameProblem.tooLong);
    }
    return clean;
  }

  Future<void> _ensureUnique(String name, {int? exceptId}) async {
    final c = _db.collections;
    final query = _db.selectOnly(c)
      ..addColumns([c.id])
      ..where(c.name.collate(Collate.noCase).equals(name));
    if (exceptId != null) query.where(c.id.equals(exceptId).not());
    final clash = await query.getSingleOrNull();
    if (clash != null) {
      throw const InvalidCollectionNameException(
        CollectionNameProblem.duplicate,
      );
    }
  }

  LibraryCollection _map(CollectionRow row, {required int documentCount}) {
    return LibraryCollection(
      id: row.id,
      name: row.name,
      documentCount: documentCount,
      createdAt: row.createdAt,
    );
  }
}
