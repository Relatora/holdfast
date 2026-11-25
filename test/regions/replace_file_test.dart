@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:holdfast/regions/region_files_io.dart';

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('holdfast_replace'));
  tearDown(() async => dir.delete(recursive: true));

  test('replaces the old file with the new one', () async {
    final target = File('${dir.path}/town.pmtiles')..writeAsStringSync('old');
    final part = File('${target.path}.part')..writeAsStringSync('new');

    await replaceFile(part, target);

    expect(target.readAsStringSync(), 'new');
    expect(part.existsSync(), isFalse);
  });

  test('waits out a read that holds the old file open', () async {
    // The map reads its archive a tile at a time. On Windows an open file
    // can't be deleted, so an update landing mid-read must wait for it.
    final target = File('${dir.path}/town.pmtiles')..writeAsStringSync('old');
    final part = File('${target.path}.part')..writeAsStringSync('new');
    final reader = await target.open();
    final released = Future<void>.delayed(const Duration(milliseconds: 150), reader.close);

    await replaceFile(part, target);
    await released;

    expect(target.readAsStringSync(), 'new');
  });
}
