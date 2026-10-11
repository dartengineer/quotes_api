import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/routes.dart';
import '../../../core/utils/load_status.dart';
import '../../../core/widgets/dialogs.dart';
import '../../../core/widgets/state_views.dart';
import '../domain/library_collection.dart';
import 'collections_cubit.dart';

class CollectionsScreen extends StatelessWidget {
  const CollectionsScreen({super.key});

  static Future<void> create(BuildContext context) async {
    final cubit = context.read<CollectionsCubit>();
    await showNameDialog(
      context,
      title: 'New collection',
      confirmLabel: 'Create',
      onSubmit: (name) async => (await cubit.create(name)).error,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Collections')),
      body: BlocBuilder<CollectionsCubit, CollectionsState>(
        builder: (context, state) {
          if (state.status == LoadStatus.loading) return const LoadingView();
          if (state.status == LoadStatus.failure && state.collections.isEmpty) {
            return ErrorStateView(
              message: 'Your collections could not be loaded.',
              onRetry: context.read<CollectionsCubit>().retry,
            );
          }
          if (state.collections.isEmpty) {
            return EmptyStateView(
              icon: Icons.collections_bookmark_outlined,
              title: 'No collections yet',
              message:
                  'Group documents into collections, such as “To read” or '
                  '“Work”.',
              action: FilledButton.tonalIcon(
                onPressed: () => create(context),
                icon: const Icon(Icons.add),
                label: const Text('New collection'),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 96),
            itemCount: state.collections.length,
            itemBuilder: (context, index) =>
                _CollectionTile(collection: state.collections[index]),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => create(context),
        icon: const Icon(Icons.add),
        label: const Text('New collection'),
      ),
    );
  }
}

enum _TileAction { rename, delete }

class _CollectionTile extends StatelessWidget {
  const _CollectionTile({required this.collection});

  final LibraryCollection collection;

  Future<void> _onAction(BuildContext context, _TileAction action) async {
    final cubit = context.read<CollectionsCubit>();
    switch (action) {
      case _TileAction.rename:
        await showNameDialog(
          context,
          title: 'Rename collection',
          confirmLabel: 'Rename',
          initialValue: collection.name,
          onSubmit: (name) async =>
              (await cubit.rename(collection.id, name)).error,
        );
      case _TileAction.delete:
        final confirmed = await showConfirmDialog(
          context,
          title: 'Delete “${collection.name}”?',
          message:
              'The collection is deleted. Its documents stay in your library.',
          confirmLabel: 'Delete',
          destructive: true,
        );
        if (confirmed) await cubit.delete(collection.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final count = collection.documentCount;
    return ListTile(
      leading: const Icon(Icons.collections_bookmark_outlined),
      title: Text(collection.name),
      subtitle: Text(count == 1 ? '1 document' : '$count documents'),
      onTap: () => context.go(Routes.collection(collection.id)),
      trailing: PopupMenuButton<_TileAction>(
        tooltip: 'Options for ${collection.name}',
        onSelected: (action) => unawaited(_onAction(context, action)),
        itemBuilder: (context) => const [
          PopupMenuItem(value: _TileAction.rename, child: Text('Rename')),
          PopupMenuItem(value: _TileAction.delete, child: Text('Delete')),
        ],
      ),
    );
  }
}
