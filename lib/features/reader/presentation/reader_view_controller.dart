import 'package:material_ui/material_ui.dart';

import '../domain/locator.dart';
import '../domain/search_hit.dart';
import '../domain/toc_entry.dart';

/// Navigation and queries that a format-specific reader view (TXT, PDF,
/// EPUB) provides to the shared reader chrome.
abstract interface class ReaderNavigator {
  /// Shows [locator] at the top of the view. [highlightLength] characters
  /// from the locator are highlighted briefly (used for search results).
  void goTo(Locator locator, {int highlightLength = 0});

  /// Jumps to an overall position in `[0, 1]`.
  void goToProgress(double progress);

  void pageForward();
  void pageBack();

  /// Short text at [locator], used as a bookmark excerpt.
  String? excerptAt(Locator locator);

  /// Finds text in the document. Implementations must not block the UI.
  Future<List<SearchHit>> search(String query);

  /// The document's table of contents; empty if it has none (or it is not
  /// known yet).
  List<TocEntry> get contents;
}

/// A [ReaderNavigator] for documents made of fixed pages (PDF).
abstract interface class PagedNavigator implements ReaderNavigator {
  /// Zero when the document is not loaded yet.
  int get pageCount;

  void goToPage(int pageIndex);

  /// A small rendering of a page, built lazily for page overviews.
  Widget buildPageThumbnail(BuildContext context, int pageIndex);
}

/// Connects the reader chrome to whichever format view is showing, in the
/// style of a `ScrollController`: the view attaches itself while mounted.
/// Calls made while no view is attached are ignored.
class ReaderViewController {
  ReaderNavigator? _navigator;

  bool get isAttached => _navigator != null;

  /// The attached view, if it has fixed pages.
  PagedNavigator? get paged => switch (_navigator) {
    final PagedNavigator paged when paged.pageCount > 0 => paged,
    _ => null,
  };

  List<TocEntry> get contents => _navigator?.contents ?? const [];

  void attach(ReaderNavigator navigator) => _navigator = navigator;

  void detach(ReaderNavigator navigator) {
    if (identical(_navigator, navigator)) _navigator = null;
  }

  void goTo(Locator locator, {int highlightLength = 0}) =>
      _navigator?.goTo(locator, highlightLength: highlightLength);

  void goToProgress(double progress) => _navigator?.goToProgress(progress);

  void pageForward() => _navigator?.pageForward();

  void pageBack() => _navigator?.pageBack();

  String? excerptAt(Locator locator) => _navigator?.excerptAt(locator);

  Future<List<SearchHit>> search(String query) =>
      _navigator?.search(query) ?? Future.value(const []);
}
