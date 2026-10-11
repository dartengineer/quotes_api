import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../core/theme/reader_palette.dart';
import '../../../../core/theme/tokens.dart';
import '../../domain/locator.dart';
import '../../domain/reader_preferences.dart';
import '../../domain/search_hit.dart';
import '../../domain/toc_entry.dart';
import '../reader_engines.dart';
import '../reader_view_controller.dart';
import '../widgets/web_link_dialog.dart';
import 'flow_document.dart';

/// Shows a reflowable document (plain text, EPUB) as a lazily built column
/// of blocks, anchored at the block that contains the reading position, so
/// opening a long document deep in never lays out what comes before.
///
/// Positions are global character offsets measured from the laid-out text,
/// so they are exact and survive font, size and rotation changes: when the
/// layout changes, the view re-anchors on the same character.
class FlowView extends StatefulWidget {
  const FlowView({super.key, required this.document, required this.config});

  final FlowDocument document;
  final ReaderViewConfig config;

  @override
  State<FlowView> createState() => _FlowViewState();
}

class _FlowViewState extends State<FlowView> implements ReaderNavigator {
  final _scroll = ScrollController();
  final _viewportKey = GlobalKey();
  final Map<int, _BlockState> _mounted = {};

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

  FlowDocument get _doc => widget.document;
  ReaderViewConfig get _config => widget.config;

  @override
  void initState() {
    super.initState();
    _config.controller.attach(this);
    final initial = _config.initialLocator;
    _anchorAt(initial == null ? 0 : _doc.offsetOf(initial) ?? 0);
  }

