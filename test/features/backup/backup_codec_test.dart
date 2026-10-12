import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/features/backup/data/backup_codec.dart';
import 'package:lectern/features/backup/domain/reading_backup.dart';
import 'package:lectern/features/library/domain/reading_status.dart';
import 'package:lectern/features/reader/domain/annotation.dart';
import 'package:lectern/features/reader/domain/locator.dart';

final _hash = 'ab' * 32;
final _created = DateTime.utc(2026, 3, 1, 12);

ReadingBackup _sample() => ReadingBackup(
  createdAt: _created,
  settings: const {'app.theme': 'dark', 'reader.fontSize': '20.0'},
  collections: [
    BackupCollection(name: 'To read', createdAt: DateTime.utc(2026, 1, 2)),
  ],
  documents: [
    BackupDocument(
      contentHash: _hash,
      title: 'A Novel',
      status: ReadingStatus.reading,
      favorite: true,
      progress: 0.25,
      lastOpenedAt: DateTime.utc(2026, 2, 3, 4, 5, 6),
      position: BackupPosition(
        locator: const EpubLocator(href: 'ch1.xhtml', offset: 40),
        updatedAt: DateTime.utc(2026, 2, 3, 4, 5, 6),
      ),
      collections: const ['To read'],
      bookmarks: [
        BackupBookmark(
          locator: const EpubLocator(href: 'ch2.xhtml', offset: 3),
          progress: 0.5,
          excerpt: 'It was night',
          createdAt: DateTime.utc(2026, 2, 1),
        ),
      ],
      highlights: [
        BackupHighlight(
          range: const TextRangeAnchor(
            start: EpubLocator(href: 'ch1.xhtml', offset: 10),
            end: EpubLocator(href: 'ch1.xhtml', offset: 20),
          ),
          progress: 0.1,
          text: 'quoted text',
          note: 'A thought\nover two lines',
          color: HighlightColor.green,
          createdAt: DateTime.utc(2026, 2, 2),
          updatedAt: DateTime.utc(2026, 2, 2, 1),
        ),
        BackupHighlight(
          range: const PdfAreaRange([
            PdfPageArea(
              pageIndex: 2,
              rects: [NormalizedRect(0.1, 0.9, 0.5, 0.85)],
            ),
          ]),
          progress: 0.3,
          text: 'on a page',
          color: HighlightColor.pink,
          createdAt: DateTime.utc(2026, 2, 4),
          updatedAt: DateTime.utc(2026, 2, 4),
        ),
      ],
      sessions: [
        BackupSession(
          startedAt: DateTime.utc(2026, 2, 3, 4),
          endedAt: DateTime.utc(2026, 2, 3, 4, 30),
          startProgress: 0.2,
          endProgress: 0.25,
        ),
      ],
    ),
  ],
);

/// A minimal valid backup with [documents] (and other fields) replaced.
Uint8List _file(Map<String, Object?> fields) => utf8.encode(
  jsonEncode({
    'format': 'lectern-reading-data',
    'version': 1,
    'createdAt': '2026-03-01T12:00:00Z',
    'documents': <Object?>[],
    ...fields,
  }),
);

Map<String, Object?> _document([Map<String, Object?> fields = const {}]) => {
  'sha256': _hash,
  'title': 'A Novel',
  ...fields,
};

Matcher _problem(BackupProblem problem) => throwsA(
  isA<BackupFormatException>().having((e) => e.problem, 'problem', problem),
);

