import 'dart:typed_data';

import '../../../core/files/safe_zip.dart';
import '../../../engines/epub/epub_package.dart';

/// Everything import needs from an EPUB. Plain data, so it can be returned
/// from a background isolate.
class EpubImportInfo {
  const EpubImportInfo({
    required this.metadata,
    required this.isFixedLayout,
    this.coverBytes,
  });

  final EpubMetadata metadata;
  final bool isFixedLayout;

  /// Encoded cover image (JPEG/PNG/...), if the book declares a usable one.
  final Uint8List? coverBytes;
}

/// Reads EPUB metadata and the cover image. Synchronous: run on a background
/// isolate. Throws [EpubException] for damaged or DRM-protected books.
EpubImportInfo readEpubImportInfo(String path) {
  final SafeZip zip;
  try {
    zip = SafeZip.open(path);
  } on Object {
    throw const EpubException(EpubProblem.damaged, 'not a readable zip');
  }
  try {
    final package = EpubPackageParser.parse(zip);
    Uint8List? cover;
    if (package.coverImage case final item?) {
      try {
        cover = EpubPackageParser.readItem(
          zip,
          item,
          EpubLimits.coverImageBytes,
        );
      } on Object {
        // A broken cover image should not block the import.
        cover = null;
      }
    }
    return EpubImportInfo(
      metadata: package.metadata,
      isFixedLayout: package.isFixedLayout,
      coverBytes: cover,
    );
  } finally {
    zip.close();
  }
}
