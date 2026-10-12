import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../core/widgets/state_views.dart';
import '../data/files/library_storage.dart';
import '../features/collections/data/collection_repository.dart';
import '../features/collections/presentation/collections_cubit.dart';
import '../features/collections/presentation/collections_screen.dart';
import '../features/home/presentation/home_cubit.dart';
import '../features/home/presentation/home_screen.dart';
import '../features/library/data/library_manager.dart';
import '../features/library/data/library_repository.dart';
import '../features/library/presentation/document_details_cubit.dart';
import '../features/library/presentation/document_details_screen.dart';
import '../features/library/presentation/library_cubit.dart';
import '../features/library/presentation/library_screen.dart';
import '../features/reader/data/annotation_repository.dart';
import '../features/reader/data/bookmark_repository.dart';
import '../features/reader/data/reading_progress_repository.dart';
import '../features/reader/presentation/reader_cubit.dart';
import '../features/reader/presentation/reader_screen.dart';
import '../features/settings/data/settings_repository.dart';
import '../features/settings/presentation/settings_screen.dart';
import 'app_shell.dart';
import 'routes.dart';

/// Builds the app's router. Each tab keeps its own navigation stack and
/// state; tab screens are built lazily on first visit. Document details
/// open above the tabs.
GoRouter buildRouter({String initialLocation = Routes.home}) {
  return GoRouter(
    initialLocation: initialLocation,
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            AppShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.home,
                builder: (context, state) => BlocProvider(
                  create: (context) =>
                      HomeCubit(context.read<LibraryRepository>()),
                  child: const HomeScreen(),
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.library,
                builder: (context, state) => BlocProvider(
                  create: (context) => _libraryCubit(context),
                  child: const LibraryScreen(),
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.collections,
                builder: (context, state) => BlocProvider(
                  create: (context) =>
                      CollectionsCubit(context.read<CollectionRepository>()),
                  child: const CollectionsScreen(),
                ),
                routes: [
                  GoRoute(
                    path: ':id',
                    builder: (context, state) {
                      final id = int.tryParse(state.pathParameters['id']!);
                      if (id == null) return const _NotFoundScreen();
                      return BlocProvider(
                        key: ValueKey('collection-$id'),
                        create: (context) =>
                            _libraryCubit(context, collectionId: id),
                        child: const LibraryScreen(),
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: Routes.settings,
                builder: (context, state) => const SettingsScreen(),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/read/:id',
        builder: (context, state) {
          final id = int.tryParse(state.pathParameters['id']!);
          if (id == null) return const _NotFoundScreen();
          return BlocProvider(
            key: ValueKey('reader-$id'),
            create: (context) => ReaderCubit(
              documentId: id,
              library: context.read<LibraryRepository>(),
              progress: context.read<ReadingProgressRepository>(),
              bookmarks: context.read<BookmarkRepository>(),
              annotations: context.read<AnnotationRepository>(),
              settings: context.read<SettingsRepository>(),
              storage: context.read<LibraryStorage>(),
            ),
            child: const ReaderScreen(),
          );
        },
      ),
      GoRoute(
        path: '/document/:id',
        builder: (context, state) {
          final id = int.tryParse(state.pathParameters['id']!);
          if (id == null) return const _NotFoundScreen();
          return BlocProvider(
            key: ValueKey('document-$id'),
            create: (context) => DocumentDetailsCubit(
              documentId: id,
              library: context.read<LibraryRepository>(),
              collections: context.read<CollectionRepository>(),
              manager: context.read<LibraryManager>(),
              progress: context.read<ReadingProgressRepository>(),
            ),
            child: const DocumentDetailsScreen(),
          );
        },
      ),
    ],
  );
}

LibraryCubit _libraryCubit(BuildContext context, {int? collectionId}) {
  return LibraryCubit(
    library: context.read<LibraryRepository>(),
    settings: context.read<SettingsRepository>(),
    manager: context.read<LibraryManager>(),
    collections: context.read<CollectionRepository>(),
    collectionId: collectionId,
  );
}

class _NotFoundScreen extends StatelessWidget {
  const _NotFoundScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: const EmptyStateView(icon: Icons.link_off, title: 'Page not found'),
    );
  }
}
