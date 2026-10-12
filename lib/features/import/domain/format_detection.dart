import '../../library/domain/document_format.dart';

/// The result of inspecting a file's contents.
sealed class FormatDetection {
  const FormatDetection();
}

/// A format the library can import and (eventually) read.
final class SupportedFormat extends FormatDetection {
  const SupportedFormat(this.format);

  final DocumentFormat format;

  @override
  bool operator ==(Object other) =>
      other is SupportedFormat && other.format == format;

  @override
  int get hashCode => format.hashCode;

  @override
  String toString() => 'SupportedFormat(${format.name})';
}

/// A recognised or unrecognised format that cannot be imported.
final class UnsupportedFormat extends FormatDetection {
  const UnsupportedFormat(this.description);

  /// User-facing name of what the file appears to be, e.g. "Word document".
  final String description;

  @override
  bool operator ==(Object other) =>
      other is UnsupportedFormat && other.description == description;

  @override
  int get hashCode => description.hashCode;

  @override
  String toString() => 'UnsupportedFormat($description)';
}

/// The file has no content.
final class EmptyFile extends FormatDetection {
  const EmptyFile();
}

/// The file is recognisably one of the supported formats but too damaged to
/// open (e.g. a cut-off EPUB whose archive directory is missing).
final class DamagedFile extends FormatDetection {
  const DamagedFile(this.format);

  final DocumentFormat format;

  @override
  bool operator ==(Object other) =>
      other is DamagedFile && other.format == format;

  @override
  int get hashCode => format.hashCode;

  @override
  String toString() => 'DamagedFile(${format.name})';
}
