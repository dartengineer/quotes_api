import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/utils/load_status.dart';
import '../../../core/widgets/state_views.dart';
import '../domain/library_document.dart';
import '../domain/library_layout.dart';
import '../domain/library_query.dart';
import 'library_cubit.dart';
import 'widgets/document_tiles.dart';

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: const [_SortButton(), _LayoutButton()],
      ),
      body: BlocBuilder<LibraryCubit, LibraryState>(
        builder: (context, state) {
          return switch (state.status) {
            LoadStatus.loading => const LoadingView(),
            LoadStatus.failure => ErrorStateView(
              message: 'Your library could not be loaded.',
              onRetry: context.read<LibraryCubit>().retry,
            ),
            LoadStatus.ready when state.documents.isEmpty =>
              const EmptyStateView(
                icon: Icons.local_library_outlined,
                title: 'No documents yet',
                message:
                    'PDF, EPUB and TXT documents you add will appear here.',
              ),
            LoadStatus.ready => switch (state.layout) {
              LibraryLayout.grid => _DocumentGrid(documents: state.documents),
              LibraryLayout.list => _DocumentList(documents: state.documents),
            },
          };
        },
      ),
    );
  }
}

class _DocumentGrid extends StatelessWidget {
  const _DocumentGrid({required this.documents});

  final List<LibraryDocument> documents;

  @override
  Widget build(BuildContext context) {
    // Built lazily: only visible tiles exist, so large libraries scroll
    // without building every cover.
    return GridView.builder(
      key: const Key('library-grid'),
      padding: const EdgeInsets.all(Spacing.md),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        mainAxisSpacing: Spacing.md,
        crossAxisSpacing: Spacing.sm,
        childAspectRatio: 0.52,
      ),
      itemCount: documents.length,
      itemBuilder: (context, index) {
        final document = documents[index];
        return DocumentGridTile(key: ValueKey(document.id), document: document);
      },
    );
  }
}

class _DocumentList extends StatelessWidget {
  const _DocumentList({required this.documents});

  final List<LibraryDocument> documents;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      key: const Key('library-list'),
      padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
      itemCount: documents.length,
      itemBuilder: (context, index) {
        final document = documents[index];
        return DocumentListTile(key: ValueKey(document.id), document: document);
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
      onSelected: (value) => context.read<LibraryCubit>().setSort(value),
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
