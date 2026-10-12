/// Layout at the extremes: the narrowest common phone width (320 dp) with
/// text at twice its normal size. Every main screen, sheet and dialog is
/// opened; any overflow is a failure.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/app/dependencies.dart';
import 'package:lectern/app/routes.dart';
import 'package:lectern/core/files/file_opener.dart';
import 'package:lectern/features/backup/data/backup_codec.dart';
import 'package:lectern/features/backup/domain/reading_backup.dart';
import 'package:lectern/features/import/domain/import_outcome.dart';
import 'package:lectern/features/library/domain/reading_status.dart';
import 'package:lectern/features/reader/domain/annotation.dart';
import 'package:lectern/features/reader/domain/locator.dart';
import 'package:lectern/features/reader/presentation/reader_cubit.dart';
import 'package:lectern/features/reader/presentation/reader_screen.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/app_harness.dart';
import '../helpers/fixtures.dart';
import '../helpers/reader_fixtures.dart';
import '../helpers/test_database.dart';
import '../helpers/test_dependencies.dart';

const _narrow = Size(320, 640);
const _longTitle =
    'An Extraordinarily Long Title for a Book That Goes On and On';
const _longName = 'Books to read on long journeys by train';

/// Collects layout errors (overflows) instead of failing at the first, so
/// one run reports every problem with the step that caused it.
class LayoutErrors {
  LayoutErrors() {
    _previous = FlutterError.onError;
    FlutterError.onError = (details) {
      final location = RegExp(r'file:///[^\s]*?lib/[^\s]*')
          .firstMatch(details.toString())
          ?.group(0);
      errors.add(
        '$step: ${details.exceptionAsString().split('\n').first}'
        '${location == null ? '' : ' ($location)'}',
      );
    };
  }

  late final FlutterExceptionHandler? _previous;
  final errors = <String>[];
  var step = 'start';

  /// Restores the test framework's handler; call before the test ends.
  void stop() => FlutterError.onError = _previous;
}

