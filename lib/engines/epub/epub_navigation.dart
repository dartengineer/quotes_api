import 'package:xml/xml.dart';

import '../../core/files/safe_zip.dart';
import 'epub_xml.dart';

/// One entry of an EPUB's table of contents, flattened: [depth] is 0 for
/// top-level entries.
class EpubTocItem {
  const EpubTocItem({
    required this.title,
    required this.path,
    this.fragment,
    this.depth = 0,
  });

  final String title;

  /// Archive path of the target document.
  final String path;
  final String? fragment;
  final int depth;

  @override
  bool operator ==(Object other) =>
      other is EpubTocItem &&
      other.title == title &&
      other.path == path &&
      other.fragment == fragment &&
      other.depth == depth;

  @override
  int get hashCode => Object.hash(title, path, fragment, depth);

  @override
  String toString() => 'EpubTocItem($title -> $path#$fragment @$depth)';
}

/// Bounds against hostile navigation documents.
const _maxEntries = 5000;
const _maxDepth = 8;

/// Reads the table of contents from an EPUB 3 navigation document at
/// [navPath]: the `nav` marked `epub:type="toc"` (or the first `nav`).
List<EpubTocItem> parseNavDocument(String source, {required String navPath}) {
  final document = _parse(source);
  if (document == null) return const [];
  final navs = _descendants(document, 'nav').toList();
  final toc =
      navs
          .where((nav) => (_attr(nav, 'type') ?? '').split(' ').contains('toc'))
          .firstOrNull ??
      navs.firstOrNull;
  final list = toc == null ? null : _descendants(toc, 'ol').firstOrNull;
  if (list == null) return const [];

  final items = <EpubTocItem>[];
  // Iterative depth-first walk: (list element, depth), in reverse order.
  final stack = <(XmlElement, int)>[];
  void pushItems(XmlElement ol, int depth) {
    final children = _children(ol, 'li').toList().reversed;
    for (final li in children) {
      stack.add((li, depth));
    }
  }

  pushItems(list, 0);
  while (stack.isNotEmpty && items.length < _maxEntries) {
    final (li, depth) = stack.removeLast();
    final label = li.childElements
        .where((e) => _local(e) == 'a' || _local(e) == 'span')
        .firstOrNull;
    final href = label == null ? null : _attr(label, 'href');
    final title = _text(label);
    if (href != null && title.isNotEmpty) {
      final item = _item(navPath, href, title, depth);
      if (item != null) items.add(item);
    }
    final nested = _children(li, 'ol').firstOrNull;
    if (nested != null && depth + 1 < _maxDepth) {
      // Entries without a target still contribute their children, one
      // level down, as headings would.
      pushItems(nested, href == null ? depth : depth + 1);
    }
  }
  return items;
}

/// Reads the table of contents from an EPUB 2 NCX file at [ncxPath].
List<EpubTocItem> parseNcx(String source, {required String ncxPath}) {
  final document = _parse(source);
  if (document == null) return const [];
  final navMap = _descendants(document, 'navMap').firstOrNull;
  if (navMap == null) return const [];

  final items = <EpubTocItem>[];
  final stack = <(XmlElement, int)>[
    for (final point in _children(navMap, 'navPoint').toList().reversed)
      (point, 0),
  ];
  while (stack.isNotEmpty && items.length < _maxEntries) {
    final (point, depth) = stack.removeLast();
    final label = _children(point, 'navLabel').firstOrNull;
    final title = _text(
      label == null ? null : _children(label, 'text').firstOrNull,
    );
    final src = _children(
      point,
      'content',
    ).map((c) => _attr(c, 'src')).firstOrNull;
    if (src != null && title.isNotEmpty) {
      final item = _item(ncxPath, src, title, depth);
      if (item != null) items.add(item);
    }
    if (depth + 1 < _maxDepth) {
      for (final child in _children(point, 'navPoint').toList().reversed) {
        stack.add((child, depth + 1));
      }
    }
  }
  return items;
}

EpubTocItem? _item(String basePath, String href, String title, int depth) {
  final target = href.trim();
  if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:').hasMatch(target)) return null;
  final hash = target.indexOf('#');
  final file = hash < 0 ? target : target.substring(0, hash);
  final fragment = hash < 0 ? null : target.substring(hash + 1);
  final path = file.isEmpty ? basePath : SafeZip.resolve(basePath, file);
  if (path.isEmpty) return null;
  String? decoded;
  if (fragment != null && fragment.isNotEmpty) {
    try {
      decoded = Uri.decodeComponent(fragment);
    } on ArgumentError {
      decoded = fragment;
    }
  }
  return EpubTocItem(title: title, path: path, fragment: decoded, depth: depth);
}

XmlDocument? _parse(String source) {
  try {
    return XmlDocument.parse(
      source,
      entityMapping: const XmlDefaultEntityMapping.html5(),
    );
  } on Object {
    return null;
  }
}

String _local(XmlElement element) => localName(element.name.qualified);

String? _attr(XmlElement element, String name) {
  for (final attribute in element.attributes) {
    if (localName(attribute.name.qualified) == name) return attribute.value;
  }
  return null;
}

Iterable<XmlElement> _descendants(XmlNode node, String name) => node.descendants
    .whereType<XmlElement>()
    .where((e) => _local(e) == name.toLowerCase());

Iterable<XmlElement> _children(XmlElement parent, String name) =>
    parent.childElements.where((e) => _local(e) == name.toLowerCase());

/// The element's text with whitespace collapsed.
String _text(XmlElement? element) => element == null
    ? ''
    : element.innerText.replaceAll(RegExp(r'\s+'), ' ').trim();
