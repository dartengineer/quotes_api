import 'dart:developer' as developer;

/// Minimal logging facade.
///
/// Privacy rule: never pass document contents, extracted text, notes, file
/// names or search queries to these methods. Log what failed, not what the
/// user was reading.
abstract final class AppLog {
  static const _name = 'lectern';

  static void info(String message) {
    developer.log(message, name: _name, level: 800);
  }

  static void error(String message, Object error, [StackTrace? stackTrace]) {
    developer.log(
      message,
      name: _name,
      level: 1000,
      error: error,
      stackTrace: stackTrace,
    );
  }
}
