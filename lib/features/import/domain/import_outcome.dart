import 'package:equatable/equatable.dart';

/// A file selected for import.
class ImportSource extends Equatable {
  const ImportSource({required this.path, required this.displayName});

  /// Readable local path (for picked files, usually a temporary copy).
  final String path;

  /// The name the user knows the file by.
  final String displayName;

  @override
  List<Object?> get props => [path, displayName];
}

enum RejectionReason {
  unsupportedFormat,
  emptyFile,
  damaged,
  drmProtected,
  fixedLayout,

  /// The app that shared the file did not let us read it.
  unreadable,

  /// Larger than the app accepts from other apps.
  tooLarge;

  String message({String? formatDescription}) => switch (this) {
    RejectionReason.unsupportedFormat =>
      formatDescription == null
          ? 'This type of file isn’t supported.'
          : 'Not supported: ${formatDescription.toLowerCase()}.',
    RejectionReason.emptyFile => 'The file is empty.',
    RejectionReason.damaged => 'The file appears to be damaged.',
    RejectionReason.drmProtected =>
      'This book is DRM-protected and can’t be opened.',
    RejectionReason.fixedLayout =>
      'Fixed-layout EPUBs (such as comics) aren’t supported yet.',
    RejectionReason.unreadable =>
      'The file couldn’t be read. The app it came from may not allow it.',
    RejectionReason.tooLarge => 'The file is too large (the limit is 1 GB).',
  };
}

/// What happened to one file.
sealed class ImportOutcome extends Equatable {
  const ImportOutcome(this.fileName);

  final String fileName;
}

final class ImportedOutcome extends ImportOutcome {
  const ImportedOutcome(
    super.fileName, {
    required this.documentId,
    required this.title,
    this.needsPassword = false,
  });

  final int documentId;
  final String title;

  /// The document is password-protected; it will ask for the password when
  /// opened.
  final bool needsPassword;

  @override
  List<Object?> get props => [fileName, documentId, title, needsPassword];
}

final class DuplicateOutcome extends ImportOutcome {
  const DuplicateOutcome(
    super.fileName, {
    required this.existingId,
    required this.existingTitle,
  });

  final int existingId;
  final String existingTitle;

  @override
  List<Object?> get props => [fileName, existingId, existingTitle];
}

final class RejectedOutcome extends ImportOutcome {
  const RejectedOutcome(super.fileName, this.reason, {this.formatDescription});

  final RejectionReason reason;
  final String? formatDescription;

  String get message => reason.message(formatDescription: formatDescription);

  @override
  List<Object?> get props => [fileName, reason, formatDescription];
}

/// An unexpected error (e.g. storage full). Details are logged, not shown.
final class FailedOutcome extends ImportOutcome {
  const FailedOutcome(super.fileName);

  @override
  List<Object?> get props => [fileName];
}

class ImportProgress extends Equatable {
  const ImportProgress({
    required this.completed,
    required this.total,
    this.currentFileName,
  });

  final int completed;
  final int total;
  final String? currentFileName;

  @override
  List<Object?> get props => [completed, total, currentFileName];
}

class ImportReport extends Equatable {
  const ImportReport({
    required this.outcomes,
    required this.total,
    required this.cancelled,
  });

  final List<ImportOutcome> outcomes;

  /// Number of files the user selected.
  final int total;

  /// The user stopped the import; files after the last outcome were skipped.
  final bool cancelled;

  List<ImportedOutcome> get imported =>
      outcomes.whereType<ImportedOutcome>().toList();
  List<DuplicateOutcome> get duplicates =>
      outcomes.whereType<DuplicateOutcome>().toList();

  /// Files that were not imported for a reason other than being duplicates.
  List<ImportOutcome> get problems => outcomes
      .where((o) => o is RejectedOutcome || o is FailedOutcome)
      .toList();
  int get skipped => total - outcomes.length;

  /// The library document to open when this import was for exactly one file
  /// that is now in the library (newly added or already there).
  int? get singleDocumentId {
    if (total != 1 || outcomes.length != 1) return null;
    return switch (outcomes.single) {
      ImportedOutcome(:final documentId) => documentId,
      DuplicateOutcome(:final existingId) => existingId,
      _ => null,
    };
  }

  @override
  List<Object?> get props => [outcomes, total, cancelled];
}
