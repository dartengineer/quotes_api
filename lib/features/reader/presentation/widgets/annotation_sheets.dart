import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../core/files/file_saver.dart';
import '../../../../core/theme/tokens.dart';
import '../../../../core/utils/app_log.dart';
import '../../domain/annotation.dart';
import '../../domain/annotation_export.dart';
import '../reader_cubit.dart';
import '../reader_labels.dart';
import '../reader_view_controller.dart';

/// What to do with selected text.
sealed class SelectionChoice {
  const SelectionChoice();
}

final class HighlightChoice extends SelectionChoice {
  const HighlightChoice(this.color);

  final HighlightColor color;
}

final class NoteChoice extends SelectionChoice {
  const NoteChoice();
}

final class CopyChoice extends SelectionChoice {
  const CopyChoice();
}

/// Handles a finished selection: highlight it, add a note or copy it.
Future<void> handleSelection(
  BuildContext context,
  AnnotationDraft draft,
) async {
  final cubit = context.read<ReaderCubit>();
  final messenger = ScaffoldMessenger.maybeOf(context);
  final choice = await showModalBottomSheet<SelectionChoice>(
    context: context,
    useSafeArea: true,
    builder: (_) => _SelectionSheet(text: draft.text),
  );
  if (!context.mounted) return;
  switch (choice) {
    case HighlightChoice(:final color):
      await cubit.addAnnotation(draft, color: color);
    case NoteChoice():
      final note = await showNoteEditor(context, excerpt: draft.text);
      if (note != null && note.trim().isNotEmpty) {
        await cubit.addAnnotation(draft, note: note);
      }
    case CopyChoice():
      await Clipboard.setData(ClipboardData(text: draft.text));
      messenger?.showSnackBar(const SnackBar(content: Text('Copied')));
    case null:
      break;
  }
}

