import 'package:equatable/equatable.dart';

import '../../library/domain/reading_status.dart';
import '../../reader/domain/annotation.dart';
import '../../reader/domain/locator.dart';

/// The user's reading data, as saved to a backup file: progress,
/// bookmarks, highlights and notes, reading history, collections and
/// settings. Books themselves are never included. Each book's data is
/// keyed by the SHA-256 of its file, so it finds the book again after a
/// reinstall or on another device, whatever the file is called.
///
/// All dates are UTC, in whole seconds (the precision the database keeps).
class ReadingBackup extends Equatable {
  const ReadingBackup({
    required this.createdAt,
    this.settings = const {},
    this.collections = const [],
    this.documents = const [],
    this.skippedEntries = 0,
  });

  final DateTime createdAt;

  /// Stored preference values, by key.
  final Map<String, String> settings;
  final List<BackupCollection> collections;
  final List<BackupDocument> documents;

  /// Entries left out when reading the file because they were invalid.
  final int skippedEntries;

  @override
  List<Object?> get props => [
    createdAt,
    settings,
    collections,
    documents,
    skippedEntries,
  ];
}

class BackupCollection extends Equatable {
  const BackupCollection({required this.name, required this.createdAt});

  final String name;
  final DateTime createdAt;

  @override
  List<Object?> get props => [name, createdAt];
}

/// One book's reading data.
class BackupDocument extends Equatable {
  const BackupDocument({
    required this.contentHash,
    required this.title,
    this.status = ReadingStatus.unread,
    this.favorite = false,
    this.progress = 0,
    this.lastOpenedAt,
    this.position,
    this.collections = const [],
    this.bookmarks = const [],
    this.highlights = const [],
    this.sessions = const [],
  });

  /// Lower-case hex SHA-256 of the book's file.
  final String contentHash;

  /// Only used to tell the user which books are missing.
  final String title;
  final ReadingStatus status;
  final bool favorite;
  final double progress;
  final DateTime? lastOpenedAt;
  final BackupPosition? position;

  /// Names of the collections the book belongs to.
  final List<String> collections;
  final List<BackupBookmark> bookmarks;
  final List<BackupHighlight> highlights;
  final List<BackupSession> sessions;

  @override
  List<Object?> get props => [
    contentHash,
    title,
    status,
    favorite,
    progress,
    lastOpenedAt,
    position,
    collections,
    bookmarks,
    highlights,
    sessions,
  ];
}

class BackupPosition extends Equatable {
  const BackupPosition({required this.locator, required this.updatedAt});

  final Locator locator;
  final DateTime updatedAt;

  @override
  List<Object?> get props => [locator, updatedAt];
}

class BackupBookmark extends Equatable {
  const BackupBookmark({
    required this.locator,
    required this.progress,
    required this.createdAt,
    this.label,
    this.excerpt,
  });

  final Locator locator;
  final double progress;
  final String? label;
  final String? excerpt;
  final DateTime createdAt;

  @override
  List<Object?> get props => [locator, progress, label, excerpt, createdAt];
}

class BackupHighlight extends Equatable {
  const BackupHighlight({
    required this.range,
    required this.progress,
    required this.text,
    required this.color,
    required this.createdAt,
    required this.updatedAt,
    this.note,
  });

  final AnnotationRange range;
  final double progress;
  final String text;
  final String? note;
  final HighlightColor color;
  final DateTime createdAt;
  final DateTime updatedAt;

  @override
  List<Object?> get props => [
    range,
    progress,
    text,
    note,
    color,
    createdAt,
    updatedAt,
  ];
}

class BackupSession extends Equatable {
  const BackupSession({
    required this.startedAt,
    required this.endedAt,
    required this.startProgress,
    required this.endProgress,
  });

  final DateTime startedAt;
  final DateTime endedAt;
  final double startProgress;
  final double endProgress;

  @override
  List<Object?> get props => [startedAt, endedAt, startProgress, endProgress];
}

/// Why a file could not be read as a backup.
enum BackupProblem {
  /// Not JSON, not a Lectern backup, or missing required parts.
  notBackup,

  /// Written by a newer version of the app, in a format this one does not
  /// know.
  newerVersion,

  /// Bigger than any real backup could be.
  tooLarge,
}

class BackupFormatException implements Exception {
  const BackupFormatException(this.problem);

  final BackupProblem problem;

  @override
  String toString() => 'BackupFormatException(${problem.name})';
}

/// What restoring a backup changed.
class RestoreReport extends Equatable {
  const RestoreReport({
    this.matchedBooks = 0,
    this.updatedBooks = 0,
    this.missingTitles = const [],
    this.positionsRestored = 0,
    this.bookmarksAdded = 0,
    this.highlightsAdded = 0,
    this.highlightsUpdated = 0,
    this.sessionsAdded = 0,
    this.collectionsCreated = 0,
    this.collectionEntriesAdded = 0,
    this.settingsRestored = false,
    this.skippedEntries = 0,
  });

  /// Books in the backup that are in the library.
  final int matchedBooks;

  /// Matched books whose data changed.
  final int updatedBooks;

  /// Titles of books in the backup that are not in the library.
  final List<String> missingTitles;
  final int positionsRestored;
  final int bookmarksAdded;
  final int highlightsAdded;

  /// Existing highlights whose note or colour the backup had newer.
  final int highlightsUpdated;
  final int sessionsAdded;
  final int collectionsCreated;

  /// Books added to collections.
  final int collectionEntriesAdded;
  final bool settingsRestored;

  /// Entries left out because they were invalid, in the file or for the
  /// book they belonged to.
  final int skippedEntries;

  bool get changedAnything =>
      updatedBooks > 0 || collectionsCreated > 0 || settingsRestored;

  @override
  List<Object?> get props => [
    matchedBooks,
    updatedBooks,
    missingTitles,
    positionsRestored,
    bookmarksAdded,
    highlightsAdded,
    highlightsUpdated,
    sessionsAdded,
    collectionsCreated,
    collectionEntriesAdded,
    settingsRestored,
    skippedEntries,
  ];
}
