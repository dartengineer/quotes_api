import 'package:material_ui/material_ui.dart';

import 'app/app.dart';
import 'app/dependencies.dart';
import 'core/utils/app_log.dart';
import 'data/database/app_database.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _bootstrap();
}

Future<void> _bootstrap() async {
  final dependencies = AppDependencies(AppDatabase.open());
  try {
    // Loading preferences before the first frame avoids a light/dark theme
    // flash; it is a single small query. It also surfaces database problems
    // up front instead of on the first screen.
    final preferences = await dependencies.settings.load();
    runApp(
      LecternApp(
        dependencies: dependencies,
        initialSettings: preferences.appSettings,
      ),
    );
  } catch (error, stackTrace) {
    AppLog.error('Start-up failed', error, stackTrace);
    await dependencies.dispose().catchError((Object _) {});
    runApp(StartupErrorApp(onRetry: () => _bootstrap()));
  }
}
