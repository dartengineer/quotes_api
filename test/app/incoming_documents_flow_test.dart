import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/app/dependencies.dart';
import 'package:lectern/app/routes.dart';
import 'package:lectern/features/import/data/incoming_documents.dart';
import 'package:lectern/features/reader/presentation/reader_cubit.dart';
import 'package:lectern/features/reader/presentation/reader_screen.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import '../helpers/app_harness.dart';
import '../helpers/fixtures.dart';
import '../helpers/reader_fixtures.dart';
import '../helpers/test_dependencies.dart';

/// Documents arriving from other apps, delivered over the platform channel
/// exactly as the Android activity sends them.
void main() {
  late AppDependencies deps;

  setUp(() async {
    deps = await createTestDependencies();
  });

  tearDown(() => disposeTestDependencies(deps));

  var copies = 0;

  /// A received copy, where the Android activity leaves it.
  File receivedCopy(String name, String content) {
    final directory = Directory(
      p.join(deps.storage.temporaryDirectory.path, 'incoming', 'r${copies++}'),
    )..createSync(recursive: true);
    return File(p.join(directory.path, name))..writeAsStringSync(content);
  }

  File receivedCopyBytes(String name, List<int> bytes) {
    final directory = Directory(
      p.join(deps.storage.temporaryDirectory.path, 'incoming', 'r${copies++}'),
    )..createSync(recursive: true);
    return File(p.join(directory.path, name))..writeAsBytesSync(bytes);
  }

  Future<void> receive(
    WidgetTester tester, {
    required String action,
    required File copy,
  }) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      IncomingDocuments.channelName,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('documentsReceived', [
          {'action': action, 'name': p.basename(copy.path), 'path': copy.path},
        ]),
      ),
      (_) {},
    );
  }

  /// The state of the topmost reader (two are on stage while one opens
  /// above another).
  ReaderState? readerState(WidgetTester tester) {
    final screens = find.byType(ReaderScreen);
    if (screens.evaluate().isEmpty) return null;
    return tester.element(screens.last).read<ReaderCubit>().state;
  }

  bool showsReaderFor(WidgetTester tester, String title) {
    final state = readerState(tester);
    return state?.document?.title == title && state?.position != null;
  }

  testWidgets('"Open with" imports the document and opens it', (tester) async {
    await pumpApp(tester, deps);
    final copy = receivedCopy('Field notes.txt', numberedLines(50));

    await receive(tester, action: 'open', copy: copy);
    await pumpUntil(tester, () => showsReaderFor(tester, 'Field notes'));
    await settle(tester);

    expect(find.text('Line 0000', findRichText: true), findsOneWidget);
    // The temporary copy is cleaned up once imported.
    await pumpUntil(tester, () => !copy.parent.existsSync());

    // Back leads to the library, not to an import summary.
    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(find.byType(ReaderScreen), findsNothing);
    expect(find.text('Import finished'), findsNothing);

    await unmountApp(tester);
  });

  testWidgets('"Open with" a PDF opens it in the PDF reader', (tester) async {
    final pdfium = await tester.runAsync(initializePdfiumForTests);
    if (pdfium != true) return markTestSkipped('PDFium not available');
    await pumpApp(tester, deps);
    final copy = receivedCopyBytes('Report.pdf', textPdf(pagedText(4)));

    await receive(tester, action: 'open', copy: copy);
    await pumpUntil(tester, () => showsReaderFor(tester, 'Report'));
    await settle(tester);
    expect(find.byType(PdfViewer), findsOneWidget);
    expect(readerState(tester)!.position!.pageCount, 4);
    await unmountApp(tester);
  });

  testWidgets('a document shared while reading: Done keeps the book open; '
      'Open shows the new one', (tester) async {
    final id = await addTextFile(
      deps,
      title: 'Current book',
      content: numberedLines(100),
    );
    await pumpApp(tester, deps, location: Routes.library);
    await tester.tap(find.byKey(ValueKey(id)));
    await tester.pump();
    await pumpUntil(tester, () => showsReaderFor(tester, 'Current book'));
    await settle(tester);

    // Shared from another app: a summary, not a jump away from the book.
    await receive(
      tester,
      action: 'share',
      copy: receivedCopy('Shared.txt', 'Shared text'),
    );
    await pumpUntil(
      tester,
      () => find.text('Import finished').evaluate().isNotEmpty,
    );
    await settle(tester);
    expect(find.text('1 document added'), findsOneWidget);

    await tester.tap(find.text('Done'));
    await settle(tester);
    expect(find.text('Import finished'), findsNothing);
    expect(showsReaderFor(tester, 'Current book'), isTrue);

    // Sharing it again finds it in the library and offers to open it.
    await receive(
      tester,
      action: 'share',
      copy: receivedCopy('Shared copy.txt', 'Shared text'),
    );
    await pumpUntil(
      tester,
      () => find.text('Import finished').evaluate().isNotEmpty,
    );
    await settle(tester);
    expect(find.text('1 document already in your library'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Open'));
    await tester.pump();
    await pumpUntil(tester, () => showsReaderFor(tester, 'Shared'));
    await settle(tester);
    expect(find.text('Shared text', findRichText: true), findsOneWidget);

    // Back returns to the book that was open before.
    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(showsReaderFor(tester, 'Current book'), isTrue);

    await unmountApp(tester);
  });

  testWidgets('documents that could not be received are explained', (
    tester,
  ) async {
    await pumpApp(tester, deps);
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      IncomingDocuments.channelName,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('documentsReceived', [
          {'action': 'open', 'name': 'Locked.pdf', 'error': 'unreadable'},
        ]),
      ),
      (_) {},
    );
    await pumpUntil(
      tester,
      () => find.text('Import finished').evaluate().isNotEmpty,
    );
    await settle(tester);
    expect(find.text('1 file not imported'), findsOneWidget);
    expect(find.text('Locked.pdf'), findsOneWidget);
    expect(find.textContaining('couldn’t be read'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Open'), findsNothing);

    await tester.tap(find.text('Done'));
    await settle(tester);
    expect(find.text('Import finished'), findsNothing);

    await unmountApp(tester);
  });
}
