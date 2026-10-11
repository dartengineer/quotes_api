import 'package:equatable/equatable.dart';

/// Page colour schemes for reading.
///
/// The enum [name] is persisted, so values must not be renamed.
enum ReaderTheme {
  /// Paper in a light app theme, night in a dark one.
  auto('Auto'),
  paper('Paper'),
  sepia('Sepia'),
  night('Night');

  const ReaderTheme(this.label);

  final String label;
}

/// The enum [name] is persisted, so values must not be renamed.
enum ReaderFont {
  serif('Serif', 'serif'),
  sans('Sans-serif', 'sans-serif');

  const ReaderFont(this.label, this.family);

  final String label;

  /// Generic family name resolved by the platform (on Android: Noto Serif /
  /// Roboto), so no fonts need to be bundled.
  final String family;
}

/// Typography and colour settings for reflowable text (TXT and EPUB).
class ReaderPreferences extends Equatable {
  const ReaderPreferences({
    this.theme = ReaderTheme.auto,
    this.font = ReaderFont.serif,
    this.fontSize = defaultFontSize,
    this.lineHeight = defaultLineHeight,
    this.paragraphSpacing = defaultParagraphSpacing,
    this.margin = defaultMargin,
    this.justify = false,
  });

  static const defaultFontSize = 18.0;
  static const minFontSize = 12.0;
  static const maxFontSize = 36.0;

  static const defaultLineHeight = 1.5;
  static const minLineHeight = 1.1;
  static const maxLineHeight = 2.2;

  /// Space after each paragraph, in multiples of the font size.
  static const defaultParagraphSpacing = 0.6;
  static const maxParagraphSpacing = 2.0;

  /// Horizontal page margin in logical pixels.
  static const defaultMargin = 20.0;
  static const minMargin = 8.0;
  static const maxMargin = 64.0;

  final ReaderTheme theme;
  final ReaderFont font;
  final double fontSize;
  final double lineHeight;
  final double paragraphSpacing;
  final double margin;
  final bool justify;

  ReaderPreferences copyWith({
    ReaderTheme? theme,
    ReaderFont? font,
    double? fontSize,
    double? lineHeight,
    double? paragraphSpacing,
    double? margin,
    bool? justify,
  }) {
    return ReaderPreferences(
      theme: theme ?? this.theme,
      font: font ?? this.font,
      fontSize: (fontSize ?? this.fontSize).clamp(minFontSize, maxFontSize),
      lineHeight: (lineHeight ?? this.lineHeight).clamp(
        minLineHeight,
        maxLineHeight,
      ),
      paragraphSpacing: (paragraphSpacing ?? this.paragraphSpacing).clamp(
        0,
        maxParagraphSpacing,
      ),
      margin: (margin ?? this.margin).clamp(minMargin, maxMargin),
      justify: justify ?? this.justify,
    );
  }

  @override
  List<Object?> get props => [
    theme,
    font,
    fontSize,
    lineHeight,
    paragraphSpacing,
    margin,
    justify,
  ];
}
