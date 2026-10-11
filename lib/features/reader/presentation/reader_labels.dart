import '../../../core/utils/formatters.dart';
import '../domain/locator.dart';

/// Where [locator] is, for lists of bookmarks and search results: the page
/// for documents with fixed pages, otherwise the percentage read.
String locationLabel(Locator locator, double progress) => switch (locator) {
  PdfLocator(:final pageIndex) => 'Page ${pageIndex + 1}',
  _ => formatPercent(progress),
};

/// Orders two locators of the same kind; null if they cannot be compared.
int? compareLocators(Locator a, Locator b) => switch ((a, b)) {
  (TextLocator(offset: final x), TextLocator(offset: final y)) => x.compareTo(
    y,
  ),
  (
    PdfLocator(pageIndex: final pa, pageOffset: final oa),
    PdfLocator(pageIndex: final pb, pageOffset: final ob),
  ) =>
    pa != pb ? pa.compareTo(pb) : oa.compareTo(ob),
  _ => null,
};