class _SelectionSheet extends StatelessWidget {
  const _SelectionSheet({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Spacing.xl, 0, Spacing.xl, Spacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Excerpt(text),
          const SizedBox(height: Spacing.lg),
          Text('Highlight', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: Spacing.sm),
          _ColorRow(
            onSelected: (color) =>
                Navigator.of(context).pop(HighlightChoice(color)),
          ),
          const SizedBox(height: Spacing.md),
          Wrap(
            spacing: Spacing.sm,
            children: [
              TextButton.icon(
                onPressed: () => Navigator.of(context).pop(const NoteChoice()),
                icon: const Icon(Icons.edit_note),
                label: const Text('Add note'),
              ),
              TextButton.icon(
                onPressed: () => Navigator.of(context).pop(const CopyChoice()),
                icon: const Icon(Icons.copy),
                label: const Text('Copy'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Edits a note. Returns the new text (empty to remove the note), or null if
/// the user cancelled.
Future<String?> showNoteEditor(
  BuildContext context, {
  String? initial,
  required String excerpt,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _NoteDialog(initial: initial, excerpt: excerpt),
  );
}

class _NoteDialog extends StatefulWidget {
  const _NoteDialog({required this.initial, required this.excerpt});

  final String? initial;
  final String excerpt;

  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  late final _field = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      // Scrolls rather than overflows with large text or the keyboard up.
      scrollable: true,
      title: Text(widget.initial == null ? 'Add note' : 'Edit note'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Excerpt(widget.excerpt, maxLines: 2),
            const SizedBox(height: Spacing.md),
            TextField(
              controller: _field,
              autofocus: true,
              minLines: 3,
              maxLines: 8,
              maxLength: 10000,
              maxLengthEnforcement: MaxLengthEnforcement.enforced,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: 'Your note',
                border: OutlineInputBorder(),
                counterText: '',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_field.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Details of a highlight: change its colour, edit its note, copy or
/// delete it.
Future<void> showAnnotationSheet(BuildContext context, Annotation annotation) {
  final cubit = context.read<ReaderCubit>();
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (_) => BlocProvider.value(
      value: cubit,
      child: _AnnotationSheet(id: annotation.id),
    ),
  );
}

class _AnnotationSheet extends StatelessWidget {
  const _AnnotationSheet({required this.id});

  final int id;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<ReaderCubit>();
    // Follows edits made from this sheet.
    final annotation = context.select(
      (ReaderCubit c) =>
          c.state.annotations.where((a) => a.id == id).firstOrNull,
    );
    if (annotation == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Spacing.xl, 0, Spacing.xl, Spacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            locationLabel(annotation.range.start, annotation.progress),
            style: theme.textTheme.labelLarge,
          ),
          const SizedBox(height: Spacing.sm),
          _Excerpt(annotation.text, maxLines: 6),
          if (annotation.hasNote) ...[
            const SizedBox(height: Spacing.md),
            Text(annotation.note!, style: theme.textTheme.bodyLarge),
          ],
          const SizedBox(height: Spacing.lg),
          _ColorRow(
            selected: annotation.color,
            onSelected: (color) =>
                unawaited(cubit.setAnnotationColor(annotation.id, color)),
          ),
          const SizedBox(height: Spacing.md),
          Wrap(
            spacing: Spacing.sm,
            children: [
              TextButton.icon(
                onPressed: () async {
                  final note = await showNoteEditor(
                    context,
                    initial: annotation.note,
                    excerpt: annotation.text,
                  );
                  if (note != null) {
                    await cubit.setAnnotationNote(annotation.id, note);
                  }
                },
                icon: const Icon(Icons.edit_note),
                label: Text(annotation.hasNote ? 'Edit note' : 'Add note'),
              ),
              TextButton.icon(
                onPressed: () async {
                  final messenger = ScaffoldMessenger.maybeOf(context);
                  await Clipboard.setData(ClipboardData(text: annotation.text));
                  messenger?.showSnackBar(
                    const SnackBar(content: Text('Copied')),
                  );
                },
                icon: const Icon(Icons.copy),
                label: const Text('Copy'),
              ),
              TextButton.icon(
                onPressed: () => _delete(context, annotation),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Deletes [annotation], offering to undo.
Future<void> _delete(BuildContext context, Annotation annotation) async {
  final cubit = context.read<ReaderCubit>();
  final messenger = ScaffoldMessenger.maybeOf(context);
  Navigator.of(context).pop();
  await cubit.deleteAnnotation(annotation.id);
  messenger?.showSnackBar(
    SnackBar(
      content: const Text('Highlight deleted'),
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () => unawaited(
          cubit.addAnnotation(
            AnnotationDraft(
              range: annotation.range,
              progress: annotation.progress,
              text: annotation.text,
            ),
            color: annotation.color,
            note: annotation.note,
          ),
        ),
      ),
    ),
  );
}

/// All highlights and notes of the document, in reading order.
Future<void> showAnnotationsSheet(
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
      child: _AnnotationsSheet(controller: controller),
    ),
  );
}

class _AnnotationsSheet extends StatelessWidget {
  const _AnnotationsSheet({required this.controller});

  final ReaderViewController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final annotations = context.select((ReaderCubit c) => c.state.annotations);
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.8,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.xl,
              0,
              Spacing.md,
              Spacing.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Highlights & notes',
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                if (annotations.isNotEmpty)
                  IconButton(
                    tooltip: 'Export',
                    icon: const Icon(Icons.ios_share),
                    onPressed: () => _export(context, annotations),
                  ),
              ],
            ),
          ),
          if (annotations.isEmpty)
            Padding(
              padding: const EdgeInsets.all(Spacing.xl),
              child: Text(
                'No highlights yet. Long-press the text to select it, then '
                'choose a colour or add a note.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: annotations.length,
                itemBuilder: (context, index) {
                  final annotation = annotations[index];
                  return ListTile(
                    leading: Container(
                      width: 6,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Color(annotation.color.argb),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    title: Text(
                      annotation.text,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      [
                        if (annotation.hasNote) annotation.note!.trim(),
                        locationLabel(
                          annotation.range.start,
                          annotation.progress,
                        ),
                      ].join('\n'),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      tooltip: 'Edit highlight',
                      icon: const Icon(Icons.more_horiz),
                      onPressed: () =>
                          unawaited(showAnnotationSheet(context, annotation)),
                    ),
                    onTap: () {
                      Navigator.of(context).pop();
                      controller.goTo(annotation.range.start);
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

  /// Saves the highlights as a Markdown file where the user chooses.
  Future<void> _export(
    BuildContext context,
    List<Annotation> annotations,
  ) async {
    final document = context.read<ReaderCubit>().state.document;
    if (document == null) return;
    final saver = context.read<FileSaver>();
    final messenger = ScaffoldMessenger.maybeOf(context);
    final markdown = annotationsToMarkdown(
      title: document.title,
      author: document.author,
      annotations: annotations,
      location: (a) => locationLabel(a.range.start, a.progress),
      exportedAt: DateTime.now(),
    );
    try {
      final saved = await saver.save(
        fileName: '${exportFileStem(document.title)} - highlights.md',
        bytes: utf8.encode(markdown),
        mimeType: 'text/markdown',
      );
      if (saved) {
        messenger?.showSnackBar(
          const SnackBar(content: Text('Highlights exported')),
        );
      }
    } catch (error, stackTrace) {
      AppLog.error('Exporting highlights failed', error, stackTrace);
      messenger?.showSnackBar(
        const SnackBar(content: Text('The highlights couldn’t be exported.')),
      );
    }
  }
}

/// A file name stem from a document title: no path separators or
/// characters file systems reject, bounded in length.
String exportFileStem(String title) {
  final cleaned = title
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (cleaned.isEmpty) return 'Document';
  return cleaned.length <= 80 ? cleaned : cleaned.substring(0, 80).trim();
}

class _Excerpt extends StatelessWidget {
  const _Excerpt(this.text, {this.maxLines = 3});

  final String text;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.only(left: Spacing.md),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: theme.colorScheme.outlineVariant, width: 3),
        ),
      ),
      child: Text(
        text,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }
}

class _ColorRow extends StatelessWidget {
  const _ColorRow({required this.onSelected, this.selected});

  final ValueChanged<HighlightColor> onSelected;
  final HighlightColor? selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: Spacing.md,
      children: [
        for (final color in HighlightColor.values)
          Semantics(
            selected: color == selected,
            child: IconButton(
              tooltip: 'Highlight ${color.label.toLowerCase()}',
              onPressed: () => onSelected(color),
              icon: DecoratedBox(
                decoration: BoxDecoration(
                  color: Color(color.argb),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: color == selected
                        ? scheme.onSurface
                        : scheme.outlineVariant,
                    width: color == selected ? 3 : 1,
                  ),
                ),
                child: const SizedBox.square(dimension: 28),
              ),
            ),
          ),
      ],
    );
  }
}