void main() {
  test('a backup survives encoding and decoding unchanged', () {
    final backup = _sample();
    expect(decodeBackup(encodeBackup(backup)), backup);
  });

  test('the file is plain, versioned JSON', () {
    final json = jsonDecode(
      utf8.decode(encodeBackup(_sample())),
    ) as Map<String, Object?>;
    expect(json['format'], 'lectern-reading-data');
    expect(json['version'], 1);
    expect(json['createdAt'], '2026-03-01T12:00:00.000Z');
    final document = (json['documents']! as List<Object?>).single! as Map;
    expect(document['sha256'], _hash);
    expect(document['status'], 'reading');
    expect(
      (document['highlights']! as List).first,
      containsPair('color', 'green'),
    );
  });

  test('a backup too large to restore is not written', () {
    final backup = _sample();
    final size = encodeBackup(backup).length;
    expect(encodeBackup(backup, maxBytes: size), hasLength(size));
    expect(
      () => encodeBackup(backup, maxBytes: size - 1),
      _problem(BackupProblem.tooLarge),
    );
  });

  group('rejects files that are not backups', () {
    test('not JSON or not UTF-8', () {
      expect(
        () => decodeBackup(Uint8List.fromList([0xFF, 0xFE, 0x00])),
        _problem(BackupProblem.notBackup),
      );
      expect(
        () => decodeBackup(utf8.encode('{"format": ')),
        _problem(BackupProblem.notBackup),
      );
    });

    test('other JSON', () {
      for (final json in [
        '[]',
        '"text"',
        '{"format": "something-else", "version": 1}',
      ]) {
        expect(
          () => decodeBackup(utf8.encode(json)),
          _problem(BackupProblem.notBackup),
          reason: json,
        );
      }
    });

    test('missing or malformed required parts', () {
      for (final fields in <Map<String, Object?>>[
        {'version': 0},
        {'version': '1'},
        {'createdAt': 'yesterday'},
        {'documents': null},
        {'documents': <String, Object?>{}},
        {'settings': <Object?>[]},
        {'collections': 'none'},
      ]) {
        expect(
          () => decodeBackup(_file(fields)),
          _problem(BackupProblem.notBackup),
          reason: '$fields',
        );
      }
    });

    test('a newer format version', () {
      expect(
        () => decodeBackup(_file({'version': 2})),
        _problem(BackupProblem.newerVersion),
      );
    });

    test('anything over the size limit, before parsing it', () {
      expect(
        () => decodeBackup(Uint8List(BackupLimits.maxFileBytes + 1)),
        _problem(BackupProblem.tooLarge),
      );
    });
  });

  test('a byte order mark and unknown fields are tolerated', () {
    final bytes = _file({
      'futureField': {'x': 1},
      'documents': [
        _document({'futureField': true}),
      ],
    });
    final backup = decodeBackup(
      Uint8List.fromList([0xEF, 0xBB, 0xBF, ...bytes]),
    );
    expect(backup.documents.single.contentHash, _hash);
    expect(backup.skippedEntries, 0);
  });

  test('invalid entries are skipped and counted, the rest kept', () {
    final backup = decodeBackup(
      _file({
        'settings': {'app.theme': 'dark', 'reader.font': 3, 'x': 'y' * 300},
        'collections': [
          {'name': 'To read'},
          {'name': 'to READ'},
          {'name': '   '},
          {'name': 'x' * 201},
          'Loose',
        ],
        'documents': [
          _document({
            'position': {
              'locator': {'t': 'epub', 'h': 'ch1.xhtml', 'o': -1},
              'updatedAt': '2026-01-01T00:00:00Z',
            },
            'bookmarks': [
              {
                'locator': {'t': 'txt', 'o': 5},
                'progress': 0.5,
                'createdAt': '2026-01-01T00:00:00Z',
              },
              {
                'locator': {'t': 'txt', 'o': 5},
                'progress': double.nan.toString(),
                'createdAt': '2026-01-01T00:00:00Z',
              },
              {'locator': 'not a locator'},
            ],
            'highlights': 'none',
            'sessions': [
              {
                'startedAt': '2026-01-01T10:00:00Z',
                'endedAt': '2026-01-01T09:00:00Z',
                'startProgress': 0,
                'endProgress': 1,
              },
            ],
            'collections': ['A', 'a', 7],
          }),
          // A second entry for the same book, and one without a valid hash.
          _document({'title': 'Again'}),
          {'sha256': 'not-a-hash', 'title': 'Bad'},
          42,
        ],
      }),
    );

    expect(backup.settings, {'app.theme': 'dark'});
    expect(backup.collections.map((c) => c.name), ['To read']);
    final document = backup.documents.single;
    expect(document.title, 'A Novel');
    expect(document.position, isNull);
    expect(document.bookmarks, hasLength(1));
    expect(document.highlights, isEmpty);
    expect(document.sessions, isEmpty);
    expect(document.collections, ['A']);
    // Settings 2, collections 4, position 1, bookmarks 2, highlights 1,
    // sessions 1, document collections 2, documents 3.
    expect(backup.skippedEntries, 16);
  });

  test('values are cleaned and bounded like text entered in the app', () {
    final backup = decodeBackup(
      _file({
        'documents': [
          _document({
            'sha256': _hash.toUpperCase(),
            'title': '  Spaced\u0000   out\ttitle ',
            'status': 'abandoned',
            'favorite': 'yes',
            'progress': 7,
            'highlights': [
              {
                'range': {
                  'k': 'text',
                  's': {'t': 'txt', 'o': 1},
                  'e': {'t': 'txt', 'o': 5},
                },
                'progress': -3,
                'text': '  ${'x' * 20000}',
                'note': '   ',
                'color': 'ultraviolet',
                'createdAt': '2026-01-01T10:00:00.999+02:00',
                'updatedAt': '2025-01-01T00:00:00Z',
              },
            ],
          }),
        ],
      }),
    );
    final document = backup.documents.single;
    expect(document.contentHash, _hash);
    expect(document.title, 'Spaced out title');
    expect(document.status, ReadingStatus.unread);
    expect(document.favorite, isFalse);
    expect(document.progress, 1);
    final highlight = document.highlights.single;
    expect(highlight.progress, 0);
    expect(highlight.text.length, lessThanOrEqualTo(10000));
    expect(highlight.note, isNull);
    expect(highlight.color, HighlightColor.yellow);
    // Converted to UTC and cut to whole seconds, as the database stores
    // them; an update before creation is taken as the creation time.
    expect(highlight.createdAt, DateTime.utc(2026, 1, 1, 8));
    expect(highlight.updatedAt, highlight.createdAt);
  });

  test('per-document lists are capped', () {
    final backup = decodeBackup(
      _file({
        'documents': [
          _document({
            'collections': [
              for (var i = 0; i <= BackupLimits.maxCollectionsPerDocument; i++)
                'C$i',
            ],
          }),
        ],
      }),
    );
    expect(
      backup.documents.single.collections,
      hasLength(BackupLimits.maxCollectionsPerDocument),
    );
    expect(backup.skippedEntries, 1);
  });
}
