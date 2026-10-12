import 'annotation.dart';

/// A document's highlights and notes as Markdown, in reading order.
///
/// [location] describes where each annotation is (a page or percentage).
String annotationsToMarkdown({
  required String title,
  String? author,
  required List<Annotation> annotations,
  required String Function(Annotation annotation) location,
  required DateTime exportedAt,
}) {
  final out = StringBuffer('# ${_singleLine(title)}\n');
  if (author != null && author.trim().isNotEmpty) {
    out.write('\n*${_singleLine(author)}*\n');
  }
  final date = exportedAt.toIso8601String().substring(0, 10);
  final count = annotations.length;
  out.write(
    '\n$count ${count == 1 ? 'highlight' : 'highlights'}, exported from '
    'Lectern on $date.\n',
  );
  for (final annotation in annotations) {
    out
      ..write('\n## ${location(annotation)}\n\n')
      ..write(_quote(annotation.text))
      ..write('\n');
    if (annotation.hasNote) {
      out.write('\n**Note:** ${annotation.note!.trim()}\n');
    }
  }
  return out.toString();
}

/// Each line of [text] as a Markdown block quote line.
String _quote(String text) => text
    .replaceAll('\r\n', '\n')
    .split('\n')
    .map((line) => line.trim().isEmpty ? '>' : '> ${line.trim()}')
    .join('\n');

String _singleLine(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();
