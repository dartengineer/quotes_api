import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/utils/load_status.dart';
import '../../../core/widgets/dialogs.dart';
import '../../../core/widgets/state_views.dart';
import '../../collections/presentation/collection_picker.dart';
import '../../import/presentation/import_cubit.dart';
import '../../reader/presentation/open_document.dart';
import '../domain/library_document.dart';
import '../domain/library_filter.dart';
import '../domain/library_layout.dart';
import '../domain/library_query.dart';
import '../domain/reading_status.dart';
import 'library_cubit.dart';
import 'library_search_request.dart';
import 'widgets/document_tiles.dart';

/// The library, or the documents of one collection when the cubit was
/// created with a collection id.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  bool _searching = false;
  LibrarySearchRequest? _searchRequests;

  bool get _isCollectionView =>
      context.read<LibraryCubit>().collectionId != null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_searchRequests == null && !_isCollectionView) {
      _searchRequests = context.read<LibrarySearchRequest?>()
        ?..addListener(_onSearchRequested);
      _onSearchRequested();
    }
  }

  @override
  void dispose() {
    _searchRequests?.removeListener(_onSearchRequested);
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onSearchRequested() {
    if (_searchRequests?.consume() ?? false) _openSearch();
  }

  void _openSearch() {
    if (!_searching) setState(() => _searching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  void _closeSearch() {
    setState(() => _searching = false);
    _searchController.clear();
    context.read<LibraryCubit>().setSearch('');
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<LibraryCubit, LibraryState>(
      listenWhen: (previous, current) =>
          current.collectionDeleted && !previous.collectionDeleted,
      listener: (context, state) {
        if (context.canPop()) context.pop();
      },
      builder: (context, state) {
        final PreferredSizeWidget appBar;
        if (state.isSelecting) {
          appBar = _SelectionAppBar(state: state);
        } else if (_searching) {
          appBar = _SearchAppBar(
            controller: _searchController,
            focusNode: _searchFocus,
            onClose: _closeSearch,
          );
        } else {
          appBar = _NormalAppBar(state: state, onSearch: _openSearch);
        }

        return PopScope(
          canPop: !state.isSelecting && !_searching,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (state.isSelecting) {
              context.read<LibraryCubit>().clearSelection();
            } else if (_searching) {
              _closeSearch();
            }
          },
          child: Scaffold(
            appBar: appBar,
            body: Column(
              children: [
                if (!state.isSelecting) _FilterBar(selected: state.filter),
                const Expanded(child: _LibraryBody()),
              ],
            ),
            floatingActionButton: state.isSelecting || _isCollectionView
                ? null
                : FloatingActionButton.extended(
                    onPressed: () =>
                        context.read<ImportCubit>().pickAndImport(),
                    icon: const Icon(Icons.add),
                    label: const Text('Import'),
                  ),
          ),
        );
      },
    );
  }
}

class _NormalAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _NormalAppBar({required this.state, required this.onSearch});

  final LibraryState state;
  final VoidCallback onSearch;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final collection = state.query.collectionId != null;
    return AppBar(
      title: Text(collection ? (state.collection?.name ?? '') : 'Library'),
      actions: [
        IconButton(
          tooltip: 'Search',
          icon: const Icon(Icons.search),
          onPressed: onSearch,
        ),
        const _SortButton(),
        const _LayoutButton(),
        if (collection) const _CollectionMenu(),
      ],
    );
  }
}

class _SearchAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _SearchAppBar({
    required this.controller,
    required this.focusNode,
    required this.onClose,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onClose;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      leading: BackButton(onPressed: onClose),
      title: TextField(
        controller: controller,
        focusNode: focusNode,
        textInputAction: TextInputAction.search,
        decoration: const InputDecoration(
          hintText: 'Search titles, authors, file names',
          border: InputBorder.none,
          filled: false,
        ),
        onChanged: context.read<LibraryCubit>().setSearch,
      ),
      actions: [
        ListenableBuilder(
          listenable: controller,
          builder: (context, _) => controller.text.isEmpty
              ? const SizedBox.shrink()
              : IconButton(
                  tooltip: 'Clear search',
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    controller.clear();
                    context.read<LibraryCubit>().setSearch('');
                  },
                ),
        ),
      ],
    );
  }
}

enum _SelectionAction {
  markUnread,
  markReading,
  markFinished,
  addToCollection,
  removeFromCollection,
  removeFromLibrary,
}

