import 'package:equatable/equatable.dart';

import 'document_format.dart';
import 'reading_status.dart';

/// A document as shown in library lists.
///
/// Large, rarely needed metadata (such as the description) is deliberately
/// not part of this model so that list queries stay small.
class LibraryDocument extends Equatable {
  const LibraryDocument({
    required this.id,
    required this.title,
    required this.format,
    required this.filePath,
    required this.originalFileName,
    required this.fileSize,
    required this.contentHash,
    required this.isFavorite,
    required this.status,
    required this.progress,
    required this.addedAt,
    this.author,
    this.pageCount,
    this.coverPath,
    this.lastOpenedAt,
  });

  final int id;
  final String title;
  final String? author;
  final DocumentFormat format;

  /// Path of the library copy, relative to the library directory.
  final String filePath;
  final String originalFileName;
  final int fileSize;
  final String contentHash;
  final int? pageCount;

  /// Path of the cached cover image, relative to the library directory.
  final String? coverPath;
  final bool isFavorite;
  final ReadingStatus status;

  /// Overall progress in `[0, 1]`.
  final double progress;
  final DateTime addedAt;
  final DateTime? lastOpenedAt;

  @override
  List<Object?> get props => [
    id,
    title,
    author,
    format,
    filePath,
    originalFileName,
    fileSize,
    contentHash,
    pageCount,
    coverPath,
    isFavorite,
    status,
    progress,
    addedAt,
    lastOpenedAt,
  ];
}

/// Data needed to register a new document in the library.
class NewDocument {
  const NewDocument({
    required this.title,
    required this.format,
    required this.filePath,
    required this.originalFileName,
    required this.fileSize,
    required this.contentHash,
    this.author,
    this.pageCount,
    this.coverPath,
    this.language,
    this.publisher,
    this.description,
  });

  final String title;
  final String? author;
  final DocumentFormat format;
  final String filePath;
  final String originalFileName;
  final int fileSize;
  final String contentHash;
  final int? pageCount;
  final String? coverPath;
  final String? language;
  final String? publisher;
  final String? description;
}
