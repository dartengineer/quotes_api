import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../../core/files/safe_zip.dart';
import '../../core/utils/text_cleanup.dart';

/// Why an EPUB cannot be used.
enum EpubProblem {
  /// Required package files are missing or unreadable.
  damaged,

  /// Content is encrypted with DRM.
  drmProtected,
}

class EpubException implements Exception {
  const EpubException(this.problem, this.detail);

  final EpubProblem problem;

  /// Developer-facing detail; never contains book content.
  final String detail;

  @override
  String toString() => 'EpubException($problem: $detail)';
}

class EpubManifestItem {
  const EpubManifestItem({
    required this.id,
    required this.path,
    required this.mediaType,
    required this.properties,
  });

  final String id;

  /// Archive path, already resolved relative to the package document.
  final String path;
  final String mediaType;
  final Set<String> properties;

  bool get isImage => mediaType.startsWith('image/');
}

class EpubSpineItem {
  const EpubSpineItem({required this.item, required this.linear});

  final EpubManifestItem item;

  /// `false` for auxiliary content the publisher excluded from the main
  /// reading order (e.g. pop-up notes).
  final bool linear;
}

class EpubMetadata {
  const EpubMetadata({
    this.title,
    this.authors = const [],
    this.language,
    this.publisher,
    this.description,
  });

  final String? title;
  final List<String> authors;
  final String? language;
  final String? publisher;
  final String? description;
}

/// The parsed package document (OPF) of an EPUB 2 or 3 publication.
class EpubPackage {
  const EpubPackage({
    required this.packagePath,
    required this.version,
    required this.metadata,
    required this.manifest,
    required this.spine,
    required this.isFixedLayout,
    this.coverImage,
    this.navDocument,
    this.ncxDocument,
  });

  /// Archive path of the OPF file.
  final String packagePath;
  final String version;
  final EpubMetadata metadata;
  final Map<String, EpubManifestItem> manifest;
  final List<EpubSpineItem> spine;

  /// Publication uses fixed (pre-paginated) layout, e.g. comics.
  final bool isFixedLayout;
  final EpubManifestItem? coverImage;

  /// EPUB 3 navigation document (table of contents).
  final EpubManifestItem? navDocument;

  /// EPUB 2 NCX table of contents.
  final EpubManifestItem? ncxDocument;
}

/// Size limits for metadata files. Anything larger is treated as damaged
/// (or malicious) rather than read into memory.
abstract final class EpubLimits {
  static const containerBytes = 256 * 1024;
  static const packageBytes = 4 * 1024 * 1024;
  static const encryptionBytes = 1024 * 1024;
  static const smallXhtmlBytes = 1024 * 1024;
  static const coverImageBytes = 15 * 1024 * 1024;
}

/// Parses the package structure of an EPUB from an open [SafeZip].
abstract final class EpubPackageParser {
  static const _fontObfuscation = {
    'http://www.idpf.org/2008/embedding',
    'http://ns.adobe.com/pdf/enc#RC',
  };

  static EpubPackage parse(SafeZip zip) {
    _checkEncryption(zip);

    final packagePath = _findPackagePath(zip);
    final opf = _parseXml(
      zip,
      packagePath,
      maxBytes: EpubLimits.packageBytes,
      what: 'package document',
    );
    final root = opf.rootElement;
    final version = _attr(root, 'version') ?? '2.0';

    final metadataElement = _child(root, 'metadata');
    final manifest = _parseManifest(root, packagePath);
    final spine = _parseSpine(root, manifest);
    if (spine.isEmpty) {
      throw const EpubException(EpubProblem.damaged, 'empty spine');
    }

    final metas = metadataElement == null
        ? const <XmlElement>[]
        : _children(metadataElement, 'meta').toList();

    return EpubPackage(
      packagePath: packagePath,
      version: version,
      metadata: _parseMetadata(metadataElement, metas),
      manifest: manifest,
      spine: spine,
      isFixedLayout: _isFixedLayout(zip, metas),
      coverImage: _findCover(zip, packagePath, root, manifest, metas, spine),
      navDocument: manifest.values
          .where((i) => i.properties.contains('nav'))
          .firstOrNull,
      ncxDocument: _findNcx(root, manifest),
    );
  }

  /// Reads the bytes of [item], or null if missing or too large.
  static Uint8List? readItem(SafeZip zip, EpubManifestItem item, int maxBytes) {
    try {
      return zip.readPath(item.path, maxBytes: maxBytes);
    } on ZipEntryTooLargeException {
      return null;
    }
  }

  // --- Container & security -------------------------------------------

