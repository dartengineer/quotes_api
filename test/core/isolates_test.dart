import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/core/utils/cancellation.dart';
import 'package:lectern/core/utils/isolates.dart';

int _spinForever() {
  var x = 0;
  while (true) {
    x = (x + 1) % 1000;
  }
}

void main() {
  test('returns the computed value', () async {
    expect(await runInBackground(() => 6 * 7), 42);
    expect(
      await runInBackground(() => 6 * 7, cancellation: CancellationToken()),
      42,
    );
  });

  test('propagates errors', () async {
    await expectLater(
      runInBackground<int>(
        () => throw const FormatException('bad'),
        cancellation: CancellationToken(),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('cancelling kills a busy isolate promptly', () async {
    final token = CancellationToken();
    final future = runInBackground(_spinForever, cancellation: token);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final stopwatch = Stopwatch()..start();
    token.cancel();
    await expectLater(future, throwsA(isA<CancelledException>()));
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test('an already cancelled token fails fast', () async {
    final token = CancellationToken()..cancel();
    await expectLater(
      runInBackground(() => 1, cancellation: token),
      throwsA(isA<CancelledException>()),
    );
  });
}
