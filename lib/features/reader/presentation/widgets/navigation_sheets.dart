import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../core/theme/tokens.dart';
import '../../domain/locator.dart';
import '../../domain/toc_entry.dart';
import '../reader_cubit.dart';
import '../reader_labels.dart';
import '../reader_view_controller.dart';

/// The document's table of contents, with the current section marked.
Future<void> showContentsSheet(
  BuildContext context,
  ReaderViewController controller,
) {
  final entries = controller.contents;
  final position = context.read<ReaderCubit>().state.position?.locator;
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (context) => _ContentsSheet(
      entries: entries,
      current: position == null ? null : currentEntryIndex(entries, position),
      onSelected: (entry) {
        Navigator.of(context).pop();
        controller.goTo(entry.locator);
      },
    ),
  );
}

/// The last entry that starts at or before [position], or null.
int? currentEntryIndex(List<TocEntry> entries, Locator position) {
  int? current;
  for (final (i, entry) in entries.indexed) {
    final order = compareLocators(entry.locator, position);
    if (order == null) return null;
    if (order <= 0) current = i;
  }
  return current;
}

class _ContentsSheet extends StatefulWidget {
  const _ContentsSheet({
    required this.entries,
    required this.current,
    required this.onSelected,
  });

  final List<TocEntry> entries;
  final int? current;
  final ValueChanged<TocEntry> onSelected;

  @override
  State<_ContentsSheet> createState() => _ContentsSheetState();
}

class _ContentsSheetState extends State<_ContentsSheet> {
  static const _rowHeight = 48.0;
  late final _scroll = ScrollController(
    // Open with the current section in view.
    initialScrollOffset:
        ((widget.current ?? 0) - 2).clamp(0, 1 << 20) * _rowHeight,
  );

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.75,
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
            child: Text('Contents', style: theme.textTheme.titleLarge),
          ),
          Flexible(
            child: ListView.builder(
              controller: _scroll,
              shrinkWrap: true,
              itemExtent: _rowHeight,
              itemCount: widget.entries.length,
              itemBuilder: (context, index) {
                final entry = widget.entries[index];
                final selected = index == widget.current;
                return ListTile(
                  dense: true,
                  selected: selected,
                  contentPadding: EdgeInsetsDirectional.only(
                    start: Spacing.xl + entry.depth.clamp(0, 6) * Spacing.lg,
                    end: Spacing.xl,
                  ),
                  title: Text(
                    entry.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: entry.depth == 0
                        ? const TextStyle(fontWeight: FontWeight.w600)
                        : null,
                  ),
                  trailing: entry.locator is PdfLocator
                      ? Text(locationLabel(entry.locator, 0))
                      : null,
                  onTap: () => widget.onSelected(entry),
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

/// A grid of page thumbnails, rendered lazily as they scroll into view.
Future<void> showPagesSheet(BuildContext context, PagedNavigator pages) {
  final position = context.read<ReaderCubit>().state.position?.locator;
  final current = position is PdfLocator ? position.pageIndex : 0;
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (sheetContext) => _PagesSheet(
      pages: pages,
      current: current,
      onSelected: (index) {
        Navigator.of(sheetContext).pop();
        pages.goToPage(index);
      },
    ),
  );
}

class _PagesSheet extends StatefulWidget {
  const _PagesSheet({
    required this.pages,
    required this.current,
    required this.onSelected,
  });

  final PagedNavigator pages;
  final int current;
  final ValueChanged<int> onSelected;

  @override
  State<_PagesSheet> createState() => _PagesSheetState();
}

class _PagesSheetState extends State<_PagesSheet> {
  static const _columns = 3;
  static const _aspectRatio = 0.62;

  /// Created on first layout, when the row height is known.
  ScrollController? _scroll;

  @override
  void dispose() {
    _scroll?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = widget.pages;
    final theme = Theme.of(context);
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.8,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.xl,
              0,
              Spacing.xl,
              Spacing.sm,
            ),
            child: Text('Pages', style: theme.textTheme.titleLarge),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                const padding = Spacing.lg;
                const spacing = Spacing.md;
                final cellWidth =
                    (constraints.maxWidth - padding * 2 - spacing * 2) /
                    _columns;
                final rowHeight = cellWidth / _aspectRatio + spacing;
                // Open with the current page in view, below one row of
                // context.
                final scroll = _scroll ??= ScrollController(
                  initialScrollOffset: math.max(
                    0,
                    (widget.current ~/ _columns - 1) * rowHeight,
                  ),
                );
                return GridView.builder(
                  controller: scroll,
                  padding: const EdgeInsets.all(padding),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: _columns,
                    childAspectRatio: _aspectRatio,
                    mainAxisSpacing: spacing,
                    crossAxisSpacing: spacing,
                  ),
                  itemCount: pages.pageCount,
                  itemBuilder: (context, index) => _PageCell(
                    index: index,
                    selected: index == widget.current,
                    thumbnail: pages.buildPageThumbnail(context, index),
                    onTap: () => widget.onSelected(index),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _PageCell extends StatelessWidget {
  const _PageCell({
    required this.index,
    required this.selected,
    required this.thumbnail,
    required this.onTap,
  });

  final int index;
  final bool selected;
  final Widget thumbnail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      label: 'Page ${index + 1}',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.sm),
        child: Column(
          children: [
            Expanded(
              child: DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: selected ? scheme.primary : Colors.transparent,
                    width: 3,
                  ),
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: thumbnail,
                ),
              ),
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              '${index + 1}',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: selected ? scheme.primary : null,
                fontWeight: selected ? FontWeight.w700 : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Asks for a page number and goes there.
Future<void> showGoToPageDialog(BuildContext context, PagedNavigator pages) {
  return showDialog<void>(
    context: context,
    builder: (_) => _GoToPageDialog(pages: pages),
  );
}

class _GoToPageDialog extends StatefulWidget {
  const _GoToPageDialog({required this.pages});

  final PagedNavigator pages;

  @override
  State<_GoToPageDialog> createState() => _GoToPageDialogState();
}

class _GoToPageDialogState extends State<_GoToPageDialog> {
  final _field = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _submit() {
    final count = widget.pages.pageCount;
    final page = int.tryParse(_field.text.trim());
    if (page == null || page < 1 || page > count) {
      setState(() => _error = 'Enter a number from 1 to $count');
      return;
    }
    Navigator.of(context).pop();
    widget.pages.goToPage(page - 1);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Go to page'),
      content: TextField(
        controller: _field,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        textInputAction: TextInputAction.go,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          labelText: 'Page (1–${widget.pages.pageCount})',
          errorText: _error,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Go')),
      ],
    );
  }
}
