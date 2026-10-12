import 'dart:convert';

import 'package:equatable/equatable.dart';

/// A position inside a document, independent of font size, screen size and
/// layout, so it survives changing reader settings or devices.
///
/// Locators are stored as JSON. Each subtype has a stable type tag; never
/// change existing tags or field names, only add new ones.
sealed class Locator extends Equatable {
  const Locator();

  Map<String, Object?> toJson();

  String encode() => jsonEncode(toJson());

  /// Parses a stored locator. Returns null for anything unrecognised or
  /// malformed, so a bad row never breaks opening a document.
  static Locator? decode(String? source) {
    if (source == null || source.isEmpty) return null;
    try {
      return fromJson(jsonDecode(source));
    } on FormatException {
      return null;
    }
  }

  /// Like [decode], for an already parsed JSON value.
  static Locator? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    try {
      return switch (json['t']) {
        TextLocator.type => TextLocator._fromJson(json),
        PdfLocator.type => PdfLocator._fromJson(json),
        EpubLocator.type => EpubLocator._fromJson(json),
        _ => null,
      };
    } on TypeError {
      return null;
    }
  }
}

/// A character position in a plain-text document: the UTF-16 code-unit
/// offset into the decoded text (after newline normalisation).
final class TextLocator extends Locator {
  const TextLocator(this.offset) : assert(offset >= 0);

  static const type = 'txt';

  final int offset;

  static TextLocator? _fromJson(Map<String, Object?> json) {
    final offset = json['o'];
    if (offset is! int || offset < 0) return null;
    return TextLocator(offset);
  }

  @override
  Map<String, Object?> toJson() => {'t': type, 'o': offset};

  @override
  List<Object?> get props => [offset];

  @override
  String toString() => 'TextLocator($offset)';
}

/// A position in a PDF: a zero-based page index plus how far down that page
/// (0 = top, 1 = bottom) the reading position is. Both are independent of
/// zoom and screen size.
///
/// [charIndex] optionally pins a character in the page's text as PDFium
/// extracts it (its raw text order), for search results and, later,
/// highlights.
final class PdfLocator extends Locator {
  const PdfLocator(this.pageIndex, {this.pageOffset = 0, this.charIndex})
    : assert(pageIndex >= 0),
      assert(charIndex == null || charIndex >= 0);

  static const type = 'pdf';

  final int pageIndex;
  final double pageOffset;
  final int? charIndex;

  static PdfLocator? _fromJson(Map<String, Object?> json) {
    final page = json['p'];
    final offset = json['y'];
    final char = json['c'];
    if (page is! int || page < 0) return null;
    final y = offset is num ? offset.toDouble().clamp(0.0, 1.0) : 0.0;
    return PdfLocator(
      page,
      pageOffset: y,
      charIndex: char is int && char >= 0 ? char : null,
    );
  }

  @override
  Map<String, Object?> toJson() => {
    't': type,
    'p': pageIndex,
    'y': pageOffset,
    'c': ?charIndex,
  };

  @override
  List<Object?> get props => [pageIndex, pageOffset, charIndex];

  @override
  String toString() => 'PdfLocator($pageIndex, $pageOffset, $charIndex)';
}

/// A position in an EPUB: the spine item (by archive path, which is stable
/// across reading-order changes) and a character offset into that chapter's
/// text. [progression] (0..1 within the chapter) is a fallback if the
/// chapter's text model ever changes.
final class EpubLocator extends Locator {
  const EpubLocator({
    required this.href,
    required this.offset,
    this.progression = 0,
  }) : assert(offset >= 0);

  static const type = 'epub';

  final String href;
  final int offset;
  final double progression;

  static EpubLocator? _fromJson(Map<String, Object?> json) {
    final href = json['h'];
    final offset = json['o'];
    final progression = json['g'];
    if (href is! String || href.isEmpty) return null;
    if (offset is! int || offset < 0) return null;
    return EpubLocator(
      href: href,
      offset: offset,
      progression: progression is num
          ? progression.toDouble().clamp(0.0, 1.0)
          : 0,
    );
  }

  @override
  Map<String, Object?> toJson() => {
    't': type,
    'h': href,
    'o': offset,
    'g': progression,
  };

  @override
  List<Object?> get props => [href, offset, progression];
}

/// Where the reader currently is, as reported by a format's view.
class ReaderPosition extends Equatable {
  const ReaderPosition({
    required this.locator,
    required this.progress,
    this.visibleEnd,
    this.pageCount,
  });

  /// The start of the visible content.
  final Locator locator;

  /// Overall progress through the document in `[0, 1]`.
  final double progress;

  /// The end of the visible content, if the format can tell. Used to decide
  /// whether a bookmark is "on screen".
  final Locator? visibleEnd;

  /// Number of pages, for formats with fixed pages (PDF).
  final int? pageCount;

  /// Whether [other] lies within the visible content.
  bool shows(Locator other) {
    final start = locator;
    final end = visibleEnd;
    return switch ((start, other, end)) {
      (
        TextLocator(:final offset),
        TextLocator(offset: final o),
        TextLocator(offset: final endOffset),
      ) =>
        o >= offset && o <= endOffset,
      (TextLocator(:final offset), TextLocator(offset: final o), null) =>
        o == offset,
      (PdfLocator(:final pageIndex), PdfLocator(pageIndex: final p), _) =>
        p == pageIndex,
      (
        EpubLocator(:final href, :final offset),
        EpubLocator(href: final h, offset: final o),
        EpubLocator(href: final endHref, offset: final endOffset),
      ) =>
        h == href && h == endHref && o >= offset && o <= endOffset,
      _ => start == other,
    };
  }

  @override
  List<Object?> get props => [locator, progress, visibleEnd, pageCount];
}
