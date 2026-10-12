import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/app/dependencies.dart';
import 'package:lectern/data/database/app_database.dart';
import 'package:lectern/features/library/domain/reading_status.dart';
import 'package:lectern/features/library/presentation/document_details_cubit.dart';

import '../../helpers/test_database.dart';
import '../../helpers/test_dependencies.dart';

void main() {
  late AppDependencies deps;

  setUp(() async {
    deps = await createTestDependencies();
  });

  tearDown(() => disposeTestDependencies(deps));

  DocumentDetailsCubit createCubit(int id) {
    final cubit = DocumentDetailsCubit(
      documentId: id,
      library: deps.library,
      collections: deps.collections,
      manager: deps.manager,
      progress: deps.readingProgress,
    );
    addTearDown(cubit.close);
    return cubit;
  }

  Future<DocumentDetailsState> until(
    DocumentDetailsCubit cubit,
    bool Function(DocumentDetailsState s) test,
  ) {
    if (test(cubit.state)) return Future.value(cubit.state);
    return cubit.stream.firstWhere(test).timeout(const Duration(seconds: 5));
  }

  test('loads the document, its details and collections', () async {
    final id = await addTestDocument(deps.library, title: 'Book');
    await (deps.database.update(
      deps.database.documents,
    )..where((d) => d.id.equals(id))).write(
      const DocumentsCompanion(
        description: Value('About it'),
        publisher: Value('Pub'),
      ),
    );
    final shelf = await deps.collections.createCollection('Shelf');
    await deps.collections.addDocuments(shelf, [id]);

    final cubit = createCubit(id);
    final state = await until(
      cubit,
      (s) =>
          s.status == DetailsStatus.ready &&
          s.details != null &&
          s.memberOf.isNotEmpty,
    );
    expect(state.document!.title, 'Book');
    expect(state.details!.description, 'About it');
    expect(state.details!.publisher, 'Pub');
    expect(state.memberOf.single.name, 'Shelf');
  });

  test('edits favourite, status and collections', () async {
    final id = await addTestDocument(deps.library);
    final shelf = await deps.collections.createCollection('Shelf');
    final cubit = createCubit(id);
    await until(cubit, (s) => s.status == DetailsStatus.ready);

    await cubit.toggleFavorite();
    await until(cubit, (s) => s.document!.isFavorite);

    await cubit.setStatus(ReadingStatus.finished);
    final finished = await until(
      cubit,
      (s) => s.document!.status == ReadingStatus.finished,
    );
    expect(finished.document!.progress, 1.0);

    await cubit.addToCollection(shelf);
    await until(cubit, (s) => s.memberOf.length == 1);
    await cubit.removeFromCollection(shelf);
    await until(cubit, (s) => s.memberOf.isEmpty);
  });

  test('removal is reported as not found', () async {
    final id = await addTestDocument(deps.library);
    final cubit = createCubit(id);
    await until(cubit, (s) => s.status == DetailsStatus.ready);

    await cubit.removeFromLibrary();
    await until(cubit, (s) => s.status == DetailsStatus.notFound);
    expect(await deps.library.findById(id), isNull);
  });

  test('an unknown id is not found', () async {
    final cubit = createCubit(12345);
    await until(cubit, (s) => s.status == DetailsStatus.notFound);
  });
}
