import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/app/dependencies.dart';
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

  test('cannot start a second import while one runs', () async {
    final first = cubit.importSources([textFile('a.txt', 'a')]);
    await cubit.importSources([textFile('b.txt', 'b')]);
    await first;
    expect((cubit.state as ImportFinished).report.total, 1);
  });

  test('dismiss is ignored while busy', () async {
    final future = cubit.importSources([textFile('a.txt', 'a')]);
    cubit.dismiss();
    expect(cubit.state, isA<ImportRunning>());
    await future;
  });
}
