import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/utils/app_log.dart';
import '../../collections/data/collection_repository.dart';
import '../../collections/domain/library_collection.dart';
import '../data/library_manager.dart';
import '../data/library_repository.dart';
import '../domain/library_document.dart';
import '../domain/reading_status.dart';

enum DetailsStatus { loading, ready, notFound, failure }

class DocumentDetailsState extends Equatable {
  const DocumentDetailsState({
    this.status = DetailsStatus.loading,
    this.document,
    this.details,
    this.memberOf = const [],
  });

  final DetailsStatus status;
  final LibraryDocument? document;
  final DocumentDetails? details;

  /// Collections containing the document, by name.
  final List<LibraryCollection> memberOf;

  DocumentDetailsState copyWith({
    DetailsStatus? status,
    LibraryDocument? document,
    DocumentDetails? details,
    List<LibraryCollection>? memberOf,
  }) {
    return DocumentDetailsState(
      status: status ?? this.status,
      document: document ?? this.document,
      details: details ?? this.details,
      memberOf: memberOf ?? this.memberOf,
    );
  }

  @override
  List<Object?> get props => [status, document, details, memberOf];
}

/// Shows and edits one document: favourite, reading status, collections and
/// removal.
class DocumentDetailsCubit extends Cubit<DocumentDetailsState> {
  DocumentDetailsCubit({
    required this.documentId,
    required this._library,
    required this._collections,
    required this._manager,
  }) : super(const DocumentDetailsState()) {
    _subscribe();
  }

  final int documentId;
  final LibraryRepository _library;
  final CollectionRepository _collections;
  final LibraryManager _manager;
  final List<StreamSubscription<Object?>> _subscriptions = [];

  List<LibraryCollection> _allCollections = const [];
  Set<int> _memberIds = const {};

  void _subscribe() {
    _subscriptions
      ..add(
        _library.watchDocument(documentId).listen((document) {
          if (document == null) {
            emit(state.copyWith(status: DetailsStatus.notFound));
          } else {
            emit(
              state.copyWith(status: DetailsStatus.ready, document: document),
            );
          }
        }, onError: _onError),
      )
      ..add(
        _collections.watchCollections().listen((all) {
          _allCollections = all;
          _emitMembership();
        }, onError: _onError),
      )
      ..add(
        _collections.watchCollectionIdsFor(documentId).listen((ids) {
          _memberIds = ids;
          _emitMembership();
        }, onError: _onError),
      );
    unawaited(_loadDetails());
  }

  Future<void> _loadDetails() async {
    try {
      final details = await _library.getDetails(documentId);
      if (!isClosed && details != null) emit(state.copyWith(details: details));
    } catch (error, stackTrace) {
      // Optional information; the screen works without it.
      AppLog.error('Loading document details failed', error, stackTrace);
    }
  }

  void _emitMembership() {
    emit(
      state.copyWith(
        memberOf: [
          for (final c in _allCollections)
            if (_memberIds.contains(c.id)) c,
        ],
      ),
    );
  }

  void _onError(Object error, StackTrace stackTrace) {
    AppLog.error('Watching document failed', error, stackTrace);
    if (state.status == DetailsStatus.loading) {
      emit(state.copyWith(status: DetailsStatus.failure));
    }
  }

  Future<void> toggleFavorite() async {
    final document = state.document;
    if (document == null) return;
    await _library.setFavorite([documentId], favorite: !document.isFavorite);
  }

  Future<void> setStatus(ReadingStatus status) =>
      _library.setStatus([documentId], status);

  Future<void> addToCollection(int collectionId) =>
      _collections.addDocuments(collectionId, [documentId]);

  Future<void> removeFromCollection(int collectionId) =>
      _collections.removeDocuments(collectionId, [documentId]);

  /// Removes the document from the library (the app's copy, bookmarks and
  /// notes). The user's original file is not affected.
  Future<void> removeFromLibrary() => _manager.removeDocuments([documentId]);

  @override
  Future<void> close() async {
    await Future.wait(_subscriptions.map((s) => s.cancel()));
    return super.close();
  }
}
