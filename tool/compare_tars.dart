import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chunked_stream/chunked_stream.dart';
import 'package:collection/collection.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:pool/pool.dart';
import 'package:pub/src/http.dart';
import 'package:pub/src/io.dart';
import 'package:pub/src/old_io.dart' as old;

const statusFilename = 'tar_diff.json';

Future<List<String>> allPackageNames() async {
  var nextUrl = 'https://pub.dev/api/packages?compact=1';
  final result = json.decode(await httpClient.read(nextUrl));
  return List<String>.from(result['packages']);
}

Future<List<String>> versionArchiveUrls(String packageName) async {
  final url = 'https://pub.dev/api/packages/$packageName';
  final result = json.decode(await httpClient.read(url));
  return List<String>.from(result['versions'].map((v) => v['archive_url']));
}

//Future<void> main() async {
// await _testUrl(
//     'https://pub.dartlang.org/packages/angel_cli/versions/1.2.0%2B2.tar.gz');
//}

Future<void> main() async {
  var alreadyDonePackages = <String>{};
  var failures = <Map<String, dynamic>>[];
  if (fileExists(statusFilename)) {
    final json = jsonDecode(readTextFile(statusFilename));
    for (final packageName in json['packages'] ?? []) {
      alreadyDonePackages.add(packageName);
    }
    for (final failure in json['failures'] ?? []) {
      failures.add(failure);
    }
  }
  print('Already processed ${alreadyDonePackages.length} packages');
  print('Already found ${alreadyDonePackages.length}');

  void writeStatus() {
    writeTextFile(
      statusFilename,
      JsonEncoder.withIndent('  ').convert({
        'packages': [...alreadyDonePackages],
        'failures': [...failures],
      }),
    );
    print('Wrote status to $statusFilename');
  }

  ProcessSignal.sigint.watch().listen((_) {
    writeStatus();
    exit(1);
  });

  final downloadPool = Pool(10);
  final computePool = Pool(1);

  try {
    for (final packageName in await allPackageNames()) {
      if (alreadyDonePackages.contains(packageName)) {
        print('Skipping $packageName - already done');
        continue;
      }
      print('Processing all versions of $packageName '
          '[+${alreadyDonePackages.length}, - ${failures.length}]');
      final resource = await downloadPool.request();
      scheduleMicrotask(() async {
        try {
          final versions = await versionArchiveUrls(packageName);
          var allVersionsGood = true;
          for (final archiveUrl in versions) {
            await withTempDir((tempDir) async {
              print('downloading $archiveUrl');
              try {
                final response = await httpClient
                    .send(http.Request('GET', Uri.parse(archiveUrl)));
                final file = File(p.join(tempDir, 'ref.tar.gz'));
                await response.stream.pipe(file.openWrite());
                print('done downloading, comparing now');

                final oldDir = p.join(tempDir, 'old');
                final newDir = p.join(tempDir, 'new');

                ensureDir(oldDir);
                await old.extractTarGz(file.openRead(), oldDir);
                await computePool
                    .withResource(() => extractTarGz(file.openRead(), newDir));

                await _compare(oldDir, newDir);
              } catch (e, _) {
                print('Failed to get and extract $archiveUrl $e');
                failures.add({'archive': archiveUrl, 'error': e.toString()});
                allVersionsGood = false;
                return;
              }
            });
          }
          if (allVersionsGood) alreadyDonePackages.add(packageName);
        } finally {
          resource.release();
        }
      });
    }
  } finally {
    writeStatus();
    exit(failures.isEmpty ? 0 : 1);
  }
}

Future<void> _testUrl(String archiveUrl) async {
  await withTempDir((tempDir) async {
    print('downloading $archiveUrl');
    final response =
        await httpClient.send(http.Request('GET', Uri.parse(archiveUrl)));
    final file = File(p.join(tempDir, 'ref.tar.gz'));
    await response.stream.pipe(file.openWrite());

    final oldDir = p.join(tempDir, 'old');
    final newDir = p.join(tempDir, 'new');

    ensureDir(oldDir);
    await old.extractTarGz(file.openRead(), oldDir);
    await extractTarGz(file.openRead(), newDir);

    await _compare(oldDir, newDir);
  });
}

Future<void> _compare(String dir1, String dir2) async {
  final firstFiles = await _relativePathsIn(Directory(dir1));
  final secondFiles = await _relativePathsIn(Directory(dir2));

  final firstMinusSecond = firstFiles.keys.toSet();
  for (final entry in secondFiles.keys) {
    if (!firstFiles.containsKey(entry)) {
      throw StateError('Missing in first: $entry');
    }
    firstMinusSecond.remove(entry);

    final firstFile = firstFiles[entry];
    final secondFile = secondFiles[entry];
    await _ensureSameContent(firstFile, secondFile);
  }

  if (firstMinusSecond.isNotEmpty) {
    throw StateError('Missing in second: ${firstMinusSecond.join(', ')}');
  }
}

Future<Map<String, File>> _relativePathsIn(Directory directory) async {
  return {
    await for (final entry in directory.list(recursive: true))
      if (entry is File) p.relative(entry.path, from: directory.path): entry,
  };
}

Future<void> _ensureSameContent(File first, File second) async {
  final a = ChunkedStreamIterator(first.openRead());
  final b = ChunkedStreamIterator(second.openRead());

  const blockSize = 1024;
  // ignore: literal_only_boolean_expressions
  while (true) {
    final chunkFromA = await a.read(blockSize);
    final chunkFromB = await b.read(blockSize);

    if (!const ListEquality().equals(chunkFromA, chunkFromB)) {
      throw StateError('Not equal: ${first.path} and ${second.path}');
    }

    if (chunkFromA.isEmpty) break;
  }
}
