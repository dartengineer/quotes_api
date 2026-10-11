import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/app/dependencies.dart';
import 'package:lectern/app/routes.dart';
import 'package:lectern/features/library/domain/library_query.dart';
import 'package:lectern/features/library/domain/reading_status.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/app_harness.dart';
import '../../helpers/test_database.dart';
import '../../helpers/test_dependencies.dart';

void main() {
  late AppDependencies deps;

  setUp(() async {
    deps = await createTestDependencies();
  });

  tearDown(() => disposeTestDependencies(deps));

  /// Top-to-bottom, left-to-right order of the given document tiles.
  List<int> visualOrder(WidgetTester tester, List<int> ids) {
    return [...ids]..sort((a, b) {
      final pa = tester.getTopLeft(find.byKey(ValueKey(a)));
      final pb = tester.getTopLeft(find.byKey(ValueKey(b)));
      final byRow = pa.dy.compareTo(pb.dy);
      return byRow != 0 ? byRow : pa.dx.compareTo(pb.dx);
    });
  }

  testWidgets('re-orders documents when sorting', (tester) async {
    final b = await addTestDocument(deps.library, title: 'Beta');
    final a = await addTestDocument(deps.library, title: 'Alpha');
    final c = await addTestDocument(deps.library, title: 'Charlie');

    await pumpApp(tester, deps, location: Routes.library);
    expect(find.byKey(const Key('library-grid')), findsOneWidget);
    expect(visualOrder(tester, [a, b, c]), [c, a, b]);

    await tester.tap(find.byTooltip('Sort'));
    await settle(tester);
    await tester.tap(
      find.widgetWithText(CheckedPopupMenuItem<LibrarySort>, 'Title'),
    );
    await settle(tester);
    expect(visualOrder(tester, [a, b, c]), [a, b, c]);

    await unmountApp(tester);
  });

  testWidgets('switches between grid and list layouts', (tester) async {
    await addTestDocument(deps.library, title: 'Only one');
    await pumpApp(tester, deps, location: Routes.library);

    await tester.tap(find.byTooltip('Show as list'));
    await settle(tester);
    expect(find.byKey(const Key('library-list')), findsOneWidget);
    expect(find.byKey(const Key('library-grid')), findsNothing);

    await tester.tap(find.byTooltip('Show as grid'));
    await settle(tester);
    expect(find.byKey(const Key('library-grid')), findsOneWidget);

    await unmountApp(tester);
  });

  testWidgets('tiles do not overflow at large text sizes', (tester) async {
    final long = await addTestDocument(
      deps.library,
      title: 'A remarkably long title that will need to wrap and truncate',
      author: 'An Author With A Long Name',
    );
    final finished = await addTestDocument(deps.library, title: 'Finished');
    await deps.library.setStatus([finished], ReadingStatus.finished);
    await deps.library.setFavorite([long], favorite: true);

    await pumpApp(tester, deps, location: Routes.library, textScale: 2);
    expect(tester.takeException(), isNull, reason: 'grid');

    // Selection mode adds marks to tiles.
    await tester.longPress(find.byKey(ValueKey(long)));
    await settle(tester);
    expect(tester.takeException(), isNull, reason: 'grid, selecting');
    await tester.tap(find.byTooltip('Cancel selection'));
    await settle(tester);

    await tester.tap(find.byTooltip('Show as list'));
    await settle(tester);
    expect(tester.takeException(), isNull, reason: 'list');
    await tester.longPress(find.byKey(ValueKey(long)));
    await settle(tester);
    expect(tester.takeException(), isNull, reason: 'list, selecting');

    await unmountApp(tester);
  });
}
