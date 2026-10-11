import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/utils/app_log.dart';
import '../../../../engines/txt/text_document.dart';
import '../../domain/locator.dart';
import '../../domain/search_hit.dart';
import '../../domain/toc_entry.dart';
import '../flow/flow_document.dart';
import '../flow/flow_view.dart';
import '../reader_engines.dart';

/// Reader view for plain-text documents.
///
/// The text is decoded on a background isolate, split into blocks, and shown
/// by the shared [FlowView]: lazily, anchored at the reading position, with
/// positions as exact character offsets.
class TxtReaderView extends StatefulWidget {
  const TxtReaderView({super.key, required this.config});

  final ReaderViewConfig config;

  @override
  State<TxtReaderView> createState() => _TxtReaderViewState();
}

class _TxtReaderViewState extends State<TxtReaderView> {
  TextDocument? _document;
  _TextFlow? _flow;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final document = await _loadInBackground(widget.config.filePath);
      if (mounted) setState(() => _document = document);
    } on TextTooLargeException {
      if (mounted) {
        setState(
          () => _error =
              'This text file is too large to open (the limit is '
              '${TextDocument.maxFileBytes ~/ (1024 * 1024)} MB).',
        );
      }
    } catch (error, stackTrace) {
      AppLog.error('Loading a text document failed', error, stackTrace);
      if (mounted) {
        setState(() => _error = 'This file could not be read.');
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
    final document = _document;
    if (document == null) {
      return Center(
        child: CircularProgressIndicator(
          semanticsLabel: 'Opening document',
          color: palette.secondaryText,
        ),
      );
    }
    return FlowView(
      document: _flow ??= _TextFlow(document),
      config: widget.config,
    );
  }
}

// Created in a top-level function so the isolate closure captures only the
// path (see core/utils/isolates.dart).
Future<TextDocument> _loadInBackground(String path) =>
    Isolate.run(() => loadTextDocument(path));

Future<List<TextMatch>> _searchInBackground(String text, String query) =>
    Isolate.run(() => searchText(text, query));

/// A plain-text document as a column of plain paragraphs. Global offsets
/// are offsets into the decoded text, as in [TextLocator].
class _TextFlow implements FlowDocument {
  _TextFlow(this._doc);

  final TextDocument _doc;

  @override
  int get length => _doc.length;

  @override
  int get blockCount => _doc.blockCount;

  @override
  int blockStart(int index) => _doc.blockStart(index);

  @override
  int blockEnd(int index) => _doc.blockEnd(index);

  @override
  int blockIndexAt(int offset) => _doc.blockIndexAt(offset);

  @override
  ContentBlock blockAt(int index) {
    final end = _doc.blockEnd(index);
    return ContentBlock(
      kind: BlockKind.paragraph,
      start: _doc.blockStart(index),
      end: end,
      // A long line split into several blocks gets no spacing in between.
      continues: end < _doc.length && _doc.text.codeUnitAt(end) != 0x0A,
    );
  }

  @override
  String blockText(int index) => _doc.blockText(index);

  @override
  bool startsSection(int index) => false;

  @override
  double progressAt(int offset) => _doc.progressAt(offset);

  @override
  int offsetAt(double progress) => _doc.offsetAt(progress);

  @override
  Locator locatorAt(int offset) => TextLocator(offset);

  @override
  int? offsetOf(Locator locator) =>
      locator is TextLocator ? locator.offset.clamp(0, _doc.length) : null;

  @override
  String? excerptAt(int offset) => _doc.excerptAt(offset);

  @override
  Future<List<SearchHit>> search(String query) async {
    final matches = await _searchInBackground(_doc.text, query);
    return [
      for (final match in matches)
        SearchHit(
          locator: TextLocator(match.offset),
          progress: _doc.progressAt(match.offset),
          snippet: match.snippet,
          snippetMatchStart: match.snippetMatchStart,
          matchLength: match.length,
        ),
    ];
  }

  /// Plain text has no table of contents.
  @override
  List<TocEntry> get contents => const [];

  @override
  FlowLinkTarget? linkAt(int index, int offsetInBlock) => null;

  @override
  Future<Uint8List?> loadImage(String path) => Future.value();
}