  @override
  void didUpdateWidget(covariant FlowView oldWidget) {
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
    if (layoutChanged || !identical(oldWidget.document, widget.document)) {
      _anchorAt(_currentOffset);
    }
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
    final box = block?.box;
    if (box == null || !box.hasSize || !_scroll.hasClients) {
      // Not laid out yet; try again next frame (bounded).
      if (_pendingAttempts++ < 10) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _applyPendingOffset(),
        );
        WidgetsBinding.instance.scheduleFrame();
      }
      return;
    }
    // Images and rules have no characters to align: show their top.
    var y = 0.0;
    final paragraph = block!.paragraph;
    if (paragraph != null && paragraph.hasSize) {
      final start = _doc.blockStart(_anchor);
      final local = (pending - start).clamp(0, _doc.blockEnd(_anchor) - start);
      final caret = paragraph.getOffsetForCaret(
        TextPosition(offset: local),
        Rect.zero,
      );
      y = paragraph.localToGlobal(caret, ancestor: box).dy;
    }
    // Near the end of the document the anchor cannot reach the top; the
    // blocks after it are all built then, so the maximum extent is exact.
    final position = _scroll.position;
    _scroll.jumpTo(y.clamp(position.minScrollExtent, position.maxScrollExtent));
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
      final box = block.box;
      if (box == null || !box.attached || !box.hasSize) continue;
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
    final end = endVisible
        ? _doc.length
        : bottomIndex == null
        ? _doc.blockEnd(lastVisible)
        : _offsetIn(bottomIndex, bottomLocalY);
    _currentOffset = start;
    return ReaderPosition(
      locator: _doc.locatorAt(start),
      // Reaching the end counts as 100% even if the last screen starts
      // earlier.
      progress: endVisible ? 1.0 : _doc.progressAt(start),
      visibleEnd: _doc.locatorAt(end < start ? start : end),
    );
  }

  /// Global character offset at [localY] pixels into block [index].
  int _offsetIn(int index, double localY) {
    final block = _mounted[index];
    final blockStart = _doc.blockStart(index);
    final paragraph = block?.paragraph;
    final box = block?.box;
    if (paragraph == null || !paragraph.hasSize || box == null) {
      return blockStart;
    }
    final top = paragraph.localToGlobal(Offset.zero, ancestor: box).dy;
    final y = (localY - top).clamp(0.0, paragraph.size.height - 1);
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
    final offset = _doc.offsetOf(locator);
    if (offset == null) return;
    _goToOffset(offset, highlightLength: highlightLength);
  }

  void _goToOffset(int offset, {int highlightLength = 0}) {
    _highlightTimer?.cancel();
    if (highlightLength > 0) {
      _highlight = TextRange(start: offset, end: offset + highlightLength);
      _highlightTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _highlight = null);
      });
    } else {
      _highlight = null;
    }
    _anchorAt(offset);
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
  String? excerptAt(Locator locator) {
    final offset = _doc.offsetOf(locator);
    return offset == null ? null : _doc.excerptAt(offset);
  }

  @override
  Future<List<SearchHit>> search(String query) => _doc.search(query);

  @override
  List<TocEntry> get contents => _doc.contents;

  @override
  int? contentsIndexAt(Locator position) {
    final offset = _doc.offsetOf(position);
    if (offset == null) return null;
    int? current;
    for (final (i, entry) in _doc.contents.indexed) {
      final start = _doc.offsetOf(entry.locator);
      if (start != null && start <= offset) current = i;
    }
    return current;
  }

  // --- Taps -------------------------------------------------------------------

  void _onTapUp(TapUpDetails details) {
    if (_followLink(details.globalPosition)) return;
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

  /// Follows a link under [globalPosition], if there is one.
  bool _followLink(Offset globalPosition) {
    for (final MapEntry(key: index, value: block) in _mounted.entries) {
      final paragraph = block.paragraph;
      if (paragraph == null || !paragraph.attached || !paragraph.hasSize) {
        continue;
      }
      final local = paragraph.globalToLocal(globalPosition);
      if (!(Offset.zero & paragraph.size).contains(local)) continue;
      final offset = paragraph.getPositionForOffset(local).offset;
      for (final candidate in [offset, offset - 1]) {
        if (candidate < 0) continue;
        final target = _doc.linkAt(index, candidate);
        if (target == null) continue;
        // Only a tap on the link's text counts, not the space beside it.
        final boxes = paragraph.getBoxesForSelection(
          TextSelection(baseOffset: candidate, extentOffset: candidate + 1),
        );
        final hit = boxes.any((b) => b.toRect().inflate(6).contains(local));
        if (!hit) continue;
        switch (target) {
          case InternalTarget(:final offset):
            _goToOffset(offset);
          case ExternalTarget(:final url):
            unawaited(showWebLinkDialog(context, url));
        }
        return true;
      }
      return false;
    }
    return false;
  }

  // --- Building -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final count = _doc.blockCount;
    final styles = _BlockStyles(
      preferences: _config.preferences,
      palette: _config.palette,
      textScaler: MediaQuery.textScalerOf(context),
    );

    Widget block(int index) => _Block(
      key: ValueKey(index),
      index: index,
      onMount: (state) => _mounted[index] = state,
      onUnmount: (state) {
        if (identical(_mounted[index], state)) _mounted.remove(index);
      },
      child: _buildBlock(index, styles),
    );

    final edge = SizedBox(height: Spacing.xl + styles.paragraphSpacing);

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

  Widget _buildBlock(int index, _BlockStyles styles) {
    final block = _doc.blockAt(index);
    final section = index > 0 && _doc.startsSection(index);
    final top = section
        ? styles.sectionSpacing
        : block.kind == BlockKind.heading
        ? styles.headingSpacing
        : 0.0;
    switch (block.kind) {
      case BlockKind.image:
        return Padding(
          padding: EdgeInsets.fromLTRB(
            styles.margin,
            top,
            styles.margin,
            styles.paragraphSpacing,
          ),
          child: _FlowImage(
            path: block.imagePath!,
            alt: block.imageAlt,
            aspectRatio: block.aspectRatio,
            load: _doc.loadImage,
            palette: styles.palette,
          ),
        );
      case BlockKind.rule:
        return Padding(
          padding: EdgeInsets.fromLTRB(
            styles.margin,
            top + styles.paragraphSpacing,
            styles.margin,
            styles.paragraphSpacing * 2,
          ),
          child: Center(
            child: FractionallySizedBox(
              widthFactor: 0.4,
              child: Divider(height: 1, color: styles.palette.secondaryText),
            ),
          ),
        );
      default:
        final start = _doc.blockStart(index);
        final highlight = _highlight;
        TextRange? local;
        if (highlight != null &&
            highlight.end > start &&
            highlight.start < _doc.blockEnd(index)) {
          local = TextRange(
            start: (highlight.start - start).clamp(0, highlight.end),
            end: highlight.end - start,
          );
        }
        final indent = switch (block.kind) {
          BlockKind.quote => styles.indent * block.level.clamp(1, 4),
          BlockKind.listItem => styles.indent * (block.level - 1).clamp(0, 6),
          _ => 0.0,
        };
        return Padding(
          padding: EdgeInsets.fromLTRB(
            styles.margin + indent,
            top,
            styles.margin,
            block.continues ? 0 : styles.spacingAfter(block),
          ),
          child: RichText(
            text: styles.span(_doc.blockText(index), block, local),
            textAlign: styles.align(block),
            textScaler: styles.textScaler,
          ),
        );
    }
  }
}

