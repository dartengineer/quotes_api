import 'dart:io';

import 'package:equatable/equatable.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../../core/utils/app_log.dart';
import '../domain/import_outcome.dart';

/// Documents that another app sent in one go.
class IncomingBatch extends Equatable {
  const IncomingBatch({
    required this.sources,
    this.rejected = const [],
    this.openWhenDone = false,
  });

  /// Received copies, ready to import.
  final List<ImportSource> sources;

  /// Documents that could not be received.
  final List<RejectedOutcome> rejected;

  /// The user chose "Open with" for this one document: show it once it is
  /// in the library.
  final bool openWhenDone;

  /// Parses a message from the Android activity. Malformed entries are
  /// ignored; returns null when nothing usable arrived.
  static IncomingBatch? fromPlatform(Object? message) {
    if (message is! List<Object?>) return null;
    final sources = <ImportSource>[];
    final rejected = <RejectedOutcome>[];
    var opens = 0;
    for (final entry in message) {
      if (entry is! Map<Object?, Object?>) continue;
      final name = entry['name'];
      if (name is! String || name.isEmpty) continue;
      final path = entry['path'];
      final error = entry['error'];
      if (path is String && path.isNotEmpty && error == null) {
        sources.add(ImportSource(path: path, displayName: name));
      } else {
        final reason = error == 'tooLarge'
            ? RejectionReason.tooLarge
            : RejectionReason.unreadable;
        rejected.add(RejectedOutcome(name, reason));
      }
      if (entry['action'] == 'open') opens++;
    }
    final count = sources.length + rejected.length;
    if (count == 0) return null;
    return IncomingBatch(
      sources: sources,
      rejected: rejected,
      openWhenDone: count == 1 && opens == 1,
    );
  }

  @override
  List<Object?> get props => [sources, rejected, openWhenDone];
}

/// Receives documents from other apps ("Open with" and the share sheet).
///
/// The Android activity reads each document it is given (it never gets
/// broader file access) and copies it to `<cache>/incoming/<random>/<name>`.
/// Those copies are temporary: the importer moves the ones it keeps into the
/// library, and [discard] deletes what is left.
class IncomingDocuments {
  IncomingDocuments({required Directory cacheDirectory, MethodChannel? channel})
    : _root = p.normalize(p.join(cacheDirectory.absolute.path, 'incoming')),
      _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'lectern/incoming_documents';

  final String _root;
  final MethodChannel _channel;

  /// Delivers documents to [onReceived] as they arrive, starting with any
  /// that arrived before the app was ready (such as the one that launched
  /// it). Does nothing on platforms without the native side.
  Future<void> start(void Function(IncomingBatch batch) onReceived) async {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'documentsReceived') {
        throw MissingPluginException(call.method);
      }
      _deliver(call.arguments, onReceived);
    });
    try {
      _deliver(await _channel.invokeMethod<Object?>('takePending'), onReceived);
    } on MissingPluginException {
      // Not running on Android: documents never arrive this way.
    } on PlatformException catch (error, stackTrace) {
      AppLog.error('Receiving documents failed', error, stackTrace);
    }
  }

  void stop() => _channel.setMethodCallHandler(null);

  void _deliver(
    Object? message,
    void Function(IncomingBatch batch) onReceived,
  ) {
    final batch = IncomingBatch.fromPlatform(message);
    if (batch != null) onReceived(batch);
  }

  /// Deletes the received copies of [sources] once they have been imported.
  /// Only directories directly inside the incoming area are touched.
  Future<void> discard(Iterable<ImportSource> sources) async {
    for (final source in sources) {
      final directory = p.dirname(p.normalize(source.path));
      if (!p.equals(p.dirname(directory), _root)) continue;
      await _deleteQuietly(Directory(directory));
    }
  }

  /// Removes copies left behind when the app closed before importing them.
  /// Recent ones are kept: they may belong to a document arriving right now.
  Future<void> clearStale({
    Duration maxAge = const Duration(hours: 1),
    DateTime? now,
  }) async {
    final root = Directory(_root);
    if (!await root.exists()) return;
    final cutoff = (now ?? DateTime.now()).subtract(maxAge);
    await for (final entity in root.list(followLinks: false)) {
      try {
        final modified = (await entity.stat()).modified;
        if (modified.isBefore(cutoff)) await entity.delete(recursive: true);
      } on FileSystemException {
        // Best effort; tried again next start.
      }
    }
  }

  Future<void> _deleteQuietly(Directory directory) async {
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } on FileSystemException {
      // Best effort; [clearStale] catches anything left.
    }
  }
}
