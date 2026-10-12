import 'dart:ui' show VoidCallback;

/// Lets other screens (e.g. Home) ask the library to open its search field.
///
/// The request is remembered until the library screen consumes it, because
/// the library tab may not have been built yet when it is made. This is a
/// one-shot signal, not observable state, so it deliberately isn't a
/// `Listenable` (nothing should rebuild because of it).
class LibrarySearchRequest {
  final Set<VoidCallback> _listeners = {};
  bool _pending = false;

  void addListener(VoidCallback listener) => _listeners.add(listener);

  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  void request() {
    _pending = true;
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  /// Returns whether a request was pending, clearing it.
  bool consume() {
    final pending = _pending;
    _pending = false;
    return pending;
  }
}
