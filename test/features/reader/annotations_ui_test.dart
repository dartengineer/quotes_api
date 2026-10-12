import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/app/dependencies.dart';
import 'package:lectern/app/routes.dart';
import 'package:lectern/features/reader/domain/annotation.dart';
import 'package:lectern/features/reader/domain/locator.dart';
import 'package:lectern/features/reader/presentation/reader_cubit.dart';
import 'package:lectern/features/reader/presentation/reader_screen.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/app_harness.dart';
import '../../helpers/fixtures.dart';
import '../../helpers/reader_fixtures.dart';
import '../../helpers/test_dependencies.dart';

void main() {
  late AppDependencies deps;
  late FakeFileSaver saver;

  setUp(() async {
    saver = FakeFileSaver();
    deps = await createTestDependencies(fileSaver: saver);
  });

  tearDown(() => disposeTestDependencies(deps));

  ReaderCubit reader(WidgetTester tester) =>
      tester.element(find.byType(ReaderScreen)).read<ReaderCubit>();

  List<Annotation> annotations(WidgetTester tester) =>
      reader(tester).state.annotations;

  Finder line(int n) =>
      find.text('Line ${n.toString().padLeft(4, '0')}', findRichText: true);

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

  /// The centre of [word] in the paragraph found by [finder].
  Offset wordCenter(WidgetTester tester, Finder finder, String word) {
    final paragraph = tester.renderObject<RenderParagraph>(finder);
    final text = paragraph.text.toPlainText();
    final start = text.indexOf(word);
    final box = paragraph
        .getBoxesForSelection(
          TextSelection(baseOffset: start, extentOffset: start + word.length),
        )
        .first;
    return paragraph.localToGlobal(box.toRect().center);
  }

  /// Long-presses at [from] and, if given, drags to [to] before lifting.
  Future<void> select(WidgetTester tester, Offset from, [Offset? to]) async {
    final gesture = await tester.startGesture(from);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    if (to != null) {
      await gesture.moveTo(to);
      await tester.pump();
    }
    await gesture.up();
    await settle(tester);
  }

  /// Whether the paragraph found by [finder] has text drawn on [color].
  bool painted(WidgetTester tester, Finder finder, Color color) {
    final span = tester.widget<RichText>(finder).text as TextSpan;
    return span.children?.any((c) => c.style?.backgroundColor == color) ??
        false;
  }

  Color highlightOf(HighlightColor color) =>
      Color(color.argb).withValues(alpha: 0.5);

  Future<int> textDocument() async {
    final id = await addTextFile(deps, content: numberedLines(200));
    await deps.readingProgress.savePosition(id, TextLocator(lineOffset(10)));
    return id;
  }

  testWidgets('long press highlights a word', (tester) async {
    final id = await textDocument();
    await open(tester, id);

    await select(tester, wordCenter(tester, line(12), '0012'));
    expect(find.text('Highlight'), findsOneWidget);
    expect(reader(tester).state.chromeVisible, isFalse);
    await tester.tap(find.byTooltip('Highlight yellow'));
    await settle(tester);

    final saved = annotations(tester).single;
    expect(saved.text, '0012');
    expect(saved.color, HighlightColor.yellow);
    expect(
      saved.range,
      TextRangeAnchor(
        start: TextLocator(lineOffset(12) + 5),
        end: TextLocator(lineOffset(12) + 9),
      ),
    );
    expect(
      painted(tester, line(12), highlightOf(HighlightColor.yellow)),
      isTrue,
    );
    await unmountApp(tester);
  });

  testWidgets('dragging selects across lines; a note can be added', (
    tester,
  ) async {
    final id = await textDocument();
    await open(tester, id);

    await select(
      tester,
      wordCenter(tester, line(12), 'Line'),
      wordCenter(tester, line(14), '0014'),
    );
    await tester.tap(find.text('Add note'));
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'Three lines here');
    await tester.tap(find.text('Save'));
    await settle(tester);

    final saved = annotations(tester).single;
    expect(saved.text, 'Line 0012\nLine 0013\nLine 0014');
    expect(saved.note, 'Three lines here');
    // Notes are marked with a dotted underline.
    final span = tester.widget<RichText>(line(13)).text as TextSpan;
    expect(
      span.children!.any(
        (c) => c.style?.decorationStyle == TextDecorationStyle.dotted,
      ),
      isTrue,
    );
    await unmountApp(tester);
  });

  testWidgets('tapping a highlight edits, deletes and undoes', (tester) async {
    final id = await textDocument();
    await open(tester, id);
    await select(tester, wordCenter(tester, line(12), '0012'));
    await tester.tap(find.byTooltip('Highlight yellow'));
    await settle(tester);

    await tester.tapAt(wordCenter(tester, line(12), '0012'));
    await settle(tester);
    expect(find.text('Edit note'), findsNothing);
    await tester.tap(find.byTooltip('Highlight blue'));
    await settle(tester);
    expect(annotations(tester).single.color, HighlightColor.blue);

    await tester.tap(find.text('Add note'));
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'A thought');
    await tester.tap(find.text('Save'));
    await settle(tester);
    expect(annotations(tester).single.note, 'A thought');
    expect(find.text('A thought'), findsOneWidget);

    await tester.tap(find.text('Delete'));
    await settle(tester);
    expect(annotations(tester), isEmpty);
    expect(
      painted(tester, line(12), highlightOf(HighlightColor.blue)),
      isFalse,
    );

    await tester.tap(find.text('Undo'));
    await settle(tester);
    final restored = annotations(tester).single;
    expect(restored.note, 'A thought');
    expect(restored.color, HighlightColor.blue);
    await unmountApp(tester);
  });

  testWidgets('copying a selection', (tester) async {
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard =
              (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final id = await textDocument();
    await open(tester, id);
    await select(tester, wordCenter(tester, line(15), '0015'));
    await tester.tap(find.text('Copy'));
    await settle(tester);
    expect(clipboard, '0015');
    expect(find.text('Copied'), findsOneWidget);
    expect(annotations(tester), isEmpty);
    await unmountApp(tester);
  });

  testWidgets('the list jumps to highlights and exports them', (tester) async {
    final id = await textDocument();
    await open(tester, id);
    await select(tester, wordCenter(tester, line(11), '0011'));
    await tester.tap(find.byTooltip('Highlight green'));
    await settle(tester);

    // Move away, then come back through the list.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
    await settle(tester);
    expect(line(11), findsNothing);

    await tester.tapAt(const Offset(195, 422));
    await settle(tester);
    await tester.tap(find.byTooltip('More options'));
    await settle(tester);
    await tester.tap(find.text('Highlights & notes'));
    await settle(tester);
    expect(find.text('0011'), findsOneWidget);

    await tester.tap(find.byTooltip('Export'));
    await settle(tester);
    expect(find.text('Highlights exported'), findsOneWidget);
    final (name, bytes, mime) = saver.saved.single;
    expect(name, 'Numbers - highlights.md');
    expect(mime, 'text/markdown');
    expect(utf8.decode(bytes), contains('# Numbers'));
    expect(utf8.decode(bytes), contains('> 0011'));

    await tester.tap(find.text('0011'));
    await settle(tester);
    expect(line(11), findsOneWidget);
    expect(tester.getTopLeft(line(11)).dy, closeTo(0, 1));
    await unmountApp(tester);
  });

  testWidgets('EPUB highlights are kept when the book is reopened', (
    tester,
  ) async {
    final id = await addEpubFile(
      deps,
      bytes: readerEpub(chapters: novelChapters(2, paragraphs: 20)),
    );
    await open(tester, id);
    final paragraph = find.text(novelParagraph(1, 3), findRichText: true);
    await select(
      tester,
      wordCenter(tester, paragraph, 'paragraph'),
      wordCenter(tester, paragraph, '003'),
    );
    await tester.tap(find.byTooltip('Highlight pink'));
    await settle(tester);
    expect(annotations(tester).single.text, 'paragraph 003');

    await tester.binding.handlePopRoute();
    await settle(tester);
    await tester.tap(find.byKey(ValueKey(id)));
    await tester.pump();
    await pumpUntil(
      tester,
      () =>
          find.byType(ReaderScreen).evaluate().isNotEmpty &&
          reader(tester).state.annotations.isNotEmpty &&
          find
              .text(novelParagraph(1, 3), findRichText: true)
              .evaluate()
              .isNotEmpty,
    );
    await settle(tester);
    expect(
      painted(
        tester,
        find.text(novelParagraph(1, 3), findRichText: true),
        highlightOf(HighlightColor.pink),
      ),
      isTrue,
    );
    await unmountApp(tester);
  });
}
