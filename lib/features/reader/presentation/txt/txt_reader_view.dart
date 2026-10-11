import 'dart:async';
import 'dart:isolate';

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/utils/app_log.dart';
import '../../../../engines/txt/text_document.dart';
import '../../domain/locator.dart';
import '../../domain/search_hit.dart';
import '../../domain/toc_entry.dart';
import '../reader_engines.dart';
import '../reader_view_controller.dart';

/// Reader view for plain-text documents.
///
/// The text is decoded on a background isolate, split into blocks, and shown
/// in a lazily built scroll view anchored at the block that contains the
/// reading position, so opening a large file deep in never lays out the text
/// before it. Positions are character offsets measured from the laid-out
/// text, so they are exact and survive font, size and rotation changes.
class TxtReaderView extends StatefulWidget {
  const TxtReaderView({super.key, required this.config});

  final ReaderViewConfig config;

  @override
  State<TxtReaderView> createState() => _TxtReaderViewState();
}

class _TxtReaderViewState extends State<TxtReaderView> {
  TextDocument? _document;
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
    return _TextPages(document: document, config: widget.config);
  }
}

// Created in a top-level function so the isolate closure captures only the
// path (see core/utils/isolates.dart).
Future<TextDocument> _loadInBackground(String path) =>
    Isolate.run(() => loadTextDocument(path));

Future<List<TextMatch>> _searchInBackground(String text, String query) =>
    Isolate.run(() => searchText(text, query));

class _TextPages extends StatefulWidget {
  const _TextPages({required this.document, required this.config});

  final TextDocument document;
  final ReaderViewConfig config;

  @override
  State<_TextPages> createState() => _TextPagesState();
}

class _TextPagesState extends State<_TextPages> implements ReaderNavigator {
  final _scroll = ScrollController();
  final _viewportKey = GlobalKey();
  final Map<int, _TextBlockState> _mounted = {};

  /// Index of the block the scroll view is anchored at (scroll offset 0).
  int _anchor = 0;
  Key _centerKey = const ValueKey('anchor-0-0');
  int _generation = 0;

  /// Character offset to align with the top of the view after layout.
  int? _pendingOffset;
  int _pendingAttempts = 0;

  /// Hidden until the initial position has been applied, so the start of
  /// the anchor block never flashes before the real position.
  bool _positioned = false;

  int _currentOffset = 0;
  double? _lastWidth;
  bool _measureScheduled = false;

  TextRange? _highlight;
  Timer? _highlightTimer;

  TextDocument get _doc => widget.document;
  ReaderViewConfig get _config => widget.config;

  @override
  void initState() {
    super.initState();
    _config.controller.attach(this);
    final initial = _config.initialLocator;
    _anchorAt(initial is TextLocator ? initial.offset : 0);
  }

