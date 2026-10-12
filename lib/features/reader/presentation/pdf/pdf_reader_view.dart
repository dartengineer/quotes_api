import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../../../core/utils/app_log.dart';
import '../../../../core/utils/text_search.dart';
import '../../../../core/widgets/state_views.dart';
import '../../../../engines/pdf/pdf_text_geometry.dart';
import '../../domain/annotation.dart';
import '../../domain/locator.dart';
import '../../domain/search_hit.dart';
import '../../domain/toc_entry.dart';
import '../reader_engines.dart';
import '../reader_view_controller.dart';
import '../widgets/navigation_sheets.dart' show currentEntryIndex;
import '../widgets/web_link_dialog.dart';
import 'pdf_dialogs.dart';

/// Reads a PDF with PDFium (through pdfrx): continuous vertical scrolling
/// with pages rendered lazily, pinch and double-tap zoom, text selection
/// and internal links.
///
/// Positions are a page index plus a fraction of that page's height, so
/// they survive zoom, rotation and screen changes.
class PdfReaderView extends StatefulWidget {
  const PdfReaderView({super.key, required this.config});

  final ReaderViewConfig config;

  @override
  State<PdfReaderView> createState() => _PdfReaderViewState();
}

class _PdfReaderViewState extends State<PdfReaderView>
    implements PagedNavigator {
  final _viewer = PdfViewerController();
  late final PdfDocumentRef _document = PdfDocumentRefFile(
    widget.config.filePath,
    passwordProvider: _askPassword,
    // Local files: measure every page up front so the layout (and with it
    // a restored position) never shifts while reading.
    useProgressiveLoading: false,
  );

  int _pageCount = 0;
  List<TocEntry> _contents = const [];

  /// Positions are reported only after the saved one has been restored, so
  /// the start of the document is never saved over it.
  bool _restored = false;
  bool _measureScheduled = false;
  ReaderPosition? _lastReported;

  int _passwordAttempts = 0;
  int _searchGeneration = 0;

  /// Recently used page texts, for excerpts and highlights (insertion
  /// order is recency order).
  final _texts = <int, PdfPageRawText>{};
  static const _maxCachedTexts = 24;

  /// Text loads in progress, shared by everyone waiting for the same page.
  final _loadingTexts = <int, Future<PdfPageRawText?>>{};

  _Highlight? _highlight;
  Timer? _highlightTimer;

  ReaderViewConfig get _config => widget.config;

  @override
  void initState() {
    super.initState();
    _viewer.addListener(_scheduleMeasure);
    _config.controller.attach(this);
  }

  @override
  void didUpdateWidget(PdfReaderView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.config.controller, _config.controller)) {
      oldWidget.config.controller.detach(this);
      _config.controller.attach(this);
    }
    // Pages are painted by the viewer: repaint for new or changed
    // highlights.
    if (!identical(oldWidget.config.annotations, _config.annotations) &&
        _viewer.isReady) {
      _viewer.invalidate();
    }
  }

  @override
  void dispose() {
    _searchGeneration++;
    _highlightTimer?.cancel();
    _viewer.removeListener(_scheduleMeasure);
    _config.controller.detach(this);
    super.dispose();
  }

  // --- Loading --------------------------------------------------------------

  /// Asks for the password of an encrypted PDF. PDFium calls this again
  /// after a wrong password; returning null gives up. Passwords are never
  /// stored.
  Future<String?> _askPassword() async {
    if (!mounted) return null;
    final retry = _passwordAttempts++ > 0;
    return showPdfPasswordDialog(context, retry: retry);
  }

  void _onViewerReady(PdfDocument document, PdfViewerController controller) {
    _pageCount = document.pages.length;
    final initial = _config.initialLocator;
    // The viewer centres an initial page that is shorter than the screen;
    // a saved position is restored exactly instead.
    if (initial is PdfLocator) {
      unawaited(_goToLocator(initial, animate: false));
    }
    _restored = true;
    _scheduleMeasure();
    unawaited(_loadContents(document));
  }

  Future<void> _loadContents(PdfDocument document) async {
    try {
      final outline = await document.loadOutline();
      if (!mounted) return;
      _contents = flattenOutline(
        outline,
        pageCount: _pageCount,
        pageHeight: (i) => document.pages[i].height,
      );
    } catch (error, stackTrace) {
      AppLog.error('Reading the PDF outline failed', error, stackTrace);
    }
  }

  void _retry() {
    _passwordAttempts = 0;
    unawaited(_document.resolveListenable().load(forceReload: true));
  }

  // --- Position -------------------------------------------------------------

  void _scheduleMeasure() {
    if (_measureScheduled) return;
    _measureScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      if (mounted) _measure();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void _measure() {
    if (!_restored || !_viewer.isReady) return;
    final rects = _viewer.layout.pageLayouts;
    if (rects.isEmpty) return;
    final visible = _viewer.visibleRect;

    var index = rects.indexWhere((r) => r.bottom > visible.top + 0.5);
    if (index < 0) index = rects.length - 1;
    final rect = rects[index];
    final offset = _round(
      ((visible.top - rect.top) / rect.height).clamp(0.0, 1.0),
    );
    var last = rects.lastIndexWhere((r) => r.top < visible.bottom - 0.5);
    if (last < index) last = index;

    final atEnd = visible.bottom >= rects.last.bottom - 0.5;
    final progress = atEnd
        ? 1.0
        : ((index + offset) / rects.length).clamp(0.0, 1.0);
    final position = ReaderPosition(
      locator: PdfLocator(index, pageOffset: offset),
      progress: progress,
      visibleEnd: PdfLocator(last),
      pageCount: rects.length,
    );
    if (position == _lastReported) return;
    final previous = _lastReported?.locator;
    _lastReported = position;
    _config.onPosition(position);
    // Have the page's text ready for a bookmark excerpt.
    if (previous is! PdfLocator || previous.pageIndex != index) {
      unawaited(_pageText(index));
    }
  }

  static double _round(double value) => (value * 10000).roundToDouble() / 10000;

  // --- Navigation -----------------------------------------------------------

  @override
  int get pageCount => _pageCount;

  @override
  List<TocEntry> get contents => _contents;

  @override
  int? contentsIndexAt(Locator position) =>
      currentEntryIndex(_contents, position);

  @override
  void goTo(Locator locator, {int highlightLength = 0}) {
    if (locator is! PdfLocator) return;
    unawaited(_goToLocator(locator, highlightLength: highlightLength));
  }

  Future<void> _goToLocator(
    PdfLocator locator, {
    int highlightLength = 0,
    bool animate = true,
  }) async {
    if (!_viewer.isReady || _pageCount == 0) return;
    final index = locator.pageIndex.clamp(0, _pageCount - 1);
    final rect = _viewer.layout.pageLayouts[index];
    var y = rect.top + locator.pageOffset * rect.height;
    final charIndex = locator.charIndex;
    if (highlightLength > 0 && charIndex != null) {
      // Leave room above the match so it is not hidden under the toolbar.
      y = math.max(rect.top, y - _viewer.visibleRect.height * 0.25);
      unawaited(_showHighlight(index, charIndex, charIndex + highlightLength));
    }
    await _viewer.goToPosition(
      documentOffset: Offset(_viewer.visibleRect.left, y),
      duration: animate ? const Duration(milliseconds: 200) : Duration.zero,
    );
  }

  @override
  void goToPage(int pageIndex) => goTo(PdfLocator(pageIndex));

  @override
  void goToProgress(double progress) {
    if (_pageCount == 0) return;
    if (progress >= 1) {
      unawaited(
        _viewer.goToPosition(
          documentOffset: Offset(
            _viewer.visibleRect.left,
            _viewer.layout.documentSize.height,
          ),
        ),
      );
      return;
    }
    final target = progress.clamp(0.0, 1.0) * _pageCount;
    final index = target.floor().clamp(0, _pageCount - 1);
    goTo(PdfLocator(index, pageOffset: (target - index).clamp(0.0, 1.0)));
  }

  @override
  void pageForward() => _scrollBy(0.9);

  @override
  void pageBack() => _scrollBy(-0.9);

  /// Scrolls by a fraction of the visible height (keeping a little overlap
  /// so no line is skipped).
  void _scrollBy(double screens) {
    if (!_viewer.isReady) return;
    final visible = _viewer.visibleRect;
    unawaited(
      _viewer.goToPosition(
        documentOffset: Offset(
          visible.left,
          visible.top + visible.height * screens,
        ),
        duration: const Duration(milliseconds: 200),
      ),
    );
  }

  // --- Text: excerpts, search, highlights -------------------------------------

  /// The raw text of a page (PDFium's character order), cached.
  Future<PdfPageRawText?> _pageText(int index) {
    final cached = _texts.remove(index);
    if (cached != null) return Future.value(_texts[index] = cached);
    // The callback must not return the removed entry: whenComplete would
    // wait for that future, which is this one. (Its callers await it.)
    return _loadingTexts[index] ??= _loadPageText(index).whenComplete(() {
      unawaited(_loadingTexts.remove(index));
    });
  }

  Future<PdfPageRawText?> _loadPageText(int index) async {
    if (!_viewer.isReady || index >= _pageCount) return null;
    final text = await _viewer.useDocument<PdfPageRawText?>(
      (document) => document.pages[index].loadText(),
    );
    if (text == null || !mounted) return null;
    _texts[index] = text;
    while (_texts.length > _maxCachedTexts) {
      _texts.remove(_texts.keys.first);
    }
    return text;
  }

  @override
  String? excerptAt(Locator locator) {
    if (locator is! PdfLocator || !_viewer.isReady) return null;
    final text = _texts[locator.pageIndex];
    if (text == null || locator.pageIndex >= _pageCount) return null;
    final page = _viewer.pages[locator.pageIndex];
    // The first character at or below the position.
    for (var i = 0; i < text.charRects.length; i++) {
      final rect = text.charRects[i];
      if (rect.isEmpty) continue;
      if (rect.toRect(page: page).bottom / page.height >= locator.pageOffset) {
        final excerpt = excerptFrom(text.fullText, i);
        return excerpt.isEmpty ? null : excerpt;
      }
    }
    return null;
  }

  @override
  Future<List<SearchHit>> search(String query) async {
    final pattern = flexibleSearchPattern(query);
    if (pattern == null || !_viewer.isReady) return const [];
    final generation = ++_searchGeneration;
    final hits = <SearchHit>[];
    final count = _pageCount;
    for (var index = 0; index < count && hits.length < _maxHits; index++) {
      // A newer search, or closing the document, abandons this one.
      if (generation != _searchGeneration || !mounted) break;
      final text = await _searchText(index);
      if (text == null) continue;
      final page = _viewer.isReady ? _viewer.pages[index] : null;
      if (page == null) break;
      for (final hit in findTextMatches(
        text.fullText,
        pattern,
        maxHits: _maxHits - hits.length,
      )) {
        final top = _charTop(text, hit.start, page);
        hits.add(
          SearchHit(
            locator: PdfLocator(index, pageOffset: top, charIndex: hit.start),
            progress: ((index + top) / count).clamp(0.0, 1.0),
            snippet: hit.snippet,
            snippetMatchStart: hit.snippetMatchStart,
            matchLength: hit.length,
          ),
        );
      }
    }
    return hits;
  }

  static const _maxHits = 500;

  /// Page text for searching: from the cache if present, but searching does
  /// not fill the cache (it would evict the pages being read).
  Future<PdfPageRawText?> _searchText(int index) async {
    final cached = _texts[index];
    if (cached != null) return cached;
    return _viewer.useDocument<PdfPageRawText?>(
      (document) => document.pages[index].loadText(),
    );
  }

  /// How far down [page] (0..1) the character at [index] starts.
  static double _charTop(PdfPageRawText text, int index, PdfPage page) {
    if (index >= text.charRects.length || page.height <= 0) return 0;
    final rect = text.charRects[index].toRect(page: page);
    return _round((rect.top / page.height).clamp(0.0, 1.0));
  }

  Future<void> _showHighlight(int pageIndex, int start, int end) async {
    final text = await _pageText(pageIndex);
    if (text == null || !mounted) return;
    _highlightTimer?.cancel();
    _highlight = _Highlight(
      pageNumber: pageIndex + 1,
      boxes: lineBoxes(text.charRects, start, end),
    );
    _viewer.invalidate();
    _highlightTimer = Timer(const Duration(seconds: 4), () {
      _highlight = null;
      if (mounted && _viewer.isReady) _viewer.invalidate();
    });
  }

  /// Paints saved highlights and the temporary search highlight on [page].
  void _paintHighlights(ui.Canvas canvas, Rect pageRect, PdfPage page) {
    final pageIndex = page.pageNumber - 1;
    final (width, height) = _unrotatedSize(page);
    for (final annotation in _config.annotations) {
      final range = annotation.range;
      if (range is! PdfAreaRange) continue;
      final paint = Paint()
        ..color = Color(annotation.color.argb)
            .withValues(alpha: _config.palette.isDark ? 0.4 : 0.5);
      for (final area in range.areas) {
        if (area.pageIndex != pageIndex) continue;
        for (final r in area.rects) {
          final rect = PdfRect(
            r.left * width,
            r.top * height,
            r.right * width,
            r.bottom * height,
          ).toRectInDocument(page: page, pageRect: pageRect);
          canvas.drawRect(rect, paint);
          if (annotation.hasNote && identical(r, area.rects.first)) {
            // A small marker shows that a note is attached.
            canvas.drawCircle(
              rect.topRight,
              pageRect.width * 0.008 + 2,
              Paint()..color = _config.palette.secondaryText,
            );
          }
        }
      }
    }

    final highlight = _highlight;
    if (highlight == null || highlight.pageNumber != page.pageNumber) return;
    final paint = Paint()..color = _config.palette.highlight;
    for (final box in highlight.boxes) {
      canvas.drawRect(
        box.toRectInDocument(page: page, pageRect: pageRect).inflate(1),
        paint,
      );
    }
  }

  /// The page's size before rotation: the space text and highlight
  /// coordinates are in.
  static (double, double) _unrotatedSize(PdfPage page) =>
      switch (page.rotation) {
        PdfPageRotation.clockwise90 ||
        PdfPageRotation.clockwise270 => (page.height, page.width),
        _ => (page.width, page.height),
      };

  // --- Annotating -------------------------------------------------------------

  /// Whether the document permits copying its text: bit 5 (value 16) of the
  /// permissions in PDF 32000-1, table 22. (pdfrx 2.6.5's `allowsCopying`
  /// tests bit 3, which is printing, so it is not relied on.)
  bool get _copyAllowed {
    if (!_viewer.isReady) return false;
    final permissions = _viewer.document.permissions;
    return permissions == null || (permissions.permissions & 0x10) != 0;
  }

  /// Adds "Highlight…" to the selection menu when the document allows its
  /// text to be copied (highlighting takes the same access); removes "Copy"
  /// when it does not.
  void _customizeMenu(
    PdfViewerContextMenuBuilderParams params,
    List<ContextMenuButtonItem> items,
  ) {
    if (!_copyAllowed) {
      items.removeWhere((item) => item.type == ContextMenuButtonType.copy);
      return;
    }
    final delegate = params.textSelectionDelegate;
    // pdfrx also gates access to the selected text on its own check.
    if (_config.onSelection == null ||
        !delegate.hasSelectedText ||
        !delegate.isCopyAllowed) {
      return;
    }
    items.insert(
      0,
      ContextMenuButtonItem(
        label: 'Highlight…',
        onPressed: () {
          params.dismissContextMenu();
          unawaited(_annotateSelection(delegate));
        },
      ),
    );
  }

  Future<void> _annotateSelection(PdfTextSelectionDelegate delegate) async {
    final onSelection = _config.onSelection;
    if (onSelection == null || !_viewer.isReady) return;
    final ranges = await delegate.getSelectedTextRanges();
    final text = await delegate.getSelectedText();
    if (!mounted || !_viewer.isReady || _pageCount == 0) return;
    final areas = <PdfPageArea>[];
    for (final range in ranges) {
      final index = range.pageNumber - 1;
      if (index < 0 || index >= _pageCount) continue;
      final (width, height) = _unrotatedSize(_viewer.pages[index]);
      if (width <= 0 || height <= 0) continue;
      final boxes = lineBoxes(range.pageText.charRects, range.start, range.end);
      if (boxes.isEmpty) continue;
      areas.add(
        PdfPageArea(
          pageIndex: index,
          rects: [
            for (final b in boxes)
              NormalizedRect(
                b.left / width,
                b.top / height,
                b.right / width,
                b.bottom / height,
              ),
          ],
        ),
      );
    }
    if (areas.isEmpty) return;
    final range = PdfAreaRange(areas);
    final start = range.start;
    await onSelection(
      AnnotationDraft(
        range: range,
        progress: ((start.pageIndex + start.pageOffset) / _pageCount).clamp(
          0.0,
          1.0,
        ),
        text: text.trim(),
      ),
    );
    if (mounted) await delegate.clearTextSelection();
  }

  /// The saved highlight under a tap at [localPosition], if any.
  Annotation? _annotationAt(
    PdfViewerController controller,
    Offset localPosition,
  ) {
    if (_config.annotations.isEmpty) return null;
    final hit = controller.getPdfPageHitTestResult(
      localPosition,
      useDocumentLayoutCoordinates: false,
    );
    if (hit == null) return null;
    final (width, height) = _unrotatedSize(hit.page);
    if (width <= 0 || height <= 0) return null;
    final x = hit.offset.x / width;
    final y = hit.offset.y / height;
    const slack = 0.005;
    for (final annotation in _config.annotations.reversed) {
      final range = annotation.range;
      if (range is! PdfAreaRange) continue;
      for (final area in range.areas) {
        if (area.pageIndex != hit.page.pageNumber - 1) continue;
        for (final r in area.rects) {
          if (x >= r.left - slack &&
              x <= r.right + slack &&
              y <= r.top + slack &&
              y >= r.bottom - slack) {
            return annotation;
          }
        }
      }
    }
    return null;
  }

  // --- Thumbnails -------------------------------------------------------------

  @override
  Widget buildPageThumbnail(BuildContext context, int pageIndex) {
    if (!_viewer.isReady) return const SizedBox.shrink();
    return PdfPageView(
      document: _viewer.document,
      pageNumber: pageIndex + 1,
      // Thumbnails stay small in memory.
      maximumDpi: 72,
    );
  }

  // --- Gestures ---------------------------------------------------------------

  bool _onTap(
    BuildContext context,
    PdfViewerController controller,
    PdfViewerGeneralTapHandlerDetails details,
  ) {
    switch (details.type) {
      case PdfViewerGeneralTapType.tap:
        // Let the viewer clear a text selection first.
        if (controller.textSelectionDelegate.hasSelectedText) return false;
        if (_annotationAt(controller, details.localPosition) case final a?) {
          _config.onAnnotationTap?.call(a);
          return true;
        }
        final fraction = details.localPosition.dy / controller.viewSize.height;
        if (fraction < 0.25) {
          pageBack();
        } else if (fraction > 0.75) {
          pageForward();
        } else {
          _config.onTapCenter();
        }
        return true;
      case PdfViewerGeneralTapType.doubleTap:
        final fit = controller.coverScale;
        final zoomedIn = controller.currentZoom > fit * 1.05;
        unawaited(
          controller.zoomOnLocalPosition(
            localPosition: details.localPosition,
            newZoom: zoomedIn ? fit : math.min(fit * 2.5, controller.maxScale),
          ),
        );
        return true;
      case PdfViewerGeneralTapType.longPress:
      case PdfViewerGeneralTapType.secondaryTap:
        return false;
    }
  }

  void _onLinkTap(PdfLink link) {
    final dest = link.dest;
    if (dest != null) {
      unawaited(_viewer.goToDest(dest));
      return;
    }
    final url = link.url;
    // Websites are never opened automatically: the app works offline and
    // makes no network requests. The address can be copied instead.
    if (url != null && mounted) unawaited(showWebLinkDialog(context, url));
  }

  // --- Building ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final palette = _config.palette;
    final initial = _config.initialLocator;
    return PdfViewer(
      _document,
      controller: _viewer,
      initialPageNumber: initial is PdfLocator ? initial.pageIndex + 1 : 1,
      params: PdfViewerParams(
        backgroundColor: palette.background,
        margin: 8,
        pageDropShadow: BoxShadow(
          color: palette.isDark ? Colors.black : Colors.black26,
          blurRadius: 4,
          offset: const Offset(0, 1),
        ),
        // A bound on rendered page images held in memory.
        maxImageBytesCachedOnMemory: 64 * 1024 * 1024,
        onViewerReady: _onViewerReady,
        onGeneralTap: _onTap,
        pagePaintCallbacks: [_paintHighlights],
        customizeContextMenuItems: _customizeMenu,
        linkHandlerParams: PdfLinkHandlerParams(onLinkTap: _onLinkTap),
        loadingBannerBuilder: (context, _, _) => const LoadingView(),
        errorBannerBuilder: (context, error, _, _) =>
            _OpenError(error: error, onRetry: _retry),
      ),
    );
  }
}

