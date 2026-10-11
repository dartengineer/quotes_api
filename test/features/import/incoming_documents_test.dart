import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/features/import/data/incoming_documents.dart';
import 'package:lectern/features/import/domain/import_outcome.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(IncomingDocuments.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory cache;
  late IncomingDocuments incoming;

  setUp(() async {
    cache = await Directory.systemTemp.createTemp('lectern_cache');
    incoming = IncomingDocuments(cacheDirectory: cache);
  });

  tearDown(() async {
    incoming.stop();
    messenger.setMockMethodCallHandler(channel, null);
    await cache.delete(recursive: true);
  });

  /// A received copy, as the Android activity leaves it.
  File received(String name, {String content = 'text'}) {
    final directory = Directory(
      p.join(cache.path, 'incoming', 'id-${name.hashCode}'),
    )..createSync(recursive: true);
    return File(p.join(directory.path, name))..writeAsStringSync(content);
  }

  /// Simulates a call from the Android activity.
  Future<void> sendFromPlatform(Object? arguments) async {
    await messenger.handlePlatformMessage(
      IncomingDocuments.channelName,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('documentsReceived', arguments),
      ),
      (_) {},
    );
  }

  group('IncomingBatch.fromPlatform', () {
    test('reads copies and failures', () {
      final batch = IncomingBatch.fromPlatform([
        {'action': 'share', 'name': 'a.pdf', 'path': '/c/incoming/1/a.pdf'},
        {'action': 'share', 'name': 'b.epub', 'error': 'unreadable'},
        {'action': 'share', 'name': 'c.pdf', 'error': 'tooLarge'},
      ])!;
      expect(batch.sources, const [
        ImportSource(path: '/c/incoming/1/a.pdf', displayName: 'a.pdf'),
      ]);
      expect(batch.rejected, const [
        RejectedOutcome('b.epub', RejectionReason.unreadable),
        RejectedOutcome('c.pdf', RejectionReason.tooLarge),
      ]);
      expect(batch.openWhenDone, isFalse);
    });

    test('opens only a single "Open with" document', () {
      final single = IncomingBatch.fromPlatform([
        {'action': 'open', 'name': 'a.pdf', 'path': '/x/a.pdf'},
      ])!;
      expect(single.openWhenDone, isTrue);

      final failed = IncomingBatch.fromPlatform([
        {'action': 'open', 'name': 'a.pdf', 'error': 'unreadable'},
      ])!;
      expect(failed.openWhenDone, isTrue, reason: 'nothing to open later');

      final two = IncomingBatch.fromPlatform([
        {'action': 'open', 'name': 'a.pdf', 'path': '/x/a.pdf'},
        {'action': 'open', 'name': 'b.pdf', 'path': '/x/b.pdf'},
      ])!;
      expect(two.openWhenDone, isFalse);
    });

    test('ignores malformed messages', () {
      expect(IncomingBatch.fromPlatform(null), isNull);
      expect(IncomingBatch.fromPlatform('a.pdf'), isNull);
      expect(IncomingBatch.fromPlatform(const []), isNull);
      expect(
        IncomingBatch.fromPlatform([
          'a.pdf',
          {'path': '/x/no-name.pdf'},
          {'name': '', 'path': '/x/empty-name.pdf'},
          {'name': 42, 'path': '/x/a.pdf'},
        ]),
        isNull,
      );
      // A name without a usable path is reported, not imported.
      final odd = IncomingBatch.fromPlatform([
        {'name': 'a.pdf', 'path': 7},
      ])!;
      expect(odd.sources, isEmpty);
      expect(odd.rejected.single.reason, RejectionReason.unreadable);
    });
  });

  group('channel', () {
    test(
      'delivers documents that arrived before start, then new ones',
      () async {
        final calls = <String>[];
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return [
            {'action': 'open', 'name': 'early.txt', 'path': '/x/early.txt'},
          ];
        });
        final batches = <IncomingBatch>[];
        await incoming.start(batches.add);

        expect(calls, ['takePending']);
        expect(batches.single.sources.single.displayName, 'early.txt');
        expect(batches.single.openWhenDone, isTrue);

        await sendFromPlatform([
          {'action': 'share', 'name': 'later.pdf', 'path': '/x/later.pdf'},
        ]);
        expect(batches, hasLength(2));
        expect(batches.last.sources.single.displayName, 'later.pdf');
      },
    );

    test('nothing pending delivers nothing', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => const []);
      final batches = <IncomingBatch>[];
      await incoming.start(batches.add);
      expect(batches, isEmpty);
    });

    test('works without the Android side', () async {
      final batches = <IncomingBatch>[];
      await incoming.start(batches.add);
      expect(batches, isEmpty);
    });
  });

  group('cleanup', () {
    test('discard deletes received copies and nothing else', () async {
      final copy = received('a.pdf');
      final outside = File(p.join(cache.path, 'keep.pdf'))
        ..writeAsStringSync('mine');
      final incomingRoot = Directory(p.join(cache.path, 'incoming'));

      await incoming.discard([
        ImportSource(path: copy.path, displayName: 'a.pdf'),
        ImportSource(path: outside.path, displayName: 'keep.pdf'),
        // A path directly in the incoming root would delete the root.
        ImportSource(
          path: p.join(incomingRoot.path, 'x.pdf'),
          displayName: 'x.pdf',
        ),
        ImportSource(
          path: p.join(incomingRoot.path, 'a', '..', '..', 'keep.pdf'),
          displayName: 'keep.pdf',
        ),
      ]);

      expect(copy.parent.existsSync(), isFalse);
      expect(outside.existsSync(), isTrue);
      expect(incomingRoot.existsSync(), isTrue);
    });

    test('discard tolerates copies the importer already moved', () async {
      final copy = received('a.pdf');
      copy.deleteSync();
      await incoming.discard([
        ImportSource(path: copy.path, displayName: 'a.pdf'),
      ]);
      expect(copy.parent.existsSync(), isFalse);
    });

    test('clearStale removes only old copies', () async {
      final copy = received('old.pdf');
      await incoming.clearStale(now: DateTime.now());
      expect(copy.existsSync(), isTrue, reason: 'may still be arriving');

      await incoming.clearStale(
        now: DateTime.now().add(const Duration(hours: 2)),
      );
      expect(copy.parent.existsSync(), isFalse);
    });

    test('clearStale without an incoming directory is a no-op', () async {
      await incoming.clearStale();
    });
  });
}