  @override
  void didUpdateWidget(covariant _TextPages oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.config.controller, _config.controller)) {
      oldWidget.config.controller.detach(this);
      _config.controller.attach(this);
    }
    final before = oldWidget.config.preferences;
    final after = _config.preferences;
    final layoutChanged =
        before.fontSize != after.fontSize ||
        before.lineHeight != after.lineHeight ||
        before.paragraphSpacing != after.paragraphSpacing ||
        before.margin != after.margin ||
        before.font != after.font ||
        before.justify != after.justify;
    // Text reflows: keep the same character at the top.
    if (layoutChanged) _anchorAt(_currentOffset);
  }

  @override
  void dispose() {
    _config.controller.detach(this);
    _highlightTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  // --- Anchoring ------------------------------------------------------------

  /// Rebuilds the list around the block containing [offset] and aligns that
  /// character with the top of the view once laid out.
  void _anchorAt(int offset) {
    final target = offset.clamp(0, _doc.length);
    _anchor = _doc.blockIndexAt(target);
    _centerKey = ValueKey('anchor-$_anchor-${_generation++}');
    _pendingOffset = target;
    _pendingAttempts = 0;
    _currentOffset = target;
    if (_scroll.hasClients) _scroll.jumpTo(0);
    if (mounted) setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => _applyPendingOffset());
  }

  void _applyPendingOffset() {
    final pending = _pendingOffset;
    if (!mounted || pending == null) return;
    final block = _mounted[_anchor];
    final paragraph = block?.paragraph;
    if (paragraph == null || !paragraph.hasSize || !_scroll.hasClients) {
      // Not laid out yet; try again next frame (bounded).
      if (_pendingAttempts++ < 10) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _applyPendingOffset(),
        );
        WidgetsBinding.instance.scheduleFrame();
      }
      return;
    }
    final local = (pending - _doc.blockStart(_anchor)).clamp(
      0,
      _doc.blockEnd(_anchor) - _doc.blockStart(_anchor),
    );
    final caret = paragraph.getOffsetForCaret(
      TextPosition(offset: local),
      Rect.zero,
    );
    // Near the end of the document the anchor cannot reach the top; the
    // blocks after it are all built then, so the maximum extent is exact.
    final position = _scroll.position;
    _scroll.jumpTo(
      caret.dy.clamp(position.minScrollExtent, position.maxScrollExtent),
    );
    _pendingOffset = null;
    if (!_positioned) setState(() => _positioned = true);
    _scheduleMeasure();
  }

  // --- Measuring the visible position --------------------------------------

  /// Measures the visible position after the next frame. Requests within
  /// one frame are coalesced, so this runs at most once per frame however
  /// many scroll notifications arrive.
  void _scheduleMeasure() {
    if (_measureScheduled) return;
    _measureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      if (!mounted || _pendingOffset != null) return;
      final position = _measure();
      if (position != null) _config.onPosition(position);
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  ReaderPosition? _measure() {
    final viewport = _viewportKey.currentContext?.findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize) return null;
    final height = viewport.size.height;
    const topLine = 2.0;

    int? topIndex;
    var topLocalY = 0.0;
    int? bottomIndex;
    var bottomLocalY = 0.0;
    int? firstVisible;
    int? lastVisible;
    var endVisible = false;

    for (final MapEntry(key: index, value: block) in _mounted.entries) {
      final box = block.context.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final dy = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
      final bottom = dy + box.size.height;
      if (bottom <= 0 || dy >= height) continue;
      if (firstVisible == null || index < firstVisible) firstVisible = index;
      if (lastVisible == null || index > lastVisible) lastVisible = index;
      if (dy <= topLine && bottom > topLine) {
        topIndex = index;
        topLocalY = topLine - dy;
      }
      if (dy < height && bottom >= height) {
        bottomIndex = index;
        bottomLocalY = height - dy - 1;
      }
      if (index == _doc.blockCount - 1 && bottom <= height + 1) {
        endVisible = true;
      }
    }
    if (firstVisible == null || lastVisible == null) return null;

    final start = topIndex == null
        ? _doc.blockStart(firstVisible)
        : _offsetIn(topIndex, topLocalY);
    final end = endVisible || bottomIndex == null
        ? (endVisible ? _doc.length : _doc.blockEnd(lastVisible))
        : _offsetIn(bottomIndex, bottomLocalY);
    _currentOffset = start;
    return ReaderPosition(
      locator: TextLocator(start),
      // Reaching the end counts as 100% even if the last screen starts
      // earlier.
      progress: endVisible ? 1.0 : _doc.progressAt(start),
      visibleEnd: TextLocator(end < start ? start : end),
    );
  }

  /// Character offset at [localY] pixels into block [index].
  int _offsetIn(int index, double localY) {
    final paragraph = _mounted[index]?.paragraph;
    final blockStart = _doc.blockStart(index);
    if (paragraph == null || !paragraph.hasSize) return blockStart;
    final y = localY.clamp(0.0, paragraph.size.height - 1);
    final position = paragraph.getPositionForOffset(Offset(1, y));
    return (blockStart + position.offset).clamp(
      blockStart,
      _doc.blockEnd(index),
    );
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollUpdateNotification ||
        notification is ScrollEndNotification) {
      _scheduleMeasure();
    }
    return false;
  }

  // --- ReaderNavigator ------------------------------------------------------

  @override
  void goTo(Locator locator, {int highlightLength = 0}) {
    if (locator is! TextLocator) return;
    _highlightTimer?.cancel();
    if (highlightLength > 0) {
      _highlight = TextRange(
        start: locator.offset,
        end: locator.offset + highlightLength,
      );
      _highlightTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _highlight = null);
      });
    } else {
      _highlight = null;
    }
    _anchorAt(locator.offset);
  }

  @override
  void goToProgress(double progress) => _anchorAt(_doc.offsetAt(progress));

  @override
  void pageForward() => _page(1);

  @override
  void pageBack() => _page(-1);

  void _page(int direction) {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final prefs = _config.preferences;
    final line =
        MediaQuery.textScalerOf(context).scale(prefs.fontSize) *
        prefs.lineHeight;
    // Keep one line of overlap so the reader does not lose their place.
    final delta = (position.viewportDimension - line).clamp(
      line,
      double.infinity,
    );
    final target = (position.pixels + direction * delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (MediaQuery.disableAnimationsOf(context)) {
      _scroll.jumpTo(target);
      _scheduleMeasure();
    } else {
      unawaited(
        _scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
        ),
      );
    }
  }

  @override
  String? excerptAt(Locator locator) =>
      locator is TextLocator ? _doc.excerptAt(locator.offset) : null;

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

  // --- Building -------------------------------------------------------------

  void _onTapUp(TapUpDetails details) {
    final box = _viewportKey.currentContext?.findRenderObject();
    if (box is! RenderBox) return;
    final fraction = details.localPosition.dy / box.size.height;
    if (fraction < 0.25) {
      pageBack();
    } else if (fraction > 0.75) {
      pageForward();
    } else {
      _config.onTapCenter();
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefs = _config.preferences;
    final palette = _config.palette;
    final textScaler = MediaQuery.textScalerOf(context);
    final style = TextStyle(
      fontFamily: prefs.font.family,
      fontSize: prefs.fontSize,
      height: prefs.lineHeight,
      color: palette.text,
    );
    final spacing = prefs.fontSize * prefs.paragraphSpacing;
    final count = _doc.blockCount;

    Widget block(int index) => _TextBlock(
      key: ValueKey(index),
      index: index,
      span: _spanFor(index, style, palette.highlight),
      textAlign: prefs.justify ? TextAlign.justify : TextAlign.start,
      textScaler: textScaler,
      padding: EdgeInsets.only(
        left: prefs.margin,
        right: prefs.margin,
        bottom: _endsLine(index) ? spacing : 0,
      ),
      onMount: (state) => _mounted[index] = state,
      onUnmount: (state) {
        if (identical(_mounted[index], state)) _mounted.remove(index);
      },
    );

    final edge = SizedBox(height: Spacing.xl + spacing);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (_lastWidth != null && _lastWidth != width) {
          // Rotation or window resize: re-anchor after this layout.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _anchorAt(_currentOffset);
          });
        }
        _lastWidth = width;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: _onTapUp,
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: Opacity(
              opacity: _positioned ? 1 : 0,
              child: CustomScrollView(
                key: _viewportKey,
                controller: _scroll,
                center: _centerKey,
                slivers: [
                  // Blocks before the anchor, built upwards on demand; the
                  // last item is the space above the first block.
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, i) =>
                          i == _anchor ? edge : block(_anchor - 1 - i),
                      childCount: _anchor + 1,
                    ),
                  ),
                  SliverList(
                    key: _centerKey,
                    delegate: SliverChildBuilderDelegate(
                      (context, i) =>
                          _anchor + i == count ? edge : block(_anchor + i),
                      childCount: count - _anchor + 1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Whether block [index] ends a line (as opposed to being part of a long
  /// line that was split), so paragraph spacing applies after it.
  bool _endsLine(int index) {
    final end = _doc.blockEnd(index);
    return end >= _doc.length || _doc.text.codeUnitAt(end) == 0x0A;
  }

  TextSpan _spanFor(int index, TextStyle style, Color highlightColor) {
    final start = _doc.blockStart(index);
    final end = _doc.blockEnd(index);
    final text = _doc.text.substring(start, end);
    final highlight = _highlight;
    if (highlight == null || highlight.end <= start || highlight.start >= end) {
      return TextSpan(text: text, style: style);
    }
    final from = (highlight.start - start).clamp(0, text.length);
    final to = (highlight.end - start).clamp(0, text.length);
    return TextSpan(
      style: style,
      children: [
        TextSpan(text: text.substring(0, from)),
        TextSpan(
          text: text.substring(from, to),
          style: TextStyle(backgroundColor: highlightColor),
        ),
        TextSpan(text: text.substring(to)),
      ],
    );
  }
}

/// One block of text. Registers itself while mounted so the view can find
/// the laid-out paragraph for a block index.
class _TextBlock extends StatefulWidget {
  const _TextBlock({
    super.key,
    required this.index,
    required this.span,
    required this.textAlign,
    required this.textScaler,
    required this.padding,
    required this.onMount,
    required this.onUnmount,
  });

  final int index;
  final TextSpan span;
  final TextAlign textAlign;
  final TextScaler textScaler;
  final EdgeInsets padding;
  final ValueChanged<_TextBlockState> onMount;
  final ValueChanged<_TextBlockState> onUnmount;

  @override
  State<_TextBlock> createState() => _TextBlockState();
}

class _TextBlockState extends State<_TextBlock> {
  /// The laid-out text of this block.
  RenderParagraph? get paragraph {
    final box = context.findRenderObject();
    return box is RenderPadding && box.child is RenderParagraph
        ? box.child! as RenderParagraph
        : null;
  }

  @override
  void initState() {
    super.initState();
    widget.onMount(this);
  }

  @override
  void didUpdateWidget(covariant _TextBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      oldWidget.onUnmount(this);
      widget.onMount(this);
    }
  }

  @override
  void dispose() {
    widget.onUnmount(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: widget.padding,
      child: RichText(
        text: widget.span,
        textAlign: widget.textAlign,
        textScaler: widget.textScaler,
      ),
    );
  }
}
