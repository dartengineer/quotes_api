import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/app/app_info.dart';

void main() {
  test('AppInfo.version matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(
      r'^version:\s*([^\s+]+)',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(match, isNotNull);
    expect(AppInfo.version, match!.group(1));
  });
}
