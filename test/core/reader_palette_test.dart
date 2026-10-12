import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/core/theme/reader_palette.dart';
import 'package:material_ui/material_ui.dart';

/// WCAG 2 contrast ratio.
double contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final (light, dark) = la > lb ? (la, lb) : (lb, la);
  return (light + 0.05) / (dark + 0.05);
}

void main() {
  test('reading palettes meet WCAG AA, as documented', () {
    const documented = {
      'paper': (ReaderPalette.paper, 16.1, 5.5),
      'sepia': (ReaderPalette.sepia, 10.9, 4.7),
      'night': (ReaderPalette.night, 12.7, 6.3),
    };
    for (final MapEntry(key: name, value: (palette, body, secondary))
        in documented.entries) {
      final bodyRatio = contrast(palette.text, palette.background);
      final secondaryRatio = contrast(
        palette.secondaryText,
        palette.background,
      );
      expect(bodyRatio, greaterThanOrEqualTo(4.5), reason: '$name body');
      expect(secondaryRatio, greaterThanOrEqualTo(4.5), reason: name);
      expect(bodyRatio, closeTo(body, 0.1), reason: '$name doc comment');
      expect(secondaryRatio, closeTo(secondary, 0.1), reason: name);
    }
  });
}
