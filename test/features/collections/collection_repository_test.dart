import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/data/database/app_database.dart';
import 'package:lectern/features/collections/data/collection_repository.dart';
import 'package:lectern/features/collections/domain/library_collection.dart';
import 'package:lectern/features/library/data/library_repository.dart';

import '../../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late LibraryRepository library;
  late CollectionRepository collections;

  setUp(() {
    db = createTestDatabase();
    final clock = FakeClock();
    library = LibraryRepository(db, clock: clock.call);
    collections = CollectionRepository(db, clock: clock.call);
  });

  tearDown(() => db.close());

  Matcher rejectsWith(CollectionNameProblem problem) => throwsA(
    isA<InvalidCollectionNameException>().having(
      (e) => e.problem,
      'problem',
      problem,
    ),
  );

  test('creates collections sorted by name with document counts', () async {
    final a = await addTestDocument(library, title: 'A');
    final b = await addTestDocument(library, title: 'B');
    final work = await collections.createCollection('work');
    await collections.createCollection('Archive');
    await collections.addDocuments(work, [a, b]);

    final list = await collections.watchCollections().first;
    expect(list.map((c) => c.name), ['Archive', 'work']);
    expect(list.map((c) => c.documentCount), [0, 2]);
  });

  test('trims and collapses whitespace in names', () async {
    final id = await collections.createCollection('  Summer   reading ');
    final list = await collections.watchCollections().first;
    expect(list.single.id, id);
    expect(list.single.name, 'Summer reading');
  });

  test('rejects empty, overlong and duplicate names', () async {
    await expectLater(
      () => collections.createCollection('   '),
      rejectsWith(CollectionNameProblem.empty),
    );
    await expectLater(
      () => collections.createCollection('x' * 201),
      rejectsWith(CollectionNameProblem.tooLong),
    );
    await collections.createCollection('Novels');
    await expectLater(
      () => collections.createCollection('NOVELS'),
      rejectsWith(CollectionNameProblem.duplicate),
    );
  });

  test('rename allows changing case of the same collection', () async {
    final id = await collections.createCollection('novels');
    final other = await collections.createCollection('Poetry');

    await collections.renameCollection(id, 'Novels');
    expect((await collections.watchCollections().first).first.name, 'Novels');

    await expectLater(
      () => collections.renameCollection(other, 'novels'),
      rejectsWith(CollectionNameProblem.duplicate),
    );
  });

  test('adding the same document twice is ignored', () async {
    final doc = await addTestDocument(library);
    final shelf = await collections.createCollection('Shelf');
    await collections.addDocuments(shelf, [doc, doc]);
    await collections.addDocuments(shelf, [doc]);
    expect(
      (await collections.watchCollections().first).single.documentCount,
      1,
    );
  });

  test('deleting a collection never deletes its documents', () async {
    final doc = await addTestDocument(library, title: 'Keep me');
    final shelf = await collections.createCollection('Shelf');
    await collections.addDocuments(shelf, [doc]);

    await collections.deleteCollection(shelf);

    expect(await collections.watchCollections().first, isEmpty);
    expect((await library.findById(doc))!.title, 'Keep me');
  });

  test('removing documents and tracking membership', () async {
    final a = await addTestDocument(library);
    final b = await addTestDocument(library);
    final one = await collections.createCollection('One');
    final two = await collections.createCollection('Two');
    await collections.addDocuments(one, [a, b]);
    await collections.addDocuments(two, [a]);

    expect(await collections.watchCollectionIdsFor(a).first, {one, two});

    await collections.removeDocuments(one, [a]);
    expect(await collections.watchCollectionIdsFor(a).first, {two});
    expect(await collections.watchCollectionIdsFor(b).first, {one});
  });
}
