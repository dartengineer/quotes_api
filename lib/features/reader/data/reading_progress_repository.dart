import 'package:drift/drift.dart';

import '../../../data/database/app_database.dart';
import '../domain/locator.dart';

/// The persistence operations a [ReadingSessionTracker] needs. Separated so
/// the tracker's timing logic can be tested without a database.
abstract interface class ProgressStore {
  Future<void> savePosition(int documentId, Locator locator);
  Future<void> saveProgress(int documentId, double progress);
  Future<void> recordSession({
    required int documentId,
    required DateTime startedAt,
    required DateTime endedAt,
    required double startProgress,
    required double endProgress,
  });
}

/// Reading positions, overall progress and reading sessions.
class ReadingProgressRepository implements ProgressStore {
  ReadingProgressRepository(this._db, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final AppDatabase _db;
  final DateTime Function() _clock;

  /// The last saved position, or null if none (or it is unreadable).
  Future<Locator?> loadPosition(int documentId) async {
    final row = await (_db.select(
      _db.readingPositions,
    )..where((p) => p.documentId.equals(documentId))).getSingleOrNull();
    return Locator.decode(row?.locator);
  }

  @override
  Future<void> savePosition(int documentId, Locator locator) async {
    await _db.readingPositions.insertOnConflictUpdate(
      ReadingPositionsCompanion.insert(
        documentId: Value(documentId),
        locator: locator.encode(),
        updatedAt: _clock(),
      ),
    );
  }

  /// Updates the document's overall progress shown in lists.
  @override
  Future<void> saveProgress(int documentId, double progress) async {
    await (_db.update(
      _db.documents,
    )..where((d) => d.id.equals(documentId))).write(
      DocumentsCompanion(
        progress: Value(progress.clamp(0.0, 1.0)),
        updatedAt: Value(_clock()),
      ),
    );
  }

  @override
  Future<void> recordSession({
    required int documentId,
    required DateTime startedAt,
    required DateTime endedAt,
    required double startProgress,
    required double endProgress,
  }) async {
    if (endedAt.isBefore(startedAt)) return;
    await _db.readingSessions.insertOne(
      ReadingSessionsCompanion.insert(
        documentId: documentId,
        startedAt: startedAt,
        endedAt: endedAt,
        startProgress: startProgress.clamp(0.0, 1.0),
        endProgress: endProgress.clamp(0.0, 1.0),
      ),
    );
  }

  /// Total time spent reading a document across all sessions.
  Future<Duration> totalReadingTime(int documentId) async {
    final sessions = await (_db.select(
      _db.readingSessions,
    )..where((s) => s.documentId.equals(documentId))).get();
    return sessions.fold<Duration>(
      Duration.zero,
      (total, s) => total + s.endedAt.difference(s.startedAt),
    );
  }
}
