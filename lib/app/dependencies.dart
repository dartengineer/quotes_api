import '../data/database/app_database.dart';
import '../features/collections/data/collection_repository.dart';
import '../features/library/data/library_repository.dart';
import '../features/settings/data/settings_repository.dart';

/// Long-lived services shared across the app, created once at start-up.
class AppDependencies {
  AppDependencies(this.database)
    : library = LibraryRepository(database),
      collections = CollectionRepository(database),
      settings = SettingsRepository(database);

  final AppDatabase database;
  final LibraryRepository library;
  final CollectionRepository collections;
  final SettingsRepository settings;

  Future<void> dispose() => database.close();
}
