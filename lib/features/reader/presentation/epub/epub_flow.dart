import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../../../../core/utils/app_log.dart';
import '../../../../core/utils/text_search.dart';
import '../../../../engines/epub/epub_book.dart';
import '../../domain/locator.dart';
import '../../domain/search_hit.dart';
import '../../domain/toc_entry.dart';
import '../flow/flow_document.dart';

/// An EPUB as one column of blocks. Chapters follow each other in reading
/// order; global offsets count the characters of all chapters, with one
/// separator between chapters.
class EpubFlow implements FlowDocument {
  EpubFlow(this._book, this._filePath) {
    var offset = 0;
    for (final (c, chapter) in _book.chapters.indexed) {
      _chapterStarts.add(offset);
      _chapterByPath.putIfAbsent(chapter.path, () => c);
      for (final (i, block) in chapter.content.blocks.indexed) {
        _blockChapter.add(c);
        _blockLocal.add(i);
        _blockStarts.add(offset + block.start);
        _blockEnds.add(offset + block.end);
      }
      offset += chapter.content.text.length + 1;
    }
    _length = offset == 0 ? 0 : offset - 1;
    _contents = _resolveContents();
  }

  final EpubBook _book;
  final String _filePath;

  final _chapterStarts = <int>[];
  final _chapterByPath = <String, int>{};
  final _blockChapter = <int>[];
  final _blockLocal = <int>[];
  final _blockStarts = <int>[];
  final _blockEnds = <int>[];
  late final int _length;
  late final List<TocEntry> _contents;

  /// Recently used images, so scrolling back does not read them again.
  final _images = <String, Future<Uint8List?>>{};
  static const _maxCachedImages = 24;

  @override
  int get length => _length;

  @override
  int get blockCount => _blockStarts.length;

  @override
  int blockStart(int index) => _blockStarts[index];

  @override
  int blockEnd(int index) => _blockEnds[index];

  @override
  int blockIndexAt(int offset) => _lastAtOrBefore(_blockStarts, offset);

  @override
  ContentBlock blockAt(int index) =>
      _book.chapters[_blockChapter[index]].content.blocks[_blockLocal[index]];

  @override
  String blockText(int index) {
    final block = blockAt(index);
    return _book.chapters[_blockChapter[index]].content.text.substring(
      block.start,
      block.end,
    );
  }

  @override
  bool startsSection(int index) => _blockLocal[index] == 0;

  @override
  double progressAt(int offset) =>
      _length == 0 ? 0 : (offset / _length).clamp(0.0, 1.0);

  @override
  int offsetAt(double progress) => (progress.clamp(0.0, 1.0) * _length).round();

  int _chapterAt(int offset) => _lastAtOrBefore(_chapterStarts, offset);

  @override
  Locator locatorAt(int offset) {
    final c = _chapterAt(offset);
    final chapter = _book.chapters[c];
    final length = chapter.content.text.length;
    final local = (offset - _chapterStarts[c]).clamp(0, length);
    return EpubLocator(
      href: chapter.path,
      offset: local,
      progression: length == 0 ? 0 : local / length,
    );
  }

  @override
  int? offsetOf(Locator locator) {
    if (locator is! EpubLocator) return null;
    final c = _chapterByPath[locator.href];
    if (c == null) return null;
    final length = _book.chapters[c].content.text.length;
    return _chapterStarts[c] + locator.offset.clamp(0, length);
  }

  @override
  String? excerptAt(int offset) {
    final c = _chapterAt(offset);
    final text = _book.chapters[c].content.text;
    final excerpt = excerptFrom(
      text.replaceAll(objectReplacement, ' '),
      (offset - _chapterStarts[c]).clamp(0, text.length),
    );
    return excerpt.isEmpty ? null : excerpt;
  }

