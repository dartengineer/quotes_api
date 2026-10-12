import 'package:flutter/foundation.dart';

import 'app_log.dart';

/// Signature of [AppLog.error], for tests.
typedef ErrorLogger = void Function(
  String message,
  Object error, [
  StackTrace? stackTrace,
]);

/// Routes uncaught errors to the app log instead of crashing.
///
/// Error messages can carry user data (a file path, a passage a parser
/// choked on), so release builds log only the error's type and stack;
/// debug builds also keep Flutter's usual error reporting.
void installErrorHandlers({ErrorLogger log = AppLog.error}) {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    log(
      'Uncaught framework error',
      describeError(details.exception),
      details.stack,
    );
    if (!kReleaseMode) previous?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stackTrace) {
    log('Uncaught asynchronous error', describeError(error), stackTrace);
    // Handled: an unexpected error in a background task should not take the
    // app down with it.
    return true;
  };
}

/// What may be logged about [error]: in release builds, only its type.
Object describeError(Object error, {bool release = kReleaseMode}) =>
    release ? error.runtimeType : error;
