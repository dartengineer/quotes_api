import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/utils/app_log.dart';
import '../../../core/utils/load_status.dart';
import '../data/collection_repository.dart';
import '../domain/library_collection.dart';

class CollectionsState extends Equatable {
  const CollectionsState({
    this.status = LoadStatus.loading,
    this.collections = const [],
  });

  final LoadStatus status;
  final List<LibraryCollection> collections;

  @override
  List<Object?> get props => [status, collections];
}

/// The result of creating or renaming a collection: the collection id on
/// success, or a user-facing error message.
typedef CollectionEditResult = ({int? id, String? error});

/// Lists collections and edits them.
class CollectionsCubit extends Cubit<CollectionsState> {
  CollectionsCubit(this._collections) : super(const CollectionsState()) {
    _subscribe();
  }

  final CollectionRepository _collections;
  StreamSubscription<List<LibraryCollection>>? _subscription;

  void _subscribe() {
    unawaited(_subscription?.cancel());
    _subscription = _collections.watchCollections().listen(
      (collections) => emit(
        CollectionsState(status: LoadStatus.ready, collections: collections),
      ),
      onError: (Object error, StackTrace stackTrace) {
        AppLog.error('Watching collections failed', error, stackTrace);
        emit(
          CollectionsState(
            status: LoadStatus.failure,
            collections: state.collections,
          ),
        );
      },
    );
  }

  void retry() {
    emit(CollectionsState(collections: state.collections));
    _subscribe();
  }

  Future<CollectionEditResult> create(String name) async {
    try {
      return (id: await _collections.createCollection(name), error: null);
    } on InvalidCollectionNameException catch (e) {
      return (id: null, error: e.message);
    }
  }

  Future<CollectionEditResult> rename(int id, String name) async {
    try {
      await _collections.renameCollection(id, name);
      return (id: id, error: null);
    } on InvalidCollectionNameException catch (e) {
      return (id: null, error: e.message);
    }
  }

  /// Deletes a collection; its documents stay in the library.
  Future<void> delete(int id) => _collections.deleteCollection(id);

  @override
  Future<void> close() async {
    await _subscription?.cancel();
    return super.close();
  }
}
