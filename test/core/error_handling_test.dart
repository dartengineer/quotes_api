import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/core/utils/error_handling.dart';

void main() {
  test('uncaught errors are logged and handled', () {
    final previousFlutter = FlutterError.onError;
    final previousPlatform = PlatformDispatcher.instance.onError;
    addTearDown(() {
      FlutterError.onError = previousFlutter;
      PlatformDispatcher.instance.onError = previousPlatform;
    });
    // Keep the test framework's own handler out of the way.
    var forwarded = 0;
    FlutterError.onError = (_) => forwarded++;

    final logged = <(String, Object)>[];
    installErrorHandlers(
      log: (message, error, [stack]) {
        logged.add((message, error));
      },
    );

    FlutterError.onError!(FlutterErrorDetails(exception: StateError('boom')));
    expect(logged.single.$1, 'Uncaught framework error');
    expect(forwarded, 1, reason: 'debug builds keep the usual reporting');

    final handled = PlatformDispatcher.instance.onError!(
      const FormatException('bad'),
      StackTrace.empty,
    );
    expect(handled, isTrue);
    expect(logged.last.$1, 'Uncaught asynchronous error');
  });

  test('release builds log only the type of an error', () {
    final error = FileSystemLikeError('/storage/emulated/0/Private Book.pdf');
    expect(describeError(error, release: true), FileSystemLikeError);
    expect(describeError(error, release: false), same(error));
  });
}

class FileSystemLikeError implements Exception {
  FileSystemLikeError(this.path);

  final String path;
}
