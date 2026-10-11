import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/features/reader/domain/locator.dart';
import 'package:lectern/features/reader/domain/toc_entry.dart';
import 'package:lectern/features/reader/presentation/pdf/pdf_reader_view.dart';
import 'package:lectern/features/reader/presentation/reader_labels.dart';
import 'package:lectern/features/reader/presentation/widgets/navigation_sheets.dart';
import 'package:pdfrx/pdfrx.dart';

PdfOutlineNode node(
  String title, {
  int? page,
  List<double?>? xyz,
  List<PdfOutlineNode> children = const [],
}) => PdfOutlineNode(
  title: title,
  dest: page == null
      ? null
      : PdfDest(
          page,
          xyz == null ? PdfDestCommand.fit : PdfDestCommand.xyz,
          xyz,
        ),
  children: children,
);

List<TocEntry> flatten(
  List<PdfOutlineNode> outline, {
  int maxEntries = 5000,
  int maxDepth = 8,
}) => flattenOutline(
  outline,
  pageCount: 10,
  pageHeight: (_) => 400,
  maxEntries: maxEntries,
  maxDepth: maxDepth,
);

void main() {
  group('flattenOutline', () {
    test('keeps reading order with depths and page offsets', () {
      final entries = flatten([
        node(
          'Part 1',
          page: 1,
          children: [
            node('Chapter 1', page: 2, xyz: [0, 300, 0]),
            node('Chapter 2', page: 4),
          ],
        ),
        node('Part 2', page: 6),
      ]);
      expect(entries, const [
        TocEntry(title: 'Part 1', locator: PdfLocator(0)),
        TocEntry(
          title: 'Chapter 1',
          locator: PdfLocator(1, pageOffset: 0.25),
          depth: 1,
        ),
        TocEntry(title: 'Chapter 2', locator: PdfLocator(3), depth: 1),
        TocEntry(title: 'Part 2', locator: PdfLocator(5)),
      ]);
    });

    test('skips entries without a valid page but keeps their children', () {
      final entries = flatten([
        node('Heading', children: [node('Inside', page: 3)]),
        node('Beyond the end', page: 11),
        node('   ', page: 1),
      ]);
      expect(entries.map((e) => (e.title, e.depth)), [('Inside', 1)]);
    });

    test('collapses whitespace in titles', () {
      expect(flatten([node(' A \n  title ', page: 1)]).single.title, 'A title');
    });

    test('is bounded for hostile outlines', () {
      // Deep nesting would overflow a recursive walk.
      var deep = node('leaf', page: 1);
      for (var i = 0; i < 10000; i++) {
        deep = node('level', page: 1, children: [deep]);
      }
      expect(flatten([deep], maxDepth: 8), hasLength(8));

      final wide = [for (var i = 0; i < 100; i++) node('n$i', page: 1)];
      expect(flatten(wide, maxEntries: 10), hasLength(10));
    });
  });

  group('labels and ordering', () {
    test('PDF locations show pages; others show progress', () {
      expect(locationLabel(const PdfLocator(4), 0.5), 'Page 5');
      expect(locationLabel(const TextLocator(10), 0.42), '42%');
    });

    test('compareLocators orders like the document', () {
      expect(
        compareLocators(const PdfLocator(1), const PdfLocator(2)),
        lessThan(0),
      );
      expect(
        compareLocators(
          const PdfLocator(2, pageOffset: 0.5),
          const PdfLocator(2, pageOffset: 0.2),
        ),
        greaterThan(0),
      );
      expect(compareLocators(const TextLocator(5), const TextLocator(5)), 0);
      expect(
        compareLocators(const TextLocator(5), const PdfLocator(5)),
        isNull,
      );
    });

    test('currentEntryIndex finds the section containing a position', () {
      const entries = [
        TocEntry(title: 'A', locator: PdfLocator(0)),
        TocEntry(title: 'B', locator: PdfLocator(4)),
        TocEntry(title: 'C', locator: PdfLocator(9)),
      ];
      expect(currentEntryIndex(entries, const PdfLocator(6)), 1);
      expect(currentEntryIndex(entries, const PdfLocator(4)), 1);
      expect(
        currentEntryIndex(entries, const PdfLocator(9, pageOffset: 0.5)),
        2,
      );
      expect(currentEntryIndex(const [], const PdfLocator(1)), isNull);
    });
  });
}
