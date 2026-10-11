import 'package:drift/drift.dart';

import '../../../data/database/app_database.dart';
import '../../library/domain/library_layout.dart';
import '../../library/domain/library_query.dart';
import '../../reader/domain/reader_preferences.dart';
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
  static const _readerThemeKey = 'reader.theme';
  static const _readerFontKey = 'reader.font';
  static const _readerFontSizeKey = 'reader.fontSize';
  static const _readerLineHeightKey = 'reader.lineHeight';
  static const _readerParagraphSpacingKey = 'reader.paragraphSpacing';
  static const _readerMarginKey = 'reader.margin';
  static const _readerJustifyKey = 'reader.justify';

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

  Future<void> setReaderPreferences(ReaderPreferences value) async {
    await _db.batch((batch) {
      batch.insertAllOnConflictUpdate(_db.preferences, [
        for (final (key, stored) in [
          (_readerThemeKey, value.theme.name),
          (_readerFontKey, value.font.name),
          (_readerFontSizeKey, '${value.fontSize}'),
          (_readerLineHeightKey, '${value.lineHeight}'),
          (_readerParagraphSpacingKey, '${value.paragraphSpacing}'),
          (_readerMarginKey, '${value.margin}'),
          (_readerJustifyKey, '${value.justify}'),
        ])
          PreferencesCompanion.insert(key: key, value: stored),
      ]);
    });
  }

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

  ReaderPreferences get readerPreferences {
    const defaults = ReaderPreferences();
    // copyWith clamps every number into its valid range.
    return defaults.copyWith(
      theme: _enum(
        ReaderTheme.values,
        SettingsRepository._readerThemeKey,
        defaults.theme,
      ),
      font: _enum(
        ReaderFont.values,
        SettingsRepository._readerFontKey,
        defaults.font,
      ),
      fontSize: _double(SettingsRepository._readerFontSizeKey),
      lineHeight: _double(SettingsRepository._readerLineHeightKey),
      paragraphSpacing: _double(SettingsRepository._readerParagraphSpacingKey),
      margin: _double(SettingsRepository._readerMarginKey),
      justify: _values[SettingsRepository._readerJustifyKey] == 'true',
    );
  }

  double? _double(String key) {
    final value = double.tryParse(_values[key] ?? '');
    return value != null && value.isFinite ? value : null;
  }

  T _enum<T extends Enum>(List<T> values, String key, T fallback) {
    final stored = _values[key];
    for (final value in values) {
      if (value.name == stored) return value;
    }
    return fallback;
  }
}