/// Text styles for blocks, derived from the reader's preferences.
class _BlockStyles {
  _BlockStyles({
    required this.preferences,
    required this.palette,
    required this.textScaler,
  });

  final ReaderPreferences preferences;
  final ReaderPalette palette;
  final TextScaler textScaler;

  double get fontSize => preferences.fontSize;
  double get margin => preferences.margin;
  double get paragraphSpacing => fontSize * preferences.paragraphSpacing;
  double get headingSpacing => fontSize * 1.2;
  double get sectionSpacing => fontSize * 3;
  double get indent => fontSize * 1.2;

  late final TextStyle base = TextStyle(
    fontFamily: preferences.font.family,
    fontSize: fontSize,
    height: preferences.lineHeight,
    color: palette.text,
  );

  double spacingAfter(ContentBlock block) => block.kind == BlockKind.heading
      ? paragraphSpacing + fontSize * 0.4
      : paragraphSpacing;

  TextAlign align(ContentBlock block) {
    if (block.centered) return TextAlign.center;
    final justify = preferences.justify;
    return switch (block.kind) {
      BlockKind.paragraph ||
      BlockKind.quote ||
      BlockKind.listItem when justify => TextAlign.justify,
      _ => TextAlign.start,
    };
  }

  TextStyle styleFor(ContentBlock block) => switch (block.kind) {
    BlockKind.heading => base.copyWith(
      fontSize:
          fontSize *
          const [1.6, 1.4, 1.25, 1.1, 1.0, 1.0][(block.level - 1).clamp(0, 5)],
      fontWeight: FontWeight.w700,
      height: 1.25,
    ),
    BlockKind.preformatted => base.copyWith(
      fontFamily: 'monospace',
      fontSize: fontSize * 0.9,
      height: 1.3,
    ),
    BlockKind.caption => base.copyWith(
      fontSize: fontSize * 0.85,
      color: palette.secondaryText,
    ),
    _ => base,
  };

  /// The block's text with its inline styles and an optional highlight
  /// (relative to the block).
  TextSpan span(String text, ContentBlock block, TextRange? highlight) {
    final blockStyle = styleFor(block);
    final runs = block.runs;
    if (runs.isEmpty && highlight == null) {
      return TextSpan(text: text, style: blockStyle);
    }
    final cuts = <int>{0, text.length};
    for (final run in runs) {
      cuts
        ..add(run.start.clamp(0, text.length))
        ..add(run.end.clamp(0, text.length));
    }
    if (highlight != null) {
      cuts
        ..add(highlight.start.clamp(0, text.length))
        ..add(highlight.end.clamp(0, text.length));
    }
    final points = cuts.toList()..sort();
    final children = <TextSpan>[];
    var runIndex = 0;
    for (var i = 0; i + 1 < points.length; i++) {
      final from = points[i];
      final to = points[i + 1];
      if (to <= from) continue;
      while (runIndex < runs.length && runs[runIndex].end <= from) {
        runIndex++;
      }
      final run = runIndex < runs.length && runs[runIndex].start <= from
          ? runs[runIndex]
          : null;
      final highlighted =
          highlight != null && from >= highlight.start && to <= highlight.end;
      children.add(
        TextSpan(
          text: text.substring(from, to),
          style: _inline(run, highlighted, blockStyle),
        ),
      );
    }
    return TextSpan(style: blockStyle, children: children);
  }

