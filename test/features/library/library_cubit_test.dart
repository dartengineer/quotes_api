import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/core/utils/load_status.dart';
import 'package:lectern/data/database/app_database.dart';
import 'package:lectern/features/library/data/library_repository.dart';
import 'package:lectern/features/library/domain/library_layout.dart';
import 'package:lectern/features/library/domain/library_query.dart';
import 'package:lectern/features/library/presentation/library_cubit.dart';
import 'package:lectern/features/settings/data/settings_repository.dart';

import '../../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late LibraryRepository library;
  late SettingsRepository settings;

  setUp(() {
    db = createTestDatabase();
    library = LibraryRepository(db, clock: FakeClock().call);
    settings = SettingsRepository(db);
  });

  tearDown(() => db.close());

  /// Resolves with the first state (current or future) matching [test].
  Future<LibraryState> until(
    LibraryCubit cubit,
    bool Function(LibraryState state) test,
  ) {
    if (test(cubit.state)) return Future.value(cubit.state);
    return cubit.stream.firstWhere(test).timeout(const Duration(seconds: 5));
  }

  Future<LibraryCubit> readyCubit() async {
    final cubit = LibraryCubit(library: library, settings: settings);
    await until(cubit, (s) => s.status == LoadStatus.ready);
    return cubit;
  }

  List<String> titlesOf(LibraryState state) =>
      state.documents.map((d) => d.title).toList();

  test('starts from stored layout and sort', () async {
    await settings.setLibraryLayout(LibraryLayout.list);
    await settings.setLibrarySort(LibrarySort.title);

    final cubit = await readyCubit();
    addTearDown(cubit.close);

    expect(cubit.state.layout, LibraryLayout.list);
    expect(cubit.state.query.sort, LibrarySort.title);
  });

  test('reflects library changes while open', () async {
    final cubit = await readyCubit();
    addTearDown(cubit.close);
    expect(cubit.state.documents, isEmpty);

    await addTestDocument(library, title: 'New arrival');
    final state = await until(cubit, (s) => s.documents.isNotEmpty);
    expect(titlesOf(state), ['New arrival']);
  });

  test('changing sort re-queries and persists the choice', () async {
    await addTestDocument(library, title: 'a');
    await addTestDocument(library, title: 'b');
    final cubit = await readyCubit();
    addTearDown(cubit.close);
    expect(titlesOf(cubit.state), ['b', 'a']);

    await cubit.setSort(LibrarySort.title);
    final sorted = await until(cubit, (s) => titlesOf(s).first == 'a');
    expect(titlesOf(sorted), ['a', 'b']);
    expect((await settings.load()).librarySort, LibrarySort.title);

    // The new subscription keeps following changes.
    await addTestDocument(library, title: 'aa');
    final updated = await until(cubit, (s) => s.documents.length == 3);
    expect(titlesOf(updated), ['a', 'aa', 'b']);
  });

  test('changing layout persists the choice', () async {
    final cubit = await readyCubit();
    addTearDown(cubit.close);

    await cubit.setLayout(LibraryLayout.list);
    expect(cubit.state.layout, LibraryLayout.list);
    expect((await settings.load()).libraryLayout, LibraryLayout.list);
  });

  test('a choice made before preferences load is not overwritten', () async {
    await settings.setLibrarySort(LibrarySort.title);

    final cubit = LibraryCubit(library: library, settings: settings);
    addTearDown(cubit.close);
    // Called synchronously, before the stored preferences have been read.
    final pending = cubit.setSort(LibrarySort.author);
    await until(cubit, (s) => s.status == LoadStatus.ready);
    await pending;
    await pumpEventQueue();

    expect(cubit.state.query.sort, LibrarySort.author);
    expect((await settings.load()).librarySort, LibrarySort.author);
  });

  test('closing cancels the library subscription', () async {
    final cubit = await readyCubit();
    await cubit.close();
    // Writes after closing must not try to emit on the closed cubit.
    await addTestDocument(library);
    await pumpEventQueue();
    expect(cubit.isClosed, isTrue);
  });
}
