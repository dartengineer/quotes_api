import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/core/utils/cancellation.dart';
import 'package:lectern/data/files/library_storage.dart';
import 'package:lectern/features/library/domain/document_format.dart';

void main() {
  late Directory base;
  late LibraryStorage storage;

  setUp(() async {
    base = await Directory.systemTemp.createTemp('storage');
    storage = LibraryStorage(
      root: Directory('${base.path}/support/library'),
      temporaryDirectory: Directory('${base.path}/cache'),
    );
    await storage.ensureDirectories();
    await Directory('${base.path}/cache').create();
    await Directory('${base.path}/user').create();
  });

  tearDown(() => base.delete(recursive: true));

  List<String> incoming() =>
      Directory('${storage.root.path}/incoming')
          .listSync()
          .map((e) => e.path)
          .toList();

  test(
    'copies user files while hashing, leaving the original intact',
    () async {
      final original = File('${base.path}/user/book.txt')
        ..writeAsStringSync('hello');
      final staged = await storage.stage(original.path);

      expect(staged.sha256, sha256.convert('hello'.codeUnits).toString());
      expect(staged.size, 5);
      expect(original.readAsStringSync(), 'hello');
      expect(File(staged.path).readAsStringSync(), 'hello');
    },
  );

  test('moves temporary copies instead of copying them again', () async {
    final temporary = File('${base.path}/cache/file_picker/1/book.txt')
      ..createSync(recursive: true)
      ..writeAsStringSync('hello');
    expect(storage.isDisposable(temporary.path), isTrue);
    expect(storage.isDisposable('${base.path}/user/x.txt'), isFalse);

    final staged = await storage.stage(temporary.path);
    expect(temporary.existsSync(), isFalse);
    expect(File(staged.path).readAsStringSync(), 'hello');
  });

  test('commit stores by content hash and reuses identical files', () async {
    final a = File('${base.path}/user/a.pdf')..writeAsStringSync('same');
    final b = File('${base.path}/user/b.pdf')..writeAsStringSync('same');

    final first = await storage.commit(
      await storage.stage(a.path),
      DocumentFormat.pdf,
    );
    final stagedB = await storage.stage(b.path);
    final second = await storage.commit(stagedB, DocumentFormat.pdf);

    expect(first, second);
    expect(first, startsWith('files/'));
    expect(first, endsWith('.pdf'));
    expect(storage.resolve(first).readAsStringSync(), 'same');
    expect(File(stagedB.path).existsSync(), isFalse);
    expect(incoming(), isEmpty);
  });

  test('saves and deletes covers and documents', () async {
    final source = File('${base.path}/user/a.txt')..writeAsStringSync('x');
    final staged = await storage.stage(source.path);
    final file = await storage.commit(staged, DocumentFormat.txt);
    final cover = await storage.saveCover(
      staged.sha256,
      Uint8List.fromList([1, 2]),
    );

    expect(storage.resolve(cover).readAsBytesSync(), [1, 2]);

    await storage.deleteDocumentFiles(filePath: file, coverPath: cover);
    expect(storage.resolve(file).existsSync(), isFalse);
    expect(storage.resolve(cover).existsSync(), isFalse);
    expect(source.existsSync(), isTrue, reason: 'originals are never touched');

    // Deleting again is harmless.
    await storage.deleteDocumentFiles(filePath: file, coverPath: cover);
  });

  test('refuses paths outside the library', () {
    expect(() => storage.resolve('../../user/x'), throwsArgumentError);
    expect(() => storage.resolve('/etc/passwd'), throwsArgumentError);
  });

  test('cancelling a copy stops it and cleans up', () async {
    final big = File('${base.path}/user/big.bin');
    final sink = big.openSync(mode: FileMode.write);
    final chunk = Uint8List(1024 * 1024);
    for (var i = 0; i < 200; i++) {
      sink.writeFromSync(chunk);
    }
    sink.closeSync();

    final token = CancellationToken();
    final future = storage.stage(big.path, cancellation: token);
    token.cancel();
    await expectLater(future, throwsA(isA<CancelledException>()));
    expect(incoming(), isEmpty);
    expect(big.lengthSync(), 200 * 1024 * 1024);
  });

  test('clearStagingArea removes leftovers', () async {
    File('${storage.root.path}/incoming/old.part').writeAsStringSync('x');
    await storage.clearStagingArea();
    expect(incoming(), isEmpty);
  });
}
