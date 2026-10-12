import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/data/database/app_database.dart';
import 'package:lectern/features/library/data/library_repository.dart';
import 'package:lectern/features/reader/data/annotation_repository.dart';
import 'package:lectern/features/reader/domain/annotation.dart';
import 'package:lectern/features/reader/domain/annotation_export.dart';
import 'package:lectern/features/reader/domain/locator.dart';

import '../../helpers/test_database.dart';

void main() {
  group('AnnotationRange', () {
    final ranges = <AnnotationRange>[
      const TextRangeAnchor(start: TextLocator(10), end: TextLocator(42)),
      const TextRangeAnchor(
        start: EpubLocator(href: 'OEBPS/ch1.xhtml', offset: 5),
        end: EpubLocator(href: 'OEBPS/ch2.xhtml', offset: 9),
      ),
      const PdfAreaRange([
        PdfPageArea(pageIndex: 3, rects: [NormalizedRect(0.1, 0.9, 0.5, 0.85)]),
        PdfPageArea(
          pageIndex: 4,
          rects: [
            NormalizedRect(0.1, 0.2, 0.9, 0.15),
            NormalizedRect(0.1, 0.14, 0.4, 0.1),
          ],
        ),
      ]),
    ];
    for (final range in ranges) {
      test('round-trips $range', () {
        expect(AnnotationRange.decode(range.encode()), range);
      });
    }

    test('a PDF range starts at its highest rectangle on the first page', () {
      expect(ranges[2].start, const PdfLocator(3, pageOffset: 0.1));
    });

    test('rejects malformed or mixed data instead of throwing', () {
      for (final bad in [
        null,
        '',
        'nonsense',
        '{"k":"text"}',
        '{"k":"text","s":{"t":"txt","o":1},"e":{"t":"pdf","p":1}}',
        '{"k":"pdf","a":[]}',
        '{"k":"pdf","a":[{"p":-1,"r":[[0,1,1,0]]}]}',
        '{"k":"pdf","a":[{"p":1,"r":[[0,1,1]]}]}',
        '{"k":"pdf","a":[{"p":1,"r":[["a",1,1,0]]}]}',
        '{"k":"note"}',
      ]) {
        expect(AnnotationRange.decode(bad), isNull, reason: '$bad');
      }
    });

    test('out-of-range coordinates are clamped', () {
      final range =
          AnnotationRange.decode(
                '{"k":"pdf","a":[{"p":0,"r":[[-1,2,0.5,0.5]]}]}',
              )!
              as PdfAreaRange;
      expect(
        range.areas.single.rects.single,
        const NormalizedRect(0, 1, 0.5, 0.5),
      );
    });
  });

  group('AnnotationRepository', () {
    late AppDatabase db;
    late AnnotationRepository repository;
    late int documentId;

    setUp(() async {
      db = createTestDatabase();
      repository = AnnotationRepository(db);
      documentId = await addTestDocument(LibraryRepository(db));
    });

    tearDown(() => db.close());

    AnnotationDraft draft(int start, {String text = 'Some text'}) =>
        AnnotationDraft(
          range: TextRangeAnchor(
            start: TextLocator(start),
            end: TextLocator(start + 5),
          ),
          progress: start / 1000,
          text: text,
        );

    test('adds, lists in reading order, edits and deletes', () async {
      final later = await repository.addAnnotation(
        documentId: documentId,
        draft: draft(500),
        color: HighlightColor.blue,
      );
      final earlier = await repository.addAnnotation(
        documentId: documentId,
        draft: draft(100, text: '  Earlier  '),
        color: HighlightColor.yellow,
        note: '   ',
      );
      var list = await repository.watchAnnotations(documentId).first;
      expect(list.map((a) => a.id), [earlier, later]);
      expect(list.first.text, 'Earlier');
      expect(list.first.note, isNull, reason: 'blank notes are not kept');
      expect(list.last.color, HighlightColor.blue);

      await repository.updateNote(earlier, 'Remember this');
      await repository.updateColor(later, HighlightColor.pink);
      list = await repository.watchAnnotations(documentId).first;
      expect(list.first.note, 'Remember this');
      expect(list.first.hasNote, isTrue);
      expect(list.last.color, HighlightColor.pink);

      await repository.updateNote(earlier, null);
      await repository.deleteAnnotation(later);
      list = await repository.watchAnnotations(documentId).first;
      expect(list.single.note, isNull);
    });

    test('bounds stored text and skips unreadable rows', () async {
      await repository.addAnnotation(
        documentId: documentId,
        draft: draft(1, text: '😀' * 6000),
        color: HighlightColor.green,
      );
      await db
          .into(db.annotations)
          .insert(
            AnnotationsCompanion.insert(
              documentId: documentId,
              range: '{"k":"unknown"}',
              progress: 0.5,
              selectedText: 'x',
              color: 0,
              createdAt: DateTime(2026),
              updatedAt: DateTime(2026),
            ),
          );
      final list = await repository.watchAnnotations(documentId).first;
      final text = list.single.text;
      expect(
        text.length,
        lessThanOrEqualTo(AnnotationRepository.maxTextLength),
      );
      // Never cut inside a surrogate pair.
      expect(text.runes.every((r) => r == 0x1F600), isTrue);
    });

    test('removing the document removes its annotations', () async {
      await repository.addAnnotation(
        documentId: documentId,
        draft: draft(1),
        color: HighlightColor.yellow,
      );
      await LibraryRepository(db).removeDocuments([documentId]);
      expect(await db.select(db.annotations).get(), isEmpty);
    });
  });

  test('exports Markdown in reading order', () {
    Annotation annotation(int id, String text, {String? note}) => Annotation(
      id: id,
      documentId: 1,
      range: TextRangeAnchor(start: TextLocator(id), end: TextLocator(id + 1)),
      progress: id / 10,
      text: text,
      note: note,
      color: HighlightColor.yellow,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    final markdown = annotationsToMarkdown(
      title: 'A  Book',
      author: 'Ada',
      annotations: [
        annotation(1, 'First line\nsecond line'),
        annotation(2, 'Another', note: 'My thought'),
      ],
      location: (a) => '${a.id * 10}%',
      exportedAt: DateTime(2026, 10, 12),
    );
    expect(
      markdown,
      '# A Book\n'
      '\n*Ada*\n'
      '\n2 highlights, exported from Lectern on 2026-10-12.\n'
      '\n## 10%\n\n> First line\n> second line\n'
      '\n## 20%\n\n> Another\n'
      '\n**Note:** My thought\n',
    );
  });
}
