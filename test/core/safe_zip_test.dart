import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/core/files/safe_zip.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('safe_zip');
  });

  tearDown(() => dir.delete(recursive: true));

  String writeZip(Map<String, List<int>> files) {
    final archive = Archive();
    files.forEach((name, data) => archive.add(ArchiveFile.bytes(name, data)));
    final path = '${dir.path}/test.zip';
    File(path).writeAsBytesSync(ZipEncoder().encodeBytes(archive));
    return path;
  }

  group('resolve', () {
    test('resolves relative paths against the base document', () {
      expect(
        SafeZip.resolve('OEBPS/text/ch1.xhtml', '../images/a.png'),
        'OEBPS/images/a.png',
      );
      expect(
        SafeZip.resolve('OEBPS/content.opf', 'ch1.xhtml'),
        'OEBPS/ch1.xhtml',
      );
      expect(SafeZip.resolve('', 'OEBPS/content.opf'), 'OEBPS/content.opf');
    });

    test('drops fragments and queries and decodes escapes', () {
      expect(
        SafeZip.resolve('OEBPS/content.opf', 'my%20file.xhtml#part2'),
        'OEBPS/my file.xhtml',
      );
      expect(SafeZip.resolve('a/b.opf', 'c.xhtml?x=1'), 'a/c.xhtml');
    });

    test('never escapes the archive root', () {
      expect(SafeZip.resolve('content.opf', '../../etc/passwd'), '');
      expect(SafeZip.resolve('a/content.opf', '../../x'), '');
    });

    test('tolerates malformed percent escapes', () {
      expect(
        SafeZip.resolve('a/b.opf', 'bad%zzname.xhtml'),
        'a/bad%zzname.xhtml',
      );
    });
  });

  test('finds entries case-insensitively and with odd paths', () {
    final zip = SafeZip.open(
      writeZip({
        'OEBPS/Images/Cover.JPG': [1, 2, 3],
      }),
    );
    addTearDown(zip.close);

    expect(zip.find('OEBPS/Images/Cover.JPG'), isNotNull);
    expect(zip.find('oebps/images/cover.jpg'), isNotNull);
    expect(zip.find('./OEBPS/Images/Cover.JPG'), isNotNull);
    expect(zip.find('/OEBPS/Images/Cover.JPG'), isNotNull);
    expect(zip.find('OEBPS/missing.jpg'), isNull);
    expect(zip.readPath('OEBPS/Images/Cover.JPG', maxBytes: 10), [1, 2, 3]);
  });

  test('rejects entries whose declared size exceeds the limit', () {
    final zip = SafeZip.open(writeZip({'big.bin': Uint8List(5000)}));
    addTearDown(zip.close);
    expect(
      () => zip.readPath('big.bin', maxBytes: 1000),
      throwsA(isA<ZipEntryTooLargeException>()),
    );
  });

  test('caps decompression even when headers understate the size', () {
    final path = writeZip({'bomb.bin': Uint8List(2 * 1024 * 1024)});
    final bytes = File(path).readAsBytesSync();
    // Rewrite the uncompressed size in the local and central headers to 10.
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i + 4 <= bytes.length; i++) {
      final signature = data.getUint32(i, Endian.little);
      if (signature == 0x04034b50) data.setUint32(i + 22, 10, Endian.little);
      if (signature == 0x02014b50) data.setUint32(i + 24, 10, Endian.little);
    }
    File(path).writeAsBytesSync(bytes);

    final zip = SafeZip.open(path);
    addTearDown(zip.close);
    final entry = zip.find('bomb.bin')!;
    expect(entry.size, 10, reason: 'header now lies about the size');
    expect(
      () => zip.read(entry, maxBytes: 64 * 1024),
      throwsA(isA<ZipEntryTooLargeException>()),
    );
  });

  test('opening a non-zip file throws', () {
    final path = '${dir.path}/not.zip';
    File(path).writeAsStringSync('definitely not a zip');
    expect(() => SafeZip.open(path), throwsFormatException);
  });

  test('an empty zip is treated as unreadable', () {
    final path = '${dir.path}/empty.zip';
    File(path).writeAsBytesSync(ZipEncoder().encodeBytes(Archive()));
    expect(() => SafeZip.open(path), throwsFormatException);
  });
}
