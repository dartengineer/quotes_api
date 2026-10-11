import 'package:xml/xml.dart' show XmlDefaultEntityMapping, XmlException;
import 'package:xml/xml_events.dart';

import '../../core/files/safe_zip.dart';
import '../content/content_blocks.dart';
import 'epub_xml.dart';

export '../content/content_blocks.dart';

/// Where a link leads: elsewhere in the book, or to a web address.
class ContentLink {
  const ContentLink.internal(String this.path, this.fragment) : url = null;
  const ContentLink.external(Uri this.url) : path = null, fragment = null;

  /// Archive path of the target document.
  final String? path;
  final String? fragment;
  final Uri? url;

  @override
  bool operator ==(Object other) =>
      other is ContentLink &&
      other.path == path &&
      other.fragment == fragment &&
      other.url == url;

  @override
  int get hashCode => Object.hash(path, fragment, url);

  @override
  String toString() =>
      url != null ? 'ContentLink($url)' : 'ContentLink($path#$fragment)';
}

/// A chapter reduced to text and blocks.
class ParsedChapter {
  const ParsedChapter({
    required this.text,
    required this.blocks,
    required this.anchors,
    required this.links,
    this.truncated = false,
  });

  /// The text of all blocks, separated by line feeds.
  final String text;
  final List<ContentBlock> blocks;

  /// Element ids and their character offsets, for links and contents.
  final Map<String, int> anchors;
  final List<ContentLink> links;

  /// The chapter was cut short at the size limit.
  final bool truncated;
}

/// Reduces an XHTML chapter to blocks of styled text, images and rules.
///
/// Only a safe subset is used: scripts, styles, forms, embedded objects and
/// CSS are ignored, as is anything the publisher's styling would change
/// (fonts, sizes, colours); the reader's own typography applies. Malformed
/// markup is tolerated: parsing stops at an unrecoverable error and keeps
/// what came before.
///
/// [path] is the chapter's archive path, for resolving links and images.
/// [maxChars] bounds the chapter text; [maxBlockLength] splits long
/// paragraphs so that layout stays lazy.
ParsedChapter parseXhtml(
  String source, {
  required String path,
  int maxChars = 4 * 1024 * 1024,
  int maxBlockLength = 2000,
}) {
  final parser = _ChapterParser(path, maxChars, maxBlockLength);
  try {
    for (final event in parseEvents(
      source,
      entityMapping: const XmlDefaultEntityMapping.html5(),
    )) {
      switch (event) {
        case XmlStartElementEvent():
          parser.start(event);
        case XmlEndElementEvent():
          parser.end(localName(event.name));
        case XmlTextEvent():
          parser.text(event.value);
        case XmlCDATAEvent():
          parser.text(event.value);
        default:
        // Comments, processing instructions, declarations: nothing to show.
      }
      if (parser.full) break;
    }
  } on XmlException {
    // Keep what was parsed before the error.
  } on FormatException {
    // Same, for malformed entity or character references.
  }
  return parser.finish();
}

const _skippedTags = {
  'head',
  'script',
  'style',
  'template',
  'noscript',
  'iframe',
  'object',
  'embed',
  'canvas',
  'audio',
  'video',
  'form',
  'select',
  'textarea',
  'button',
  'input',
  'math',
};

const _voidTags = {
  'br',
  'img',
  'hr',
  'meta',
  'link',
  'input',
  'col',
  'area',
  'base',
  'wbr',
  'source',
  'embed',
  'param',
  'track',
};

const _blockTags = {
  'body',
  'p',
  'div',
  'section',
  'article',
  'aside',
  'header',
  'footer',
  'nav',
  'main',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'blockquote',
  'pre',
  'li',
  'ul',
  'ol',
  'dl',
  'dt',
  'dd',
  'figure',
  'figcaption',
  'table',
  'thead',
  'tbody',
  'tfoot',
  'tr',
  'caption',
  'address',
  'center',
  'hgroup',
};

int _inlineStyle(String name) => switch (name) {
  'b' || 'strong' => InlineStyle.bold,
  'i' || 'em' || 'cite' || 'dfn' || 'var' => InlineStyle.italic,
  'u' || 'ins' => InlineStyle.underline,
  's' || 'strike' || 'del' => InlineStyle.strikethrough,
  'code' || 'tt' || 'kbd' || 'samp' => InlineStyle.monospace,
  'small' => InlineStyle.small,
  'sup' => InlineStyle.superscript,
  'sub' => InlineStyle.subscript,
  _ => 0,
};

class _Frame {
  _Frame(
    this.name, {
    this.style = 0,
    this.link,
    this.skip = false,
    this.block = false,
    this.centered = false,
    this.svg = false,
  });

