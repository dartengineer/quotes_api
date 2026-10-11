import 'package:material_ui/material_ui.dart';

import '../../features/reader/domain/reader_preferences.dart';

/// Page colours for reading. Measured WCAG contrast, body text / secondary
/// text: paper 16.1:1 / 5.5:1, sepia 10.9:1 / 4.7:1, night 12.7:1 / 6.3:1
/// (all at least AA).
class ReaderPalette {
  const ReaderPalette._({
    required this.background,
    required this.text,
    required this.secondaryText,
    required this.highlight,
    required this.isDark,
  });

  static const paper = ReaderPalette._(
    background: Color(0xFFFBFAF7),
    text: Color(0xFF1F1D1A),
    secondaryText: Color(0xFF6B665E),
    highlight: Color(0x66FFD54F),
    isDark: false,
  );

  static const sepia = ReaderPalette._(
    background: Color(0xFFF3E9D2),
    text: Color(0xFF3A2E1F),
    secondaryText: Color(0xFF75644E),
    highlight: Color(0x66E0A030),
    isDark: false,
  );

  static const night = ReaderPalette._(
    background: Color(0xFF121212),
    text: Color(0xFFD8D4CC),
    secondaryText: Color(0xFF9A958C),
    highlight: Color(0x804A6FA5),
    isDark: true,
  );

  /// Resolves [theme], following the app's brightness for
  /// [ReaderTheme.auto].
  static ReaderPalette of(ReaderTheme theme, Brightness appBrightness) {
    return switch (theme) {
      ReaderTheme.auto => appBrightness == Brightness.dark ? night : paper,
      ReaderTheme.paper => paper,
      ReaderTheme.sepia => sepia,
      ReaderTheme.night => night,
    };
  }

  final Color background;
  final Color text;
  final Color secondaryText;

  /// Background for highlighted text (search hits, later annotations).
  final Color highlight;
  final bool isDark;
}