  TextStyle? _inline(StyledRun? run, bool highlighted, TextStyle blockStyle) {
    if (run == null && !highlighted) return null;
    final style = run?.style ?? 0;
    final decorations = <TextDecoration>[
      if (style & InlineStyle.underline != 0 || run?.link != null)
        TextDecoration.underline,
      if (style & InlineStyle.strikethrough != 0) TextDecoration.lineThrough,
    ];
    final smaller =
        style &
            (InlineStyle.small |
                InlineStyle.superscript |
                InlineStyle.subscript) !=
        0;
    return TextStyle(
      fontWeight: style & InlineStyle.bold != 0 ? FontWeight.w700 : null,
      fontStyle: style & InlineStyle.italic != 0 ? FontStyle.italic : null,
      fontFamily: style & InlineStyle.monospace != 0 ? 'monospace' : null,
      fontSize: smaller ? (blockStyle.fontSize ?? fontSize) * 0.75 : null,
      decoration: decorations.isEmpty
          ? null
          : TextDecoration.combine(decorations),
      decorationColor: run?.link != null ? palette.secondaryText : null,
      backgroundColor: highlighted ? palette.highlight : null,
    );
  }
}

/// One block. Registers itself while mounted so the view can find the
/// laid-out block for an index.
class _Block extends StatefulWidget {
  const _Block({
    super.key,
    required this.index,
    required this.onMount,
    required this.onUnmount,
    required this.child,
  });

  final int index;
  final ValueChanged<_BlockState> onMount;
  final ValueChanged<_BlockState> onUnmount;
  final Widget child;

  @override
  State<_Block> createState() => _BlockState();
}

class _BlockState extends State<_Block> {
  RenderBox? get box {
    final object = context.findRenderObject();
    return object is RenderBox ? object : null;
  }

  /// The laid-out text of this block, if it is a text block.
  RenderParagraph? get paragraph {
    RenderParagraph? found;
    void visit(RenderObject child) {
      if (found != null) return;
      if (child is RenderParagraph) {
        found = child;
      } else {
        child.visitChildren(visit);
      }
    }

    final root = box;
    if (root != null) visit(root);
    return found;
  }

  @override
  void initState() {
    super.initState();
    widget.onMount(this);
  }

  @override
  void didUpdateWidget(covariant _Block oldWidget) {
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
  Widget build(BuildContext context) => widget.child;
}

/// An image from the document, decoded no larger than the screen.
class _FlowImage extends StatefulWidget {
  const _FlowImage({
    required this.path,
    required this.alt,
    required this.aspectRatio,
    required this.load,
    required this.palette,
  });

  final String path;
  final String? alt;
  final double? aspectRatio;
  final Future<Uint8List?> Function(String path) load;
  final ReaderPalette palette;

  @override
  State<_FlowImage> createState() => _FlowImageState();
}

class _FlowImageState extends State<_FlowImage> {
  late Future<Uint8List?> _bytes = widget.load(widget.path);

  @override
  void didUpdateWidget(covariant _FlowImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) _bytes = widget.load(widget.path);
  }

  Widget _alt() {
    final alt = widget.alt;
    if (alt == null) return const SizedBox.shrink();
    return Text(
      alt,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: widget.palette.secondaryText,
        fontStyle: FontStyle.italic,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final ratio = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final maxHeight = screen.height * 0.85;
        return FutureBuilder<Uint8List?>(
          future: _bytes,
          builder: (context, snapshot) {
            final bytes = snapshot.data;
            if (bytes == null) {
              if (snapshot.connectionState != ConnectionState.done) {
                // Reserve the space the image will take when it is known.
                final aspect = widget.aspectRatio;
                return SizedBox(
                  height: aspect == null
                      ? 120
                      : (width / aspect).clamp(0, maxHeight).toDouble(),
                );
              }
              return _alt();
            }
            return Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: width,
                  maxHeight: maxHeight,
                ),
                child: Image(
                  // Decoded to fit the screen at most: bounded memory
                  // whatever the file's dimensions.
                  image: ResizeImage(
                    MemoryImage(bytes),
                    width: (width * ratio).round(),
                    height: (maxHeight * ratio).round(),
                    policy: ResizeImagePolicy.fit,
                  ),
                  fit: BoxFit.scaleDown,
                  semanticLabel: widget.alt,
                  excludeFromSemantics: widget.alt == null,
                  errorBuilder: (context, _, _) => _alt(),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
