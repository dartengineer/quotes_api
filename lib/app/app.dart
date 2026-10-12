import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../core/files/file_saver.dart';
import '../core/theme/app_theme.dart';
import '../core/widgets/state_views.dart';
import '../features/import/data/incoming_documents.dart';
import '../features/import/presentation/import_cubit.dart';
import '../features/library/presentation/library_search_request.dart';
import '../features/settings/domain/app_settings.dart';
import '../features/settings/presentation/settings_cubit.dart';
import 'app_info.dart';
import 'dependencies.dart';
import 'router.dart';
import 'routes.dart';

class LecternApp extends StatefulWidget {
  const LecternApp({
    super.key,
    required this.dependencies,
    required this.initialSettings,
    this.initialLocation = Routes.home,
  });

  final AppDependencies dependencies;
  final AppSettings initialSettings;
  final String initialLocation;

  @override
  State<LecternApp> createState() => _LecternAppState();
}

class _LecternAppState extends State<LecternApp> {
  late final GoRouter _router = buildRouter(
    initialLocation: widget.initialLocation,
  );
  final _searchRequests = LibrarySearchRequest();
  late final ImportCubit _imports = ImportCubit(
    picker: widget.dependencies.picker,
    importer: widget.dependencies.importer,
  );

  @override
  void initState() {
    super.initState();
    unawaited(widget.dependencies.incoming.start(_onDocumentsReceived));
  }

  /// Imports documents sent from other apps ("Open with", share), then
  /// deletes their temporary copies.
  void _onDocumentsReceived(IncomingBatch batch) {
    unawaited(_importReceived(batch));
  }

  Future<void> _importReceived(IncomingBatch batch) async {
    await _imports.importSources(
      batch.sources,
      rejected: batch.rejected,
      openWhenDone: batch.openWhenDone,
    );
    await widget.dependencies.incoming.discard(batch.sources);
  }

  @override
  void dispose() {
    widget.dependencies.incoming.stop();
    unawaited(_imports.close());
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final deps = widget.dependencies;
    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider.value(value: deps.library),
        RepositoryProvider.value(value: deps.collections),
        RepositoryProvider.value(value: deps.settings),
        RepositoryProvider.value(value: deps.storage),
        RepositoryProvider.value(value: deps.manager),
        RepositoryProvider.value(value: deps.readingProgress),
        RepositoryProvider.value(value: deps.bookmarks),
        RepositoryProvider.value(value: deps.annotations),
        RepositoryProvider<FileSaver>.value(value: deps.fileSaver),
        RepositoryProvider.value(value: _searchRequests),
      ],
      child: MultiBlocProvider(
        providers: [
          BlocProvider(
            create: (context) =>
                SettingsCubit(deps.settings, widget.initialSettings),
          ),
          BlocProvider.value(value: _imports),
        ],
        child: BlocBuilder<SettingsCubit, AppSettings>(
          buildWhen: (previous, current) =>
              previous.themePreference != current.themePreference,
          builder: (context, settings) => MaterialApp.router(
            title: AppInfo.name,
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light,
            darkTheme: AppTheme.dark,
            themeMode: switch (settings.themePreference) {
              ThemePreference.system => ThemeMode.system,
              ThemePreference.light => ThemeMode.light,
              ThemePreference.dark => ThemeMode.dark,
            },
            routerConfig: _router,
          ),
        ),
      ),
    );
  }
}

/// Shown instead of the app when start-up fails (e.g. the database cannot be
/// opened), so the user sees an explanation rather than a blank screen.
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppInfo.name,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      home: Scaffold(
        body: ErrorStateView(
          title: '${AppInfo.name} could not start',
          message:
              'Your library data could not be opened. Your documents have '
              'not been changed. Try again, or restart the device if the '
              'problem continues.',
          onRetry: onRetry,
        ),
      ),
    );
  }
}
