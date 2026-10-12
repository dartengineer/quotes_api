import 'package:pdfrx/pdfrx.dart';

/// Merges the character boxes of a text range into one box per line, for
/// highlighting. Empty boxes (spaces, line breaks) are skipped.
List<PdfRect> lineBoxes(List<PdfRect> charRects, int start, int end) {
  final boxes = <PdfRect>[];
  PdfRect? line;
  final to = end.clamp(0, charRects.length);
  for (var i = start.clamp(0, to); i < to; i++) {
    final rect = charRects[i];
    if (rect.isEmpty) continue;
    final current = line;
    if (current != null && _sameLine(current, rect)) {
      line = current.merge(rect);
    } else {
      if (current != null) boxes.add(current);
      line = rect;
    }
  }
  if (line != null) boxes.add(line);
  return boxes;
}

/// Boxes on the same line overlap vertically by at least half the smaller
/// box's height.
bool _sameLine(PdfRect a, PdfRect b) {
  final overlap =
      (a.top < b.top ? a.top : b.top) -
      (a.bottom > b.bottom ? a.bottom : b.bottom);
  final smaller = a.height < b.height ? a.height : b.height;
  return overlap >= smaller / 2;
}
