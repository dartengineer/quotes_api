import 'dart:convert';

import 'package:equatable/equatable.dart';

import 'locator.dart';

/// What part of a document an annotation covers. Stored as JSON; each kind
/// has a stable tag, and existing field names never change.
sealed class AnnotationRange extends Equatable {
  const AnnotationRange();

  /// Where the annotation starts, for ordering and jumping to it.
  Locator get start;

  Map<String, Object?> toJson();

  String encode() => jsonEncode(toJson());

  /// Parses a stored range; null for anything unrecognised or malformed.
  static AnnotationRange? decode(String? source) {
    if (source == null || source.isEmpty) return null;
    try {
      return fromJson(jsonDecode(source));
    } on FormatException {
      return null;
    }
  }

  /// Like [decode], for an already parsed JSON value.
  static AnnotationRange? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    try {
      return switch (json['k']) {
        TextRangeAnchor.kind => TextRangeAnchor._fromJson(json),
        PdfAreaRange.kind => PdfAreaRange._fromJson(json),
        _ => null,
      };
    } on TypeError {
      return null;
    }
  }
}

/// A stretch of reflowable text (TXT, EPUB) from [start] up to, not
/// including, [end]. Both locators are of the document's kind.
final class TextRangeAnchor extends AnnotationRange {
  const TextRangeAnchor({required this.start, required this.end});

  static const kind = 'text';

  @override
  final Locator start;
  final Locator end;

  static TextRangeAnchor? _fromJson(Map<String, Object?> json) {
    final start = Locator.fromJson(json['s']);
    final end = Locator.fromJson(json['e']);
    if (start == null || end == null) return null;
    if (start.runtimeType != end.runtimeType) return null;
    return TextRangeAnchor(start: start, end: end);
  }

  @override
  Map<String, Object?> toJson() => {
    'k': kind,
    's': start.toJson(),
    'e': end.toJson(),
  };

  @override
  List<Object?> get props => [start, end];
}

/// Highlighted areas on PDF pages, as rectangles in page coordinates
/// scaled to `[0, 1]` (origin at the bottom left, as in PDF). Geometry,
/// rather than text offsets, keeps highlights in place whatever text
/// extraction makes of the page.
final class PdfAreaRange extends AnnotationRange {
  /// [areas] must not be empty (decoding never produces an empty range).
  const PdfAreaRange(this.areas);

  static const kind = 'pdf';

  final List<PdfPageArea> areas;

  @override
  PdfLocator get start {
    final first = areas.first;
    final top = first.rects.map((r) => r.top).reduce((a, b) => a > b ? a : b);
    final offset = ((1 - top).clamp(0.0, 1.0) * 10000).roundToDouble() / 10000;
    return PdfLocator(first.pageIndex, pageOffset: offset);
  }

  static PdfAreaRange? _fromJson(Map<String, Object?> json) {
    final raw = json['a'];
    if (raw is! List<Object?>) return null;
    final areas = <PdfPageArea>[];
    for (final item in raw.take(_maxPages)) {
      if (item is! Map<String, Object?>) return null;
      final page = item['p'];
      final rects = item['r'];
      if (page is! int || page < 0 || rects is! List<Object?>) return null;
      final parsed = <NormalizedRect>[];
      for (final r in rects.take(_maxRectsPerPage)) {
        final rect = NormalizedRect._fromJson(r);
        if (rect == null) return null;
        parsed.add(rect);
      }
      if (parsed.isEmpty) return null;
      areas.add(PdfPageArea(pageIndex: page, rects: parsed));
    }
    return areas.isEmpty ? null : PdfAreaRange(areas);
  }

  static const _maxPages = 64;
  static const _maxRectsPerPage = 512;

  @override
  Map<String, Object?> toJson() => {
    'k': kind,
    'a': [
      for (final area in areas)
        {
          'p': area.pageIndex,
          'r': [for (final r in area.rects) r.toJson()],
        },
    ],
  };

  @override
  List<Object?> get props => [areas];
}

class PdfPageArea extends Equatable {
  const PdfPageArea({required this.pageIndex, required this.rects});

  final int pageIndex;
  final List<NormalizedRect> rects;

  @override
  List<Object?> get props => [pageIndex, rects];
}

/// A rectangle on a page, each edge as a fraction of the page's width or
/// height, measured from the bottom left (so [top] > [bottom]).
class NormalizedRect extends Equatable {
  const NormalizedRect(this.left, this.top, this.right, this.bottom);

  final double left;
  final double top;
  final double right;
  final double bottom;

  static NormalizedRect? _fromJson(Object? json) {
    if (json is! List<Object?> || json.length != 4) return null;
    final values = <double>[];
    for (final v in json) {
      if (v is! num || !v.isFinite) return null;
      values.add(v.toDouble().clamp(0.0, 1.0));
    }
    return NormalizedRect(values[0], values[1], values[2], values[3]);
  }

  List<double> toJson() => [
    for (final v in [left, top, right, bottom])
      (v * 100000).roundToDouble() / 100000,
  ];

  @override
  List<Object?> get props => [left, top, right, bottom];
}

/// Highlight colours offered when annotating.
enum HighlightColor {
  yellow(0xFFFFD54F, 'Yellow'),
  green(0xFF81C784, 'Green'),
  blue(0xFF64B5F6, 'Blue'),
  pink(0xFFF48FB1, 'Pink');

  const HighlightColor(this.argb, this.label);

  /// Opaque colour; drawn translucently over text.
  final int argb;
  final String label;

  static HighlightColor fromArgb(int argb) =>
      values.where((c) => c.argb == argb).firstOrNull ?? yellow;
}

/// A highlighted passage, optionally with a note.
class Annotation extends Equatable {
  const Annotation({
    required this.id,
    required this.documentId,
    required this.range,
    required this.progress,
    required this.text,
    required this.color,
    required this.createdAt,
    required this.updatedAt,
    this.note,
  });

  final int id;
  final int documentId;
  final AnnotationRange range;

  /// Position of the start in `[0, 1]`, for ordering and display.
  final double progress;

  /// The highlighted text.
  final String text;
  final String? note;
  final HighlightColor color;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get hasNote => note != null && note!.trim().isNotEmpty;

  @override
  List<Object?> get props => [
    id,
    documentId,
    range,
    progress,
    text,
    note,
    color,
    createdAt,
    updatedAt,
  ];
}

/// A new annotation, before it is saved.
class AnnotationDraft extends Equatable {
  const AnnotationDraft({
    required this.range,
    required this.progress,
    required this.text,
  });

  final AnnotationRange range;
  final double progress;
  final String text;

  @override
  List<Object?> get props => [range, progress, text];
}
