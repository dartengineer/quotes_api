import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/utils/load_status.dart';
import '../../../core/widgets/dialogs.dart';
import '../../../core/widgets/state_views.dart';
import '../data/collection_repository.dart';
import 'collections_cubit.dart';

/// Lets the user pick a collection, or create one. Resolves to the chosen
/// collection's id, or null if dismissed. Collections in [exclude] are shown
/// as already containing the document(s).
Future<int?> showCollectionPicker(
  BuildContext context, {
  Set<int> exclude = const {},
}) {
  final repository = context.read<CollectionRepository>();
  return showModalBottomSheet<int>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (_) => BlocProvider(
      create: (_) => CollectionsCubit(repository),
      child: _CollectionPicker(exclude: exclude),
    ),
  );
}

class _CollectionPicker extends StatelessWidget {
  const _CollectionPicker({required this.exclude});

  final Set<int> exclude;

  Future<void> _createAndPick(BuildContext context) async {
    final cubit = context.read<CollectionsCubit>();
    int? createdId;
    final created = await showNameDialog(
      context,
      title: 'New collection',
      confirmLabel: 'Create',
      onSubmit: (name) async {
        final result = await cubit.create(name);
        createdId = result.id;
        return result.error;
      },
    );
    if (created && createdId != null && context.mounted) {
      Navigator.of(context).pop(createdId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.7,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.xl,
              0,
              Spacing.xl,
              Spacing.sm,
            ),
            child: Text('Add to collection', style: theme.textTheme.titleLarge),
          ),
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('New collection'),
            onTap: () => _createAndPick(context),
          ),
          const Divider(),
          Flexible(
            child: BlocBuilder<CollectionsCubit, CollectionsState>(
              builder: (context, state) {
                if (state.status == LoadStatus.loading) {
                  return const Padding(
                    padding: EdgeInsets.all(Spacing.xl),
                    child: LoadingView(),
                  );
                }
                if (state.collections.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.all(Spacing.xl),
                    child: Text(
                      'You have no collections yet.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium,
                    ),
                  );
                }
                return ListView.builder(
                  shrinkWrap: true,
                  itemCount: state.collections.length,
                  itemBuilder: (context, index) {
                    final collection = state.collections[index];
                    final included = exclude.contains(collection.id);
                    return ListTile(
                      leading: Icon(
                        included
                            ? Icons.check_circle
                            : Icons.collections_bookmark_outlined,
                      ),
                      title: Text(collection.name),
                      subtitle: included ? const Text('Already added') : null,
                      enabled: !included,
                      onTap: () => Navigator.of(context).pop(collection.id),
                    );
                  },
                );
              },
            ),
          ),
          const SizedBox(height: Spacing.md),
        ],
      ),
    );
  }
}
