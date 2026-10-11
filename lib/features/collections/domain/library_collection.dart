import 'package:equatable/equatable.dart';

/// A user-defined group of documents.
class LibraryCollection extends Equatable {
  const LibraryCollection({
    required this.id,
    required this.name,
    required this.documentCount,
    required this.createdAt,
  });

  final int id;
  final String name;
  final int documentCount;
  final DateTime createdAt;

  @override
  List<Object?> get props => [id, name, documentCount, createdAt];
}

enum CollectionNameProblem { empty, tooLong, duplicate }

/// Thrown when a collection name is rejected.
class InvalidCollectionNameException implements Exception {
  const InvalidCollectionNameException(this.problem);

  final CollectionNameProblem problem;

  String get message => switch (problem) {
    CollectionNameProblem.empty => 'Enter a name for the collection.',
    CollectionNameProblem.tooLong => 'That name is too long.',
    CollectionNameProblem.duplicate => 'A collection with that name exists.',
  };

  @override
  String toString() => 'InvalidCollectionNameException($problem)';
}