  @override
  String textBetween(int start, int end) {
    final parts = <String>[];
    var from = start.clamp(0, _length);
    final to = end.clamp(from, _length);
    while (from < to) {
      final c = _chapterAt(from);
      final chapterStart = _chapterStarts[c];
      final text = _book.chapters[c].content.text;
      final local = (from - chapterStart).clamp(0, text.length);
      final localEnd = (to - chapterStart).clamp(local, text.length);
      parts.add(text.substring(local, localEnd));
      // Continue in the next chapter, after the separator.
      from = chapterStart + text.length + 1;
    }
    return parts.join('\n').replaceAll(objectReplacement, '').trim();
  }

  @override
  Future<List<SearchHit>> search(String query) async {
    final texts = [for (final c in _book.chapters) c.content.text];
    final found = await _searchInBackground(texts, query);
    return [
      for (final (chapter, hit) in found)
        SearchHit(
          locator: locatorAt(_chapterStarts[chapter] + hit.start),
          progress: progressAt(_chapterStarts[chapter] + hit.start),
          snippet: hit.snippet,
          snippetMatchStart: hit.snippetMatchStart,
          matchLength: hit.length,
        ),
    ];
  }

  @override
  List<TocEntry> get contents => _contents;

  List<TocEntry> _resolveContents() => [
    for (final item in _book.toc)
      if (_chapterByPath[item.path] case final c?)
        TocEntry(
          title: item.title,
          locator: locatorAt(
            _chapterStarts[c] +
                (item.fragment == null
                    ? 0
                    : _book.chapters[c].content.anchors[item.fragment] ?? 0),
          ),
          depth: item.depth,
        ),
  ];

  @override
  FlowLinkTarget? linkAt(int index, int offsetInBlock) {
    final chapter = _book.chapters[_blockChapter[index]];
    for (final run in blockAt(index).runs) {
      if (run.link == null) continue;
      if (offsetInBlock < run.start || offsetInBlock >= run.end) continue;
      final link = chapter.content.links[run.link!];
      if (link.url case final url?) return ExternalTarget(url);
      final target = _chapterByPath[link.path];
      // Links into documents outside the reading order are not followed.
      if (target == null) return null;
      final anchor = link.fragment == null
          ? 0
          : _book.chapters[target].content.anchors[link.fragment] ?? 0;
      return InternalTarget(_chapterStarts[target] + anchor);
    }
    return null;
  }

  @override
  Future<Uint8List?> loadImage(String path) {
    final cached = _images.remove(path);
    if (cached != null) return _images[path] = cached;
    final loading = _readInBackground(_filePath, path).catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      AppLog.error('Reading a book image failed', error, stackTrace);
      return null;
    });
    _images[path] = loading;
    while (_images.length > _maxCachedImages) {
      // Evicted loads still complete for whoever awaits them.
      unawaited(_images.remove(_images.keys.first));
    }
    return loading;
  }

  /// Index of the last value at or before [offset] in ascending [starts].
  static int _lastAtOrBefore(List<int> starts, int offset) {
    var low = 0;
    var high = starts.length - 1;
    var result = 0;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (starts[mid] <= offset) {
        result = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return result;
  }
}

// Isolate closures are built in top-level functions so that they capture
// only their arguments.

Future<Uint8List?> _readInBackground(String filePath, String entryPath) =>
    Isolate.run(() => readEpubResource(filePath, entryPath));

Future<List<(int, TextHit)>> _searchInBackground(
  List<String> texts,
  String query,
) => Isolate.run(() => searchChapters(texts, query));

/// Finds [query] in chapter [texts], at most [maxHits] in all. Snippets show
/// no placeholder characters.
List<(int, TextHit)> searchChapters(
  List<String> texts,
  String query, {
  int maxHits = 500,
}) {
  final pattern = flexibleSearchPattern(query);
  if (pattern == null) return const [];
  final hits = <(int, TextHit)>[];
  for (final (c, text) in texts.indexed) {
    for (final hit in findTextMatches(
      text,
      pattern,
      maxHits: maxHits - hits.length,
    )) {
      hits.add((
        c,
        TextHit(
          start: hit.start,
          end: hit.end,
          snippet: hit.snippet.replaceAll(objectReplacement, ' '),
          snippetMatchStart: hit.snippetMatchStart,
        ),
      ));
    }
    if (hits.length >= maxHits) break;
  }
  return hits;
}
