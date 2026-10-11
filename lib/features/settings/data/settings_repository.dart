import 'package:drift/drift.dart';

import '../../../data/database/app_database.dart';
import '../../library/domain/library_layout.dart';
import '../../library/domain/library_query.dart';
import '../domain/app_settings.dart';

/// Persists user preferences in the `preferences` table.
///
/// Values are stored as strings. Unknown or corrupt values fall back to
/// defaults instead of failing, so a bad row can never block start-up.
class SettingsRepository {
  SettingsRepository(this._db);

  static const _themeKey = 'app.theme';
  static const _libraryLayoutKey = 'library.layout';
  static const _librarySortKey = 'library.sort';

  final AppDatabase _db;

  Future<StoredPreferences> load() async {
    final rows = await _db.select(_db.preferences).get();
    return StoredPreferences({for (final row in rows) row.key: row.value});
  }

  Future<void> setThemePreference(ThemePreference value) =>
      _put(_themeKey, value.name);

  Future<void> setLibraryLayout(LibraryLayout value) =>
      _put(_libraryLayoutKey, value.name);

  Future<void> setLibrarySort(LibrarySort value) =>
      _put(_librarySortKey, value.name);

  Future<void> _put(String key, String value) async {
    await _db.preferences.insertOnConflictUpdate(
      PreferencesCompanion.insert(key: key, value: value),
    );
  }
}

/// A typed, read-only view of the stored preference values.
class StoredPreferences {
  const StoredPreferences(this._values);

  final Map<String, String> _values;

  AppSettings get appSettings => AppSettings(
    themePreference: _enum(
      ThemePreference.values,
      SettingsRepository._themeKey,
      ThemePreference.system,
    ),
  );

  LibraryLayout get libraryLayout => _enum(
    LibraryLayout.values,
    SettingsRepository._libraryLayoutKey,
    LibraryLayout.grid,
  );

  LibrarySort get librarySort => _enum(
    LibrarySort.values,
    SettingsRepository._librarySortKey,
    LibrarySort.recentlyAdded,
  );

  T _enum<T extends Enum>(List<T> values, String key, T fallback) {
    final stored = _values[key];
    for (final value in values) {
      if (value.name == stored) return value;
    }
    return fallback;
  }
}
