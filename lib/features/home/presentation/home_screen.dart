import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/app_info.dart';
import '../../../app/routes.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/utils/load_status.dart';
import '../../../core/widgets/section_header.dart';
import '../../../core/widgets/state_views.dart';
import '../../library/domain/library_document.dart';
import '../../library/presentation/widgets/document_cover.dart';
import '../../library/presentation/widgets/document_tiles.dart';
import 'home_cubit.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(AppInfo.name)),
      body: BlocBuilder<HomeCubit, HomeState>(
        builder: (context, state) {
          return switch (state.status) {
            LoadStatus.loading => const LoadingView(),
            LoadStatus.failure => ErrorStateView(
              message: 'Your reading overview could not be loaded.',
              onRetry: context.read<HomeCubit>().retry,
            ),
            LoadStatus.ready when state.isLibraryEmpty => EmptyStateView(
              icon: Icons.auto_stories_outlined,
              title: 'Welcome to ${AppInfo.name}',
              message: 'Books and documents you are reading will show up here.',
              action: FilledButton.tonal(
                onPressed: () => context.go(Routes.library),
                child: const Text('Open library'),
              ),
            ),
            LoadStatus.ready => _HomeContent(state: state),
          };
        },
      ),
    );
  }
}

class _HomeContent extends StatelessWidget {
  const _HomeContent({required this.state});

  final HomeState state;

  @override
  Widget build(BuildContext context) {
    final current = state.continueReading.firstOrNull;
    return ListView(
      padding: const EdgeInsets.only(bottom: Spacing.xl),
      children: [
        if (current != null) ...[
          const SectionHeader(title: 'Continue reading'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
            child: _ContinueReadingCard(document: current),
          ),
        ],
        if (state.recentlyOpened.isNotEmpty) ...[
          const SectionHeader(title: 'Recently opened'),
          _CoverStrip(documents: state.recentlyOpened),
        ],
        SectionHeader(
          title: 'Recently added',
          actionLabel: 'See all',
          onAction: () => context.go(Routes.library),
        ),
        _CoverStrip(documents: state.recentlyAdded),
      ],
    );
  }
}

class _ContinueReadingCard extends StatelessWidget {
  const _ContinueReadingCard({required this.document});

  final LibraryDocument document;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Semantics(
        label: documentSemanticsLabel(document),
        excludeSemantics: true,
        child: Padding(
          padding: const EdgeInsets.all(Spacing.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 72,
                height: 104,
                child: DocumentCover(document: document),
              ),
              const SizedBox(width: Spacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      document.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                    if (document.author case final author?)
                      Text(
                        author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    const SizedBox(height: Spacing.md),
                    ReadingProgressBar(progress: document.progress),
                    const SizedBox(height: Spacing.xs),
                    Text(
                      '${formatPercent(document.progress)} read',
                      style: theme.textTheme.labelMedium,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A horizontally scrolling row of covers.
class _CoverStrip extends StatelessWidget {
  const _CoverStrip({required this.documents});

  static const _tileWidth = 116.0;

  final List<LibraryDocument> documents;

  @override
  Widget build(BuildContext context) {
    // Leave room for two lines of title and one of author at the current
    // text size, on top of a book-proportioned cover.
    final textHeight = MediaQuery.textScalerOf(context).scale(64);
    return SizedBox(
      height: _tileWidth * 1.5 + textHeight + Spacing.lg,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
        itemCount: documents.length,
        separatorBuilder: (context, index) => const SizedBox(width: Spacing.xs),
        itemBuilder: (context, index) {
          final document = documents[index];
          return SizedBox(
            key: ValueKey(document.id),
            width: _tileWidth,
            child: DocumentGridTile(document: document),
          );
        },
      ),
    );
  }
}
