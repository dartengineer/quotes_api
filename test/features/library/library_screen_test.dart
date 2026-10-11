import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/core/theme/app_theme.dart';
import 'package:lectern/data/database/app_database.dart';
import 'package:lectern/features/library/data/library_repository.dart';
import 'package:lectern/features/library/domain/library_query.dart';
import 'package:lectern/features/library/domain/reading_status.dart';
import 'package:lectern/features/library/presentation/library_cubit.dart';
import 'package:lectern/features/library/presentation/library_screen.dart';
import 'package:lectern/features/settings/data/settings_repository.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late LibraryRepository library;
  late SettingsRepository settings;

  setUp(() {
    db = createTestDatabase();
    library = LibraryRepository(db, clock: FakeClock().call);
    settings = SettingsRepository(db);
  });

  Future<void> pumpLibrary(WidgetTester tester, {double textScale = 1}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: BlocProvider(
            create: (_) => LibraryCubit(library: library, settings: settings),
            child: const LibraryScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await db.close();
  }

  /// Top-to-bottom, left-to-right order of the given document tiles.
  List<int> visualOrder(WidgetTester tester, List<int> ids) {
    final sorted = [...ids]
      ..sort((a, b) {
        final pa = tester.getTopLeft(find.byKey(ValueKey(a)));
        final pb = tester.getTopLeft(find.byKey(ValueKey(b)));
        final byRow = pa.dy.compareTo(pb.dy);
        return byRow != 0 ? byRow : pa.dx.compareTo(pb.dx);
      });
    return sorted;
  }

  testWidgets('shows the empty state for an empty library', (tester) async {
    await pumpLibrary(tester);
    expect(find.text('No documents yet'), findsOneWidget);
    await dispose(tester);
  });

  testWidgets('lists documents and re-orders them when sorting', (
    tester,
  ) async {
    final b = await addTestDocument(library, title: 'Beta');
    final a = await addTestDocument(library, title: 'Alpha');
    final c = await addTestDocument(library, title: 'Charlie');

    await pumpLibrary(tester);
    expect(find.byKey(const Key('library-grid')), findsOneWidget);
    // Default: most recently added first.
    expect(visualOrder(tester, [a, b, c]), [c, a, b]);

    await tester.tap(find.byTooltip('Sort'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(CheckedPopupMenuItem<LibrarySort>, 'Title'),
    );
    await tester.pumpAndSettle();

    expect(visualOrder(tester, [a, b, c]), [a, b, c]);
    await dispose(tester);
  });

  testWidgets('switches between grid and list layouts', (tester) async {
    await addTestDocument(library, title: 'Only one');
    await pumpLibrary(tester);

    await tester.tap(find.byTooltip('Show as list'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('library-list')), findsOneWidget);
    expect(find.byKey(const Key('library-grid')), findsNothing);

    await tester.tap(find.byTooltip('Show as grid'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('library-grid')), findsOneWidget);
    await dispose(tester);
  });

  testWidgets('tiles do not overflow at large text sizes', (tester) async {
    await addTestDocument(
      library,
      title: 'A remarkably long title that will need to wrap and truncate',
      author: 'An Author With A Long Name',
    );
    await library.setStatus([
      await addTestDocument(library, title: 'Finished'),
    ], ReadingStatus.finished);

    for (final scale in [1.0, 2.0]) {
      await pumpLibrary(tester, textScale: scale);
      expect(tester.takeException(), isNull, reason: 'grid @ $scale');
      await tester.tap(find.byTooltip('Show as list'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'list @ $scale');
      await tester.tap(find.byTooltip('Show as grid'));
      await tester.pumpAndSettle();
    }
    await dispose(tester);
  });
}
