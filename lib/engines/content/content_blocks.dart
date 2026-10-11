/// Formatted text as a column of blocks, shared by the reflowable formats
/// (EPUB chapters, plain text).
library;

/// Inline style flags of a [StyledRun]; combine with `|`.
abstract final class InlineStyle {
  static const bold = 1 << 0;
  static const italic = 1 << 1;
  static const underline = 1 << 2;
  static const strikethrough = 1 << 3;
  static const monospace = 1 << 4;
  static const small = 1 << 5;
  static const superscript = 1 << 6;
  static const subscript = 1 << 7;
}

/// A styled stretch of a block's text. Offsets are relative to the block.
class StyledRun {
  const StyledRun(this.start, this.end, this.style, [this.link]);

  final int start;
  final int end;
  final int style;

  /// Index into the document's list of links, if this run is a link.
  final int? link;

  @override
  bool operator ==(Object other) =>
      other is StyledRun &&
      other.start == start &&
      other.end == end &&
      other.style == style &&
      other.link == link;

  @override
  int get hashCode => Object.hash(start, end, style, link);

  @override
  String toString() => 'StyledRun($start, $end, $style, $link)';
}

enum BlockKind {
  paragraph,
  heading,
  quote,
  preformatted,
  listItem,
  caption,
  image,
  rule,
}

/// One block of a chapter: a paragraph-like piece of text, an image or a
/// horizontal rule. Text blocks own `text[start, end)` of the chapter text;
/// images and rules stand for one placeholder character.
class ContentBlock {
  const ContentBlock({
    required this.kind,
    required this.start,
    required this.end,
    this.level = 0,
    this.centered = false,
    this.continues = false,
    this.runs = const [],
    this.imagePath,
    this.imageAlt,
    this.aspectRatio,
  });

  final BlockKind kind;
  final int start;
  final int end;

  /// Heading level (1-6), or nesting depth of lists and quotes.
  final int level;
  final bool centered;

  /// The block is part of a longer paragraph that was split for layout;
  /// no paragraph spacing follows it.
  final bool continues;

  /// Inline styles; text outside every run is plain.
  final List<StyledRun> runs;

  /// Archive path of an image block's picture.
  final String? imagePath;
  final String? imageAlt;

  /// Width / height, when the document states the image's size.
  final double? aspectRatio;

  int get length => end - start;
}

/// The placeholder character images and rules stand for.
const objectReplacement = '\uFFFC';
