import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/core/theme/app_theme.dart';
import 'package:lectern/data/database/app_database.dart';
import 'package:lectern/features/home/presentation/home_cubit.dart';
import 'package:lectern/features/home/presentation/home_screen.dart';
import 'package:lectern/features/library/data/library_repository.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late LibraryRepository library;

  setUp(() {
    db = createTestDatabase();
    library = LibraryRepository(db, clock: FakeClock().call);
  });

  Future<void> pumpHome(WidgetTester tester, {double textScale = 1}) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(360, 740),
            textScaler: TextScaler.linear(textScale),
          ),
          child: BlocProvider(
            create: (_) => HomeCubit(library),
            child: const HomeScreen(),
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

  testWidgets('shows sections for a library in progress', (tester) async {
    final current = await addTestDocument(
      library,
      title: 'The Current Book',
      author: 'Someone',
    );
    await addTestDocument(library, title: 'Something New');
    await library.markOpened(current);

    await pumpHome(tester);

    expect(find.text('Continue reading'), findsOneWidget);
    expect(find.text('Recently opened'), findsOneWidget);
    expect(find.text('Recently added'), findsOneWidget);
    expect(find.text('0% read'), findsOneWidget);
    await dispose(tester);
  });

  testWidgets('does not overflow at large text sizes', (tester) async {
    for (var i = 0; i < 4; i++) {
      final id = await addTestDocument(
        library,
        title: 'A fairly long book title number $i that wraps',
        author: 'Author $i',
      );
      await library.markOpened(id);
    }

    await pumpHome(tester, textScale: 2);
    expect(tester.takeException(), isNull);

    await tester.drag(find.byType(ListView).first, const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await dispose(tester);
  });
}
