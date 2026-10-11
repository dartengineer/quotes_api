import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'app/app.dart';
import 'app/dependencies.dart';
import 'core/utils/app_log.dart';
import 'data/database/app_database.dart';
import 'data/files/library_storage.dart';
import 'features/settings/data/settings_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _bootstrap();
}

Future<void> _bootstrap() async {
  final database = AppDatabase.open();
  try {
    // Loading preferences before the first frame avoids a light/dark theme
    // flash; it is a single small query. It also surfaces database problems
    // up front instead of on the first screen.
    final (storage, preferences) = await (
      _openStorage(),
      SettingsRepository(database).load(),
    ).wait;
    final dependencies = AppDependencies(database: database, storage: storage);
    runApp(
      LecternApp(
        dependencies: dependencies,
        initialSettings: preferences.appSettings,
      ),
    );
    unawaited(_clearPickerCopies(dependencies));
  } catch (error, stackTrace) {
    AppLog.error('Start-up failed', error, stackTrace);
    await database.close().catchError((Object _) {});
    runApp(StartupErrorApp(onRetry: () => _bootstrap()));
  }
}

/// Opens library storage and removes leftovers of imports interrupted by a
/// crash. This happens before the first frame so it can never race with a
/// new import; the staging area is normally empty, so it is quick.
Future<LibraryStorage> _openStorage() async {
  final storage = await LibraryStorage.open();
  try {
    await storage.clearStagingArea();
  } catch (error, stackTrace) {
    AppLog.error('Clearing the import staging area failed', error, stackTrace);
  }
  return storage;
}

/// Deletes picker copies left by an interrupted session.
Future<void> _clearPickerCopies(AppDependencies dependencies) async {
  try {
    await dependencies.picker.clearTemporaryFiles();
  } catch (error, stackTrace) {
    AppLog.error('Clearing picker copies failed', error, stackTrace);
  }
}
