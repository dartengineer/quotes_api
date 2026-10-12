import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/app/dependencies.dart';
import 'package:lectern/features/library/domain/document_format.dart';
import 'package:lectern/features/library/domain/reading_status.dart';
import 'package:lectern/features/reader/domain/locator.dart';
import 'package:lectern/features/reader/domain/reader_preferences.dart';
import 'package:lectern/features/reader/presentation/reader_cubit.dart';

import '../../helpers/reader_fixtures.dart';
import '../../helpers/test_database.dart';
import '../../helpers/test_dependencies.dart';

void main() {
  late AppDependencies deps;

  setUp(() async {
    deps = await createTestDependencies();
  });

  tearDown(() => disposeTestDependencies(deps));

  ReaderCubit open(int id) {
    final cubit = ReaderCubit(
      documentId: id,
      library: deps.library,
      progress: deps.readingProgress,
      bookmarks: deps.bookmarks,
      annotations: deps.annotations,
      settings: deps.settings,
      storage: deps.storage,
    );
    addTearDown(cubit.close);
    return cubit;
  }

  Future<ReaderState> until(
    ReaderCubit cubit,
    bool Function(ReaderState s) test,
  ) {
    if (test(cubit.state)) return Future.value(cubit.state);
    return cubit.stream.firstWhere(test).timeout(const Duration(seconds: 5));
  }

  test('opens with the saved position and preferences', () async {
    final id = await addTextFile(deps, content: 'Hello\nworld');
    await deps.readingProgress.savePosition(id, const TextLocator(6));
    await deps.settings.setReaderPreferences(
      const ReaderPreferences(fontSize: 22),
    );

    final cubit = open(id);
    final state = await until(cubit, (s) => s.status != ReaderStatus.loading);
    expect(state.status, ReaderStatus.ready);
    expect(state.initialLocator, const TextLocator(6));
    expect(state.preferences.fontSize, 22);
    expect(state.filePath, endsWith('.txt'));
    expect(state.chromeVisible, isFalse);

    final document = (await deps.library.findById(id))!;
    expect(document.status, ReadingStatus.reading);
    expect(document.lastOpenedAt, isNotNull);
  });

  test('reports missing documents and files', () async {
    expect(
      (await until(open(9999), (s) => s.status != ReaderStatus.loading)).status,
      ReaderStatus.notFound,
    );

    final noFile = await addTestDocument(
      deps.library,
      format: DocumentFormat.txt,
    );
    expect(
      (await until(
        open(noFile),
        (s) => s.status != ReaderStatus.loading,
      )).status,
      ReaderStatus.missingFile,
    );
  });

  test('toggles a bookmark at the visible position', () async {
    final id = await addTextFile(deps, content: numberedLines(100));
    final cubit = open(id);
    await until(cubit, (s) => s.status == ReaderStatus.ready);

    cubit.onPosition(
      ReaderPosition(
        locator: TextLocator(lineOffset(10)),
        progress: 0.1,
        visibleEnd: TextLocator(lineOffset(30)),
      ),
    );
    await cubit.toggleBookmark(excerpt: 'Line 0010');
    final added = await until(cubit, (s) => s.bookmarks.length == 1);
    expect(added.bookmarksHere, hasLength(1));
    expect(added.bookmarks.single.excerpt, 'Line 0010');

    await cubit.toggleBookmark();
    await until(cubit, (s) => s.bookmarks.isEmpty);
  });

  test('saves position and progress when closed', () async {
    final id = await addTextFile(deps, content: numberedLines(100));
    final cubit = open(id);
    await until(cubit, (s) => s.status == ReaderStatus.ready);
    cubit.onPosition(
      ReaderPosition(locator: TextLocator(lineOffset(50)), progress: 0.5),
    );
    await cubit.close();

    expect(
      await deps.readingProgress.loadPosition(id),
      TextLocator(lineOffset(50)),
    );
    expect((await deps.library.findById(id))!.progress, 0.5);
  });

  test('saves position and progress when the app is paused', () async {
    final id = await addTextFile(deps, content: numberedLines(100));
    final cubit = open(id);
    await until(cubit, (s) => s.status == ReaderStatus.ready);
    cubit.onPosition(
      ReaderPosition(locator: TextLocator(lineOffset(20)), progress: 0.2),
    );
    await cubit.onAppPaused();
    expect(
      await deps.readingProgress.loadPosition(id),
      TextLocator(lineOffset(20)),
    );
    expect((await deps.library.findById(id))!.progress, 0.2);

    // Reading continues after returning to the app.
    cubit.onAppResumed();
    cubit.onPosition(
      ReaderPosition(locator: TextLocator(lineOffset(40)), progress: 0.4),
    );
    await cubit.close();
    expect(
      await deps.readingProgress.loadPosition(id),
      TextLocator(lineOffset(40)),
    );
  });

  test('saves preferences', () async {
    final id = await addTextFile(deps, content: 'x');
    final cubit = open(id);
    await until(cubit, (s) => s.status == ReaderStatus.ready);

    cubit.previewPreferences(const ReaderPreferences(fontSize: 30));
    expect(
      (await deps.settings.load()).readerPreferences.fontSize,
      ReaderPreferences.defaultFontSize,
      reason: 'previews are not saved',
    );
    await cubit.savePreferences(
      const ReaderPreferences(theme: ReaderTheme.sepia),
    );
    expect(
      (await deps.settings.load()).readerPreferences.theme,
      ReaderTheme.sepia,
    );
  });
}
