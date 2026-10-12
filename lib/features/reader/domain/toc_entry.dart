import 'package:equatable/equatable.dart';

import 'locator.dart';

/// One entry of a document's table of contents, flattened: [depth] is 0 for
/// top-level entries.
class TocEntry extends Equatable {
  const TocEntry({required this.title, required this.locator, this.depth = 0});

  final String title;
  final Locator locator;
  final int depth;

  @override
  List<Object?> get props => [title, locator, depth];
}
