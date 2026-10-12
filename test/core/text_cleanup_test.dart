import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/core/utils/text_cleanup.dart';

void main() {
  group('cleanMetadataText', () {
    test('collapses whitespace and strips control characters', () {
      expect(cleanMetadataText('  A\u0000 \t title\n here '), 'A title here');
    });

    test('returns null for empty values', () {
      expect(cleanMetadataText(null), isNull);
      expect(cleanMetadataText(' \n\t '), isNull);
    });

    test('truncates long values with an ellipsis', () {
      final result = cleanMetadataText('x' * 50, maxLength: 10)!;
      expect(result.length, lessThanOrEqualTo(10));
      expect(result, endsWith('…'));
    });

    test('never splits a surrogate pair', () {
      final result = truncateText('${'a' * 8}😀😀😀', 10);
      expect(result, isNot(contains('�')));
      // Every high surrogate is followed by a low surrogate.
      for (var i = 0; i < result.length; i++) {
        final unit = result.codeUnitAt(i);
        if (unit >= 0xD800 && unit <= 0xDBFF) {
          final next = result.codeUnitAt(i + 1);
          expect(next >= 0xDC00 && next <= 0xDFFF, isTrue);
        }
      }
    });
  });

  test('titleFromFileName', () {
    expect(titleFromFileName('war_and_peace.epub'), 'war and peace');
    expect(titleFromFileName('My Book.final.pdf'), 'My Book.final');
    expect(titleFromFileName('.epub'), '.epub');
  });

  group('plainTextFromHtml', () {
    test('drops tags, keeps paragraph breaks, decodes entities', () {
      expect(
        plainTextFromHtml(
          '<p>One &amp; two</p><p>Three&nbsp;&#8212; four&#x21;</p>',
        ),
        'One & two\nThree — four!',
      );
    });

    test('never interprets script content as markup to run', () {
      expect(
        plainTextFromHtml('<script>alert(1)</script>Safe'),
        'alert(1)Safe',
      );
    });

    test('ignores invalid character references', () {
      expect(
        plainTextFromHtml('A&#xD800;B&#99999999;C'),
        'A&#xD800;B&#99999999;C',
      );
    });
  });
}
