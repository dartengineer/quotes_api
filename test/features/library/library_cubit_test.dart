import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/app/dependencies.dart';
import 'package:lectern/core/utils/load_status.dart';
import 'package:lectern/features/library/domain/library_filter.dart';
import 'package:lectern/features/library/domain/library_layout.dart';
import 'package:lectern/features/library/domain/library_query.dart';
import 'package:lectern/features/library/domain/reading_status.dart';
import 'package:lectern/features/library/presentation/library_cubit.dart';

import '../../helpers/test_database.dart';
import '../../helpers/test_dependencies.dart';

void main() {
  late AppDependencies deps;

  setUp(() async {
    deps = await createTestDependencies();
  });

  tearDown(() => disposeTestDependencies(deps));

  LibraryCubit createCubit({int? collectionId}) => LibraryCubit(
    library: deps.library,
    settings: deps.settings,
    manager: deps.manager,
    collections: deps.collections,
    collectionId: collectionId,
    searchDebounce: const Duration(milliseconds: 10),
  );

  /// Resolves with the first state (current or future) matching [test].
  Future<LibraryState> until(
    LibraryCubit cubit,
    bool Function(LibraryState state) test,
  ) {
    if (test(cubit.state)) return Future.value(cubit.state);
    return cubit.stream.firstWhere(test).timeout(const Duration(seconds: 5));
  }

  Future<LibraryCubit> readyCubit({int? collectionId}) async {
    final cubit = createCubit(collectionId: collectionId);
    addTearDown(cubit.close);
    await until(cubit, (s) => s.status == LoadStatus.ready);
    return cubit;
  }

  List<String> titlesOf(LibraryState state) =>
      state.documents.map((d) => d.title).toList();

  group('view preferences', () {
    test('starts from stored layout and sort', () async {
      await deps.settings.setLibraryLayout(LibraryLayout.list);
      await deps.settings.setLibrarySort(LibrarySort.title);

      final cubit = await readyCubit();
      expect(cubit.state.layout, LibraryLayout.list);
      expect(cubit.state.query.sort, LibrarySort.title);
    });

    test('changing sort re-queries and persists the choice', () async {
      await addTestDocument(deps.library, title: 'a');
      await addTestDocument(deps.library, title: 'b');
      final cubit = await readyCubit();
      expect(titlesOf(cubit.state), ['b', 'a']);

      await cubit.setSort(LibrarySort.title);
      final sorted = await until(cubit, (s) => titlesOf(s).first == 'a');
      expect(titlesOf(sorted), ['a', 'b']);
      expect((await deps.settings.load()).librarySort, LibrarySort.title);
    });

    test('changing layout persists the choice', () async {
      final cubit = await readyCubit();
      await cubit.setLayout(LibraryLayout.list);
      expect(cubit.state.layout, LibraryLayout.list);
      expect((await deps.settings.load()).libraryLayout, LibraryLayout.list);
    });

    test('a choice made before preferences load is not overwritten', () async {
      await deps.settings.setLibrarySort(LibrarySort.title);
      final cubit = createCubit();
      addTearDown(cubit.close);
      final pending = cubit.setSort(LibrarySort.author);
      await until(cubit, (s) => s.status == LoadStatus.ready);
      await pending;
      await pumpEventQueue();
      expect(cubit.state.query.sort, LibrarySort.author);
    });
  });

  group('search and filters', () {
    setUp(() async {
      final a = await addTestDocument(deps.library, title: 'Alpha');
      await addTestDocument(deps.library, title: 'Beta');
      await deps.library.setFavorite([a], favorite: true);
    });

    test('search narrows after the debounce', () async {
      final cubit = await readyCubit();
      cubit.setSearch('alp');
      expect(cubit.state.query.search, 'alp');
      final narrowed = await until(cubit, (s) => s.documents.length == 1);
      expect(titlesOf(narrowed), ['Alpha']);
      expect(narrowed.isNarrowed, isTrue);
    });

    test('filters apply immediately and can be cleared', () async {
      final cubit = await readyCubit();
      cubit.setFilter(LibraryFilter.favorites);
      expect(cubit.state.filter, LibraryFilter.favorites);
      final favorites = await until(cubit, (s) => s.documents.length == 1);
      expect(titlesOf(favorites), ['Alpha']);

      cubit.clearNarrowing();
      expect(cubit.state.filter, LibraryFilter.all);
      await until(cubit, (s) => s.documents.length == 2);
    });

    test('filter mapping round-trips', () {
      for (final filter in LibraryFilter.values) {
        expect(LibraryFilter.of(filter.applyTo(const LibraryQuery())), filter);
      }
    });
  });

  group('selection', () {
    late int a;
    late int b;

    setUp(() async {
      a = await addTestDocument(deps.library, title: 'A');
      b = await addTestDocument(deps.library, title: 'B');
    });

    test('toggle, select all and clear', () async {
      final cubit = await readyCubit();
      cubit.toggleSelected(a);
      expect(cubit.state.selectedIds, {a});
      expect(cubit.state.isSelecting, isTrue);
      cubit.selectAll();
      expect(cubit.state.selectedIds, {a, b});
      cubit.toggleSelected(a);
      expect(cubit.state.selectedIds, {b});
      cubit.clearSelection();
      expect(cubit.state.isSelecting, isFalse);
    });

    test('favourite sets all, then clears when all are set', () async {
      final cubit = await readyCubit();
      cubit.selectAll();
      await cubit.toggleFavoriteForSelection();
      await until(cubit, (s) => s.documents.every((d) => d.isFavorite));
      await cubit.toggleFavoriteForSelection();
      await until(cubit, (s) => s.documents.every((d) => !d.isFavorite));
    });

    test('status and collection actions apply to the selection', () async {
      final cubit = await readyCubit();
      final shelf = await deps.collections.createCollection('Shelf');

      cubit.toggleSelected(a);
      await cubit.setStatusForSelection(ReadingStatus.finished);
      expect(cubit.state.isSelecting, isFalse);
      expect((await deps.library.findById(a))!.status, ReadingStatus.finished);

      cubit.toggleSelected(b);
      await cubit.addSelectionToCollection(shelf);
      expect(await deps.collections.watchCollectionIdsFor(b).first, {shelf});
    });

    test('removing deletes rows and library files', () async {
      final cubit = await readyCubit();
      final doc = (await deps.library.findById(a))!;
      final file = deps.storage.resolve(doc.filePath)
        ..createSync(recursive: true)
        ..writeAsStringSync('copy');

      cubit.toggleSelected(a);
      expect(await cubit.removeSelectionFromLibrary(), 1);
      expect(cubit.state.isSelecting, isFalse);
      expect(await deps.library.findById(a), isNull);
      expect(file.existsSync(), isFalse);
      await until(cubit, (s) => s.documents.length == 1);
    });

    test('selections of documents that disappear are dropped', () async {
      final cubit = await readyCubit();
      cubit.selectAll();
      await deps.library.removeDocuments([a]);
      final state = await until(cubit, (s) => s.documents.length == 1);
      expect(state.selectedIds, {b});
    });
  });

  group('collection view', () {
    test('shows only members and follows rename and delete', () async {
      final a = await addTestDocument(deps.library, title: 'In');
      await addTestDocument(deps.library, title: 'Out');
      final shelf = await deps.collections.createCollection('Shelf');
      await deps.collections.addDocuments(shelf, [a]);

      final cubit = await readyCubit(collectionId: shelf);
      expect(titlesOf(cubit.state), ['In']);
      await until(cubit, (s) => s.collection?.name == 'Shelf');

      expect(await cubit.renameCollection('Favourite shelf'), isNull);
      await until(cubit, (s) => s.collection?.name == 'Favourite shelf');

      cubit.toggleSelected(a);
      await cubit.removeSelectionFromCollection();
      await until(cubit, (s) => s.documents.isEmpty);
      expect(await deps.library.findById(a), isNotNull);

      await cubit.deleteCollection();
      await until(cubit, (s) => s.collectionDeleted);
    });

    test('rename reports invalid names', () async {
      final shelf = await deps.collections.createCollection('Shelf');
      await deps.collections.createCollection('Other');
      final cubit = await readyCubit(collectionId: shelf);
      expect(await cubit.renameCollection('other'), isNotNull);
      expect(await cubit.renameCollection(''), isNotNull);
    });
  });

  test('closing cancels subscriptions', () async {
    final cubit = await readyCubit();
    await cubit.close();
    await addTestDocument(deps.library);
    await pumpEventQueue();
    expect(cubit.isClosed, isTrue);
  });
}