/// Flattens a PDF outline (depth-first, as shown in readers) into entries
/// with locators. Entries without a usable destination are kept only if
/// they have children (as headings for them). Bounded against hostile
/// files: at most [maxEntries] entries and [maxDepth] levels.
List<TocEntry> flattenOutline(
  List<PdfOutlineNode> outline, {
  required int pageCount,
  required double Function(int pageIndex) pageHeight,
  int maxEntries = 5000,
  int maxDepth = 8,
}) {
  final entries = <TocEntry>[];
  // Iterative, so a deeply nested outline cannot overflow the stack.
  final stack = <(PdfOutlineNode, int)>[
    for (final node in outline.reversed) (node, 0),
  ];
  while (stack.isNotEmpty && entries.length < maxEntries) {
    final (node, depth) = stack.removeLast();
    final locator = _outlineLocator(node.dest, pageCount, pageHeight);
    final title = node.title.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (locator != null && title.isNotEmpty) {
      entries.add(TocEntry(title: title, locator: locator, depth: depth));
    }
    if (depth + 1 < maxDepth) {
      for (final child in node.children.reversed) {
        stack.add((child, depth + 1));
      }
    }
  }
  return entries;
}

PdfLocator? _outlineLocator(
  PdfDest? dest,
  int pageCount,
  double Function(int pageIndex) pageHeight,
) {
  if (dest == null) return null;
  final index = dest.pageNumber - 1;
  if (index < 0 || index >= pageCount) return null;
  // "XYZ left top zoom": top is in PDF units from the bottom of the page.
  final params = dest.params;
  var offset = 0.0;
  if (dest.command == PdfDestCommand.xyz &&
      params != null &&
      params.length > 1 &&
      params[1] != null) {
    final height = pageHeight(index);
    if (height > 0) offset = (1 - params[1]! / height).clamp(0.0, 1.0);
  }
  return PdfLocator(index, pageOffset: offset);
}

class _Highlight {
  const _Highlight({required this.pageNumber, required this.boxes});

  final int pageNumber;
  final List<PdfRect> boxes;
}

/// Shown when the PDF cannot be opened: a password was not given, or the
/// file is damaged.
class _OpenError extends StatelessWidget {
  const _OpenError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (error is PdfPasswordException) {
      return ErrorStateView(
        icon: Icons.lock_outline,
        title: 'Password required',
        message: 'This PDF is protected with a password.',
        retryLabel: 'Enter password',
        retryIcon: Icons.key,
        onRetry: onRetry,
      );
    }
    // The error's text can contain the file path; only its type is logged.
    AppLog.error('Opening a PDF failed', error.runtimeType);
    return ErrorStateView(
      title: 'Can’t open this PDF',
      message: 'The file may be damaged or use features that aren’t supported.',
      onRetry: onRetry,
    );
  }
}
