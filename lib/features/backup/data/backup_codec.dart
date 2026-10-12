import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import '../../../core/utils/text_cleanup.dart';
import '../../collections/data/collection_repository.dart';
import '../../library/domain/reading_status.dart';
import '../../reader/data/annotation_repository.dart';
import '../../reader/data/bookmark_repository.dart';
import '../../reader/domain/annotation.dart';
import '../../reader/domain/locator.dart';
import '../domain/reading_backup.dart';

/// Identifies backup files. Never change it; raise [backupVersion] instead
/// when the format changes incompatibly (fields may be added freely, as
/// readers ignore what they do not know).
const backupFormat = 'lectern-reading-data';
const backupVersion = 1;

/// Bounds on what a backup file may hold. A backup is untrusted input: it
/// could have been edited, damaged or made up.
abstract final class BackupLimits {
  static const maxFileBytes = 32 * 1024 * 1024;
  static const maxDocuments = 100000;
  static const maxCollections = 10000;
  static const maxSettings = 64;
  static const maxSettingLength = 256;
  static const maxTitleLength = 1024;
  static const maxLabelLength = 200;
  static const maxCollectionsPerDocument = 1000;
  static const maxBookmarksPerDocument = 10000;
  static const maxHighlightsPerDocument = 50000;
  static const maxSessionsPerDocument = 100000;
}

/// Encodes a backup as UTF-8 JSON on a background isolate.
Future<Uint8List> encodeBackupInBackground(ReadingBackup backup) =>
    Isolate.run(() => encodeBackup(backup));

/// Reads a backup file on a background isolate; see [decodeBackup].
Future<ReadingBackup> decodeBackupInBackground(Uint8List bytes) =>
    Isolate.run(() => decodeBackup(bytes));

/// Encodes [backup]. Throws [BackupFormatException] (too large) rather than
/// produce a file over [maxBytes], which could not be restored.
Uint8List encodeBackup(
  ReadingBackup backup, {
  int maxBytes = BackupLimits.maxFileBytes,
}) {
  final json = {
    'format': backupFormat,
    'version': backupVersion,
    'createdAt': _date(backup.createdAt),
    'settings': backup.settings,
    'collections': [
      for (final c in backup.collections)
        {'name': c.name, 'createdAt': _date(c.createdAt)},
    ],
    'documents': [for (final d in backup.documents) _document(d)],
  };
  // Compact: a heavily annotated library can run to tens of megabytes.
  final bytes = utf8.encode(jsonEncode(json));
  if (bytes.length > maxBytes) {
    throw const BackupFormatException(BackupProblem.tooLarge);
  }
  return bytes;
}

Map<String, Object?> _document(BackupDocument d) => {
  'sha256': d.contentHash,
  'title': d.title,
  'status': d.status.name,
  'favorite': d.favorite,
  'progress': d.progress,
  'lastOpenedAt': ?_dateOrNull(d.lastOpenedAt),
  if (d.position case final position?)
    'position': {
      'locator': position.locator.toJson(),
      'updatedAt': _date(position.updatedAt),
    },
  if (d.collections.isNotEmpty) 'collections': d.collections,
  if (d.bookmarks.isNotEmpty)
    'bookmarks': [
      for (final b in d.bookmarks)
        {
          'locator': b.locator.toJson(),
          'progress': b.progress,
          'label': ?b.label,
          'excerpt': ?b.excerpt,
          'createdAt': _date(b.createdAt),
        },
    ],
  if (d.highlights.isNotEmpty)
    'highlights': [
      for (final h in d.highlights)
        {
          'range': h.range.toJson(),
          'progress': h.progress,
          'text': h.text,
          'note': ?h.note,
          'color': h.color.name,
          'createdAt': _date(h.createdAt),
          'updatedAt': _date(h.updatedAt),
        },
    ],
  if (d.sessions.isNotEmpty)
    'sessions': [
      for (final s in d.sessions)
        {
          'startedAt': _date(s.startedAt),
          'endedAt': _date(s.endedAt),
          'startProgress': s.startProgress,
          'endProgress': s.endProgress,
        },
    ],
};

String _date(DateTime date) => date.toUtc().toIso8601String();
String? _dateOrNull(DateTime? date) => date == null ? null : _date(date);

