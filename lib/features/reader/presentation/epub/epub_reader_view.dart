import 'dart:async';
import 'dart:isolate';

import 'package:material_ui/material_ui.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/utils/app_log.dart';
import '../../../../engines/epub/epub_book.dart';
import '../../../../engines/epub/epub_package.dart';
import '../flow/flow_view.dart';
import '../reader_engines.dart';
import 'epub_flow.dart';

/// Reader view for reflowable EPUBs, with Lectern's own engine: chapters
/// are reduced to safe, styled text blocks on a background isolate and shown
/// with the reader's typography by the shared [FlowView].
class EpubReaderView extends StatefulWidget {
  const EpubReaderView({super.key, required this.config});

  final ReaderViewConfig config;

  @override
  State<EpubReaderView> createState() => _EpubReaderViewState();
}

class _EpubReaderViewState extends State<EpubReaderView> {
  EpubFlow? _flow;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final path = widget.config.filePath;
    try {
      final book = await _loadInBackground(path);
      if (mounted) setState(() => _flow = EpubFlow(book, path));
    } on EpubException catch (error) {
      if (!mounted) return;
      setState(
        () => _error = switch (error.problem) {
          EpubProblem.drmProtected =>
            'This book is DRM-protected and can’t be opened.',
          EpubProblem.damaged =>
            'This book can’t be opened. The file may be damaged.',
        },
      );
    } catch (error, stackTrace) {
      AppLog.error('Opening a book failed', error, stackTrace);
      if (mounted) {
        setState(
          () => _error = 'This book can’t be opened. The file may be damaged.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.config.palette;
    if (_error case final error?) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Spacing.xl),
          child: Text(
            error,
            textAlign: TextAlign.center,
            style: TextStyle(color: palette.text, fontSize: 16),
          ),
        ),
      );
    }
    final flow = _flow;
    if (flow == null) {
      return Center(
        child: CircularProgressIndicator(
          semanticsLabel: 'Opening book',
          color: palette.secondaryText,
        ),
      );
    }
    return FlowView(document: flow, config: widget.config);
  }
}

// Created in a top-level function so the isolate closure captures only the
// path.
Future<EpubBook> _loadInBackground(String path) =>
    Isolate.run(() => loadEpubBook(path));
