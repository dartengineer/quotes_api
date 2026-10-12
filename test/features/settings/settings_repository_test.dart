import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/data/database/app_database.dart';
import 'package:lectern/features/library/domain/library_layout.dart';
import 'package:lectern/features/library/domain/library_query.dart';
import 'package:lectern/features/settings/data/settings_repository.dart';
import 'package:lectern/features/settings/domain/app_settings.dart';

import '../../helpers/test_database.dart';

void main() {
  test('defaults are used when nothing is stored', () async {
    final db = createTestDatabase();
    addTearDown(db.close);

    final prefs = await SettingsRepository(db).load();
    expect(prefs.appSettings, const AppSettings());
    expect(prefs.libraryLayout, LibraryLayout.grid);
    expect(prefs.librarySort, LibrarySort.recentlyAdded);
  });

  test('unknown stored values fall back to defaults', () async {
    final db = createTestDatabase();
    addTearDown(db.close);
    await db.preferences.insertAll([
      PreferencesCompanion.insert(key: 'app.theme', value: 'purple'),
      PreferencesCompanion.insert(key: 'library.sort', value: ''),
    ]);

    final prefs = await SettingsRepository(db).load();
    expect(prefs.appSettings.themePreference, ThemePreference.system);
    expect(prefs.librarySort, LibrarySort.recentlyAdded);
  });

  test('preferences survive closing and reopening the database', () async {
    final dir = await Directory.systemTemp.createTemp('lectern_settings');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/test.sqlite');

    final first = AppDatabase(NativeDatabase(file));
    final writer = SettingsRepository(first);
    await writer.setThemePreference(ThemePreference.dark);
    await writer.setLibraryLayout(LibraryLayout.list);
    await writer.setLibrarySort(LibrarySort.title);
    // Overwriting a value must replace it, not add a second row.
    await writer.setLibrarySort(LibrarySort.author);
    await first.close();

    final second = AppDatabase(NativeDatabase(file));
    addTearDown(second.close);
    final prefs = await SettingsRepository(second).load();
    expect(prefs.appSettings.themePreference, ThemePreference.dark);
    expect(prefs.libraryLayout, LibraryLayout.list);
    expect(prefs.librarySort, LibrarySort.author);
  });
}