  static String _findPackagePath(SafeZip zip) {
    XmlDocument? container;
    try {
      container = _parseXml(
        zip,
        'META-INF/container.xml',
        maxBytes: EpubLimits.containerBytes,
        what: 'container',
      );
    } on EpubException {
      container = null;
    }
    final rootfiles = container == null
        ? const <XmlElement>[]
        : _descendants(container, 'rootfile');
    for (final rootfile in rootfiles) {
      final mediaType = _attr(rootfile, 'media-type');
      final fullPath = _attr(rootfile, 'full-path')?.trim();
      if (fullPath == null || fullPath.isEmpty) continue;
      if (mediaType != null && mediaType != 'application/oebps-package+xml') {
        continue;
      }
      final resolved = SafeZip.resolve('', fullPath);
      if (zip.contains(resolved)) return resolved;
    }
    // Some broken books lack a container or point it at a missing file;
    // fall back to the only OPF in the archive.
    final opfs = zip.fileNames
        .where((n) => n.toLowerCase().endsWith('.opf'))
        .toList();
    if (opfs.length == 1) return opfs.single;
    throw const EpubException(EpubProblem.damaged, 'no package document');
  }

  static void _checkEncryption(SafeZip zip) {
    final Uint8List? bytes;
    try {
      bytes = zip.readPath(
        'META-INF/encryption.xml',
        maxBytes: EpubLimits.encryptionBytes,
      );
    } on Object {
      throw const EpubException(EpubProblem.drmProtected, 'encryption.xml');
    }
    if (bytes == null) return;

    final XmlDocument document;
    try {
      document = XmlDocument.parse(_decodeXml(bytes));
    } on Object {
      // An unreadable encryption declaration cannot be trusted to only cover
      // fonts.
      throw const EpubException(EpubProblem.drmProtected, 'encryption.xml');
    }
    for (final method in _descendants(document, 'EncryptionMethod')) {
      final algorithm = _attr(method, 'Algorithm');
      if (!_fontObfuscation.contains(algorithm)) {
        throw const EpubException(EpubProblem.drmProtected, 'encrypted');
      }
    }
  }

  // --- Package document ------------------------------------------------

  static Map<String, EpubManifestItem> _parseManifest(
    XmlElement root,
    String packagePath,
  ) {
    final manifest = <String, EpubManifestItem>{};
    final element = _child(root, 'manifest');
    if (element == null) return manifest;
    for (final item in _children(element, 'item')) {
      final id = _attr(item, 'id');
      final href = _attr(item, 'href');
      if (id == null || href == null || href.isEmpty) continue;
      final path = SafeZip.resolve(packagePath, href);
      if (path.isEmpty) continue;
      manifest[id] = EpubManifestItem(
        id: id,
        path: path,
        mediaType: (_attr(item, 'media-type') ?? '').trim().toLowerCase(),
        properties: (_attr(item, 'properties') ?? '')
            .split(RegExp(r'\s+'))
            .where((s) => s.isNotEmpty)
            .toSet(),
      );
    }
    return manifest;
  }

  static List<EpubSpineItem> _parseSpine(
    XmlElement root,
    Map<String, EpubManifestItem> manifest,
  ) {
    final element = _child(root, 'spine');
    if (element == null) return const [];
    return [
      for (final itemref in _children(element, 'itemref'))
        if (manifest[_attr(itemref, 'idref')] case final item?)
          EpubSpineItem(item: item, linear: _attr(itemref, 'linear') != 'no'),
    ];
  }

  static EpubManifestItem? _findNcx(
    XmlElement root,
    Map<String, EpubManifestItem> manifest,
  ) {
    final spine = _child(root, 'spine');
    final tocId = spine == null ? null : _attr(spine, 'toc');
    if (tocId != null && manifest[tocId] != null) return manifest[tocId];
    return manifest.values
        .where((i) => i.mediaType == 'application/x-dtbncx+xml')
        .firstOrNull;
  }

