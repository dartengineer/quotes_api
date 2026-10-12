/// Thrown when an operation stops because its [CancellationToken] was
/// cancelled.
class CancelledException implements Exception {
  const CancelledException();

  @override
  String toString() => 'CancelledException';
}

/// Cooperative cancellation for long-running work.
class CancellationToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = [];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final listeners = List.of(_listeners);
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }

  void throwIfCancelled() {
    if (_cancelled) throw const CancelledException();
  }

  /// Runs [callback] when the token is cancelled (immediately if it already
  /// is). Returns a function that unregisters the callback.
  void Function() onCancel(void Function() callback) {
    if (_cancelled) {
      callback();
      return () {};
    }
    _listeners.add(callback);
    return () => _listeners.remove(callback);
  }
}
