import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme/tokens.dart';
import '../../reader/presentation/open_document.dart';
import '../domain/import_outcome.dart';
import 'import_cubit.dart';

/// Opens the import sheet whenever an import starts, wherever it was
/// started from, and reports picker failures.
class ImportProgressListener extends StatefulWidget {
  const ImportProgressListener({super.key, required this.child});

  final Widget child;

  @override
  State<ImportProgressListener> createState() => _ImportProgressListenerState();
}

class _ImportProgressListenerState extends State<ImportProgressListener> {
  bool _sheetVisible = false;

  Future<void> _showSheet(BuildContext context) async {
    _sheetVisible = true;
    final cubit = context.read<ImportCubit>();
    // The sheet closes with the id of a document to open, if any.
    final documentId = await showModalBottomSheet<int>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) =>
          BlocProvider.value(value: cubit, child: const ImportSheet()),
    );
    _sheetVisible = false;
    cubit.dismiss();
    if (documentId != null && context.mounted) {
      await openDocumentById(context, documentId);
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<ImportCubit, ImportState>(
      listener: (context, state) {
        if (state is ImportPickerFailed) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('The file picker couldn’t be opened.'),
            ),
          );
          context.read<ImportCubit>().dismiss();
        } else if (state.isBusy && !_sheetVisible) {
          unawaited(_showSheet(context));
        }
      },
      child: widget.child,
    );
  }
}

/// Progress while importing, then a summary of what happened to each file.
class ImportSheet extends StatefulWidget {
  const ImportSheet({super.key});

  @override
  State<ImportSheet> createState() => _ImportSheetState();

  static int _ordinal(ImportProgress progress) =>
      (progress.completed + 1).clamp(1, progress.total);
}

class _ImportSheetState extends State<ImportSheet> {
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    // The import may have ended before this sheet was built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _closeIfDone(context.read<ImportCubit>().state);
    });
  }

  /// Closes the sheet without waiting for the user when there is nothing
  /// to show (the picker came back empty after "preparing", e.g. every copy
  /// failed) or when the imported document should open right away.
  void _closeIfDone(ImportState state) {
    // Once the sheet is closing (e.g. the user tapped Done, which resets the
    // state), popping again would close the screen underneath instead.
    if (_closing || !(ModalRoute.of(context)?.isCurrent ?? false)) return;
    final int? documentId;
    switch (state) {
      case ImportIdle():
        documentId = null;
      case ImportFinished(:final documentToOpen?):
        documentId = documentToOpen;
      default:
        return;
    }
    _closing = true;
    // Not maybePop: this runs before the rebuild, while the PopScope still
    // blocks closing for the import that just ended.
    Navigator.of(context).pop(documentId);
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<ImportCubit, ImportState>(
      listener: (context, state) => _closeIfDone(state),
      builder: (context, state) {
        return PopScope(
          canPop: !state.isBusy,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.xl,
              0,
              Spacing.xl,
              Spacing.xl,
            ),
            child: switch (state) {
              ImportPreparing() => const _Busy(
                title: 'Preparing files…',
                detail: 'Large files can take a moment.',
              ),
              ImportRunning(:final progress, :final cancelling) => _Busy(
                title: cancelling
                    ? 'Stopping…'
                    : 'Importing ${ImportSheet._ordinal(progress)} '
                          'of ${progress.total}',
                detail: progress.currentFileName,
                value: progress.total == 0
                    ? null
                    : progress.completed / progress.total,
                onCancel: cancelling
                    ? null
                    : context.read<ImportCubit>().cancel,
              ),
              ImportFinished(:final report) => _Summary(report: report),
              _ => const SizedBox.shrink(),
            },
          ),
        );
      },
    );
  }
}

class _Busy extends StatelessWidget {
  const _Busy({required this.title, this.detail, this.value, this.onCancel});

  final String title;
  final String? detail;
  final double? value;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          liveRegion: true,
          child: Text(title, style: theme.textTheme.titleLarge),
        ),
        const SizedBox(height: Spacing.lg),
        LinearProgressIndicator(value: value),
        const SizedBox(height: Spacing.sm),
        Text(
          detail ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: Spacing.md),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(onPressed: onCancel, child: const Text('Cancel')),
        ),
      ],
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.report});

  final ImportReport report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final imported = report.imported;
    final duplicates = report.duplicates;
    final problems = report.problems;
    final needPassword = imported.where((o) => o.needsPassword).length;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          liveRegion: true,
          child: Text(
            report.cancelled ? 'Import stopped' : 'Import finished',
            style: theme.textTheme.titleLarge,
          ),
        ),
        const SizedBox(height: Spacing.md),
        if (imported.isNotEmpty)
          _SummaryRow(
            icon: Icons.check_circle_outline,
            text: '${_count(imported.length, 'document')} added',
          ),
        if (duplicates.isNotEmpty)
          _SummaryRow(
            icon: Icons.library_books_outlined,
            text:
                '${_count(duplicates.length, 'document')} already in your library',
          ),
        if (problems.isNotEmpty)
          _SummaryRow(
            icon: Icons.error_outline,
            color: theme.colorScheme.error,
            text: '${_count(problems.length, 'file')} not imported',
          ),
        if (report.cancelled && report.skipped > 0)
          _SummaryRow(
            icon: Icons.block,
            text: '${_count(report.skipped, 'file')} skipped',
          ),
        if (report.outcomes.isEmpty && !report.cancelled)
          const _SummaryRow(
            icon: Icons.info_outline,
            text: 'Nothing to import.',
          ),
        if (needPassword > 0)
          _SummaryRow(
            icon: Icons.lock_outline,
            text:
                '${_count(needPassword, 'PDF')} ${needPassword == 1 ? 'needs' : 'need'} '
                'a password, which you’ll be asked for when opening.',
          ),
        if (problems.isNotEmpty) ...[
          const SizedBox(height: Spacing.md),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final problem in problems)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      problem.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(switch (problem) {
                      RejectedOutcome() => problem.message,
                      _ => 'Something went wrong while importing this file.',
                    }),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: Spacing.lg),
        if (report.singleDocumentId case final documentId?)
          OverflowBar(
            alignment: MainAxisAlignment.end,
            spacing: Spacing.sm,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(documentId),
                child: const Text('Open'),
              ),
            ],
          )
        else
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done'),
            ),
          ),
      ],
    );
  }

  static String _count(int count, String noun) =>
      '$count ${count == 1 ? noun : '${noun}s'}';
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.icon, required this.text, this.color});

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: Spacing.md),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