  static EpubMetadata _parseMetadata(
    XmlElement? metadata,
    List<XmlElement> metas,
  ) {
    if (metadata == null) return const EpubMetadata();

    // EPUB 3 attaches extra information with <meta refines="#id">.
    final refinements = <String, Map<String, String>>{};
    for (final meta in metas) {
      final refines = _attr(meta, 'refines');
      final property = _attr(meta, 'property');
      if (refines == null || property == null) continue;
      final id = refines.startsWith('#') ? refines.substring(1) : refines;
      (refinements[id] ??= {})[property] = meta.innerText.trim();
    }

    final titles = _children(metadata, 'title').toList();
    final mainTitle =
        titles
            .where((t) => refinements[_attr(t, 'id')]?['title-type'] == 'main')
            .firstOrNull ??
        titles.firstOrNull;

    final creators = _children(metadata, 'creator')
        .map((creator) {
          final role =
              _attr(creator, 'role') ??
              refinements[_attr(creator, 'id')]?['role'];
          return (name: cleanMetadataText(creator.innerText), role: role);
        })
        .where((c) => c.name != null);
    final authors = [
      for (final c in creators)
        if (c.role == null || c.role == 'aut') c.name!,
    ];
    final people = authors.isNotEmpty
        ? authors
        : [for (final c in creators) c.name!];

    return EpubMetadata(
      title: cleanMetadataText(mainTitle?.innerText, maxLength: 1024),
      authors: people.toSet().toList(),
      language: cleanMetadataText(
        _children(metadata, 'language').firstOrNull?.innerText,
        maxLength: 35,
      ),
      publisher: cleanMetadataText(
        _children(metadata, 'publisher').firstOrNull?.innerText,
      ),
      description: plainTextFromHtml(
        _children(metadata, 'description').firstOrNull?.innerText,
      ),
    );
  }

  static bool _isFixedLayout(SafeZip zip, List<XmlElement> metas) {
    for (final meta in metas) {
      if (_attr(meta, 'refines') != null) continue;
      if (_attr(meta, 'property') == 'rendition:layout' &&
          meta.innerText.trim() == 'pre-paginated') {
        return true;
      }
      // Kindle-style hint used by some converters.
      if (_attr(meta, 'name') == 'fixed-layout' &&
          _attr(meta, 'content')?.toLowerCase() == 'true') {
        return true;
      }
    }
    // Apple Books display options.
    try {
      final bytes = zip.readPath(
        'META-INF/com.apple.ibooks.display-options.xml',
        maxBytes: 64 * 1024,
      );
      if (bytes != null) {
        final document = XmlDocument.parse(_decodeXml(bytes));
        for (final option in _descendants(document, 'option')) {
          if (_attr(option, 'name') == 'fixed-layout' &&
              option.innerText.trim().toLowerCase() == 'true') {
            return true;
          }
        }
      }
    } on Object {
      // Optional vendor file; ignore if unreadable.
    }
    return false;
  }

  // --- Cover -------------------------------------------------------------

  static const _decodableImages = {
    'image/jpeg',
    'image/jpg',
    'image/png',
    'image/gif',
    'image/webp',
  };

  static EpubManifestItem? _findCover(
    SafeZip zip,
    String packagePath,
    XmlElement root,
    Map<String, EpubManifestItem> manifest,
    List<XmlElement> metas,
    List<EpubSpineItem> spine,
  ) {
    bool usable(EpubManifestItem? item) =>
        item != null &&
        _decodableImages.contains(item.mediaType) &&
        zip.contains(item.path);

    // 1. EPUB 3: properties="cover-image".
    final declared = manifest.values
        .where((i) => i.properties.contains('cover-image'))
        .firstOrNull;
    if (usable(declared)) return declared;

    // 2. EPUB 2: <meta name="cover" content="item-id">. Some tools put the
    //    href in `content` instead of the id.
    for (final meta in metas) {
      if (_attr(meta, 'name') != 'cover') continue;
      final content = _attr(meta, 'content');
      if (content == null) continue;
      final byId = manifest[content];
      if (usable(byId)) return byId;
      final byHref = manifest.values
          .where((i) => i.path.endsWith(content))
          .firstOrNull;
      if (usable(byHref)) return byHref;
    }

    // 3. An image whose id or file name says "cover".
    final named = manifest.values
        .where(
          (i) =>
              _decodableImages.contains(i.mediaType) &&
              (i.id.toLowerCase().contains('cover') ||
                  i.path.toLowerCase().split('/').last.contains('cover')),
        )
        .where(usable)
        .firstOrNull;
    if (named != null) return named;

    // 4. A cover page (guide reference or first spine item) that shows an
    //    image.
    final coverPages = <EpubManifestItem>[];
    final guide = _child(root, 'guide');
    if (guide != null) {
      for (final reference in _children(guide, 'reference')) {
        final type = _attr(reference, 'type')?.toLowerCase();
        final href = _attr(reference, 'href');
        if (href == null || (type != 'cover' && type != 'title-page')) continue;
        // Guide hrefs are relative to the package document, like manifest
        // hrefs.
        final path = SafeZip.resolve(packagePath, href).toLowerCase();
        final target = manifest.values
            .where((i) => i.path.toLowerCase() == path)
            .firstOrNull;
        if (target != null) coverPages.add(target);
      }
    }
    if (spine.isNotEmpty) coverPages.add(spine.first.item);

    for (final page in coverPages) {
      final image = _imageInPage(zip, page, manifest);
      if (usable(image)) return image;
    }
    return null;
  }

