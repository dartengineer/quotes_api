import 'dart:isolate';
import 'dart:typed_data';

import '../../../core/images/thumbnail_encoder.dart';
import '../../../core/utils/app_log.dart';
import '../../../core/utils/cancellation.dart';
import '../../../core/utils/isolates.dart';
import '../../../core/utils/text_cleanup.dart';
import '../../../data/files/library_storage.dart';
import '../../../engines/epub/epub_package.dart';
import '../../../engines/pdf/pdf_inspector.dart';
import '../../../engines/txt/text_document.dart';
import '../../library/data/library_repository.dart';
import '../../library/domain/document_format.dart';
import '../../library/domain/library_document.dart';
import '../domain/format_detection.dart';
import '../domain/import_outcome.dart';
import 'epub_import_reader.dart';
import 'format_detector.dart';

/// Imports files into the library, one at a time:
///
/// 1. detect the format from the contents;
/// 2. stage the file in app storage while hashing it (background isolate);
/// 3. skip it if identical content is already in the library;
/// 4. extract metadata and a cover thumbnail;
/// 5. move it to its permanent place and register it in the database.
///
/// A failure in one file never affects the others. Originals are never
/// modified (see [LibraryStorage]).
class DocumentImporter {
  DocumentImporter({
    required this._library,
    required this._storage,
    this._pdfInspector = const PdfrxInspector(),
    this._thumbnails = const ThumbnailEncoder(),
  });

  final LibraryRepository _library;
  final LibraryStorage _storage;
  final PdfInspector _pdfInspector;
  final ThumbnailEncoder _thumbnails;

  /// Imports [sources] in order, reporting progress before each file.
  /// Cancelling stops the file in progress and skips the rest.
  Future<ImportReport> importAll(
    List<ImportSource> sources, {
    CancellationToken? cancellation,
    void Function(ImportProgress progress)? onProgress,
  }) async {
    final outcomes = <ImportOutcome>[];
    for (final source in sources) {
      if (cancellation?.isCancelled ?? false) break;
      onProgress?.call(
        ImportProgress(
          completed: outcomes.length,
          total: sources.length,
          currentFileName: source.displayName,
        ),
      );
      try {
        outcomes.add(await importFile(source, cancellation: cancellation));
      } on CancelledException {
        break;
      }
    }
    onProgress?.call(
      ImportProgress(completed: outcomes.length, total: sources.length),
    );
    return ImportReport(
      outcomes: outcomes,
      total: sources.length,
      cancelled: cancellation?.isCancelled ?? false,
    );
  }

  /// Imports one file. Throws only [CancelledException]; every other problem
  /// is reported as an [ImportOutcome].
  Future<ImportOutcome> importFile(
    ImportSource source, {
    CancellationToken? cancellation,
  }) async {
    final name = source.displayName;
    try {
      final path = source.path;
      final detection = await _detectInBackground(path, cancellation);
      final format = switch (detection) {
        SupportedFormat(:final format) => format,
        UnsupportedFormat(:final description) => throw _Rejection(
          RejectionReason.unsupportedFormat,
          formatDescription: description,
        ),
        EmptyFile() => throw const _Rejection(RejectionReason.emptyFile),
        DamagedFile() => throw const _Rejection(RejectionReason.damaged),
      };

      final staged = await _storage.stage(path, cancellation: cancellation);
      var committed = false;
      try {
        final existing = await _library.findByHash(staged.sha256);
        if (existing != null) {
          return DuplicateOutcome(
            name,
            existingId: existing.id,
            existingTitle: existing.title,
          );
        }

        // The text reader holds the whole text in memory, so it has a
        // limit; there is no point importing what it could never open.
        if (format == DocumentFormat.txt &&
            staged.size > TextDocument.maxFileBytes) {
          throw const _Rejection(RejectionReason.textTooLarge);
        }
        final metadata = await _extractMetadata(format, staged.path, name);
        cancellation?.throwIfCancelled();

        final filePath = await _storage.commit(staged, format);
        committed = true;
        final coverPath = await _saveCover(staged.sha256, metadata.thumbnail);

        try {
          final id = await _library.addDocument(
            NewDocument(
              title: metadata.title,
              author: metadata.author,
              format: format,
              filePath: filePath,
              originalFileName: name,
              fileSize: staged.size,
              contentHash: staged.sha256,
              pageCount: metadata.pageCount,
              coverPath: coverPath,
              language: metadata.language,
              publisher: metadata.publisher,
              description: metadata.description,
            ),
          );
          return ImportedOutcome(
            name,
            documentId: id,
            title: metadata.title,
            needsPassword: metadata.needsPassword,
          );
        } catch (_) {
          // Another import of the same content may have won the race; its
          // row now owns the (identical) files, so keep them.
          final raced = await _library.findByHash(staged.sha256);
          if (raced != null) {
            return DuplicateOutcome(
              name,
              existingId: raced.id,
              existingTitle: raced.title,
            );
          }
          await _storage.deleteDocumentFiles(
            filePath: filePath,
            coverPath: coverPath,
          );
          rethrow;
        }
      } finally {
        if (!committed) await _storage.discard(staged);
      }
    } on CancelledException {
      rethrow;
    } on _Rejection catch (rejection) {
      return RejectedOutcome(
        name,
        rejection.reason,
        formatDescription: rejection.formatDescription,
      );
    } catch (error, stackTrace) {
      // File names are user data; log only the failure itself.
      AppLog.error('Import of a file failed', error, stackTrace);
      return FailedOutcome(name);
    }
  }

