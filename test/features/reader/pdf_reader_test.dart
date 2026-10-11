import 'dart:io';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/app/dependencies.dart';
import 'package:lectern/app/routes.dart';
import 'package:lectern/core/theme/reader_palette.dart';
import 'package:lectern/features/reader/domain/locator.dart';
import 'package:lectern/features/reader/presentation/reader_cubit.dart';
import 'package:lectern/features/reader/presentation/reader_screen.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../helpers/app_harness.dart';
import '../../helpers/fixtures.dart';
import '../../helpers/reader_fixtures.dart';
import '../../helpers/test_dependencies.dart';

void main() {
  late bool pdfium;
  late AppDependencies deps;

  setUpAll(() async {
    pdfium = await initializePdfiumForTests();
  });

  setUp(() async {
    deps = await createTestDependencies();
  });

  tearDown(() => disposeTestDependencies(deps));

  ReaderCubit reader(WidgetTester tester) =>
      tester.element(find.byType(ReaderScreen)).read<ReaderCubit>();

  PdfLocator? position(WidgetTester tester) =>
      reader(tester).state.position?.locator as PdfLocator?;

  PdfViewerController viewer(WidgetTester tester) =>
      tester.widget<PdfViewer>(find.byType(PdfViewer)).controller!;

  Future<void> open(WidgetTester tester, int id) async {
    await pumpApp(tester, deps, location: Routes.library);
    await tester.tap(find.byKey(ValueKey(id)));
    await tester.pump();
    await pumpUntil(
      tester,
      () =>
          find.byType(ReaderScreen).evaluate().isNotEmpty &&
          reader(tester).state.position != null,
    );
    await settle(tester);
    // Let background work started by opening (page text) finish.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
  }

  /// The page whose top edge is nearest the top of the view.
  int topPage(WidgetTester tester) => position(tester)!.pageIndex;

  Future<void> showChrome(WidgetTester tester) async {
    if (!reader(tester).state.chromeVisible) {
      await tester.tapAt(const Offset(195, 422));
      // Single taps wait out the double-tap timeout.
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester);
    }
    expect(reader(tester).state.chromeVisible, isTrue);
  }

  Future<void> openMenu(WidgetTester tester, String item) async {
    await showChrome(tester);
    await tester.tap(find.byTooltip('More options'));
    await settle(tester);
    await tester.tap(find.text(item));
    await settle(tester);
  }

  /// Taps a page-turn zone and lets the scroll animation finish.
  Future<void> tapZone(WidgetTester tester, double y) async {
    await tester.tapAt(Offset(195, y));
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
  }

  group('opening', () {
    testWidgets('restores the saved page and offset; shows page numbers', (
      tester,
    ) async {
      if (!pdfium) return markTestSkipped('PDFium not available');
      final id = await addPdfFile(deps, bytes: textPdf(pagedText(20)));
      await deps.readingProgress.savePosition(
        id,
        const PdfLocator(7, pageOffset: 0.5),
      );
      await open(tester, id);

      expect(position(tester), const PdfLocator(7, pageOffset: 0.5));
      final state = reader(tester).state.position!;
      expect(state.pageCount, 20);
      expect(state.progress, closeTo(7.5 / 20, 1e-6));

      await showChrome(tester);
      expect(find.text('8 / 20'), findsOneWidget);
      await unmountApp(tester);
    });

    testWidgets('scrolling is saved on close, independent of zoom', (
      tester,
    ) async {
      if (!pdfium) return markTestSkipped('PDFium not available');
      final id = await addPdfFile(deps, bytes: textPdf(pagedText(20)));
      await open(tester, id);
      expect(position(tester), const PdfLocator(0));

      await tester.drag(find.byType(PdfViewer), const Offset(0, -1500));
      await settle(tester);
      final scrolled = position(tester)!;
      expect(scrolled.pageIndex, greaterThan(1));

      await tester.binding.handlePopRoute();
      await settle(tester);
      final saved = await resolve(
        tester,
        deps.readingProgress.loadPosition(id),
      );
      expect(saved, scrolled);
      final document = await resolve(tester, deps.library.findById(id));
      expect(
        document!.progress,
        closeTo((scrolled.pageIndex + scrolled.pageOffset) / 20, 1e-6),
      );
      await unmountApp(tester);
    });

    testWidgets('a damaged PDF is explained', (tester) async {
      if (!pdfium) return markTestSkipped('PDFium not available');
      final bytes = textPdf(pagedText(3));
      final id = await addPdfFile(
        deps,
        bytes: bytes.sublist(0, bytes.length ~/ 3),
      );
      await pumpApp(tester, deps, location: Routes.library);
      await tester.tap(find.byKey(ValueKey(id)));
      await tester.pump();
      await pumpUntil(
        tester,
        () => find.text('Can’t open this PDF').evaluate().isNotEmpty,
      );
      expect(find.text('Try again'), findsOneWidget);
      await unmountApp(tester);
    });
  });

  group('password-protected PDFs', () {
    late int id;

    setUp(() async {
      id = await addPdfFile(
        deps,
        bytes: File('test/fixtures/password_protected.pdf').readAsBytesSync(),
      );
    });

    Future<void> openLocked(WidgetTester tester) async {
      await pumpApp(tester, deps, location: Routes.library);
      await tester.tap(find.byKey(ValueKey(id)));
      await tester.pump();
      await pumpUntil(
        tester,
        () => find.text('Password required').evaluate().isNotEmpty,
      );
      // The loading spinner behind the dialog never settles.
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('asks again after a wrong password, then opens', (
      tester,
    ) async {
      if (!pdfium) return markTestSkipped('PDFium not available');
      await openLocked(tester);
      expect(find.byType(AlertDialog), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'wrong');
      await tester.tap(find.widgetWithText(FilledButton, 'Open'));
      await tester.pump();
      await pumpUntil(
        tester,
        () => find.text('Incorrect password').evaluate().isNotEmpty,
      );
      // Let the first dialog finish closing.
      await tester.pump(const Duration(milliseconds: 300));

      await tester.enterText(find.byType(TextField), 'secret');
      await tester.tap(find.widgetWithText(FilledButton, 'Open'));
      await tester.pump();
      await pumpUntil(tester, () => reader(tester).state.position != null);
      await settle(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(reader(tester).state.position!.pageCount, 2);
      // Unknown at import (no password then); learned now.
      final document = await resolve(tester, deps.library.findById(id));
      expect(document!.pageCount, 2);
      await unmountApp(tester);
    });

    testWidgets('cancelling explains and offers to try again', (tester) async {
      if (!pdfium) return markTestSkipped('PDFium not available');
      await openLocked(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await pumpUntil(
        tester,
        () =>
            find.text('Enter password').evaluate().isNotEmpty &&
            find.byType(AlertDialog).evaluate().isEmpty,
      );
      expect(
        find.text('This PDF is protected with a password.'),
        findsOneWidget,
      );

      await tester.tap(find.text('Enter password'));
      await tester.pump();
      await pumpUntil(
        tester,
        () => find.byType(AlertDialog).evaluate().isNotEmpty,
      );
      // Routes ignore taps until their entrance animation ends.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(TextField), 'secret');
      await tester.tap(find.widgetWithText(FilledButton, 'Open'));
      await tester.pump();
      await pumpUntil(tester, () => reader(tester).state.position != null);
      await settle(tester);
      expect(find.text('Password required'), findsNothing);
      await unmountApp(tester);
    });
  });

  group('navigation', () {
    testWidgets('tapping the edges scrolls by a screen; the middle shows '
        'toolbars', (tester) async {
      if (!pdfium) return markTestSkipped('PDFium not available');
      final id = await addPdfFile(deps, bytes: textPdf(pagedText(20)));
      await open(tester, id);
      final before = viewer(tester).visibleRect;

      await tapZone(tester, 800);
      final after = viewer(tester).visibleRect;
      expect(after.top - before.top, closeTo(before.height * 0.9, 1));

      await tapZone(tester, 40);
      expect(viewer(tester).visibleRect.top, closeTo(before.top, 1));
      expect(reader(tester).state.chromeVisible, isFalse);

      await showChrome(tester);
      await unmountApp(tester);
    });

    testWidgets('rotating the screen keeps the page', (tester) async {
      if (!pdfium) return markTestSkipped('PDFium not available');
      final id = await addPdfFile(deps, bytes: textPdf(pagedText(20)));
      await deps.readingProgress.savePosition(
        id,
        const PdfLocator(9, pageOffset: 0.3),
      );
      await open(tester, id);

      tester.view.physicalSize = const Size(844, 390);
      await tester.pump();
      await settle(tester);
      expect(position(tester)!.pageIndex, 9);
      expect(position(tester)!.pageOffset, closeTo(0.3, 0.05));

      tester.view.physicalSize = const Size(390, 844);
      await tester.pump();
      await settle(tester);
      expect(position(tester)!.pageIndex, 9);
      expect(position(tester)!.pageOffset, closeTo(0.3, 0.05));
      await unmountApp(tester);
    });

    testWidgets('double tap zooms in and back out', (tester) async {
      if (!pdfium) return markTestSkipped('PDFium not available');
      final id = await addPdfFile(deps, bytes: textPdf(pagedText(5)));
      await open(tester, id);
      final fit = viewer(tester).currentZoom;

      Future<void> doubleTap() async {
        await tester.tapAt(const Offset(195, 400));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tapAt(const Offset(195, 400));
        await tester.pump(const Duration(milliseconds: 400));
        await settle(tester);
      }

      await doubleTap();
      expect(viewer(tester).currentZoom, greaterThan(fit * 2));
      expect(reader(tester).state.chromeVisible, isFalse);
      await doubleTap();
      expect(viewer(tester).currentZoom, closeTo(fit, 1e-6));
      await unmountApp(tester);
    });

    testWidgets('the slider goes to a page and labels it', (tester) async {
      if (!pdfium) return markTestSkipped('PDFium not available');
      final id = await addPdfFile(deps, bytes: textPdf(pagedText(20)));
      await open(tester, id);
      await showChrome(tester);

      final slider = tester.widget<Slider>(find.byType(Slider));
      slider.onChanged!(0.5);
      await tester.pump();
      expect(find.text('11 / 20'), findsOneWidget);
      slider.onChangeEnd!(0.5);
      await settle(tester);
      expect(position(tester), const PdfLocator(10));

      // The end counts as finished.
      slider.onChangeEnd!(1);
      await settle(tester);
      expect(reader(tester).state.position!.progress, 1.0);
      await unmountApp(tester);
    });

    testWidgets('go to page validates and jumps', (tester) async {
      if (!pdfium) return markTestSkipped('PDFium not available');
      final id = await addPdfFile(deps, bytes: textPdf(pagedText(20)));
      await open(tester, id);

      await openMenu(tester, 'Go to page…');
      await tester.enterText(find.byType(TextField), '42');
      await tester.tap(find.text('Go'));
      await tester.pump();
      expect(find.text('Enter a number from 1 to 20'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '15');
      await tester.tap(find.text('Go'));
      await settle(tester);
      expect(position(tester), const PdfLocator(14));
      await unmountApp(tester);
    });

    testWidgets('page thumbnails: the current page is marked; tapping one '
        'goes there', (tester) async {
      if (!pdfium) return markTestSkipped('PDFium not available');
      final id = await addPdfFile(deps, bytes: textPdf(pagedText(20)));
      await deps.readingProgress.savePosition(id, const PdfLocator(4));
      await open(tester, id);

      await openMenu(tester, 'Pages');
      await pumpUntil(
        tester,
        () => find.byType(PdfPageView).evaluate().isNotEmpty,
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel('Page 5')),
        isSemantics(isSelected: true),
      );

      await tester.tap(find.bySemanticsLabel('Page 6'));
      await settle(tester);
      expect(find.text('Pages'), findsNothing);
      expect(position(tester), const PdfLocator(5));
      await unmountApp(tester);
    });

    testWidgets('the outline becomes the contents, marking the current '
        'section', (tester) async {
      if (!pdfium) return markTestSkipped('PDFium not available');
      final id = await addPdfFile(
        deps,
        bytes: textPdf(
          pagedText(12),
          outline: [('Introduction', 0), ('Methods', 4), ('Results', 9)],
        ),
      );
      await deps.readingProgress.savePosition(id, const PdfLocator(6));
      await open(tester, id);

      await openMenu(tester, 'Contents');
      expect(find.text('Introduction'), findsOneWidget);
      final methods = tester.widget<ListTile>(
        find.widgetWithText(ListTile, 'Methods'),
      );
      expect(methods.selected, isTrue);
      expect(find.text('Page 10'), findsOneWidget);

      await tester.tap(find.text('Results'));
      await settle(tester);
      expect(position(tester), const PdfLocator(9));
      await unmountApp(tester);
    });

    testWidgets('documents without an outline offer no contents', (
      tester,
    ) async {
      if (!pdfium) return markTestSkipped('PDFium not available');
      final id = await addPdfFile(deps, bytes: textPdf(pagedText(3)));
      await open(tester, id);
      await showChrome(tester);
      await tester.tap(find.byTooltip('More options'));
      await settle(tester);
      expect(find.text('Contents'), findsNothing);
      expect(find.text('Pages'), findsOneWidget);
      await unmountApp(tester);
    });
  });

  group('text', () {
    testWidgets('search finds text across line breaks and jumps to it', (
      tester,
    ) async {
      if (!pdfium) return markTestSkipped('PDFium not available');
      final id = await addPdfFile(deps, bytes: textPdf(pagedText(20)));
      await open(tester, id);
      await showChrome(tester);

      await tester.tap(find.byTooltip('Search in document'));
      await settle(tester);
      // "marker 013" is on one line, "013 Some" spans a line break.
      await tester.enterText(find.byType(TextField), '013   some');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await pumpUntil(tester, () => find.text('1 match').evaluate().isNotEmpty);
      expect(find.text('Page 14'), findsOneWidget);

      await tester.tap(find.byType(ListTile).first);
      await settle(tester);
      expect(topPage(tester), 13);

      // The match is highlighted (once its page text has loaded), then the
      // highlight fades after a few seconds.
      final highlight = ReaderPalette.paper.highlight;
      final pages = find.descendant(
        of: find.byType(PdfViewer),
        matching: find.byType(CustomPaint),
      );
      // A `paints` pattern matches one render object's paint calls; the
      // pages are painted by one of the viewer's CustomPaints. Other
      // rectangles (page shadows) are drawn too, so look for any rectangle
      // in the highlight colour.
      bool highlighted() {
        for (final element in pages.evaluate()) {
          final pattern = paints
            ..something(
              (method, arguments) =>
                  method == #drawRect &&
                  // Paint keeps 32-bit channels; compare at that precision.
                  (arguments[1] as Paint).color.toARGB32() ==
                      highlight.toARGB32(),
            );
          final matcher = pattern as Matcher;
          if (matcher.matches(element.renderObject, <dynamic, dynamic>{})) {
            return true;
          }
        }
        return false;
      }

      await pumpUntil(tester, highlighted);
      await tester.pump(const Duration(seconds: 5));
      expect(highlighted(), isFalse);
      await unmountApp(tester);
    });

    testWidgets('bookmarks record the page and its text', (tester) async {
      if (!pdfium) return markTestSkipped('PDFium not available');
      final id = await addPdfFile(deps, bytes: textPdf(pagedText(20)));
      await deps.readingProgress.savePosition(id, const PdfLocator(11));
      await open(tester, id);
      await showChrome(tester);

      await tester.tap(find.byTooltip('Add bookmark'));
      await settle(tester);
      expect(find.byTooltip('Remove bookmark'), findsOneWidget);
      final bookmark = reader(tester).state.bookmarks.single;
      expect(bookmark.locator, const PdfLocator(11));
      expect(bookmark.excerpt, 'Page marker 011 Some text on this page');

      await tester.tap(find.byTooltip('Bookmarks'));
      await settle(tester);
      expect(find.textContaining('Page 12 ·'), findsOneWidget);
      await unmountApp(tester);
    });

    testWidgets('long press selects text', (tester) async {
      if (!pdfium) return markTestSkipped('PDFium not available');
      final id = await addPdfFile(deps, bytes: textPdf(pagedText(2)));
      await open(tester, id);
      final controller = viewer(tester);
      // The first word of the first page ("Page" at 20-50 pt from the left,
      // about 31-43 pt from the top), in screen coordinates.
      final page = controller.layout.pageLayouts.first;
      final word = controller.documentToGlobal(
        Offset(page.left + 30, page.top + 37),
      )!;
      await tester.longPressAt(word);
      await settle(tester);
      expect(controller.textSelectionDelegate.hasSelectedText, isTrue);
      expect(
        await tester.runAsync(
          () => controller.textSelectionDelegate.getSelectedText(),
        ),
        'Page',
      );
      await unmountApp(tester);
    });
  });

  group('links', () {
    // A link area over the middle of the first page.
    const area = (50, 150, 250, 250);

    Future<void> tapLink(WidgetTester tester) async {
      // Link areas load in the background once a page is painted.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
      final controller = viewer(tester);
      final page = controller.layout.pageLayouts.first;
      // (150, 200) in PDF points is 200 pt from the top of the 400 pt page.
      await tester.tapAt(
        controller.documentToGlobal(Offset(page.left + 150, page.top + 200))!,
      );
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester);
    }

    testWidgets('internal links go to their page', (tester) async {
      if (!pdfium) return markTestSkipped('PDFium not available');
      final id = await addPdfFile(
        deps,
        bytes: textPdf(pagedText(10), links: [(from: 0, rect: area, to: 6)]),
      );
      await open(tester, id);
      await tapLink(tester);
      expect(position(tester), const PdfLocator(6));
      expect(reader(tester).state.chromeVisible, isFalse);
      await unmountApp(tester);
    });

    testWidgets('web links are shown, never opened', (tester) async {
      if (!pdfium) return markTestSkipped('PDFium not available');
      final id = await addPdfFile(
        deps,
        bytes: textPdf(
          pagedText(2),
          links: [(from: 0, rect: area, to: 'https://example.com/paper')],
        ),
      );
      await open(tester, id);
      await tapLink(tester);
      expect(find.text('Link to a website'), findsOneWidget);
      expect(find.text('https://example.com/paper'), findsOneWidget);

      await tester.tap(find.text('Copy link'));
      await settle(tester);
      expect(find.text('Link copied'), findsOneWidget);
      expect(position(tester), const PdfLocator(0));
      await unmountApp(tester);
    });
  });

  testWidgets('reading settings for PDFs offer themes, not typography', (
    tester,
  ) async {
    if (!pdfium) return markTestSkipped('PDFium not available');
    final id = await addPdfFile(deps, bytes: textPdf(pagedText(3)));
    await open(tester, id);
    await showChrome(tester);
    await tester.tap(find.byTooltip('Reading settings'));
    await settle(tester);
    expect(find.text('Night'), findsOneWidget);
    expect(find.byTooltip('Larger text'), findsNothing);
    expect(find.textContaining('Pinch or double-tap'), findsOneWidget);
    await unmountApp(tester);
  });
}
