import 'package:equatable/equatable.dart';

import 'locator.dart';

/// A saved place in a document.
class Bookmark extends Equatable {
  const Bookmark({
    required this.id,
    required this.documentId,
    required this.locator,
    required this.progress,
    required this.createdAt,
    this.excerpt,
    this.label,
  });

  final int id;
  final int documentId;
  final Locator locator;

  /// Position in `[0, 1]`, for ordering and display.
  final double progress;

  /// A short piece of text at the bookmark, to recognise it in a list.
  final String? excerpt;
  final String? label;
  final DateTime createdAt;

  @override
  List<Object?> get props => [
    id,
    documentId,
    locator,
    progress,
    excerpt,
    label,
    createdAt,
  ];
}
