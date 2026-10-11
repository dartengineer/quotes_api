import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/utils/formatters.dart';
import '../reader_cubit.dart';
import '../reader_view_controller.dart';

Future<void> showBookmarksSheet(
  BuildContext context,
  ReaderViewController controller,
) {
  final cubit = context.read<ReaderCubit>();
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (_) => BlocProvider.value(
      value: cubit,
      child: _BookmarksSheet(controller: controller),
    ),
  );
}

class _BookmarksSheet extends StatelessWidget {
  const _BookmarksSheet({required this.controller});

  final ReaderViewController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bookmarks = context.select((ReaderCubit c) => c.state.bookmarks);
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
            child: Text('Bookmarks', style: theme.textTheme.titleLarge),
          ),
          if (bookmarks.isEmpty)
            Padding(
              padding: const EdgeInsets.all(Spacing.xl),
              child: Text(
                'No bookmarks yet. Use the bookmark button at the top of '
                'the page to mark your place.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: bookmarks.length,
                itemBuilder: (context, index) {
                  final bookmark = bookmarks[index];
                  final date = MaterialLocalizations.of(context)
                      .formatShortDate(bookmark.createdAt.toLocal());
                  return ListTile(
                    leading: const Icon(Icons.bookmark_outline),
                    title: Text(
                      bookmark.label ?? bookmark.excerpt ?? 'Bookmark',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${formatPercent(bookmark.progress)} · $date',
                    ),
                    trailing: IconButton(
                      tooltip: 'Delete bookmark',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => unawaited(
                        context.read<ReaderCubit>().deleteBookmark(bookmark.id),
                      ),
                    ),
                    onTap: () {
                      Navigator.of(context).pop();
                      controller.goTo(bookmark.locator);
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
