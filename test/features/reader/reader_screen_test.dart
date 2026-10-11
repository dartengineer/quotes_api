import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/app/dependencies.dart';
import 'package:lectern/app/routes.dart';
import 'package:lectern/core/theme/reader_palette.dart';
import 'package:lectern/features/library/domain/document_format.dart';
import 'package:lectern/features/reader/domain/locator.dart';
import 'package:lectern/features/reader/presentation/reader_cubit.dart';
import 'package:lectern/features/reader/presentation/reader_screen.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/app_harness.dart';
import '../../helpers/reader_fixtures.dart';
import '../../helpers/test_database.dart';
import '../../helpers/test_dependencies.dart';

void main() {
  late AppDependencies deps;

  setUp(() async {
    deps = await createTestDependencies();
  });

  tearDown(() => disposeTestDependencies(deps));

  ReaderCubit reader(WidgetTester tester) =>
      tester.element(find.byType(ReaderScreen)).read<ReaderCubit>();

  Finder line(int n) =>
      find.text('Line ${n.toString().padLeft(4, '0')}', findRichText: true);

  int currentOffset(WidgetTester tester) =>
      (reader(tester).state.position!.locator as TextLocator).offset;

  /// Opens document [id] from the library, as a user would.
  Future<void> openFromLibrary(WidgetTester tester, int id) async {
    await pumpApp(tester, deps, location: Routes.library);
    await tester.tap(find.byKey(ValueKey(id)));
    await tester.pump();
    await pumpUntil(
      tester,
      () =>
          find.byType(ReaderScreen).evaluate().isNotEmpty &&
          reader(tester).state.position != null,
    );
    // Finish the page transition.
    await settle(tester);
  }

  Future<void> showChrome(WidgetTester tester) async {
    if (!reader(tester).state.chromeVisible) {
      await tester.tapAt(const Offset(195, 422));
      await settle(tester);
    }
    expect(reader(tester).state.chromeVisible, isTrue);
  }

  /// The line's top edge relative to the top of the screen.
  double topOf(WidgetTester tester, int n) => tester.getTopLeft(line(n)).dy;

  testWidgets('restores the exact saved position', (tester) async {
    final id = await addTextFile(deps, content: numberedLines(3000));
    await deps.readingProgress.savePosition(id, TextLocator(lineOffset(1500)));

    await openFromLibrary(tester, id);

    expect(topOf(tester, 1500), closeTo(0, 1));
    expect(currentOffset(tester), lineOffset(1500));
    expect(reader(tester).state.chromeVisible, isFalse);

    await unmountApp(tester);
  });

  testWidgets('changing text size keeps the reading position', (tester) async {
    final id = await addTextFile(deps, content: numberedLines(3000));
    await deps.readingProgress.savePosition(id, TextLocator(lineOffset(1500)));
    await openFromLibrary(tester, id);

    await showChrome(tester);
    await tester.tap(find.byTooltip('Reading settings'));
    await settle(tester);
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byTooltip('Larger text'));
      await settle(tester);
    }
    expect(reader(tester).state.preferences.fontSize, 21);

    expect(topOf(tester, 1500), closeTo(0, 1));
    expect(currentOffset(tester), lineOffset(1500));

    // The choice is saved for next time.
    final stored = await resolve(tester, deps.settings.load());
    expect(stored.readerPreferences.fontSize, 21);

    await unmountApp(tester);
  });

  testWidgets('saves the position and progress on close', (tester) async {
    final id = await addTextFile(deps, content: numberedLines(3000));
    await openFromLibrary(tester, id);
    expect(currentOffset(tester), 0);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await settle(tester);
    final offset = currentOffset(tester);
    expect(offset, greaterThan(lineOffset(10)));

    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(find.byType(ReaderScreen), findsNothing);

    final saved = await resolve(tester, deps.readingProgress.loadPosition(id));
    expect(saved, TextLocator(offset));
    final document = await resolve(tester, deps.library.findById(id));
    expect(
      document!.progress,
      closeTo(offset / numberedLines(3000).length, 1e-6),
    );

    await unmountApp(tester);
  });

  testWidgets('tapping the edges turns pages; the middle shows toolbars', (
    tester,
  ) async {
    final id = await addTextFile(deps, content: numberedLines(3000));
    await openFromLibrary(tester, id);

    await tester.tapAt(const Offset(195, 800));
    await tester.pump(const Duration(milliseconds: 300));
    await settle(tester);
    final afterForward = currentOffset(tester);
    expect(afterForward, greaterThan(lineOffset(10)));

    await tester.tapAt(const Offset(195, 40));
    await tester.pump(const Duration(milliseconds: 300));
    await settle(tester);
    expect(currentOffset(tester), lessThan(afterForward));

    await showChrome(tester);
    expect(find.byTooltip('Bookmarks'), findsOneWidget);

    await unmountApp(tester);
  });

  testWidgets('bookmarks, search and jumping back', (tester) async {
    final id = await addTextFile(deps, content: numberedLines(3000));
    await deps.readingProgress.savePosition(id, TextLocator(lineOffset(1500)));
    await openFromLibrary(tester, id);

    await showChrome(tester);
    await tester.tap(find.byTooltip('Add bookmark'));
    await settle(tester);
    expect(find.byTooltip('Remove bookmark'), findsOneWidget);

    // Search for an early line and jump to it.
    await tester.tap(find.byTooltip('Search in document'));
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'line 0042');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await pumpUntil(tester, () => find.text('1 match').evaluate().isNotEmpty);
    await tester.tap(find.byType(ListTile).first);
    await settle(tester);
    expect(topOf(tester, 42), closeTo(0, 1));
    expect(find.byTooltip('Add bookmark'), findsOneWidget);

    // Back to the bookmark.
    await tester.tap(find.byTooltip('Bookmarks'));
    await settle(tester);
    expect(find.textContaining('Line 1500'), findsOneWidget);
    await tester.tap(find.textContaining('Line 1500'));
    await settle(tester);
    expect(topOf(tester, 1500), closeTo(0, 1));

    final bookmarks = reader(tester).state.bookmarks;
    expect(bookmarks.single.locator, TextLocator(lineOffset(1500)));

    await unmountApp(tester);
  });

  testWidgets('the progress slider jumps; the end counts as 100%', (
    tester,
  ) async {
    final id = await addTextFile(deps, content: numberedLines(3000));
    await openFromLibrary(tester, id);
    await showChrome(tester);

    await tester.drag(find.byType(Slider), const Offset(600, 0));
    await settle(tester);
    expect(reader(tester).state.position!.progress, 1.0);
    expect(find.text('100%'), findsOneWidget);
    expect(line(2999), findsOneWidget);

    await unmountApp(tester);
  });

  testWidgets('night theme changes the page colours', (tester) async {
    final id = await addTextFile(deps, content: numberedLines(100));
    await openFromLibrary(tester, id);
    await showChrome(tester);

    await tester.tap(find.byTooltip('Reading settings'));
    await settle(tester);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Night'));
    await settle(tester);

    final scaffold = tester.widget<Scaffold>(
      find.descendant(
        of: find.byType(ReaderScreen),
        matching: find.byType(Scaffold),
      ),
    );
    expect(scaffold.backgroundColor, ReaderPalette.night.background);

    await unmountApp(tester);
  });

  testWidgets('PDFs open their details until the PDF reader exists', (
    tester,
  ) async {
    final pdf = await addTestDocument(
      deps.library,
      title: 'A PDF',
      format: DocumentFormat.pdf,
    );
    final txt = await addTextFile(deps, title: 'A text', content: 'Hello');
    await pumpApp(tester, deps, location: Routes.library);

    await tester.tap(find.byKey(ValueKey(pdf)));
    await settle(tester);
    expect(find.byType(ReaderScreen), findsNothing);
    expect(find.text('Reading status'), findsOneWidget);
    expect(find.text('Read'), findsNothing);
    await tester.binding.handlePopRoute();
    await settle(tester);

    // A readable document's details (reached from the reader) offer to
    // continue reading.
    await tester.tap(find.byKey(ValueKey(txt)));
    await tester.pump();
    await pumpUntil(
      tester,
      () =>
          find.byType(ReaderScreen).evaluate().isNotEmpty &&
          reader(tester).state.position != null,
    );
    await settle(tester);
    await showChrome(tester);
    await tester.tap(find.byTooltip('More options'));
    await settle(tester);
    await tester.tap(find.text('Document details'));
    await settle(tester);
    expect(find.text('Reading status'), findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, 'Read').evaluate().length +
          find
              .widgetWithText(FilledButton, 'Continue reading')
              .evaluate()
              .length,
      1,
    );
    await unmountApp(tester);
  });

  testWidgets('a missing library file is explained', (tester) async {
    final id = await addTestDocument(
      deps.library,
      title: 'Ghost',
      format: DocumentFormat.txt,
    );
    await pumpApp(tester, deps, location: Routes.library);
    await tester.tap(find.byKey(ValueKey(id)));
    await tester.pump();
    await pumpUntil(
      tester,
      () => find.text('File missing').evaluate().isNotEmpty,
    );
    await unmountApp(tester);
  });
}
