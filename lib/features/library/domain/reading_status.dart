/// The user's reading state for a document.
///
/// The enum [name] is persisted in the database, so existing values must never
/// be renamed.
enum ReadingStatus {
  unread('Not started'),
  reading('Reading'),
  finished('Finished');

  const ReadingStatus(this.label);

  final String label;
}
