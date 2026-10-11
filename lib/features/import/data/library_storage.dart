import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/utils/cancellation.dart';
import '../../../core/utils/isolates.dart';
import '../../library/domain/document_format.dart';
import 'file_hashing.dart';

/// A file copied into the library's staging area, not yet committed.
class StagedFile {
  const StagedFile({
    required this.path,
    required this.sha256,
    required this.size,
  });

  final String path;
  final String sha256;
  final int size;
}

/// Owns the app-private library directory:
///
/// ```
/// <app support>/library/
///   files/<sha256>.<ext>    imported documents
///   covers/<sha256>.jpg     cover thumbnails
///   incoming/               staging area for imports in progress
/// ```
///
/// Paths stored in the database are relative to [root] and always use `/`.
///
/// Safety rule: a source file is only ever moved or deleted when it lies
/// inside [temporaryDirectory] (the app's own cache, where the system file
/// picker leaves its copies). The user's original files are never modified.
class LibraryStorage {
  LibraryStorage({required this.root, required this.temporaryDirectory});

  static Future<LibraryStorage> open() async {
    final support = await getApplicationSupportDirectory();
    final temporary = await getTemporaryDirectory();
    final storage = LibraryStorage(
      root: Directory(p.join(support.path, 'library')),
      temporaryDirectory: temporary,
    );
    await storage.ensureDirectories();
    return storage;
  }

  final Directory root;
  final Directory temporaryDirectory;
  final Random _random = Random();

  Directory get _files => Directory(p.join(root.path, 'files'));
  Directory get _covers => Directory(p.join(root.path, 'covers'));
  Directory get _incoming => Directory(p.join(root.path, 'incoming'));

  Future<void> ensureDirectories() async {
    for (final dir in [_files, _covers, _incoming]) {
      await dir.create(recursive: true);
    }
  }

  /// Resolves a database-relative path. Throws [ArgumentError] for paths
  /// that would escape the library directory.
  File resolve(String relativePath) {
    final resolved = p.normalize(p.join(root.path, relativePath));
    if (!p.isWithin(root.path, resolved)) {
      throw ArgumentError.value(
        relativePath,
        'relativePath',
        'outside library',
      );
    }
    return File(resolved);
  }

  /// Whether [path] is a temporary copy this app may move or delete.
  bool isDisposable(String path) {
    final source = p.normalize(File(path).absolute.path);
    return p.isWithin(p.normalize(temporaryDirectory.absolute.path), source);
  }

  /// Brings [sourcePath] into the staging area and hashes it.
  ///
  /// Temporary copies are hashed and then moved (no second copy); any other
  /// source is copied and hashed in a single pass, leaving it untouched.
  /// Work runs on a background isolate and stops immediately on
  /// [cancellation].
  Future<StagedFile> stage(
    String sourcePath, {
    CancellationToken? cancellation,
  }) async {
    final target = p.join(_incoming.path, '${_uniqueName()}.part');
    try {
      if (isDisposable(sourcePath)) {
        final hashed = await _hashInBackground(sourcePath, cancellation);
        await _move(File(sourcePath), File(target));
        return StagedFile(
          path: target,
          sha256: hashed.sha256,
          size: hashed.size,
        );
      }
      final hashed = await _copyAndHashInBackground(
        sourcePath,
        target,
        cancellation,
      );
      return StagedFile(path: target, sha256: hashed.sha256, size: hashed.size);
    } catch (_) {
      await _deleteQuietly(File(target));
      rethrow;
    }
  }

  /// Moves a staged file to its permanent location and returns the relative
  /// path to store. If identical content is already stored, the staged copy
  /// is discarded and the existing file is reused.
  Future<String> commit(StagedFile staged, DocumentFormat format) async {
    final relative = p.posix.join(
      'files',
      '${staged.sha256}.${format.extension}',
    );
    final destination = resolve(relative);
    if (await destination.exists()) {
      await _deleteQuietly(File(staged.path));
    } else {
      await _move(File(staged.path), destination);
    }
    return relative;
  }

  /// Writes a cover thumbnail atomically and returns its relative path.
  Future<String> saveCover(String sha256, Uint8List jpeg) async {
    final relative = p.posix.join('covers', '$sha256.jpg');
    final destination = resolve(relative);
    final temporary = File(p.join(_incoming.path, '${_uniqueName()}.jpg'));
    await temporary.writeAsBytes(jpeg, flush: true);
    await _move(temporary, destination);
    return relative;
  }

  /// Deletes the library's copy of a document and its cover. Missing files
  /// are ignored. Never touches anything outside the library directory.
  Future<void> deleteDocumentFiles({
    required String filePath,
    String? coverPath,
  }) async {
    await _deleteQuietly(resolve(filePath));
    if (coverPath != null) await _deleteQuietly(resolve(coverPath));
  }

  Future<void> discard(StagedFile staged) => _deleteQuietly(File(staged.path));

  /// Removes leftovers from imports interrupted by a crash or app kill.
  Future<void> clearStagingArea() async {
    if (!await _incoming.exists()) return;
    await for (final entity in _incoming.list()) {
      try {
        await entity.delete(recursive: true);
      } on FileSystemException {
        // Best effort.
      }
    }
  }

  Future<void> _move(File source, File destination) async {
    await destination.parent.create(recursive: true);
    try {
      await source.rename(destination.path);
    } on FileSystemException {
      // Different file systems: fall back to copy and delete.
      await source.copy(destination.path);
      await source.delete();
    }
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Already gone or not deletable; nothing more to do.
    }
  }

  String _uniqueName() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(1 << 32)}';
}

// Isolate closures are built in top-level functions so that they capture
// only their arguments (see DocumentImporter for the reasoning).

Future<HashedFile> _hashInBackground(
  String path,
  CancellationToken? cancellation,
) => runInBackground(() => hashFileSync(path), cancellation: cancellation);

Future<HashedFile> _copyAndHashInBackground(
  String source,
  String target,
  CancellationToken? cancellation,
) => runInBackground(
  () => copyAndHashSync(source, target),
  cancellation: cancellation,
);
