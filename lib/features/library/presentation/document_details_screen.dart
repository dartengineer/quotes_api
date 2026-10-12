import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/dialogs.dart';
import '../../../core/widgets/state_views.dart';
import '../../collections/presentation/collection_picker.dart';
import '../../reader/presentation/open_document.dart';
import '../domain/library_document.dart';
import '../domain/reading_status.dart';
import 'document_details_cubit.dart';
import 'widgets/document_cover.dart';
import 'widgets/document_tiles.dart';

class DocumentDetailsScreen extends StatelessWidget {
  const DocumentDetailsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<DocumentDetailsCubit, DocumentDetailsState>(
      // Leave once the document is gone (removed here or elsewhere).
      listenWhen: (previous, current) =>
          previous.status == DetailsStatus.ready &&
          current.status == DetailsStatus.notFound,
      listener: (context, state) {
        if (context.canPop()) context.pop();
      },
      builder: (context, state) {
        return switch (state.status) {
          DetailsStatus.loading => Scaffold(
            appBar: AppBar(),
            body: const LoadingView(),
          ),
          DetailsStatus.failure => Scaffold(
            appBar: AppBar(),
            body: const ErrorStateView(
              message: 'This document could not be loaded.',
            ),
          ),
          DetailsStatus.notFound => Scaffold(
            appBar: AppBar(),
            body: const EmptyStateView(
              icon: Icons.find_in_page_outlined,
              title: 'Not in your library',
              message: 'This document has been removed.',
            ),
          ),
          DetailsStatus.ready => _Details(state: state),
        };
      },
    );
  }
}

enum _DetailsAction { remove }

class _Details extends StatelessWidget {
  const _Details({required this.state});

  final DocumentDetailsState state;

  Future<void> _remove(BuildContext context) async {
    final cubit = context.read<DocumentDetailsCubit>();
    final confirmed = await showConfirmDialog(
      context,
      title: 'Remove from library?',
      message:
          'This removes the document and its bookmarks and notes from '
          'Lectern. The original file on your device isn’t affected.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!confirmed || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    // The screen closes itself when the document disappears.
    await cubit.removeFromLibrary();
    messenger.showSnackBar(
      const SnackBar(content: Text('Removed from library')),
    );
  }

  Future<void> _addToCollection(BuildContext context) async {
    final cubit = context.read<DocumentDetailsCubit>();
    final id = await showCollectionPicker(
      context,
      exclude: {for (final c in state.memberOf) c.id},
    );
    if (id != null) await cubit.addToCollection(id);
  }

  @override
  Widget build(BuildContext context) {
    final document = state.document!;
    final cubit = context.read<DocumentDetailsCubit>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
            tooltip: document.isFavorite
                ? 'Remove from favourites'
                : 'Add to favourites',
            isSelected: document.isFavorite,
            icon: const Icon(Icons.favorite_border),
            selectedIcon: const Icon(Icons.favorite),
            onPressed: cubit.toggleFavorite,
          ),
          // `onSelected` runs with this screen's context; a menu item's own
          // context belongs to the menu route and cannot see the cubit.
          PopupMenuButton<_DetailsAction>(
            tooltip: 'More options',
            onSelected: (action) => switch (action) {
              _DetailsAction.remove => unawaited(_remove(context)),
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: _DetailsAction.remove,
                child: Text('Remove from library…'),
              ),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          Spacing.lg,
          Spacing.sm,
          Spacing.lg,
          Spacing.xxl,
        ),
        children: [
          _Header(document: document),
          if (canRead(document)) ...[
            const SizedBox(height: Spacing.lg),
            FilledButton.icon(
              onPressed: () => openDocument(context, document),
              icon: const Icon(Icons.menu_book_outlined),
              label: Text(document.progress > 0 ? 'Continue reading' : 'Read'),
            ),
          ],
          if (document.progress > 0) ...[
            const SizedBox(height: Spacing.lg),
            ReadingProgressBar(progress: document.progress),
            const SizedBox(height: Spacing.xs),
            Text(
              '${formatPercent(document.progress)} read',
              style: theme.textTheme.labelMedium,
            ),
          ],
          const _Heading('Reading status'),
          SegmentedButton<ReadingStatus>(
            showSelectedIcon: false,
            segments: [
              for (final status in ReadingStatus.values)
                ButtonSegment(value: status, label: Text(status.label)),
            ],
            selected: {document.status},
            onSelectionChanged: (selection) =>
                unawaited(cubit.setStatus(selection.single)),
          ),
          const _Heading('Collections'),
          Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.sm,
            children: [
              for (final collection in state.memberOf)
                InputChip(
                  label: Text(collection.name),
                  onDeleted: () =>
                      unawaited(cubit.removeFromCollection(collection.id)),
                  deleteButtonTooltipMessage: 'Remove from ${collection.name}',
                ),
              ActionChip(
                avatar: const Icon(Icons.add),
                label: const Text('Add to collection'),
                onPressed: () => _addToCollection(context),
              ),
            ],
          ),
          if (state.details?.description case final description?) ...[
            const _Heading('About'),
            _ExpandableText(description),
          ],
          const _Heading('Details'),
          _InfoRow('File', document.originalFileName),
          if (state.details?.publisher case final publisher?)
            _InfoRow('Publisher', publisher),
          if (state.details?.language case final language?)
            _InfoRow('Language', language),
          _InfoRow('Added', _date(context, document.addedAt)),
          _InfoRow(
            'Last opened',
            document.lastOpenedAt == null
                ? 'Never'
                : _date(context, document.lastOpenedAt!),
          ),
          if (state.readingTime > Duration.zero)
            _InfoRow('Reading time', formatDuration(state.readingTime)),
        ],
      ),
    );
  }

  static String _date(BuildContext context, DateTime date) =>
      MaterialLocalizations.of(context).formatMediumDate(date.toLocal());
}

class _Header extends StatelessWidget {
  const _Header({required this.document});

  final LibraryDocument document;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final facts = [
      document.format.label,
      formatFileSize(document.fileSize),
      if (document.pageCount case final pages?) '$pages pages',
    ].join(' · ');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 110,
          height: 165,
          child: DocumentCover(document: document),
        ),
        const SizedBox(width: Spacing.lg),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(document.title, style: theme.textTheme.titleLarge),
              if (document.author case final author?) ...[
                const SizedBox(height: Spacing.xs),
                Text(author, style: theme.textTheme.titleSmall),
              ],
              const SizedBox(height: Spacing.sm),
              Text(
                facts,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: Spacing.xl, bottom: Spacing.sm),
      child: Semantics(
        header: true,
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 104,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

/// Long text that starts collapsed.
class _ExpandableText extends StatefulWidget {
  const _ExpandableText(this.text);

  final String text;

  @override
  State<_ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<_ExpandableText> {
  static const _collapsedLines = 6;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium;
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          maxLines: _collapsedLines,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final overflows = painter.didExceedMaxLines;
        painter.dispose();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.text,
              style: style,
              maxLines: _expanded ? null : _collapsedLines,
              overflow: _expanded ? null : TextOverflow.fade,
            ),
            if (overflows)
              TextButton(
                onPressed: () => setState(() => _expanded = !_expanded),
                child: Text(_expanded ? 'Show less' : 'Show more'),
              ),
          ],
        );
      },
    );
  }
}
