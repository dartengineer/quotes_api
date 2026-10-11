import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/app/app.dart';
import 'package:lectern/app/dependencies.dart';
import 'package:lectern/app/routes.dart';
import 'package:lectern/features/settings/domain/app_settings.dart';
import 'package:material_ui/material_ui.dart';

/// Pumps the whole app at [location] on a phone-sized screen.
Future<void> pumpApp(
  WidgetTester tester,
  AppDependencies deps, {
  String location = Routes.home,
  Size size = const Size(390, 844),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    LecternApp(
      dependencies: deps,
      initialSettings: const AppSettings(),
      initialLocation: location,
    ),
  );
  await tester.pumpAndSettle();
}

/// Unmounts the app so cubits cancel their streams before the database is
/// closed in tearDown.
Future<void> unmountApp(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
}

/// Lets real asynchronous work (isolates, file I/O) progress inside a widget
/// test until [done] returns true, pumping frames in between.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final stopwatch = Stopwatch()..start();
  while (!done()) {
    if (stopwatch.elapsed > timeout) {
      fail('Condition not met within $timeout');
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pump();
}

/// [WidgetTester.pumpAndSettle] with a short timeout, so an animation that
/// never ends (e.g. a stuck loading spinner) fails fast at the right line.
Future<void> settle(WidgetTester tester) => tester.pumpAndSettle(
  const Duration(milliseconds: 100),
  EnginePhase.sendSemanticsUpdate,
  const Duration(seconds: 10),
);

/// Awaits [future] inside a widget test by advancing fake time until it
/// completes. Direct database calls can queue behind stream re-queries that
/// wait on timers, which only fire when the fake clock moves.
Future<T> resolve<T>(WidgetTester tester, Future<T> future) async {
  late T value;
  Object? error;
  var done = false;
  unawaited(
    future.then(
      (v) {
        value = v;
        done = true;
      },
      onError: (Object e) {
        error = e;
        done = true;
      },
    ),
  );
  for (var i = 0; i < 200 && !done; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  if (!done) fail('Future did not complete');
  if (error case final e?) throw e;
  return value;
}
