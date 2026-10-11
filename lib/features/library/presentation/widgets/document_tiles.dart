import 'package:material_ui/material_ui.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/utils/formatters.dart';
import '../../domain/library_document.dart';
import '../../domain/reading_status.dart';
import 'document_cover.dart';

/// Builds the screen-reader description shared by all document tiles.
String documentSemanticsLabel(LibraryDocument document) {
  final parts = <String>[
    document.title,
    if (document.author case final author?) 'by $author',
    document.format.label,
    if (document.status == ReadingStatus.finished)
      'finished'
    else if (document.progress > 0)
      '${formatPercent(document.progress)} read',
    if (document.isFavorite) 'favourite',
  ];
  return parts.join(', ');
}

/// A thin progress bar for reading progress.
class ReadingProgressBar extends StatelessWidget {
  const ReadingProgressBar({super.key, required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: Radii.smAll,
      child: LinearProgressIndicator(
        value: progress.clamp(0.0, 1.0),
        minHeight: 3,
      ),
    );
  }
}

/// Cover-first tile for grid layouts.
class DocumentGridTile extends StatelessWidget {
  const DocumentGridTile({
    super.key,
    required this.document,
    this.onTap,
    this.onLongPress,
    this.selected,
  });

  final LibraryDocument document;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Null when selection is not active; otherwise whether this is selected.
  final bool? selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSelected = selected ?? false;
    return Semantics(
      label: documentSemanticsLabel(document),
      button: onTap != null,
      selected: selected,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: Radii.mdAll,
        child: Padding(
          padding: const EdgeInsets.all(Spacing.xs),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    AnimatedScale(
                      scale: isSelected ? 0.92 : 1,
                      duration: const Duration(milliseconds: 120),
                      child: DocumentCover(document: document),
                    ),
                    if (document.isFavorite)
                      const Positioned(
                        right: Spacing.xs,
                        bottom: Spacing.xs,
                        child: _Badge(icon: Icons.favorite),
                      ),
                    if (selected != null)
                      Positioned(
                        left: Spacing.xs,
                        top: Spacing.xs,
                        child: _SelectionMark(selected: isSelected),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: Spacing.sm),
              Text(
                document.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
              if (document.author case final author?)
                Text(
                  author,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              if (document.progress > 0) ...[
                const SizedBox(height: Spacing.xs),
                ReadingProgressBar(progress: document.progress),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact row tile for list layouts.
class DocumentListTile extends StatelessWidget {
  const DocumentListTile({
    super.key,
    required this.document,
    this.onTap,
    this.onLongPress,
    this.selected,
  });

  final LibraryDocument document;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool? selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final details = [
      document.format.label,
      formatFileSize(document.fileSize),
      if (document.pageCount case final pages?) '$pages pages',
    ].join(' · ');

    return Semantics(
      label: documentSemanticsLabel(document),
      button: onTap != null,
      selected: selected,
      excludeSemantics: true,
      child: Material(
        color: (selected ?? false)
            ? theme.colorScheme.secondaryContainer
            : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.lg,
              vertical: Spacing.sm,
            ),
            child: Row(
              children: [
                if (selected case final isSelected?) ...[
                  _SelectionMark(selected: isSelected),
                  const SizedBox(width: Spacing.md),
                ],
                SizedBox(
                  width: 44,
                  height: 64,
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
                        style: theme.textTheme.titleSmall,
                      ),
                      if (document.author case final author?)
                        Text(
                          author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      Text(
                        details,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (document.progress > 0) ...[
                        const SizedBox(height: Spacing.xs),
                        ReadingProgressBar(progress: document.progress),
                      ],
                    ],
                  ),
                ),
                if (document.isFavorite) ...[
                  const SizedBox(width: Spacing.sm),
                  Icon(
                    Icons.favorite,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.9),
        shape: BoxShape.circle,
      ),
      child: Padding(
        padding: const EdgeInsets.all(Spacing.xs),
        child: Icon(icon, size: 14, color: scheme.primary),
      ),
    );
  }
}

class _SelectionMark extends StatelessWidget {
  const _SelectionMark({required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: selected
            ? scheme.primary
            : scheme.surface.withValues(alpha: 0.9),
        shape: BoxShape.circle,
        border: Border.all(color: scheme.primary, width: 2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Icon(
          Icons.check,
          size: 16,
          color: selected ? scheme.onPrimary : Colors.transparent,
        ),
      ),
    );
  }
}