  final String name;
  final int style;
  final int? link;
  final bool skip;
  final bool block;
  final bool centered;
  final bool svg;

  /// For `ol`/`ul`: the next item number (null for unordered lists).
  int? nextNumber;
  bool ordered = false;
}

class _ChapterParser {
  _ChapterParser(this._path, this._maxChars, this._maxBlockLength);

  final String _path;
  final int _maxChars;
  final int _maxBlockLength;

  final _text = StringBuffer();
  final _blocks = <ContentBlock>[];
  final _anchors = <String, int>{};
  final _links = <ContentLink>[];
  final _linkIndex = <ContentLink, int>{};
  final _stack = <_Frame>[];

  // The paragraph being collected.
  final _para = StringBuffer();
  final _runs = <StyledRun>[];
  int _runStart = 0;
  int _runStyle = 0;
  int? _runLink;
  bool _lastSpace = true;
  int _prefixLength = 0;
  BlockKind _paraKind = BlockKind.paragraph;
  int _paraLevel = 0;
  bool _paraCentered = false;
  bool _paraStarted = false;

  bool full = false;

  /// Elements nested deeper than this are not tracked (their styling is
  /// lost), which bounds the work per text node for hostile markup.
  static const _maxDepth = 256;
  int _untracked = 0;
  int _preDepth = 0;

  _Frame? get _top => _stack.isEmpty ? null : _stack.last;
  bool get _skipping => _top?.skip ?? false;
  int get _style => _top?.style ?? 0;
  int? get _link => _top?.link;

  /// Where the next block will start in the chapter text.
  int get _nextBlockStart => _text.length + (_blocks.isEmpty ? 0 : 1);

  void start(XmlStartElementEvent event) {
    final name = localName(event.name);
    final attributes = {
      for (final a in event.attributes) localName(a.name): a.value,
    };
    final parent = _top;
    // Elements that start a new block end the current paragraph first, so
    // an id on them points at the new block, not the end of the old one.
    final startsBlock =
        _blockTags.contains(name) ||
        name == 'img' ||
        name == 'hr' ||
        ((parent?.svg ?? false) && name == 'image');
    if (startsBlock && !_skipping) _flush();
    final id = attributes['id'] ?? (name == 'a' ? attributes['name'] : null);
    if (id != null && id.isNotEmpty && !_anchors.containsKey(id)) {
      _anchors[id] = _nextBlockStart + _para.length;
    }

    if (_stack.length >= _maxDepth) {
      if (!_voidTags.contains(name) && !event.isSelfClosing) _untracked++;
      return;
    }
    if (_skipping) {
      if (!_voidTags.contains(name) && !event.isSelfClosing) {
        _stack.add(_Frame(name, skip: true));
      }
      return;
    }

    if (parent?.svg ?? false) {
      // Inside SVG only embedded pictures are kept (common for covers).
      if (name == 'image') {
        _image(
          attributes['href'],
          null,
          attributes['width'],
          attributes['height'],
        );
      }
      if (!event.isSelfClosing) _stack.add(_Frame(name, svg: true));
      return;
    }

    switch (name) {
      case 'br':
        // A line break inside a paragraph; leading breaks add nothing.
        if (_para.length > _prefixLength) {
          _appendRaw('\n');
          _lastSpace = true;
        }
        return;
      case 'img':
        _image(
          attributes['src'],
          attributes['alt'],
          attributes['width'],
          attributes['height'],
        );
        return;
      case 'hr':
        _flush();
        _addPlaceholder(BlockKind.rule);
        return;
    }
    if (_voidTags.contains(name)) return;

    if (name == 'svg') {
      _stack.add(_Frame(name, svg: true, style: _style, link: _link));
    } else if (_skippedTags.contains(name)) {
      _stack.add(_Frame(name, skip: true));
    } else if (_blockTags.contains(name)) {
      _flush();
      final frame = _Frame(
        name,
        style:
            _style |
            (name.startsWith('h') && name.length == 2 ? InlineStyle.bold : 0),
        link: _link,
        block: true,
        centered:
            (parent?.centered ?? false) ||
            name == 'center' ||
            name == 'figcaption' ||
            name == 'caption' ||
            attributes['align']?.toLowerCase() == 'center',
      );
      if (name == 'ol' || name == 'ul') {
        frame.ordered = name == 'ol';
        frame.nextNumber = int.tryParse(attributes['start'] ?? '') ?? 1;
      }
      _stack.add(frame);
      if (name == 'pre') _preDepth++;
      if (name == 'li') _startListItem();
    } else if (name == 'td' || name == 'th') {
      // Table cells share their row's paragraph.
      if (_para.length > _prefixLength) _appendRaw(' · ');
      _lastSpace = true;
      _stack.add(
        _Frame(
          name,
          style: _style | (name == 'th' ? InlineStyle.bold : 0),
          link: _link,
        ),
      );
    } else {
      int? link = _link;
      if (name == 'a') {
        final href = attributes['href'];
        if (href != null) link = _linkFor(href) ?? link;
      }
      _stack.add(_Frame(name, style: _style | _inlineStyle(name), link: link));
    }
    if (event.isSelfClosing) end(name);
  }

