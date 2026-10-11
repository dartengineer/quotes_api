import 'package:material_ui/material_ui.dart';

/// Spacing scale (logical pixels). Use these instead of ad-hoc numbers.
abstract final class Spacing {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;
}

/// Corner radii.
abstract final class Radii {
  static const double sm = 6;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;

  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgAll = BorderRadius.all(Radius.circular(lg));
}

/// Width breakpoints for adaptive layouts.
abstract final class Breakpoints {
  /// From this width up, the app uses a navigation rail instead of a bottom
  /// navigation bar.
  static const double medium = 600;
  static const double expanded = 840;
}

/// Brand colours. The full palette is derived from [seed] with Material 3's
/// tonal algorithm, so light and dark schemes stay consistent.
abstract final class BrandColors {
  /// A deep ink teal: calm, high-contrast and not tiring for long reading.
  static const Color seed = Color(0xFF2B5D5A);

  /// Background tints used for generated covers when a document has no cover
  /// image. Chosen to stay legible with white text.
  static const List<Color> coverTints = [
    Color(0xFF2B5D5A),
    Color(0xFF6B4E71),
    Color(0xFF8C5A3C),
    Color(0xFF3F5873),
    Color(0xFF5D6B35),
    Color(0xFF7A3E48),
    Color(0xFF45536B),
    Color(0xFF6E5A2E),
  ];
}
