import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/core/utils/load_status.dart';
import 'package:lectern/data/database/app_database.dart';
import 'package:lectern/features/home/presentation/home_cubit.dart';
import 'package:lectern/features/library/data/library_repository.dart';

import '../../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late LibraryRepository library;

  setUp(() {
    db = createTestDatabase();
    library = LibraryRepository(db, clock: FakeClock().call);
  });

  tearDown(() => db.close());

  Future<HomeState> until(HomeCubit cubit, bool Function(HomeState s) test) {
    if (test(cubit.state)) return Future.value(cubit.state);
    return cubit.stream.firstWhere(test).timeout(const Duration(seconds: 5));
  }

  test('becomes ready with an empty library', () async {
    final cubit = HomeCubit(library);
    addTearDown(cubit.close);

    final state = await until(cubit, (s) => s.status == LoadStatus.ready);
    expect(state.isLibraryEmpty, isTrue);
    expect(state.continueReading, isEmpty);
    expect(state.recentlyAdded, isEmpty);
  });

  test('fills sections from the library and follows changes', () async {
    final opened = await addTestDocument(library, title: 'Opened');
    await addTestDocument(library, title: 'Fresh');
    await library.markOpened(opened);

    final cubit = HomeCubit(library, sectionSize: 5);
    addTearDown(cubit.close);
    final state = await until(cubit, (s) => s.status == LoadStatus.ready);

    expect(state.totalCount, 2);
    expect(state.continueReading.map((d) => d.title), ['Opened']);
    expect(state.recentlyOpened.map((d) => d.title), ['Opened']);
    expect(state.recentlyAdded.map((d) => d.title), ['Fresh', 'Opened']);

    await addTestDocument(library, title: 'Newest');
    final updated = await until(cubit, (s) => s.totalCount == 3);
    expect(updated.status, LoadStatus.ready);
  });
}
