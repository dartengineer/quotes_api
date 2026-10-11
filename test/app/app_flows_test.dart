import 'dart:async';
import 'dart:io';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/app/dependencies.dart';
import 'package:lectern/app/routes.dart';
import 'package:lectern/features/import/domain/import_outcome.dart';
import 'package:lectern/features/import/presentation/import_cubit.dart';
import 'package:lectern/features/library/domain/reading_status.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/app_harness.dart';
import '../helpers/fixtures.dart';
import '../helpers/test_database.dart';
import '../helpers/test_dependencies.dart';

void main() {
  late AppDependencies deps;
  late FakeDocumentPicker picker;

  setUp(() async {
    picker = FakeDocumentPicker();
    deps = await createTestDependencies(picker: picker);
  });

  tearDown(() => disposeTestDependencies(deps));

  ImportSource sourceFile(String name, List<int> bytes) {
    final file = File('${deps.storage.root.parent.path}/$name')
      ..writeAsBytesSync(bytes);
    return ImportSource(path: file.path, displayName: name);
  }

  ImportState importState(WidgetTester tester) =>
      tester.element(find.byType(Scaffold).first).read<ImportCubit>().state;

  testWidgets('imports from the empty library and shows a summary', (
    tester,
  ) async {
    picker.next = await tester.runAsync(
      () async => [
        sourceFile('first_book.epub', buildEpub(title: 'First Book')),
        sourceFile('notes.txt', 'Some notes'.codeUnits),
        sourceFile('picture.txt', pngImage()),
      ],
    ) as List<ImportSource>;

    await pumpApp(tester, deps, location: Routes.library);
    expect(find.text('No documents yet'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Import documents'));
    await tester.pump();
    await pumpUntil(tester, () => importState(tester) is ImportFinished);

    expect(find.text('Import finished'), findsOneWidget);
    expect(find.text('2 documents added'), findsOneWidget);
    expect(find.text('1 file not imported'), findsOneWidget);
    expect(find.text('picture.txt'), findsOneWidget);
    expect(find.text('Not supported: image.'), findsOneWidget);

    await tester.tap(find.text('Done'));
    await settle(tester);
    expect(find.text('First Book'), findsWidgets);
    expect(find.text('notes'), findsWidgets);
    expect(importState(tester), isA<ImportIdle>());

    await unmountApp(tester);
  });

  testWidgets('a single picked document can be opened from the summary', (
    tester,
  ) async {
    picker.next = await tester.runAsync(
      () async => [sourceFile('notes.txt', 'Some notes'.codeUnits)],
    ) as List<ImportSource>;
    await pumpApp(tester, deps, location: Routes.library);

    await tester.tap(find.widgetWithText(FilledButton, 'Import documents'));
    await tester.pump();
    await pumpUntil(tester, () => importState(tester) is ImportFinished);
    await settle(tester);
    expect(find.text('1 document added'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Open'));
    await tester.pump();
    await pumpUntil(
      tester,
      () => find.text('Some notes', findRichText: true).evaluate().isNotEmpty,
    );
    await settle(tester);

    await unmountApp(tester);
  });

  testWidgets('the sheet closes when the picker prepares nothing', (
    tester,
  ) async {
    final copying = Completer<void>();
    picker
      ..prepareEvenIfEmpty = true
      ..preparing = copying.future;
    await pumpApp(tester, deps, location: Routes.library);

    await tester.tap(find.widgetWithText(FilledButton, 'Import documents'));
    // An indeterminate progress bar never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Preparing files…'), findsOneWidget);

    copying.complete();
    await settle(tester);
    expect(find.text('Preparing files…'), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
    expect(importState(tester), isA<ImportIdle>());
    expect(find.text('No documents yet'), findsOneWidget);

    await unmountApp(tester);
  });

  testWidgets('searches, filters and bulk-edits the library', (tester) async {
    final alpha = await addTestDocument(deps.library, title: 'Alpha');
    final beta = await addTestDocument(deps.library, title: 'Beta');
    await addTestDocument(deps.library, title: 'Gamma');

    await pumpApp(tester, deps, location: Routes.library);

    // Search (debounced).
    await tester.tap(find.byTooltip('Search'));
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'alp');
    await tester.pump(const Duration(milliseconds: 300));
    await settle(tester);
    expect(find.text('Alpha'), findsWidgets);
    expect(find.text('Beta'), findsNothing);
    await tester.tap(find.byType(BackButton));
    await settle(tester);
    expect(find.text('Beta'), findsWidgets);

    // Select two, favourite them, then filter by favourites.
    await tester.longPress(find.byKey(ValueKey(alpha)));
    await tester.pump();
    await tester.tap(find.byKey(ValueKey(beta)));
    await settle(tester);
    expect(find.text('2 selected'), findsOneWidget);
    await tester.tap(find.byTooltip('Add to favourites'));
    await settle(tester);
    await tester.tap(find.byTooltip('Cancel selection'));
    await settle(tester);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Favourites'));
    await settle(tester);
    expect(find.text('Gamma'), findsNothing);
    expect(find.text('Alpha'), findsWidgets);
    await tester.tap(find.widgetWithText(ChoiceChip, 'All'));
    await settle(tester);

    // Mark as finished through the selection menu.
    await tester.longPress(find.byKey(ValueKey(alpha)));
    await settle(tester);
    await tester.tap(find.byTooltip('More actions'));
    await settle(tester);
    await tester.tap(find.text('Mark as finished'));
    await settle(tester);
    expect(
      (await resolve(tester, deps.library.findById(alpha)))!.status,
      ReadingStatus.finished,
    );

    // Remove with confirmation.
    await tester.longPress(find.byKey(ValueKey(beta)));
    await settle(tester);
    await tester.tap(find.byTooltip('More actions'));
    await settle(tester);
    await tester.tap(find.text('Remove from library…'));
    await settle(tester);
    expect(find.text('Remove document?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await settle(tester);
    expect(find.text('Beta'), findsNothing);
    // Deleting the library copy is real file I/O.
    await pumpUntil(
      tester,
      () => find.text('Removed 1 document').evaluate().isNotEmpty,
    );

    await unmountApp(tester);
  });

  testWidgets('back clears the selection before leaving', (tester) async {
    final id = await addTestDocument(deps.library, title: 'Only');
    await pumpApp(tester, deps, location: Routes.library);
    await tester.longPress(find.byKey(ValueKey(id)));
    await settle(tester);
    expect(find.text('1 selected'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(find.text('1 selected'), findsNothing);
    expect(find.text('Library'), findsWidgets);

    await unmountApp(tester);
  });

  testWidgets('document details: status, collections and removal', (
    tester,
  ) async {
    final id = await addTestDocument(
      deps.library,
      title: 'Details Book',
      author: 'Someone',
    );
    await pumpApp(tester, deps, location: Routes.library);

    await tester.tap(find.byKey(ValueKey(id)));
    await settle(tester);
    expect(find.text('Details Book'), findsWidgets);
    expect(find.text('Reading status'), findsOneWidget);

    await tester.tap(find.text('Finished'));
    await settle(tester);
    expect(
      (await resolve(tester, deps.library.findById(id)))!.status,
      ReadingStatus.finished,
    );
    expect(find.text('100% read'), findsOneWidget);

    await tester.tap(find.byTooltip('Add to favourites'));
    await settle(tester);
    expect(find.byTooltip('Remove from favourites'), findsOneWidget);

    // Create a collection from the picker and add the book to it.
    await tester.tap(find.text('Add to collection'));
    await settle(tester);
    await tester.tap(find.text('New collection'));
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'Shelf');
    await tester.tap(find.text('Create'));
    await settle(tester);
    expect(find.widgetWithText(InputChip, 'Shelf'), findsOneWidget);

    // Remove from the library; the screen closes.
    await tester.tap(find.byTooltip('More options'));
    await settle(tester);
    await tester.tap(find.text('Remove from library…'));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await settle(tester);
    expect(find.text('Reading status'), findsNothing);
    expect(find.text('No documents yet'), findsOneWidget);
    expect(await resolve(tester, deps.library.findById(id)), isNull);
    // Collections survive removal of their documents.
    await tester.tap(find.text('Collections'));
    await settle(tester);
    expect(find.text('Shelf'), findsOneWidget);
    expect(find.text('0 documents'), findsOneWidget);

    await unmountApp(tester);
  });

  testWidgets('collections: create, open, rename and delete', (tester) async {
    await pumpApp(tester, deps, location: Routes.collections);
    expect(find.text('No collections yet'), findsOneWidget);

    await tester.tap(find.byType(FloatingActionButton));
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'To read');
    await tester.tap(find.text('Create'));
    await settle(tester);
    expect(find.text('To read'), findsOneWidget);
    expect(find.text('0 documents'), findsOneWidget);

    // Duplicate names are refused inside the dialog.
    await tester.tap(find.byType(FloatingActionButton));
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'TO READ');
    await tester.tap(find.text('Create'));
    await settle(tester);
    expect(find.text('A collection with that name exists.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await settle(tester);

    await tester.tap(find.text('To read'));
    await settle(tester);
    expect(find.text('This collection is empty'), findsOneWidget);

    await tester.tap(find.byTooltip('Collection options'));
    await settle(tester);
    await tester.tap(find.text('Rename collection'));
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'Next up');
    await tester.tap(find.text('Rename'));
    await settle(tester);
    expect(find.text('Next up'), findsOneWidget);

    await tester.tap(find.byTooltip('Collection options'));
    await settle(tester);
    await tester.tap(find.text('Delete collection'));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await settle(tester);
    expect(find.text('No collections yet'), findsOneWidget);

    await unmountApp(tester);
  });

  testWidgets('home search opens the library search field', (tester) async {
    await addTestDocument(deps.library, title: 'Findable');
    await pumpApp(tester, deps);

    await tester.tap(find.byTooltip('Search library'));
    await settle(tester);
    expect(find.byType(TextField), findsOneWidget);

    await unmountApp(tester);
  });
}
