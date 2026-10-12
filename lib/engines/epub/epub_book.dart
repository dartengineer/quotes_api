import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/files/safe_zip.dart';
import 'epub_content.dart';
import 'epub_navigation.dart';
import 'epub_package.dart';
import 'epub_xml.dart';

/// Limits applied when opening a book for reading. Content beyond them is
/// left out (and the book marked as truncated) rather than exhausting
/// memory.
abstract final class EpubReadLimits {
  /// Compressed books can be large; one chapter document cannot.
  static const chapterBytes = 8 * 1024 * 1024;
  static const chapterChars = 4 * 1024 * 1024;

  /// Characters of text across the whole book (about 80 MB in memory).
  static const totalChars = 40 * 1024 * 1024;
  static const chapters = 5000;
  static const navigationBytes = 2 * 1024 * 1024;
  static const imageBytes = 15 * 1024 * 1024;
}

/// The path of the notice that ends a book cut short by [EpubReadLimits];
/// not a valid archive path.
const truncatedNoticePath = 'lectern:truncated';

/// A chapter (spine document) of a book.
class EpubChapter {
  const EpubChapter({required this.path, required this.content});

  /// Archive path; identifies the chapter in reading positions.
  final String path;
  final ParsedChapter content;
}

/// An EPUB loaded for reading: its chapters in reading order, reduced to
/// text and blocks, and its table of contents.
class EpubBook {
  const EpubBook({
    required this.chapters,
    required this.toc,
    this.truncated = false,
  });

  final List<EpubChapter> chapters;
  final List<EpubTocItem> toc;

  /// Some content was left out because of [EpubReadLimits].
  final bool truncated;
}

const _markupTypes = {
  'application/xhtml+xml',
  'text/html',
  'application/xml',
  'text/xml',
  'image/svg+xml',
};

/// Loads the EPUB at [filePath] for reading. Synchronous and CPU-bound:
/// call it on a background isolate.
///
/// Throws [EpubException] for damaged or DRM-protected books and
/// [FormatException] if the file is not a zip archive.
EpubBook loadEpubBook(
  String filePath, {
  int maxChars = EpubReadLimits.totalChars,
}) {
  final zip = SafeZip.open(filePath);
  try {
    final package = EpubPackageParser.parse(zip);
    final linear = package.spine.where((s) => s.linear).toList();
    // Some broken books mark everything non-linear; read them anyway.
    final spine = linear.isEmpty ? package.spine : linear;

    final chapters = <EpubChapter>[];
    final seen = <String>{};
    var budget = maxChars;
    var truncated = false;
    for (final entry in spine) {
      final item = entry.item;
      if (!seen.add(item.path)) continue;
      if (budget <= 0 || chapters.length >= EpubReadLimits.chapters) {
        truncated = true;
        break;
      }
      final content = _loadChapter(
        zip,
        item,
        math.min(budget, EpubReadLimits.chapterChars),
      );
      if (content == null) continue;
      if (content.truncated) truncated = true;
      budget -= content.text.length + 1;
      chapters.add(EpubChapter(path: item.path, content: content));
    }
    if (chapters.isEmpty) {
      throw const EpubException(EpubProblem.damaged, 'no readable chapters');
    }
    if (truncated) {
      // Say so at the end rather than stopping silently.
      chapters.add(
        EpubChapter(
          path: truncatedNoticePath,
          content: _notice('The rest of this book is too large to display.'),
        ),
      );
    }
    return EpubBook(
      chapters: chapters,
      toc: _loadToc(zip, package),
      truncated: truncated,
    );
  } finally {
    zip.close();
  }
}

ParsedChapter? _loadChapter(SafeZip zip, EpubManifestItem item, int maxChars) {
  if (item.isImage) {
    // A picture as a whole page.
    return ParsedChapter(
      text: objectReplacement,
      blocks: [
        ContentBlock(
          kind: BlockKind.image,
          start: 0,
          end: 1,
          centered: true,
          imagePath: item.path,
        ),
      ],
      anchors: const {},
      links: const [],
    );
  }
  if (!_markupTypes.contains(item.mediaType)) return null;
  final Uint8List? bytes;
  try {
    bytes = zip.readPath(item.path, maxBytes: EpubReadLimits.chapterBytes);
  } on ZipEntryTooLargeException {
    return _notice('This part of the book is too large to display.');
  } on Object {
    return null;
  }
  if (bytes == null) return null;
  final chapter = parseXhtml(
    decodeXml(bytes),
    path: item.path,
    maxChars: maxChars,
  );
  // Documents with nothing to show (blank pages) are left out.
  return chapter.blocks.isEmpty ? null : chapter;
}

/// A chapter showing only [message], in italics.
ParsedChapter _notice(String message) => ParsedChapter(
  text: message,
  blocks: [
    ContentBlock(
      kind: BlockKind.paragraph,
      start: 0,
      end: message.length,
      centered: true,
      runs: [StyledRun(0, message.length, InlineStyle.italic)],
    ),
  ],
  anchors: const {},
  links: const [],
);

List<EpubTocItem> _loadToc(SafeZip zip, EpubPackage package) {
  final nav = package.navDocument;
  final ncx = package.ncxDocument;
  try {
    if (nav != null) {
      final bytes = zip.readPath(
        nav.path,
        maxBytes: EpubReadLimits.navigationBytes,
      );
      if (bytes != null) {
        final items = parseNavDocument(decodeXml(bytes), navPath: nav.path);
        if (items.isNotEmpty) return items;
      }
    }
    if (ncx != null) {
      final bytes = zip.readPath(
        ncx.path,
        maxBytes: EpubReadLimits.navigationBytes,
      );
      if (bytes != null) return parseNcx(decodeXml(bytes), ncxPath: ncx.path);
    }
  } on Object {
    // A broken table of contents is not worth failing the book over.
  }
  return const [];
}

/// Reads one file (such as an image) from the EPUB at [filePath], or null
/// if it is missing or larger than [maxBytes]. Call on a background
/// isolate.
Uint8List? readEpubResource(
  String filePath,
  String entryPath, {
  int maxBytes = EpubReadLimits.imageBytes,
}) {
  final zip = SafeZip.open(filePath);
  try {
    return zip.readPath(entryPath, maxBytes: maxBytes);
  } on ZipEntryTooLargeException {
    return null;
  } finally {
    zip.close();
  }
}
