import '../data/database/app_database.dart';
import '../data/files/library_storage.dart';
import '../engines/pdf/pdf_inspector.dart';
import '../features/collections/data/collection_repository.dart';
import '../features/import/data/document_importer.dart';
import '../features/import/data/document_picker.dart';
import '../features/import/data/incoming_documents.dart';
import '../features/library/data/library_manager.dart';
import '../features/library/data/library_repository.dart';
import '../features/reader/data/bookmark_repository.dart';
import '../features/reader/data/reading_progress_repository.dart';
import '../features/settings/data/settings_repository.dart';

/// Long-lived services shared across the app, created once at start-up.
class AppDependencies {
  AppDependencies({
    required this.database,
    required this.storage,
    this.picker = const SystemDocumentPicker(),
    IncomingDocuments? incoming,
    this._pdfInspector = const PdfrxInspector(),
  }) : incoming =
           incoming ??
           IncomingDocuments(cacheDirectory: storage.temporaryDirectory),
       library = LibraryRepository(database),
       collections = CollectionRepository(database),
       settings = SettingsRepository(database),
       readingProgress = ReadingProgressRepository(database),
       bookmarks = BookmarkRepository(database);

  final AppDatabase database;
  final LibraryStorage storage;
  final DocumentPicker picker;
  final IncomingDocuments incoming;
  final LibraryRepository library;
  final CollectionRepository collections;
  final SettingsRepository settings;
  final ReadingProgressRepository readingProgress;
  final BookmarkRepository bookmarks;
  final PdfInspector _pdfInspector;

  late final DocumentImporter importer = DocumentImporter(
    library: library,
    storage: storage,
    pdfInspector: _pdfInspector,
  );

  late final LibraryManager manager = LibraryManager(
    library: library,
    storage: storage,
  );

  Future<void> dispose() => database.close();
}