/// Reads a backup file.
///
/// Throws [BackupFormatException] unless the file is a backup this version
/// understands. Within a valid backup, invalid entries are left out and
/// counted in [ReadingBackup.skippedEntries], so one damaged entry does not
/// cost the rest; text is bounded as it is when entered in the app.
ReadingBackup decodeBackup(Uint8List bytes) {
  if (bytes.length > BackupLimits.maxFileBytes) {
    throw const BackupFormatException(BackupProblem.tooLarge);
  }
  final Object? json;
  try {
    var text = utf8.decode(bytes);
    if (text.startsWith('﻿')) text = text.substring(1);
    json = jsonDecode(text);
  } on FormatException {
    throw const BackupFormatException(BackupProblem.notBackup);
  }
  if (json is! Map<String, Object?> || json['format'] != backupFormat) {
    throw const BackupFormatException(BackupProblem.notBackup);
  }
  final version = json['version'];
  if (version is! int || version < 1) {
    throw const BackupFormatException(BackupProblem.notBackup);
  }
  if (version > backupVersion) {
    throw const BackupFormatException(BackupProblem.newerVersion);
  }
  final createdAt = _parseDate(json['createdAt']);
  final documents = json['documents'];
  final settings = json['settings'] ?? const <String, Object?>{};
  final collections = json['collections'] ?? const <Object?>[];
  if (createdAt == null ||
      documents is! List<Object?> ||
      settings is! Map<String, Object?> ||
      collections is! List<Object?>) {
    throw const BackupFormatException(BackupProblem.notBackup);
  }
  return _BackupReader().read(
    createdAt: createdAt,
    settings: settings,
    collections: collections,
    documents: documents,
  );
}

class _BackupReader {
  var _skipped = 0;

  ReadingBackup read({
    required DateTime createdAt,
    required Map<String, Object?> settings,
    required List<Object?> collections,
    required List<Object?> documents,
  }) {
    final collectionNames = <String>{};
    final hashes = <String>{};
    return ReadingBackup(
      createdAt: createdAt,
      settings: _settings(settings),
      collections: _items(collections, BackupLimits.maxCollections, (item) {
        final collection = _collection(item);
        if (collection == null) return null;
        return collectionNames.add(collection.name.toLowerCase())
            ? collection
            : null;
      }),
      documents: _items(documents, BackupLimits.maxDocuments, (item) {
        final document = _document(item);
        // A book listed twice keeps its first entry.
        if (document == null || !hashes.add(document.contentHash)) return null;
        return document;
      }),
      skippedEntries: _skipped,
    );
  }

  /// Parses each of [items] with [parse], keeping at most [max]. Items
  /// beyond that, and those [parse] rejects, are counted as skipped.
  List<T> _items<T extends Object>(
    Iterable<Object?> items,
    int max,
    T? Function(Object? item) parse,
  ) {
    final result = <T>[];
    final length = items.length;
    if (length > max) _skipped += length - max;
    for (final item in items.take(max)) {
      final parsed = parse(item);
      if (parsed == null) {
        _skipped++;
      } else {
        result.add(parsed);
      }
    }
    return result;
  }

  /// The items of an optional list field, parsed like [_items]. A value
  /// that is not a list counts as one skipped entry.
  List<T> _optionalItems<T extends Object>(
    Object? value,
    int max,
    T? Function(Object? item) parse,
  ) {
    if (value == null) return const [];
    if (value is! List<Object?>) {
      _skipped++;
      return const [];
    }
    return _items(value, max, parse);
  }

  Map<String, String> _settings(Map<String, Object?> settings) {
    final result = <String, String>{};
    final entries = _items(
      settings.entries,
      BackupLimits.maxSettings,
      (item) => switch (item) {
        MapEntry(key: final String key, value: final String value)
            when key.length <= BackupLimits.maxSettingLength &&
                value.length <= BackupLimits.maxSettingLength =>
          MapEntry(key, value),
        _ => null,
      },
    );
    result.addEntries(entries);
    return result;
  }

  BackupCollection? _collection(Object? item) {
    if (item is! Map<String, Object?>) return null;
    final name = _collectionName(item['name']);
    if (name == null) return null;
    return BackupCollection(
      name: name,
      createdAt: _parseDate(item['createdAt']) ?? _epoch,
    );
  }

  BackupDocument? _document(Object? item) {
    if (item is! Map<String, Object?>) return null;
    final hash = item['sha256'];
    if (hash is! String || !_sha256.hasMatch(hash)) return null;
    final names = <String>{};
    return BackupDocument(
      contentHash: hash.toLowerCase(),
      title:
          cleanMetadataText(
            _string(item['title']),
            maxLength: BackupLimits.maxTitleLength,
          ) ??
          'Untitled',
      status: _status(item['status']),
      favorite: item['favorite'] == true,
      progress: _fraction(item['progress']) ?? 0,
      lastOpenedAt: _parseDate(item['lastOpenedAt']),
      position: switch (item['position']) {
        null => null,
        final value => _position(value) ?? _skipNull(),
      },
      collections: _optionalItems(
        item['collections'],
        BackupLimits.maxCollectionsPerDocument,
        (value) {
          final name = _collectionName(value);
          if (name == null || !names.add(name.toLowerCase())) return null;
          return name;
        },
      ),
      bookmarks: _optionalItems(
        item['bookmarks'],
        BackupLimits.maxBookmarksPerDocument,
        _bookmark,
      ),
      highlights: _optionalItems(
        item['highlights'],
        BackupLimits.maxHighlightsPerDocument,
        _highlight,
      ),
      sessions: _optionalItems(
        item['sessions'],
        BackupLimits.maxSessionsPerDocument,
        _session,
      ),
    );
  }

