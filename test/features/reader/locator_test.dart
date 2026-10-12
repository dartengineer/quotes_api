import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/features/reader/domain/locator.dart';

void main() {
  group('round-trips through JSON', () {
    for (final locator in <Locator>[
      const TextLocator(0),
      const TextLocator(123456),
      const PdfLocator(0),
      const PdfLocator(41, pageOffset: 0.25),
      const PdfLocator(3, pageOffset: 0.5, charIndex: 120),
      const EpubLocator(href: 'OEBPS/ch1.xhtml', offset: 99, progression: 0.5),
    ]) {
      test('$locator', () {
        expect(Locator.decode(locator.encode()), locator);
      });
    }
  });

  test('uses stable, compact field names', () {
    expect(const TextLocator(7).encode(), '{"t":"txt","o":7}');
    expect(
      const PdfLocator(2, pageOffset: 0.5).encode(),
      '{"t":"pdf","p":2,"y":0.5}',
    );
  });

  test('the optional PDF character index is omitted when absent', () {
    expect(
      const PdfLocator(2, charIndex: 9).encode(),
      '{"t":"pdf","p":2,"y":0.0,"c":9}',
    );
    // Positions saved before it existed still decode, and a bad index is
    // dropped rather than rejecting the position.
    expect(
      Locator.decode('{"t":"pdf","p":1,"y":0.5}'),
      const PdfLocator(1, pageOffset: 0.5),
    );
    expect(
      Locator.decode('{"t":"pdf","p":1,"y":0.5,"c":-4}'),
      const PdfLocator(1, pageOffset: 0.5),
    );
  });

  test('rejects malformed or unknown data instead of throwing', () {
    for (final bad in [
      null,
      '',
      'not json',
      '[]',
      '{"t":"txt"}',
      '{"t":"txt","o":-1}',
      '{"t":"txt","o":"12"}',
      '{"t":"pdf","p":-3}',
      '{"t":"epub","o":4}',
      '{"t":"epub","h":"","o":4}',
      '{"t":"mobi","o":1}',
    ]) {
      expect(Locator.decode(bad), isNull, reason: '$bad');
    }
  });

  test('clamps out-of-range fractions', () {
    expect(
      Locator.decode('{"t":"pdf","p":1,"y":7}'),
      const PdfLocator(1, pageOffset: 1),
    );
  });

  group('ReaderPosition.shows', () {
    test('text: within the visible range', () {
      const position = ReaderPosition(
        locator: TextLocator(100),
        progress: 0.1,
        visibleEnd: TextLocator(400),
      );
      expect(position.shows(const TextLocator(100)), isTrue);
      expect(position.shows(const TextLocator(400)), isTrue);
      expect(position.shows(const TextLocator(250)), isTrue);
      expect(position.shows(const TextLocator(99)), isFalse);
      expect(position.shows(const TextLocator(401)), isFalse);
    });

    test('pdf: same page', () {
      const position = ReaderPosition(locator: PdfLocator(3), progress: 0.3);
      expect(position.shows(const PdfLocator(3, pageOffset: 0.9)), isTrue);
      expect(position.shows(const PdfLocator(4)), isFalse);
    });

    test('different formats never match', () {
      const position = ReaderPosition(locator: TextLocator(0), progress: 0);
      expect(position.shows(const PdfLocator(0)), isFalse);
    });
  });
}
