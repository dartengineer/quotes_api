import 'library_query.dart';
import 'reading_status.dart';

/// Quick filters offered as chips above the library.
enum LibraryFilter {
  all('All'),
  favorites('Favourites'),
  reading('Reading'),
  unread('Not started'),
  finished('Finished');

  const LibraryFilter(this.label);

  final String label;

  LibraryQuery applyTo(LibraryQuery query) => query.copyWith(
    favoritesOnly: this == LibraryFilter.favorites,
    status: () => switch (this) {
      LibraryFilter.reading => ReadingStatus.reading,
      LibraryFilter.unread => ReadingStatus.unread,
      LibraryFilter.finished => ReadingStatus.finished,
      LibraryFilter.all || LibraryFilter.favorites => null,
    },
  );

  static LibraryFilter of(LibraryQuery query) {
    if (query.favoritesOnly) return LibraryFilter.favorites;
    return switch (query.status) {
      null => LibraryFilter.all,
      ReadingStatus.reading => LibraryFilter.reading,
      ReadingStatus.unread => LibraryFilter.unread,
      ReadingStatus.finished => LibraryFilter.finished,
    };
  }
}
