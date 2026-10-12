import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/app/app.dart';
import 'package:lectern/app/dependencies.dart';
import 'package:lectern/features/settings/domain/app_settings.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_dependencies.dart';

void main() {
  late AppDependencies deps;

  setUp(() async {
    deps = await createTestDependencies();
  });

  tearDown(() => disposeTestDependencies(deps));

  /// Pumps the app on a phone-sized screen unless [size] says otherwise.
  Future<void> pumpApp(
    WidgetTester tester, {
    AppSettings settings = const AppSettings(),
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      LecternApp(dependencies: deps, initialSettings: settings),
    );
    await tester.pumpAndSettle();
  }

  Future<void> disposeApp(WidgetTester tester) async {
    // Unmount so cubits cancel their database streams before tearDown
    // closes the database.
    await tester.pumpWidget(const SizedBox.shrink());
  }

  testWidgets('starts on an empty home screen and switches tabs', (
    tester,
  ) async {
    await pumpApp(tester);

    expect(find.text('Welcome to Lectern'), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);

    expect(find.text('Import documents'), findsOneWidget);

    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();
    expect(find.text('No documents yet'), findsOneWidget);

    await tester.tap(find.text('Collections'));
    await tester.pumpAndSettle();
    expect(find.text('No collections yet'), findsOneWidget);

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Appearance'), findsOneWidget);

    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    expect(find.text('Welcome to Lectern'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('theme choice applies immediately and is persisted', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);

    final stored = await deps.settings.load();
    expect(stored.appSettings.themePreference, ThemePreference.dark);

    await disposeApp(tester);
  });

  testWidgets('uses a navigation rail on wide screens', (tester) async {
    await pumpApp(tester, size: const Size(1280, 800));
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);

    await disposeApp(tester);
  });
}
