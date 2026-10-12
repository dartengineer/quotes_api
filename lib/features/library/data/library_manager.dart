import '../../../core/utils/app_log.dart';
import '../../../data/files/library_storage.dart';
import 'library_repository.dart';

/// Library operations that span the database and the library's files.
class LibraryManager {
  LibraryManager({required this._library, required this._storage});

  final LibraryRepository _library;
  final LibraryStorage _storage;

  /// Removes documents from the library together with their bookmarks,
  /// notes and the app's private copy of each file. The user's original
  /// files (outside the app) are never affected.
  ///
  /// Returns how many documents were removed.
  Future<int> removeDocuments(Iterable<int> ids) async {
    final removed = await _library.removeDocuments(ids);
    for (final document in removed) {
      try {
        await _storage.deleteDocumentFiles(
          filePath: document.filePath,
          coverPath: document.coverPath,
        );
      } catch (error, stackTrace) {
        // The database rows are gone; an orphaned file only costs space.
        AppLog.error('Deleting library files failed', error, stackTrace);
      }
    }
    return removed.length;
  }
}
