/// Document formats the library can register.
///
/// The enum [name] is persisted in the database, so existing values must never
/// be renamed. Add new formats only once a reader for them exists and has been
/// tested.
enum DocumentFormat {
  pdf('PDF', 'pdf'),
  epub('EPUB', 'epub'),
  txt('TXT', 'txt');

  const DocumentFormat(this.label, this.extension);

  /// Short, user-visible label (e.g. on a cover badge).
  final String label;

  /// Canonical file extension, without the dot.
  final String extension;
}