  Future<_Metadata> _extractMetadata(
    DocumentFormat format,
    String path,
    String fileName,
  ) async {
    switch (format) {
      case DocumentFormat.pdf:
        final PdfInspection info;
        try {
          info = await _pdfInspector.inspect(path);
        } on PdfUnreadableException {
          throw const _Rejection(RejectionReason.damaged);
        }
        return _Metadata(
          title: titleFromFileName(fileName),
          pageCount: info.pageCount,
          needsPassword: info.isPasswordProtected,
          thumbnail: info.firstPage == null
              ? null
              : await _optional(
                  () => _thumbnails.encodePixels(info.firstPage!),
                ),
        );

      case DocumentFormat.epub:
        final EpubImportInfo info;
        try {
          info = await _readEpubInBackground(path);
        } on EpubException catch (error) {
          throw _Rejection(switch (error.problem) {
            EpubProblem.drmProtected => RejectionReason.drmProtected,
            EpubProblem.damaged => RejectionReason.damaged,
          });
        }
        if (info.isFixedLayout) {
          throw const _Rejection(RejectionReason.fixedLayout);
        }
        final meta = info.metadata;
        final cover = info.coverBytes;
        return _Metadata(
          title: meta.title ?? titleFromFileName(fileName),
          author: formatAuthors(meta.authors),
          language: meta.language,
          publisher: meta.publisher,
          description: meta.description,
          thumbnail: cover == null
              ? null
              : await _optional(() => _thumbnails.fromEncodedImage(cover)),
        );

      case DocumentFormat.txt:
        return _Metadata(title: titleFromFileName(fileName));
    }
  }

  Future<String?> _saveCover(String sha256, Uint8List? thumbnail) async {
    if (thumbnail == null) return null;
    return _optional(() => _storage.saveCover(sha256, thumbnail));
  }

  /// Runs an optional step (covers), logging and swallowing failures.
  Future<T?> _optional<T>(Future<T?> Function() step) async {
    try {
      return await step();
    } catch (error, stackTrace) {
      AppLog.error('Optional import step failed', error, stackTrace);
      return null;
    }
  }
}

// Closures sent to isolates are created in these top-level functions so they
// capture only the path. A closure created inside a method shares its scope's
// context with every other closure there, and could drag along objects that
// cannot cross isolates (such as the database connection).

Future<FormatDetection> _detectInBackground(
  String path,
  CancellationToken? cancellation,
) => runInBackground(
  () => FormatDetector.detectFile(path),
  cancellation: cancellation,
);

Future<EpubImportInfo> _readEpubInBackground(String path) =>
    Isolate.run(() => readEpubImportInfo(path));

/// Joins author names for display, abbreviating long lists.
String? formatAuthors(List<String> authors) {
  if (authors.isEmpty) return null;
  final shown = authors.take(3).join(', ');
  final joined = authors.length > 3 ? '$shown et al.' : shown;
  return cleanMetadataText(joined);
}

class _Metadata {
  const _Metadata({
    required this.title,
    this.author,
    this.language,
    this.publisher,
    this.description,
    this.pageCount,
    this.thumbnail,
    this.needsPassword = false,
  });

  final String title;
  final String? author;
  final String? language;
  final String? publisher;
  final String? description;
  final int? pageCount;
  final Uint8List? thumbnail;
  final bool needsPassword;
}

class _Rejection implements Exception {
  const _Rejection(this.reason, {this.formatDescription});

  final RejectionReason reason;
  final String? formatDescription;
}
