import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../../features/library/domain/document_format.dart';
import '../../features/library/domain/reading_status.dart';
import 'tables.dart';

part 'app_database.g.dart';

@DriftDatabase(
  tables: [
    Documents,
    ReadingPositions,
    Collections,
    DocumentCollections,
    Bookmarks,
    Annotations,
    ReadingSessions,
    Preferences,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  /// Opens the on-device database. Queries run on a background isolate.
  ///
  /// The database lives in the app-support directory, which is private to the
  /// app and not exposed to the user's file manager.
  factory AppDatabase.open() {
    return AppDatabase(
      driftDatabase(
        name: 'lectern',
        native: const DriftNativeOptions(
          databaseDirectory: getApplicationSupportDirectory,
        ),
      ),
    );
  }

  /// Bump this and add a step to [migration] whenever the schema changes, then
  /// run `dart run drift_dev make-migrations` to snapshot the new schema and
  /// generate migration tests.
  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    beforeOpen: (details) async {
      // SQLite does not enforce foreign keys unless asked to, and cascading
      // deletes (bookmarks, positions, memberships) depend on them.
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}