  /// Counts an invalid entry where a value is optional.
  Null _skipNull() {
    _skipped++;
    return null;
  }

  BackupPosition? _position(Object? item) {
    if (item is! Map<String, Object?>) return null;
    final locator = Locator.fromJson(item['locator']);
    final updatedAt = _parseDate(item['updatedAt']);
    if (locator == null || updatedAt == null) return null;
    return BackupPosition(locator: locator, updatedAt: updatedAt);
  }

  BackupBookmark? _bookmark(Object? item) {
    if (item is! Map<String, Object?>) return null;
    final locator = Locator.fromJson(item['locator']);
    final progress = _fraction(item['progress']);
    final createdAt = _parseDate(item['createdAt']);
    if (locator == null || progress == null || createdAt == null) return null;
    return BackupBookmark(
      locator: locator,
      progress: progress,
      createdAt: createdAt,
      label: cleanMetadataText(
        _string(item['label']),
        maxLength: BackupLimits.maxLabelLength,
      ),
      excerpt: cleanMetadataText(
        _string(item['excerpt']),
        maxLength: BookmarkRepository.maxExcerptLength,
      ),
    );
  }

  BackupHighlight? _highlight(Object? item) {
    if (item is! Map<String, Object?>) return null;
    final range = AnnotationRange.fromJson(item['range']);
    final progress = _fraction(item['progress']);
    final text = item['text'];
    final createdAt = _parseDate(item['createdAt']);
    if (range == null ||
        progress == null ||
        text is! String ||
        createdAt == null) {
      return null;
    }
    final note = _string(item['note'])?.trim();
    final updatedAt = _parseDate(item['updatedAt']);
    return BackupHighlight(
      range: range,
      progress: progress,
      text: truncateText(text.trim(), AnnotationRepository.maxTextLength),
      note: note == null || note.isEmpty
          ? null
          : truncateText(note, AnnotationRepository.maxNoteLength),
      color:
          HighlightColor.values.asNameMap()[item['color']] ??
          HighlightColor.yellow,
      createdAt: createdAt,
      updatedAt: updatedAt == null || updatedAt.isBefore(createdAt)
          ? createdAt
          : updatedAt,
    );
  }

  BackupSession? _session(Object? item) {
    if (item is! Map<String, Object?>) return null;
    final startedAt = _parseDate(item['startedAt']);
    final endedAt = _parseDate(item['endedAt']);
    final startProgress = _fraction(item['startProgress']);
    final endProgress = _fraction(item['endProgress']);
    if (startedAt == null ||
        endedAt == null ||
        endedAt.isBefore(startedAt) ||
        startProgress == null ||
        endProgress == null) {
      return null;
    }
    return BackupSession(
      startedAt: startedAt,
      endedAt: endedAt,
      startProgress: startProgress,
      endProgress: endProgress,
    );
  }
}

final _sha256 = RegExp(r'^[0-9a-fA-F]{64}$');
final _epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

String? _string(Object? value) => value is String ? value : null;

ReadingStatus _status(Object? value) =>
    ReadingStatus.values.asNameMap()[value] ?? ReadingStatus.unread;

/// A finite number clamped to `[0, 1]`.
double? _fraction(Object? value) {
  if (value is! num || !value.isFinite) return null;
  return value.toDouble().clamp(0.0, 1.0);
}

/// A collection name as the app would store it, or null if it could not be
/// one.
String? _collectionName(Object? value) {
  if (value is! String) return null;
  final name = cleanMetadataText(value, maxLength: value.length + 1);
  if (name == null || name.length > CollectionRepository.maxNameLength) {
    return null;
  }
  return name;
}

/// An ISO 8601 date in UTC, cut to whole seconds like the database's
/// timestamps, so dates read from a backup compare equal to those saved
/// from it.
DateTime? _parseDate(Object? value) {
  if (value is! String || value.length > 64) return null;
  final date = DateTime.tryParse(value);
  if (date == null) return null;
  final seconds = date.millisecondsSinceEpoch ~/ 1000;
  // Beyond what the database can store or the app could have written.
  if (seconds.abs() > 253402300799) return null;
  return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
}
