import 'package:equatable/equatable.dart';

import 'reading_status.dart';

/// Library orderings. Each has a natural direction (e.g. newest first).
///
/// The enum [name] is persisted as a preference, so values must not be renamed.
enum LibrarySort {
  recentlyOpened('Recently opened'),
  recentlyAdded('Recently added'),
  title('Title'),
  author('Author'),
  progress('Progress');

  const LibrarySort(this.label);

  final String label;
}

/// A library listing request: what to include and how to order it.
class LibraryQuery extends Equatable {
  const LibraryQuery({
    this.sort = LibrarySort.recentlyAdded,
    this.search = '',
    this.favoritesOnly = false,
    this.status,
    this.collectionId,
  });

  final LibrarySort sort;

  /// Free-text filter on title, author and file name.
  final String search;
  final bool favoritesOnly;
  final ReadingStatus? status;
  final int? collectionId;

  LibraryQuery copyWith({
    LibrarySort? sort,
    String? search,
    bool? favoritesOnly,
    ReadingStatus? Function()? status,
    int? Function()? collectionId,
  }) {
    return LibraryQuery(
      sort: sort ?? this.sort,
      search: search ?? this.search,
      favoritesOnly: favoritesOnly ?? this.favoritesOnly,
      status: status != null ? status() : this.status,
      collectionId: collectionId != null ? collectionId() : this.collectionId,
    );
  }

  @override
  List<Object?> get props => [
    sort,
    search,
    favoritesOnly,
    status,
    collectionId,
  ];
}
