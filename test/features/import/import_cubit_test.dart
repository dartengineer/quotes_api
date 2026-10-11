import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/app/dependencies.dart';
import 'package:lectern/features/import/data/document_picker.dart';
import 'package:lectern/features/import/domain/import_outcome.dart';
import 'package:lectern/features/import/presentation/import_cubit.dart';

import '../../helpers/test_dependencies.dart';

void main() {
  late AppDependencies deps;
  late FakeDocumentPicker picker;
  late ImportCubit cubit;

  setUp(() async {
    picker = FakeDocumentPicker();
    deps = await createTestDependencies(picker: picker);
    cubit = ImportCubit(picker: picker, importer: deps.importer);
  });

  tearDown(() async {
    await cubit.close();
    await disposeTestDependencies(deps);
  });

  ImportSource textFile(String name, String content) {
    final file = File('${deps.storage.root.parent.path}/$name')
      ..writeAsStringSync(content);
    return ImportSource(path: file.path, displayName: name);
  }

  test('picks, imports and reports', () async {
    picker.next = [textFile('a.txt', 'one'), textFile('b.txt', 'two')];
    final states = <ImportState>[];
    final subscription = cubit.stream.listen(states.add);

    await cubit.pickAndImport();
    await pumpEventQueue();
    await subscription.cancel();

    expect(states.first, isA<ImportPreparing>());
    expect(states.whereType<ImportRunning>(), isNotEmpty);
    final finished = cubit.state as ImportFinished;
    expect(finished.report.imported, hasLength(2));
    expect(picker.clearCalls, 1, reason: 'picker copies are cleaned up');
    expect(await deps.library.watchCount().first, 2);

    cubit.dismiss();
    expect(cubit.state, isA<ImportIdle>());
  });

  test('a cancelled pick returns to idle', () async {
    await cubit.pickAndImport();
    expect(cubit.state, isA<ImportIdle>());
    expect(picker.clearCalls, 1);
  });

  test('a picker failure is reported', () async {
    picker.error = StateError('no activity');
    await cubit.pickAndImport();
    expect(cubit.state, isA<ImportPickerFailed>());
    cubit.dismiss();
    expect(cubit.state, isA<ImportIdle>());
  });

  test('cancelling stops after the current file', () async {
    final sources = [
      for (var i = 0; i < 5; i++) textFile('f$i.txt', utf8.encode('$i').join()),
    ];
    final subscription = cubit.stream.listen((state) {
      if (state is ImportRunning && state.progress.completed == 1) {
        cubit.cancel();
      }
    });
    await cubit.importSources(sources);
    await subscription.cancel();

    final report = (cubit.state as ImportFinished).report;
    expect(report.cancelled, isTrue);
    expect(report.outcomes.length, lessThan(5));
  });

  test('files arriving during an import are queued, not dropped', () async {
    final totals = <int>[];
    final subscription = cubit.stream.listen((state) {
      if (state is ImportRunning) totals.add(state.progress.total);
    });
    final first = cubit.importSources([textFile('a.txt', 'a')]);
    final second = cubit.importSources([
      textFile('b.txt', 'b'),
      textFile('c.txt', 'c'),
    ]);
    await Future.wait([first, second]);
    await subscription.cancel();

    final report = (cubit.state as ImportFinished).report;
    expect(report.total, 3, reason: 'one summary for both requests');
    expect(report.imported, hasLength(3));
    expect(totals.last, 3, reason: 'progress grows as files arrive');
    expect(await deps.library.watchCount().first, 3);
  });

  test('files that could not be received are reported', () async {
    await cubit.importSources(
      [textFile('a.txt', 'a')],
      rejected: const [RejectedOutcome('b.pdf', RejectionReason.unreadable)],
    );
    final report = (cubit.state as ImportFinished).report;
    expect(report.total, 2);
    expect(report.imported, hasLength(1));
    expect(report.problems.single.fileName, 'b.pdf');
  });

  test('"Open with" names the document to open, new or existing', () async {
    await cubit.importSources([textFile('a.txt', 'a')], openWhenDone: true);
    final added = cubit.state as ImportFinished;
    final id = added.report.imported.single.documentId;
    expect(added.documentToOpen, id);
    cubit.dismiss();

    await cubit.importSources([textFile('copy.txt', 'a')], openWhenDone: true);
    expect((cubit.state as ImportFinished).documentToOpen, id);
    cubit.dismiss();

    // Not for a share, nor for an unsupported file.
    await cubit.importSources([textFile('b.txt', 'b')]);
    expect((cubit.state as ImportFinished).documentToOpen, isNull);
    expect((cubit.state as ImportFinished).report.singleDocumentId, isNotNull);
    cubit.dismiss();
    await cubit.importSources([
      textFile('c.zip', 'PK\u0003\u0004'),
    ], openWhenDone: true);
    expect((cubit.state as ImportFinished).documentToOpen, isNull);
  });

  test('cancelling also skips queued files', () async {
    final subscription = cubit.stream.listen((state) {
      if (state is ImportRunning && state.progress.completed == 1) {
        cubit.cancel();
      }
    });
    final first = cubit.importSources([
      for (var i = 0; i < 3; i++) textFile('f$i.txt', 'file $i'),
    ]);
    final queued = cubit.importSources([textFile('q.txt', 'queued')]);
    await Future.wait([first, queued]);
    await subscription.cancel();

    final report = (cubit.state as ImportFinished).report;
    expect(report.cancelled, isTrue);
    expect(report.total, 4);
    expect(report.skipped, greaterThanOrEqualTo(2));
  });

  test(
    'an empty pick does not disturb an import that started meanwhile',
    () async {
      final picker = _GatedPicker();
      final gatedCubit = ImportCubit(picker: picker, importer: deps.importer);
      addTearDown(gatedCubit.close);

      final picking = gatedCubit.pickAndImport();
      final importing = gatedCubit.importSources([textFile('a.txt', 'a')]);
      expect(gatedCubit.state, isA<ImportRunning>());
      picker.result.complete(const []);
      await Future.wait([picking, importing]);

      expect(gatedCubit.state, isA<ImportFinished>());
      expect(
        (gatedCubit.state as ImportFinished).report.imported,
        hasLength(1),
      );
    },
  );

  test('dismiss is ignored while busy', () async {
    final future = cubit.importSources([textFile('a.txt', 'a')]);
    cubit.dismiss();
    expect(cubit.state, isA<ImportRunning>());
    await future;
  });
}

/// A picker that stays open until the test supplies its result.
class _GatedPicker implements DocumentPicker {
  final result = Completer<List<ImportSource>>();

  @override
  Future<List<ImportSource>> pick({void Function()? onPreparing}) =>
      result.future;

  @override
  Future<void> clearTemporaryFiles() async {}
}