class _SelectionAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _SelectionAppBar({required this.state});

  final LibraryState state;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  Future<void> _onAction(BuildContext context, _SelectionAction action) async {
    final cubit = context.read<LibraryCubit>();
    switch (action) {
      case _SelectionAction.markUnread:
        await cubit.setStatusForSelection(ReadingStatus.unread);
      case _SelectionAction.markReading:
        await cubit.setStatusForSelection(ReadingStatus.reading);
      case _SelectionAction.markFinished:
        await cubit.setStatusForSelection(ReadingStatus.finished);
      case _SelectionAction.addToCollection:
        final id = await showCollectionPicker(context);
        if (id != null) await cubit.addSelectionToCollection(id);
      case _SelectionAction.removeFromCollection:
        await cubit.removeSelectionFromCollection();
      case _SelectionAction.removeFromLibrary:
        final count = state.selectedIds.length;
        final noun = count == 1 ? 'document' : '$count documents';
        final confirmed = await showConfirmDialog(
          context,
          title: 'Remove $noun?',
          message:
              '${count == 1 ? 'It' : 'They'} will be removed from Lectern '
              'with ${count == 1 ? 'its' : 'their'} bookmarks and notes. '
              'Original files on your device aren’t affected.',
          confirmLabel: 'Remove',
          destructive: true,
        );
        if (!confirmed || !context.mounted) return;
        final messenger = ScaffoldMessenger.of(context);
        final removed = await cubit.removeSelectionFromLibrary();
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              removed == 1
                  ? 'Removed 1 document'
                  : 'Removed $removed documents',
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<LibraryCubit>();
    final allFavorite = state.selectedDocuments.every((d) => d.isFavorite);
    final inCollection = state.query.collectionId != null;
    return AppBar(
      leading: IconButton(
        tooltip: 'Cancel selection',
        icon: const Icon(Icons.close),
        onPressed: cubit.clearSelection,
      ),
      title: Text('${state.selectedIds.length} selected'),
      actions: [
        IconButton(
          tooltip: 'Select all',
          icon: const Icon(Icons.select_all),
          onPressed: cubit.selectAll,
        ),
        IconButton(
          tooltip: allFavorite ? 'Remove from favourites' : 'Add to favourites',
          icon: Icon(allFavorite ? Icons.favorite : Icons.favorite_border),
          onPressed: cubit.toggleFavoriteForSelection,
        ),
        PopupMenuButton<_SelectionAction>(
          tooltip: 'More actions',
          onSelected: (action) => _onAction(context, action),
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: _SelectionAction.markUnread,
              child: Text('Mark as not started'),
            ),
            const PopupMenuItem(
              value: _SelectionAction.markReading,
              child: Text('Mark as reading'),
            ),
            const PopupMenuItem(
              value: _SelectionAction.markFinished,
              child: Text('Mark as finished'),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem(
              value: _SelectionAction.addToCollection,
              child: Text('Add to collection…'),
            ),
            if (inCollection)
              const PopupMenuItem(
                value: _SelectionAction.removeFromCollection,
                child: Text('Remove from this collection'),
              ),
            const PopupMenuItem(
              value: _SelectionAction.removeFromLibrary,
              child: Text('Remove from library…'),
            ),
          ],
        ),
      ],
    );
  }
}

enum _CollectionAction { rename, delete }

class _CollectionMenu extends StatelessWidget {
  const _CollectionMenu();

  Future<void> _onAction(BuildContext context, _CollectionAction action) async {
    final cubit = context.read<LibraryCubit>();
    final name = cubit.state.collection?.name ?? '';
    switch (action) {
      case _CollectionAction.rename:
        await showNameDialog(
          context,
          title: 'Rename collection',
          confirmLabel: 'Rename',
          initialValue: name,
          onSubmit: cubit.renameCollection,
        );
      case _CollectionAction.delete:
        final confirmed = await showConfirmDialog(
          context,
          title: 'Delete “$name”?',
          message:
              'The collection is deleted. Its documents stay in your '
              'library.',
          confirmLabel: 'Delete',
          destructive: true,
        );
        if (confirmed) await cubit.deleteCollection();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_CollectionAction>(
      tooltip: 'Collection options',
      onSelected: (action) => _onAction(context, action),
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: _CollectionAction.rename,
          child: Text('Rename collection'),
        ),
        PopupMenuItem(
          value: _CollectionAction.delete,
          child: Text('Delete collection'),
        ),
      ],
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.selected});

  final LibraryFilter selected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.xs,
      ),
      child: Row(
        children: [
          for (final filter in LibraryFilter.values) ...[
            ChoiceChip(
              label: Text(filter.label),
              selected: filter == selected,
              onSelected: (_) => context.read<LibraryCubit>().setFilter(filter),
            ),
            const SizedBox(width: Spacing.sm),
          ],
        ],
      ),
    );
  }
}

