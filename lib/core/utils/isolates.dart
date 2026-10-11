import 'dart:async';
import 'dart:isolate';

import 'cancellation.dart';

/// Runs [computation] on a background isolate.
///
/// Without a [cancellation] token this is [Isolate.run]. With one, the
/// isolate is killed as soon as the token is cancelled and the returned
/// future fails with [CancelledException], so expensive work (hashing or
/// copying a large file) stops immediately rather than running to the end.
///
/// [computation] must only capture values that can be sent between isolates.
/// Create it in a small top-level function: a closure written inside a
/// method shares a context with the method's other closures and may capture
/// unsendable objects through them.
Future<R> runInBackground<R>(
  FutureOr<R> Function() computation, {
  CancellationToken? cancellation,
}) async {
  if (cancellation == null) return Isolate.run(computation);
  cancellation.throwIfCancelled();

  final port = RawReceivePort();
  final completer = Completer<R>();
  // Cancellation can fail the future before anyone awaits it (while the
  // isolate is still spawning); don't report that as an unhandled error.
  completer.future.ignore();
  Isolate? isolate;

  void finish() {
    port.close();
  }

  port.handler = (Object? message) {
    if (completer.isCompleted) return;
    switch (message) {
      case _Success(:final value):
        completer.complete(value as R);
      case _Failure(:final error, :final stackTrace):
        completer.completeError(error, stackTrace);
      default:
        // `null` is sent by the exit listener when the isolate dies without
        // reporting (e.g. it was killed).
        completer.completeError(
          cancellation.isCancelled
              ? const CancelledException()
              : StateError('Background isolate exited unexpectedly'),
        );
    }
    finish();
  };

  final unregister = cancellation.onCancel(() {
    isolate?.kill(priority: Isolate.immediate);
    if (!completer.isCompleted) {
      completer.completeError(const CancelledException());
      finish();
    }
  });

  try {
    isolate = await Isolate.spawn<_Request>(
      _entryPoint,
      _Request(port.sendPort, computation),
      onExit: port.sendPort,
      errorsAreFatal: true,
    );
    // The token may have been cancelled while the isolate was starting.
    if (cancellation.isCancelled) {
      isolate.kill(priority: Isolate.immediate);
    }
    return await completer.future;
  } catch (_) {
    if (!completer.isCompleted) finish();
    rethrow;
  } finally {
    unregister();
  }
}

class _Request {
  const _Request(this.reply, this.computation);

  final SendPort reply;
  final FutureOr<Object?> Function() computation;
}

final class _Success {
  const _Success(this.value);
  final Object? value;
}

final class _Failure {
  const _Failure(this.error, this.stackTrace);
  final Object error;
  final StackTrace stackTrace;
}

Future<void> _entryPoint(_Request request) async {
  Object message;
  try {
    message = _Success(await request.computation());
  } catch (error, stackTrace) {
    message = _Failure(error, stackTrace);
  }
  try {
    Isolate.exit(request.reply, message);
  } on ArgumentError {
    // The error object could not be sent; send a description instead.
    final failure = message as _Failure;
    Isolate.exit(
      request.reply,
      _Failure(
        RemoteError(failure.error.toString(), failure.stackTrace.toString()),
        StackTrace.empty,
      ),
    );
  }
}