  static final _imageReference = RegExp(
    r'''(?:src|xlink:href|href)\s*=\s*["']([^"']+\.(?:jpe?g|png|gif|webp))["']''',
    caseSensitive: false,
  );

  static EpubManifestItem? _imageInPage(
    SafeZip zip,
    EpubManifestItem page,
    Map<String, EpubManifestItem> manifest,
  ) {
    if (!page.mediaType.contains('html')) return null;
    final Uint8List? bytes;
    try {
      bytes = readItem(zip, page, EpubLimits.smallXhtmlBytes);
    } on Object {
      // Optional lookup: a damaged cover page just means no cover.
      return null;
    }
    if (bytes == null) return null;
    // A regular expression is enough here and tolerates malformed markup;
    // the page is never rendered or executed.
    final match = _imageReference.firstMatch(_decodeXml(bytes));
    if (match == null) return null;
    final path = SafeZip.resolve(page.path, match[1]!);
    return manifest.values
            .where((i) => i.path.toLowerCase() == path.toLowerCase())
            .firstOrNull ??
        (zip.contains(path)
            ? EpubManifestItem(
                id: '',
                path: path,
                mediaType: _mediaTypeFromName(path),
                properties: const {},
              )
            : null);
  }

  static String _mediaTypeFromName(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    return 'image/jpeg';
  }

  // --- XML helpers -------------------------------------------------------

  static XmlDocument _parseXml(
    SafeZip zip,
    String path, {
    required int maxBytes,
    required String what,
  }) {
    final Uint8List? bytes;
    try {
      bytes = zip.readPath(path, maxBytes: maxBytes);
    } on ZipEntryTooLargeException {
      throw EpubException(EpubProblem.damaged, '$what too large');
    } on Object {
      throw EpubException(EpubProblem.damaged, '$what unreadable');
    }
    if (bytes == null) {
      throw EpubException(EpubProblem.damaged, '$what missing');
    }
    try {
      // HTML5 entity names are accepted because sloppy EPUBs use &nbsp; and
      // friends in XML files. Only the fixed, finite HTML entity table is
      // expanded; DTD-defined entities and external references never are.
      return XmlDocument.parse(
        _decodeXml(bytes),
        entityMapping: const XmlDefaultEntityMapping.html5(),
      );
    } on Object {
      throw EpubException(EpubProblem.damaged, '$what is not valid XML');
    }
  }

  /// Decodes XML bytes honouring a byte-order mark or a declared single-byte
  /// encoding; defaults to UTF-8.
  static String _decodeXml(Uint8List bytes) {
    if (bytes.length >= 2) {
      if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
        return _decodeUtf16(bytes.sublist(2), littleEndian: true);
      }
      if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
        return _decodeUtf16(bytes.sublist(2), littleEndian: false);
      }
    }
    final start =
        bytes.length >= 3 &&
            bytes[0] == 0xEF &&
            bytes[1] == 0xBB &&
            bytes[2] == 0xBF
        ? 3
        : 0;
    final body = bytes.sublist(start);
    final declaration = latin1
        .decode(body.sublist(0, body.length < 200 ? body.length : 200))
        .toLowerCase();
    final encoding = RegExp(r'''encoding\s*=\s*["']([^"']+)["']''')
        .firstMatch(declaration)?[1];
    if (encoding == 'iso-8859-1' ||
        encoding == 'latin1' ||
        encoding == 'windows-1252') {
      return latin1.decode(body);
    }
    return utf8.decode(body, allowMalformed: true);
  }

  static String _decodeUtf16(Uint8List bytes, {required bool littleEndian}) {
    final units = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      units.add(
        littleEndian
            ? bytes[i] | (bytes[i + 1] << 8)
            : (bytes[i] << 8) | bytes[i + 1],
      );
    }
    return String.fromCharCodes(units);
  }

  /// Attribute by local name, ignoring namespace prefixes.
  static String? _attr(XmlElement element, String localName) {
    for (final attribute in element.attributes) {
      if (attribute.name.local == localName) return attribute.value;
    }
    return null;
  }

  /// Descendant elements by local name. `findAllElements` compares
  /// qualified names, so it would miss prefixed elements such as
  /// `<enc:EncryptionMethod>`.
  static Iterable<XmlElement> _descendants(XmlNode node, String localName) =>
      node.descendants.whereType<XmlElement>().where(
        (e) => e.name.local == localName,
      );

  static XmlElement? _child(XmlElement parent, String localName) =>
      _children(parent, localName).firstOrNull;

  static Iterable<XmlElement> _children(XmlElement parent, String localName) =>
      parent.childElements.where((e) => e.name.local == localName);
}
