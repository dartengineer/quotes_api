import 'package:equatable/equatable.dart';

import 'locator.dart';

/// One result of searching inside a document.
class SearchHit extends Equatable {
  const SearchHit({
    required this.locator,
    required this.progress,
    required this.snippet,
    required this.snippetMatchStart,
    required this.matchLength,
  });

  final Locator locator;
  final double progress;

  /// Text around the match, on one line.
  final String snippet;
  final int snippetMatchStart;
  final int matchLength;

  @override
  List<Object?> get props => [
    locator,
    progress,
    snippet,
    snippetMatchStart,
    matchLength,
  ];
}