  void end(String name) {
    if (_untracked > 0) {
      _untracked--;
      return;
    }
    // Tolerate stray or misnested end tags: close up to the matching open
    // element, or ignore the tag if nothing matches.
    final index = _stack.lastIndexWhere((f) => f.name == name);
    if (index < 0) return;
    while (_stack.length > index) {
      final frame = _stack.removeLast();
      if (frame.block) _flush();
      if (frame.name == 'pre' && !frame.skip) _preDepth--;
      if (frame.name == 'td' || frame.name == 'th') _lastSpace = false;
    }
  }

  void text(String value) {
    if (_skipping || (_top?.svg ?? false) || full) return;
    if (_inPre) {
      _append(value.replaceAll('\r\n', '\n').replaceAll('\r', '\n'));
      return;
    }
    final out = StringBuffer();
    for (final code in value.runes) {
      final space =
          code == 0x20 ||
          code == 0x09 ||
          code == 0x0A ||
          code == 0x0D ||
          code == 0x0C;
      if (space) {
        if (!_lastSpace) {
          out.write(' ');
          _lastSpace = true;
        }
      } else if (code >= 0x20 &&
          code != 0x7F &&
          (code < 0x80 || code >= 0xA0)) {
        // Control characters are dropped.
        out.writeCharCode(code);
        _lastSpace = false;
      }
    }
    if (out.isNotEmpty) _append(out.toString());
  }

  bool get _inPre => _preDepth > 0;

  void _startListItem() {
    final list = _stack.lastWhere(
      (f) => f.name == 'ol' || f.name == 'ul',
      orElse: () => _Frame('ul'),
    );
    final String prefix;
    if (list.ordered) {
      final number = list.nextNumber ?? 1;
      list.nextNumber = number + 1;
      prefix = '$number. ';
    } else {
      prefix = '• ';
    }
    _beginParagraph();
    _appendRaw(prefix, style: 0);
    _prefixLength = _para.length;
    _lastSpace = true;
  }

  void _beginParagraph() {
    if (_paraStarted) return;
    _paraStarted = true;
    var kind = BlockKind.paragraph;
    var level = 0;
    var listDepth = 0;
    var quoteDepth = 0;
    for (final frame in _stack) {
      switch (frame.name) {
        case 'ul' || 'ol':
          listDepth++;
        case 'blockquote':
          quoteDepth++;
      }
    }
    for (final frame in _stack.reversed) {
      if (!frame.block) continue;
      final name = frame.name;
      if (name.length == 2 && name.startsWith('h') && name != 'hr') {
        final n = int.tryParse(name.substring(1));
        if (n != null && n >= 1 && n <= 6) {
          kind = BlockKind.heading;
          level = n;
          break;
        }
      }
      if (name == 'pre') {
        kind = BlockKind.preformatted;
        break;
      }
      if (name == 'li') {
        kind = BlockKind.listItem;
        level = listDepth;
        break;
      }
      if (name == 'figcaption' || name == 'caption') {
        kind = BlockKind.caption;
        break;
      }
      if (name == 'blockquote') {
        kind = BlockKind.quote;
        level = quoteDepth;
        break;
      }
    }
    _paraKind = kind;
    _paraLevel = level;
    _paraCentered = _top?.centered ?? false;
  }

  void _append(String value) {
    _beginParagraph();
    _appendRaw(value, style: _style, link: _link);
    if (_text.length + _para.length > _maxChars) full = true;
  }

  void _appendRaw(String value, {int? style, int? link}) {
    _beginParagraph();
    final s = style ?? _style;
    final l = style == null ? _link : link;
    if (s != _runStyle || l != _runLink) {
      _closeRun();
      _runStyle = s;
      _runLink = l;
    }
    _para.write(value);
  }

  void _closeRun() {
    final end = _para.length;
    if (end > _runStart && (_runStyle != 0 || _runLink != null)) {
      _runs.add(StyledRun(_runStart, end, _runStyle, _runLink));
    }
    _runStart = end;
  }

