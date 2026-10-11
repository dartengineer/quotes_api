import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/core/utils/text_search.dart';
import 'package:lectern/engines/pdf/pdf_text_geometry.dart';
import 'package:pdfrx/pdfrx.dart';

void main() {
  group('flexibleSearchPattern', () {
    test('is case-insensitive and matches across any whitespace', () {
      final pattern = flexibleSearchPattern('  quick   BROWN ')!;
      expect(pattern.hasMatch('The quick brown fox'), isTrue);
      expect(pattern.hasMatch('the Quick\r\nbrown'), isTrue);
      expect(pattern.hasMatch('quickbrown'), isFalse);
    });

    test('treats the query literally', () {
      final pattern = flexibleSearchPattern('a.b (c)')!;
      expect(pattern.hasMatch('a.b (c)'), isTrue);
      expect(pattern.hasMatch('axb (c)'), isFalse);
    });

    test('an empty query has no pattern', () {
      expect(flexibleSearchPattern(''), isNull);
      expect(flexibleSearchPattern('   '), isNull);
    });
  });

  group('findTextMatches', () {
    test('keeps offsets aligned with the page text and the snippet', () {
      const text = 'First line\r\nsecond line with a match\nthird';
      final hits = findTextMatches(text, flexibleSearchPattern('line with')!);
      expect(hits, hasLength(1));
      final hit = hits.single;
      expect(text.substring(hit.start, hit.end), 'line with');
      expect(
        hit.snippet.substring(
          hit.snippetMatchStart,
          hit.snippetMatchStart + hit.length,
        ),
        'line with',
      );
      expect(hit.snippet, isNot(contains('\n')));
    });

    test('a match spanning a line break is shown on one line', () {
      const text = 'end of one\nstart of next';
      final hit = findTextMatches(
        text,
        flexibleSearchPattern('one start')!,
      ).single;
      expect(hit.length, 'one\nstart'.length);
      expect(hit.snippet, 'end of one start of next');
    });

    test('stops at maxHits', () {
      final text = List.filled(20, 'cat').join(' ');
      expect(
        findTextMatches(text, flexibleSearchPattern('cat')!, maxHits: 5),
        hasLength(5),
      );
    });
  });

  test('excerptFrom collapses whitespace and cuts long text', () {
    expect(excerptFrom('a\r\n  b\tc', 0), 'a b c');
    expect(excerptFrom('abc', 5), '');
    expect(excerptFrom('x' * 500, 0), hasLength(160));
  });

  group('lineBoxes', () {
    // PDF coordinates: y grows upwards, top > bottom.
    const a = PdfRect(10, 100, 15, 90);
    const b = PdfRect(15, 100, 20, 90);
    const space = PdfRect(20, 100, 20, 100);
    const nextLine = PdfRect(10, 80, 15, 70);

    test('merges characters on a line and skips empty boxes', () {
      expect(lineBoxes([a, b, space, nextLine], 0, 4), [
        const PdfRect(10, 100, 20, 90),
        nextLine,
      ]);
    });

    test('respects the range and clamps it', () {
      expect(lineBoxes([a, b, nextLine], 1, 2), [b]);
      expect(lineBoxes([a, b], -5, 99), [const PdfRect(10, 100, 20, 90)]);
      expect(lineBoxes([a], 1, 1), isEmpty);
    });
  });
}
