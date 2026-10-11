import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:lectern/data/database/app_database.dart';
import 'package:lectern/features/library/data/library_repository.dart';
import 'package:lectern/features/library/domain/document_format.dart';
import 'package:lectern/features/library/domain/library_document.dart';

/// An in-memory database for tests.
///
/// Streams close synchronously so widget tests do not leave timers pending.
AppDatabase createTestDatabase() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  return AppDatabase(
    DatabaseConnection(
      NativeDatabase.memory(),
      closeStreamsSynchronously: true,
    ),
  );
}

/// A deterministic clock that advances one minute per call, so insertion
/// order is reflected in timestamps (which are stored at second precision).
class FakeClock {
  FakeClock([DateTime? start]) : _now = start ?? DateTime.utc(2026, 1, 1, 9);

  DateTime _now;

  DateTime call() {
    _now = _now.add(const Duration(minutes: 1));
    return _now;
  }
}

int _hashCounter = 0;

/// Adds a document with sensible defaults and returns its id.
Future<int> addTestDocument(
  LibraryRepository repository, {
  String title = 'Untitled',
  String? author,
  DocumentFormat format = DocumentFormat.epub,
  String? fileName,
  String? contentHash,
  int fileSize = 1024,
}) {
  final hash = contentHash ?? 'hash-${_hashCounter++}';
  final name = fileName ?? '$title.${format.extension}';
  return repository.addDocument(
    NewDocument(
      title: title,
      author: author,
      format: format,
      filePath: '$hash.${format.extension}',
      originalFileName: name,
      fileSize: fileSize,
      contentHash: hash,
    ),
  );
}
