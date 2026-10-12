import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/app/dependencies.dart';
import 'package:lectern/app/routes.dart';
import 'package:lectern/core/theme/reader_palette.dart';
import 'package:lectern/features/reader/domain/locator.dart';
import 'package:lectern/features/reader/presentation/reader_cubit.dart';
import 'package:lectern/features/reader/presentation/reader_screen.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/app_harness.dart';
import '../../helpers/fixtures.dart';
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

  EpubLocator? position(WidgetTester tester) =>
      reader(tester).state.position?.locator as EpubLocator?;

  Finder paragraph(int c, int p) =>
      find.text(novelParagraph(c, p), findRichText: true);

  double topOf(WidgetTester tester, Finder finder) =>
      tester.getTopLeft(finder).dy;

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
  }

  Future<void> showChrome(WidgetTester tester) async {
    if (!reader(tester).state.chromeVisible) {
      await tester.tapAt(const Offset(195, 422));
      await settle(tester);
    }
    expect(reader(tester).state.chromeVisible, isTrue);
  }

  Future<int> novel(
    WidgetTester tester, {
    int chapters = 3,
    List<(String, String)> toc = const [],
  }) => addEpubFile(
    deps,
    bytes: readerEpub(chapters: novelChapters(chapters), toc: toc),
  );

  testWidgets('restores the exact saved position in a later chapter', (
    tester,
  ) async {
    final id = await novel(tester);
    await deps.readingProgress.savePosition(
      id,
      EpubLocator(href: chapterPath(2), offset: novelOffset(2, 30)),
    );
    await open(tester, id);

    expect(topOf(tester, paragraph(2, 30)), closeTo(0, 1));
    expect(
      position(tester),
      EpubLocator(
        href: chapterPath(2),
        offset: novelOffset(2, 30),
        progression: position(tester)!.progression,
      ),
    );
    // Overall progress counts the whole first chapter.
    expect(reader(tester).state.position!.progress, inInclusiveRange(0.4, 0.6));
    await unmountApp(tester);
  });

  testWidgets('scrolling crosses chapters and is saved on close', (
    tester,
  ) async {
    final id = await novel(tester, chapters: 2);
    await deps.readingProgress.savePosition(
      id,
      EpubLocator(href: chapterPath(1), offset: novelOffset(1, 55)),
    );
    await open(tester, id);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -900));
    await settle(tester);
    final now = position(tester)!;
    expect(now.href, chapterPath(2));
    expect(
      find.textContaining('Chapter 2 paragraph', findRichText: true),
      findsWidgets,
    );

    await tester.binding.handlePopRoute();
    await settle(tester);
    final saved = await resolve(tester, deps.readingProgress.loadPosition(id));
    expect(saved, now);
    await unmountApp(tester);
  });

  testWidgets('larger text keeps the same paragraph at the top', (
    tester,
  ) async {
    final id = await novel(tester);
    await deps.readingProgress.savePosition(
      id,
      EpubLocator(href: chapterPath(3), offset: novelOffset(3, 20)),
    );
    await open(tester, id);
    await showChrome(tester);

    await tester.tap(find.byTooltip('Reading settings'));
    await settle(tester);
    // Reflowable: typography settings are offered.
    await tester.tap(find.byTooltip('Larger text'));
    await settle(tester);
    await tester.tap(find.byTooltip('Larger text'));
    await settle(tester);
    expect(topOf(tester, paragraph(3, 20)), closeTo(0, 1));
    expect(position(tester)!.offset, novelOffset(3, 20));
    await unmountApp(tester);
  });

  testWidgets('contents: lists entries, marks the current one, jumps', (
    tester,
  ) async {
    final id = await novel(
      tester,
      toc: [
        ('Chapter One', 'ch1.xhtml'),
        ('Middle of one', 'ch1.xhtml#c1p30'),
        ('Chapter Two', 'ch2.xhtml'),
        ('Chapter Three', 'ch3.xhtml#c3'),
      ],
    );
    await deps.readingProgress.savePosition(
      id,
      EpubLocator(href: chapterPath(1), offset: novelOffset(1, 40)),
    );
    await open(tester, id);
    await showChrome(tester);
    await tester.tap(find.byTooltip('More options'));
    await settle(tester);
    await tester.tap(find.text('Contents'));
    await settle(tester);

    final current = tester.widget<ListTile>(
      find.widgetWithText(ListTile, 'Middle of one'),
    );
    expect(current.selected, isTrue);

    await tester.tap(find.text('Chapter Two'));
    await settle(tester);
    expect(position(tester)!.href, chapterPath(2));
    expect(position(tester)!.offset, 0);
    expect(
      topOf(tester, find.text('Chapter 2', findRichText: true)),
      lessThan(200),
    );
    await unmountApp(tester);
  });

  testWidgets('links: footnotes jump inside the book; web links are shown', (
    tester,
  ) async {
    final id = await addEpubFile(
      deps,
      bytes: readerEpub(
        chapters: [
          '<p>See the <a href="ch2.xhtml#n1">note</a> or '
              '<a href="https://example.org/">site</a>.</p>'
              '${[for (var p = 0; p < 40; p++) '<p>Filler $p</p>'].join()}',
          '${[for (var p = 0; p < 40; p++) '<p>Before $p</p>'].join()}'
              '<p id="n1">The note itself.</p>',
        ],
      ),
    );
    await open(tester, id);

    final text = find.text('See the note or site.', findRichText: true);

    /// Taps the middle of [word] in the first paragraph.
    Future<void> tapWord(String word) async {
      final paragraph = tester.renderObject<RenderParagraph>(text);
      final start = 'See the note or site.'.indexOf(word);
      final box = paragraph
          .getBoxesForSelection(
            TextSelection(baseOffset: start, extentOffset: start + word.length),
          )
          .first;
      await tester.tapAt(paragraph.localToGlobal(box.toRect().center));
      await settle(tester);
    }

    await tapWord('site');
    expect(find.text('Link to a website'), findsOneWidget);
    expect(find.text('https://example.org/'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await settle(tester);
    expect(position(tester)!.href, chapterPath(1));

    await tapWord('note');
    expect(position(tester)!.href, chapterPath(2));
    expect(
      topOf(tester, find.text('The note itself.', findRichText: true)),
      lessThan(300),
    );
    // A tap on plain text is not a link: the middle of the page toggles the
    // toolbars instead.
    expect(reader(tester).state.chromeVisible, isFalse);

    await tester.binding.handlePopRoute();
    await settle(tester);
    await unmountApp(tester);
  });

  testWidgets('search across chapters jumps to the result', (tester) async {
    final id = await novel(tester);
    await open(tester, id);
    await showChrome(tester);

    await tester.tap(find.byTooltip('Search in document'));
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'chapter 3 paragraph 042');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await pumpUntil(tester, () => find.text('1 match').evaluate().isNotEmpty);
    await tester.tap(find.byType(ListTile).first);
    await settle(tester);

    expect(position(tester)!.href, chapterPath(3));
    expect(topOf(tester, paragraph(3, 42)), closeTo(0, 1));

    // The match is highlighted for a few seconds.
    bool highlighted() {
      final span = tester.widget<RichText>(paragraph(3, 42)).text as TextSpan;
      return span.children?.any(
            (child) =>
                child.style?.backgroundColor == ReaderPalette.paper.highlight,
          ) ??
          false;
    }

    expect(highlighted(), isTrue);
    await tester.pump(const Duration(seconds: 5));
    expect(highlighted(), isFalse);
    await unmountApp(tester);
  });

  testWidgets('book formatting is shown with the reader’s typography', (
    tester,
  ) async {
    final id = await addEpubFile(
      deps,
      bytes: readerEpub(
        chapters: [
          '<h2>A Heading</h2>'
              '<p>Some <em>emphasis</em> and <strong>weight</strong>.</p>'
              '<blockquote><p>A quotation.</p></blockquote>'
              '<ul><li>An item</li></ul><hr/>'
              '<p style="font-family: Comic Sans; color: red">Styled</p>',
        ],
      ),
    );
    await open(tester, id);

    TextSpan spanOf(String text) =>
        tester.widget<RichText>(find.text(text, findRichText: true)).text
            as TextSpan;

    final heading = spanOf('A Heading');
    expect(heading.style!.fontWeight, FontWeight.w700);
    expect(heading.style!.fontSize, greaterThan(18));

    final body = spanOf('Some emphasis and weight.');
    final styles = {
      for (final child in body.children!.cast<TextSpan>())
        child.text: child.style,
    };
    expect(styles['emphasis']!.fontStyle, FontStyle.italic);
    expect(styles['weight']!.fontWeight, FontWeight.w700);

    expect(find.text('• An item', findRichText: true), findsOneWidget);
    // The book's own fonts and colours are not used.
    expect(spanOf('Styled').style!.fontFamily, isNot('Comic Sans'));
    expect(spanOf('Styled').style!.color, ReaderPalette.paper.text);
    await unmountApp(tester);
  });

  testWidgets('bookmarks record the chapter position and its text', (
    tester,
  ) async {
    final id = await novel(tester);
    await deps.readingProgress.savePosition(
      id,
      EpubLocator(href: chapterPath(2), offset: novelOffset(2, 5)),
    );
    await open(tester, id);
    await showChrome(tester);

    await tester.tap(find.byTooltip('Add bookmark'));
    await settle(tester);
    final bookmark = reader(tester).state.bookmarks.single;
    expect((bookmark.locator as EpubLocator).href, chapterPath(2));
    expect(bookmark.excerpt, startsWith('Chapter 2 paragraph 005'));
    await unmountApp(tester);
  });

  testWidgets('images in the book are shown', (tester) async {
    final id = await addEpubFile(
      deps,
      bytes: readerEpub(
        chapters: [
          '<p>Before</p><p><img src="../images/pic.png" alt="A picture"/></p>'
              '<p>After</p>',
        ],
        images: {'images/pic.png': pngImage(width: 120, height: 80)},
      ),
    );
    await open(tester, id);
    await pumpUntil(
      tester,
      () => find.bySemanticsLabel('A picture').evaluate().isNotEmpty,
    );
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('After', findRichText: true), findsOneWidget);
    await unmountApp(tester);
  });

  testWidgets('a damaged book is explained', (tester) async {
    final id = await addEpubFile(deps, bytes: readerEpub(chapters: ['<div/>']));
    await pumpApp(tester, deps, location: Routes.library);
    await tester.tap(find.byKey(ValueKey(id)));
    await tester.pump();
    await pumpUntil(
      tester,
      () => find
          .text('This book can’t be opened. The file may be damaged.')
          .evaluate()
          .isNotEmpty,
    );
    await unmountApp(tester);
  });

  testWidgets('a missing library file is explained', (tester) async {
    final id = await addTestDocument(deps.library, title: 'Ghost');
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
