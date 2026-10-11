import 'dart:typed_data';

import '../../../../engines/content/content_blocks.dart';
import '../../domain/locator.dart';
import '../../domain/search_hit.dart';
import '../../domain/toc_entry.dart';

export '../../../../engines/content/content_blocks.dart';

/// Where a link leads.
sealed class FlowLinkTarget {
  const FlowLinkTarget();
}

/// A place in the same document, as a global character offset.
final class InternalTarget extends FlowLinkTarget {
  const InternalTarget(this.offset);

  final int offset;
}

/// A web address (never opened by the app; see the link dialog).
final class ExternalTarget extends FlowLinkTarget {
  const ExternalTarget(this.url);

  final Uri url;
}

/// A reflowable document shown as a column of blocks (plain text, EPUB).
///
/// Every character has a global offset in `[0, length)`; blocks cover
/// consecutive ranges in order. The flow view lays out only the blocks near
/// the reading position, and measures positions as global offsets, which
/// this interface translates to and from the format's [Locator]s.
abstract interface class FlowDocument {
  int get length;
  int get blockCount;

  /// Global offset of the first character of block [index].
  int blockStart(int index);

  /// Global offset just after block [index].
  int blockEnd(int index);

  /// The block containing [offset] (the nearest one before a gap).
  int blockIndexAt(int offset);

  /// How block [index] is shown. Its runs are relative to the block.
  ContentBlock blockAt(int index);

  /// The text of block [index].
  String blockText(int index);

  /// Whether block [index] begins a chapter, which gets extra space above.
  bool startsSection(int index);

  double progressAt(int offset);
  int offsetAt(double progress);

  Locator locatorAt(int offset);

  /// The global offset of [locator], or null if it is not a position in
  /// this document.
  int? offsetOf(Locator locator);

  /// Short text starting at [offset], for bookmark excerpts.
  String? excerptAt(int offset);

  Future<List<SearchHit>> search(String query);

  List<TocEntry> get contents;

  /// Where the link covering [offsetInBlock] of block [index] leads.
  FlowLinkTarget? linkAt(int index, int offsetInBlock);

  /// The bytes of an image referenced by an image block.
  Future<Uint8List?> loadImage(String path);
}
