import 'package:drift/drift.dart';

import '../../../data/database/app_database.dart';
import '../domain/annotation.dart';

/// Highlights and notes, stored only in the app's private database.
class AnnotationRepository {
  AnnotationRepository(this._db, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  /// Bounds on stored text, so a huge selection cannot bloat the database.
  static const maxTextLength = 10000;
  static const maxNoteLength = 10000;

  final AppDatabase _db;
  final DateTime Function() _clock;

  /// Watches a document's annotations in reading order. Rows whose range
  /// can no longer be understood are skipped rather than failing the list.
  Stream<List<Annotation>> watchAnnotations(int documentId) {
    final query = _db.select(_db.annotations)
      ..where((a) => a.documentId.equals(documentId))
      ..orderBy([
        (a) => OrderingTerm.asc(a.progress),
        (a) => OrderingTerm.asc(a.createdAt),
      ]);
    return query.watch().map(
      (rows) => [
        for (final row in rows)
          if (AnnotationRange.decode(row.range) case final range?)
            Annotation(
              id: row.id,
              documentId: row.documentId,
              range: range,
              progress: row.progress,
              text: row.selectedText,
              note: row.note,
              color: HighlightColor.fromArgb(row.color),
              createdAt: row.createdAt,
              updatedAt: row.updatedAt,
            ),
      ],
    );
  }

  Future<int> addAnnotation({
    required int documentId,
    required AnnotationDraft draft,
    required HighlightColor color,
    String? note,
  }) {
    final now = _clock();
    return _db.annotations.insertOne(
      AnnotationsCompanion.insert(
        documentId: documentId,
        range: draft.range.encode(),
        progress: draft.progress.clamp(0.0, 1.0),
        selectedText: _bounded(draft.text.trim(), maxTextLength),
        note: Value(_cleanNote(note)),
        color: color.argb,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  /// Sets or clears (with null or blank text) an annotation's note.
  Future<void> updateNote(int id, String? note) async {
    await (_db.update(_db.annotations)..where((a) => a.id.equals(id))).write(
      AnnotationsCompanion(
        note: Value(_cleanNote(note)),
        updatedAt: Value(_clock()),
      ),
    );
  }

  Future<void> updateColor(int id, HighlightColor color) async {
    await (_db.update(_db.annotations)..where((a) => a.id.equals(id))).write(
      AnnotationsCompanion(
        color: Value(color.argb),
        updatedAt: Value(_clock()),
      ),
    );
  }

  Future<void> deleteAnnotation(int id) async {
    await _db.annotations.deleteWhere((a) => a.id.equals(id));
  }

  static String? _cleanNote(String? note) {
    final trimmed = note?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return _bounded(trimmed, maxNoteLength);
  }

  /// Cuts [text] to at most [max] UTF-16 units, never inside a surrogate
  /// pair.
  static String _bounded(String text, int max) {
    if (text.length <= max) return text;
    var end = max;
    final last = text.codeUnitAt(end - 1);
    if (last >= 0xD800 && last <= 0xDBFF) end--;
    return text.substring(0, end);
  }
}