  int? _linkFor(String href) {
    final target = href.trim();
    if (target.isEmpty) return null;
    final ContentLink link;
    final scheme = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*):').firstMatch(target);
    if (scheme != null) {
      final s = scheme[1]!.toLowerCase();
      if (s != 'http' && s != 'https' && s != 'mailto') return null;
      final uri = Uri.tryParse(target);
      if (uri == null) return null;
      link = ContentLink.external(uri);
    } else {
      final hash = target.indexOf('#');
      final fragment = hash < 0 ? null : target.substring(hash + 1);
      final file = hash < 0 ? target : target.substring(0, hash);
      final resolved = file.isEmpty ? _path : SafeZip.resolve(_path, file);
      if (resolved.isEmpty) return null;
      link = ContentLink.internal(
        resolved,
        fragment == null || fragment.isEmpty ? null : _decode(fragment),
      );
    }
    return _linkIndex.putIfAbsent(link, () {
      _links.add(link);
      return _links.length - 1;
    });
  }

  static String _decode(String value) {
    try {
      return Uri.decodeComponent(value);
    } on ArgumentError {
      return value;
    }
  }

  void _image(String? src, String? alt, String? width, String? height) {
    if (src == null || src.trim().isEmpty || src.startsWith('data:')) return;
    final path = SafeZip.resolve(_path, src.trim());
    if (path.isEmpty) return;
    _flush();
    final w = _dimension(width);
    final h = _dimension(height);
    _addPlaceholder(
      BlockKind.image,
      imagePath: path,
      imageAlt: alt?.trim().isEmpty ?? true ? null : alt!.trim(),
      aspectRatio: w != null && h != null ? w / h : null,
    );
  }

  static double? _dimension(String? value) {
    final match = RegExp(r'^\s*(\d+(?:\.\d+)?)\s*(px)?\s*$')
        .firstMatch(value ?? '');
    final number = match == null ? null : double.tryParse(match[1]!);
    return number != null && number > 0 ? number : null;
  }

  void _addPlaceholder(
    BlockKind kind, {
    String? imagePath,
    String? imageAlt,
    double? aspectRatio,
  }) {
    final start = _nextBlockStart;
    if (_blocks.isNotEmpty) _text.write('\n');
    _text.write(objectReplacement);
    _blocks.add(
      ContentBlock(
        kind: kind,
        start: start,
        end: start + 1,
        centered: true,
        imagePath: imagePath,
        imageAlt: imageAlt,
        aspectRatio: aspectRatio,
      ),
    );
  }

  /// Ends the current paragraph, adding it as one or more blocks.
  void _flush() {
    _closeRun();
    var text = _para.toString();
    final runs = List.of(_runs);
    _para.clear();
    _runs.clear();
    _runStart = 0;
    _runStyle = 0;
    _runLink = null;
    _lastSpace = true;
    final prefix = _prefixLength;
    _prefixLength = 0;
    final started = _paraStarted;
    _paraStarted = false;
    if (!started) return;

    if (_paraKind != BlockKind.preformatted) {
      text = text.trimRight();
    } else {
      text = text.replaceFirst(RegExp(r'\n+$'), '');
    }
    if (text.length <= prefix || text.trim().isEmpty) return;

    final start = _nextBlockStart;
    if (_blocks.isNotEmpty) _text.write('\n');
    _text.write(text);

    var from = 0;
    while (from < text.length) {
      var to = text.length;
      if (to - from > _maxBlockLength) {
        to = _splitPoint(text, from, from + _maxBlockLength);
      }
      _blocks.add(
        ContentBlock(
          kind: _paraKind,
          start: start + from,
          end: start + to,
          level: _paraLevel,
          centered: _paraCentered,
          continues: to < text.length,
          runs: _clipRuns(runs, from, to),
        ),
      );
      from = to;
    }
  }

  /// A split point at or before [limit], after whitespace when possible,
  /// never inside a surrogate pair.
  static int _splitPoint(String text, int from, int limit) {
    // Look back at most half a block for a space.
    final floor = from + (limit - from) ~/ 2;
    for (var i = limit; i > floor; i--) {
      if (text.codeUnitAt(i - 1) == 0x20 || text.codeUnitAt(i - 1) == 0x0A) {
        return i;
      }
    }
    var i = limit;
    final unit = text.codeUnitAt(i - 1);
    if (unit >= 0xD800 && unit <= 0xDBFF) i--;
    return i;
  }

  static List<StyledRun> _clipRuns(List<StyledRun> runs, int from, int to) => [
    for (final run in runs)
      if (run.end > from && run.start < to)
        StyledRun(
          (run.start < from ? from : run.start) - from,
          (run.end > to ? to : run.end) - from,
          run.style,
          run.link,
        ),
  ];

  ParsedChapter finish() {
    _flush();
    final text = _text.toString();
    return ParsedChapter(
      text: text,
      blocks: List.unmodifiable(_blocks),
      anchors: {
        for (final entry in _anchors.entries)
          entry.key: entry.value.clamp(0, text.length),
      },
      links: List.unmodifiable(_links),
      truncated: full,
    );
  }
}