class _LibraryBody extends StatelessWidget {
  const _LibraryBody();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<LibraryCubit>().state;
    final cubit = context.read<LibraryCubit>();
    switch (state.status) {
      case LoadStatus.loading:
        return const LoadingView();
      case LoadStatus.failure:
        return ErrorStateView(
          message: 'Your library could not be loaded.',
          onRetry: cubit.retry,
        );
      case LoadStatus.ready when state.documents.isEmpty:
        if (state.isNarrowed) {
          return EmptyStateView(
            icon: Icons.search_off,
            title: 'No matches',
            message: 'Try a different search or filter.',
            action: TextButton(
              onPressed: cubit.clearNarrowing,
              child: const Text('Clear search and filters'),
            ),
          );
        }
        if (state.query.collectionId != null) {
          return const EmptyStateView(
            icon: Icons.collections_bookmark_outlined,
            title: 'This collection is empty',
            message:
                'In the library, long-press documents to select them, then '
                'choose “Add to collection”.',
          );
        }
        return EmptyStateView(
          icon: Icons.local_library_outlined,
          title: 'No documents yet',
          message: 'Import PDF, EPUB or TXT files from your device.',
          action: FilledButton.icon(
            onPressed: () => context.read<ImportCubit>().pickAndImport(),
            icon: const Icon(Icons.add),
            label: const Text('Import documents'),
          ),
        );
      case LoadStatus.ready:
        return switch (state.layout) {
          LibraryLayout.grid => _DocumentGrid(state: state),
          LibraryLayout.list => _DocumentList(state: state),
        };
    }
  }
}

/// Tap/long-press behaviour shared by both layouts.
({VoidCallback onTap, VoidCallback onLongPress, bool? selected}) _interaction(
  BuildContext context,
  LibraryState state,
  LibraryDocument document,
) {
  final cubit = context.read<LibraryCubit>();
  return (
    onTap: state.isSelecting
        ? () => cubit.toggleSelected(document.id)
        : () => openDocument(context, document),
    onLongPress: () => cubit.toggleSelected(document.id),
    selected: state.isSelecting
        ? state.selectedIds.contains(document.id)
        : null,
  );
}

class _DocumentGrid extends StatelessWidget {
  const _DocumentGrid({required this.state});

  final LibraryState state;

  @override
  Widget build(BuildContext context) {
    final documents = state.documents;
    // Built lazily: only visible tiles exist, so large libraries scroll
    // without building every cover.
    return GridView.builder(
      key: const Key('library-grid'),
      padding: const EdgeInsets.fromLTRB(
        Spacing.md,
        Spacing.sm,
        Spacing.md,
        Spacing.xxxl * 2,
      ),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        mainAxisSpacing: Spacing.md,
        crossAxisSpacing: Spacing.sm,
        childAspectRatio: 0.52,
      ),
      itemCount: documents.length,
      itemBuilder: (context, index) {
        final document = documents[index];
        final i = _interaction(context, state, document);
        return DocumentGridTile(
          key: ValueKey(document.id),
          document: document,
          onTap: i.onTap,
          onLongPress: i.onLongPress,
          selected: i.selected,
        );
      },
    );
  }
}

class _DocumentList extends StatelessWidget {
  const _DocumentList({required this.state});

  final LibraryState state;

  @override
  Widget build(BuildContext context) {
    final documents = state.documents;
    return ListView.builder(
      key: const Key('library-list'),
      padding: const EdgeInsets.only(top: Spacing.xs, bottom: Spacing.xxxl * 2),
      itemCount: documents.length,
      itemBuilder: (context, index) {
        final document = documents[index];
        final i = _interaction(context, state, document);
        return DocumentListTile(
          key: ValueKey(document.id),
          document: document,
          onTap: i.onTap,
          onLongPress: i.onLongPress,
          selected: i.selected,
        );
      },
    );
  }
}

class _SortButton extends StatelessWidget {
  const _SortButton();

  @override
  Widget build(BuildContext context) {
    final sort = context.select((LibraryCubit c) => c.state.query.sort);
    return PopupMenuButton<LibrarySort>(
      tooltip: 'Sort',
      icon: const Icon(Icons.sort),
      initialValue: sort,
      onSelected: (value) =>
          unawaited(context.read<LibraryCubit>().setSort(value)),
      itemBuilder: (context) => [
        for (final option in LibrarySort.values)
          CheckedPopupMenuItem(
            value: option,
            checked: option == sort,
            child: Text(option.label),
          ),
      ],
    );
  }
}

class _LayoutButton extends StatelessWidget {
  const _LayoutButton();

  @override
  Widget build(BuildContext context) {
    final layout = context.select((LibraryCubit c) => c.state.layout);
    final isGrid = layout == LibraryLayout.grid;
    return IconButton(
      tooltip: isGrid ? 'Show as list' : 'Show as grid',
      icon: Icon(isGrid ? Icons.view_list_outlined : Icons.grid_view_outlined),
      onPressed: () => context.read<LibraryCubit>().setLayout(
        isGrid ? LibraryLayout.list : LibraryLayout.grid,
      ),
    );
  }
}