void main() {
  late AppDependencies deps;
  late FakeDocumentPicker picker;
  late FakeFileOpener opener;
  late LayoutErrors layout;
  late bool pdfiumAvailable;

  setUpAll(() async {
    pdfiumAvailable = await initializePdfiumForTests();
  });

  setUp(() async {
    picker = FakeDocumentPicker();
    opener = FakeFileOpener();
    deps = await createTestDependencies(picker: picker, fileOpener: opener);
  });

  tearDown(() => disposeTestDependencies(deps));

  /// A widget test whose layout errors are collected and reported at the
  /// end (the test framework's error handler is always restored first).
  void layoutTest(
    String description,
    Future<void> Function(WidgetTester tester) body,
  ) {
    testWidgets(description, (tester) async {
      layout = LayoutErrors();
      try {
        await body(tester);
        await unmountApp(tester);
      } finally {
        layout.stop();
        printOnFailure('Layout errors:\n${layout.errors.join('\n')}');
      }
      expect(layout.errors, isEmpty);
    });
  }

  Future<void> start(WidgetTester tester, String location) =>
      pumpApp(tester, deps, location: location, size: _narrow, textScale: 2);

  /// Taps [finder] (scrolling it into view) and settles, as step [name].
  Future<void> tap(WidgetTester tester, Finder finder, String name) async {
    layout.step = name;
    if (finder.evaluate().isEmpty) {
      // Not built yet: further down a lazily built list.
      await tester.scrollUntilVisible(
        finder,
        200,
        scrollable: find.byType(Scrollable).first,
      );
    }
    await tester.ensureVisible(finder.first);
    await tester.pump();
    await tester.tap(finder.first);
    await settle(tester);
  }

  Future<void> back(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await settle(tester);
  }

  /// Closes open bottom sheets.
  Future<void> closeSheets(WidgetTester tester) async {
    for (
      var i = 0;
      i < 5 && find.byType(BottomSheet).evaluate().isNotEmpty;
      i++
    ) {
      await back(tester);
    }
  }

  /// Goes back until [finder] shows (closing sheets and screens).
  Future<void> backTo(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 5 && finder.evaluate().isEmpty; i++) {
      await back(tester);
    }
  }

  Future<int> addBooks() async {
    final long = await addTestDocument(
      deps.library,
      title: _longTitle,
      author: 'Someone With a Considerably Long Name',
    );
    final other = await addTestDocument(deps.library, title: 'Short');
    await deps.library.markOpened(long);
    await deps.library.setFavorite([long], favorite: true);
    await deps.library.setStatus([other], ReadingStatus.finished);
    final shelf = await deps.collections.createCollection(_longName);
    await deps.collections.addDocuments(shelf, [long, other]);
    return long;
  }

  layoutTest('library screens, sheets and dialogs', (tester) async {
    final long = await addBooks();
    await start(tester, Routes.home);

    layout.step = 'home';
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
    await settle(tester);

    await tap(tester, find.text('Library'), 'library grid');
    await tap(tester, find.byTooltip('Sort'), 'sort menu');
    await tap(tester, find.text('Title').last, 'sorted');
    await tap(tester, find.byTooltip('Show as list'), 'library list');
    await tap(tester, find.byTooltip('Search'), 'search');
    await tester.enterText(find.byType(TextField), 'extraordinarily');
    await tester.pump(const Duration(milliseconds: 300));
    await settle(tester);
    await back(tester);

    layout.step = 'selection';
    await tester.longPress(find.byKey(ValueKey(long)));
    await settle(tester);
    await tap(tester, find.byTooltip('More actions'), 'selection menu');
    await tap(tester, find.text('Remove from library…'), 'remove dialog');
    await tap(tester, find.text('Cancel'), 'remove cancelled');
    await tap(tester, find.byTooltip('Details'), 'details');
    await tap(tester, find.text('Add to collection'), 'collection picker');
    await tap(tester, find.text('New collection'), 'new collection dialog');
    await tester.enterText(find.byType(TextField), 'x' * 120);
    await settle(tester);
    await tap(tester, find.text('Cancel'), 'details again');
    await backTo(tester, find.text('Collections'));

    await tap(tester, find.text('Collections'), 'collections');
    await tap(tester, find.byTooltip('Options for $_longName'), 'options');
    await back(tester);
    await tap(tester, find.text(_longName), 'collection');
    await tap(tester, find.byTooltip('Collection options'), 'its options');
    await tap(tester, find.text('Rename collection'), 'rename dialog');
    await tap(tester, find.text('Cancel'), 'collection again');

    await tap(tester, find.text('Settings'), 'settings');
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -800));
    await settle(tester);

    opener.next = OpenedFile(
      name: 'backup.json',
      bytes: encodeBackup(
        ReadingBackup(
          createdAt: DateTime.utc(2026, 3, 1),
          settings: const {'reader.fontSize': '20'},
          documents: [
            for (var i = 0; i < 8; i++)
              BackupDocument(
                contentHash: i.toRadixString(16).padLeft(64, '0'),
                title: '$_longTitle, volume $i',
                favorite: true,
              ),
          ],
        ),
      ),
    );
    layout.step = 'restore confirmation';
    await tester.ensureVisible(find.text('Restore from backup'));
    await tester.pump();
    await tester.tap(find.text('Restore from backup'));
    await pumpUntil(
      tester,
      () => find.text('Restore reading data?').evaluate().isNotEmpty,
    );
    await settle(tester);
    layout.step = 'restore report';
    await tester.tap(find.text('Restore'));
    await pumpUntil(tester, () => find.text('OK').evaluate().isNotEmpty);
    await settle(tester);
    await tap(tester, find.text('OK'), 'settings after restore');

    opener.next = OpenedFile(name: 'x.json', bytes: utf8.encode('{}'));
    layout.step = 'restore problem';
    await tester.ensureVisible(find.text('Restore from backup'));
    await tester.pump();
    await tester.tap(find.text('Restore from backup'));
    await pumpUntil(tester, () => find.text('OK').evaluate().isNotEmpty);
    await settle(tester);
    await tap(tester, find.text('OK'), 'settings again');
  });

  layoutTest('import summary', (tester) async {
    final dir = deps.storage.temporaryDirectory..createSync(recursive: true);
    picker.next = [
      for (final (name, bytes) in [
        ('$_longTitle.txt', utf8.encode('Some text\n')),
        ('photo.txt', pngImage()),
        ('empty.txt', <int>[]),
      ])
        ImportSource(
          path: (File('${dir.path}/$name')..writeAsBytesSync(bytes)).path,
          displayName: name,
        ),
    ];
    await start(tester, Routes.home);
    layout.step = 'import';
    await tester.tap(find.byTooltip('Import documents'));
    await pumpUntil(
      tester,
      () => find.textContaining('photo.txt').evaluate().isNotEmpty,
    );
    await settle(tester);
  });

  ReaderCubit reader(WidgetTester tester) =>
      tester.element(find.byType(ReaderScreen)).read<ReaderCubit>();

  Future<void> open(WidgetTester tester, int id) async {
    await start(tester, Routes.library);
    layout.step = 'opening';
    await tester.tap(find.byKey(ValueKey(id)));
    await tester.pump();
    await pumpUntil(
      tester,
      () =>
          find.byType(ReaderScreen).evaluate().isNotEmpty &&
          reader(tester).state.position != null,
    );
    await settle(tester);
  }

  Future<void> showChrome(WidgetTester tester) async {
    if (reader(tester).state.chromeVisible) return;
    layout.step = 'toolbars';
    await tester.tapAt(_narrow.center(Offset.zero));
    // The PDF viewer waits to rule out a double tap.
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
    expect(reader(tester).state.chromeVisible, isTrue);
  }

  layoutTest('text reader, its sheets and dialogs', (tester) async {
    final id = await addTextFile(
      deps,
      content: numberedLines(400),
      title: _longTitle,
    );
    await deps.bookmarks.addBookmark(
      documentId: id,
      locator: TextLocator(lineOffset(3)),
      progress: 0.01,
      excerpt: 'Line 0003 and some more text that goes on',
    );
    await deps.annotations.addAnnotation(
      documentId: id,
      draft: AnnotationDraft(
        range: TextRangeAnchor(
          start: TextLocator(lineOffset(5)),
          end: TextLocator(lineOffset(6)),
        ),
        progress: 0.02,
        text: 'Line 0005',
      ),
      color: HighlightColor.green,
      note: 'A note long enough to need wrapping onto several lines here',
    );
    await open(tester, id);

    await showChrome(tester);
    await tap(tester, find.byTooltip('Reading settings'), 'reading settings');
    for (var i = 0; i < 12; i++) {
      await tap(tester, find.byTooltip('Larger text'), 'largest text');
    }
    await back(tester);
    await showChrome(tester);
    await tap(tester, find.byTooltip('Bookmarks'), 'bookmarks');
    await back(tester);
    await showChrome(tester);

    await tap(tester, find.byTooltip('Search in document'), 'search');
    await tester.enterText(find.byType(TextField), 'line 01');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    layout.step = 'search results';
    await pumpUntil(
      tester,
      () => find.textContaining('matches').evaluate().isNotEmpty,
    );
    await settle(tester);
    await back(tester);
    await showChrome(tester);

    await tap(tester, find.byTooltip('More options'), 'menu');
    await tap(tester, find.text('Highlights & notes'), 'highlights');
    await tap(tester, find.byTooltip('Edit highlight'), 'highlight sheet');
    await tap(tester, find.text('Edit note'), 'note editor');
    await tap(tester, find.text('Cancel'), 'highlight sheet again');
    await closeSheets(tester);

    await showChrome(tester);
    await tap(tester, find.byTooltip('More options'), 'menu again');
    await tap(tester, find.text('Document details'), 'details from reader');
    await back(tester);
  });

  layoutTest('selecting text shows its actions', (tester) async {
    final id = await addTextFile(deps, content: numberedLines(200));
    await open(tester, id);
    layout.step = 'selection';
    final gesture = await tester.startGesture(const Offset(60, 120));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await gesture.up();
    await settle(tester);
    expect(find.text('Copy'), findsOneWidget);
  });

  layoutTest('PDF reader, pages and contents', (tester) async {
    if (!pdfiumAvailable) {
      markTestSkipped('PDFium is not available');
      return;
    }
    final id = await addPdfFile(
      deps,
      bytes: textPdf(
        [for (var i = 1; i <= 12; i++) 'Page $i'],
        outline: [('A chapter with a long and winding title', 3)],
      ),
      title: _longTitle,
    );
    await open(tester, id);
    // The outline loads in the background.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    await showChrome(tester);
    await tap(tester, find.byTooltip('More options'), 'menu');
    await tap(tester, find.text('Contents'), 'contents');
    await back(tester);
    await showChrome(tester);
    await tap(tester, find.byTooltip('More options'), 'menu again');
    await tap(tester, find.text('Pages'), 'pages');
    layout.step = 'page thumbnails';
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await settle(tester);
    await back(tester);
    await showChrome(tester);
    await tap(tester, find.byTooltip('More options'), 'menu once more');
    await tap(tester, find.text('Go to page…'), 'go to page');
    await tap(tester, find.text('Cancel'), 'reader again');
  });

  layoutTest('PDF password', (tester) async {
    if (!pdfiumAvailable) {
      markTestSkipped('PDFium is not available');
      return;
    }
    final id = await addPdfFile(
      deps,
      bytes: File('test/fixtures/password_protected.pdf').readAsBytesSync(),
      title: _longTitle,
    );
    await start(tester, Routes.library);
    layout.step = 'password dialog';
    await tester.tap(find.byKey(ValueKey(id)));
    await tester.pump();
    await pumpUntil(
      tester,
      () => find.text('Password required').evaluate().isNotEmpty,
    );
    // The loading spinner behind the dialog never settles.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField), 'wrong');
    layout.step = 'password retry';
    await tester.tap(find.widgetWithText(FilledButton, 'Open'));
    await tester.pump();
    await pumpUntil(
      tester,
      () => find.text('Incorrect password').evaluate().isNotEmpty,
    );
    await tester.pump(const Duration(milliseconds: 300));
    layout.step = 'reader without password';
    await tester.tap(find.text('Cancel'));
    await tester.pump(const Duration(milliseconds: 300));
  });

  layoutTest('EPUB reader contents', (tester) async {
    final id = await addEpubFile(
      deps,
      bytes: readerEpub(
        chapters: novelChapters(3, paragraphs: 10),
        toc: [
          (
            'The first chapter, which has a very long title indeed',
            'ch1.xhtml',
          ),
          ('Two', 'ch2.xhtml'),
        ],
      ),
    );
    await open(tester, id);
    await showChrome(tester);
    await tap(tester, find.byTooltip('More options'), 'menu');
    await tap(tester, find.text('Contents'), 'contents');
    await back(tester);
  });

  testWidgets('the layout check notices an overflow', (tester) async {
    final errors = LayoutErrors()..step = 'too wide';
    try {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 100,
              child: Row(children: [SizedBox(width: 150, height: 10)]),
            ),
          ),
        ),
      );
    } finally {
      errors.stop();
    }
    expect(
      errors.errors.single,
      startsWith('too wide: A RenderFlex overflowed'),
    );
  });
}
