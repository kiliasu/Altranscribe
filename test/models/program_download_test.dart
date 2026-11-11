import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:altranscribe/data/services/models/model_catalog.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/zip_builder.dart';

void main() {
  late Directory root;
  late HttpServer server;
  late ModelCatalog catalog;
  late Uint8List archive;
  late ProgramPackage package;

  ProgramPackage describe(Uint8List bytes, {String path = 'tool.zip'}) =>
      ProgramPackage(
        'tool-1.0',
        name: 'Tool',
        version: '1.0',
        variant: 'CPU',
        engine: ProgramEngine.whisper,
        url: 'http://127.0.0.1:${server.port}/$path',
        bytes: bytes.length,
        sha256: sha256.convert(bytes).toString(),
        executable: 'whisper-server.exe',
        licenseName: 'MIT',
        sourceUrl: 'https://example.com/tool',
      );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('program-download-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    // The library does not compress, so the archive is large enough to
    // arrive in several pieces.
    var seed = 20261111;
    archive = buildZip([
      ZipFile('Release/whisper-server.exe', [77, 90, ...List.filled(4000, 9)]),
      ZipFile(
        'Release/whisper.dll',
        List.generate(
          300000,
          (_) => (seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF) >> 16 & 0xFF,
        ),
      ),
      ZipFile('Release/readme.txt', 'kept beside it'.codeUnits, deflate: false),
    ]);
    package = describe(archive);
    catalog = ModelCatalog(
      Directory('${root.path}/models'),
      packages: [package],
      stallTimeout: const Duration(seconds: 2),
      retryDelay: const Duration(milliseconds: 20),
    );
  });
  tearDown(() async {
    catalog.dispose();
    await server.close(force: true);
    await root.delete(recursive: true);
  });

  List<String> leftovers() => Directory('${root.path}/programs').existsSync()
      ? Directory('${root.path}/programs')
            .listSync()
            .map(
              (entry) => entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty),
            )
            .toList()
      : [];

  test('a program is downloaded, checked, unpacked and found', () async {
    // The release page answers with a redirect to where the file is kept.
    server.listen((request) async {
      if (request.uri.path == '/tool.zip') {
        await request.response.redirect(
          Uri.parse('http://127.0.0.1:${server.port}/stored/tool.zip'),
        );
        return;
      }
      request.response.contentLength = archive.length;
      request.response.add(archive);
      await request.response.close();
    });
    final stages = <DownloadStage>{};
    catalog.addListener(() {
      if (catalog.downloadingModel != null) stages.add(catalog.downloadStage);
    });
    expect((await catalog.scan())[package.id], ModelAvailability.missing);
    expect(catalog.installedProgram(ProgramEngine.whisper), isNull);

    expect(
      await catalog.download(package),
      isTrue,
      reason: catalog.downloadError,
    );
    expect(
      stages,
      containsAll([DownloadStage.receiving, DownloadStage.installing]),
    );
    expect(catalog.installProgress, 1);
    expect(catalog.availability[package.id], ModelAvailability.available);

    // Beside the models, in a folder of its own, with the archive gone.
    final program = catalog.programPath(package)!;
    expect(
      program.replaceAll(r'\', '/'),
      endsWith('programs/tool-1.0/Release/whisper-server.exe'),
    );
    expect(File(program).readAsBytesSync().take(2), [77, 90]);
    expect(catalog.installedProgram(ProgramEngine.whisper), program);
    expect(catalog.installedProgram(ProgramEngine.transcribe), isNull);
    expect(
      File('${catalog.programFolder(package)}/Release/readme.txt')
          .readAsStringSync(),
      'kept beside it',
    );
    expect(leftovers(), ['tool-1.0']);

    // A new catalog finds it again on disk.
    final next = ModelCatalog(
      Directory('${root.path}/models'),
      packages: [package],
    );
    addTearDown(next.dispose);
    expect((await next.scan())[package.id], ModelAvailability.available);
    expect(next.programPath(package), program);

    await catalog.remove(package);
    expect(catalog.availability[package.id], ModelAvailability.missing);
    expect(catalog.programPath(package), isNull);
    expect(leftovers(), isEmpty);
  });

  test(
    'a program that is running is not removed, in part or in whole',
    () async {
      server.listen((request) async {
        request.response.contentLength = archive.length;
        request.response.add(archive);
        await request.response.close();
      });
      expect(await catalog.download(package), isTrue);
      final program = File(catalog.programPath(package)!);
      // Something that runs for a while, started from the program's folder.
      final running = File('${program.parent.path}/running.exe');
      File(r'C:\Windows\System32\PING.EXE').copySync(running.path);
      final process = await Process.start(running.path, [
        '-n',
        '30',
        '127.0.0.1',
      ]);
      addTearDown(process.kill);

      await expectLater(
        catalog.remove(package),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'modelRemoveFailed',
          ),
        ),
      );
      // All of it is still there and still counts as installed.
      expect(catalog.availability[package.id], ModelAvailability.available);
      expect(catalog.programPath(package), program.path);
      expect(
        Directory(catalog.programFolder(package))
            .listSync(recursive: true)
            .whereType<File>()
            .map((file) => file.uri.pathSegments.last)
            .toSet(),
        {
          'whisper-server.exe',
          'whisper.dll',
          'readme.txt',
          'running.exe',
          'installed.txt',
        },
      );
      expect(leftovers(), ['tool-1.0']);

      process.kill();
      await process.exitCode;
      // Windows lets go of the file a moment after the process has ended.
      for (var attempt = 0; ; attempt++) {
        try {
          await catalog.remove(package);
          break;
        } on StateError {
          if (attempt == 20) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      expect(catalog.availability[package.id], ModelAvailability.missing);
      expect(leftovers(), isEmpty);
    },
    skip: !Platform.isWindows,
  );

  test('a file that is not the published one is never unpacked', () async {
    final other = Uint8List.fromList(archive)..[archive.length ~/ 2] ^= 0xFF;
    server.listen((request) async {
      request.response.contentLength = other.length;
      request.response.add(other);
      await request.response.close();
    });
    expect(await catalog.download(package), isFalse);
    expect(catalog.downloadError, 'modelDownloadInvalid');
    expect(catalog.availability[package.id], ModelAvailability.missing);
    expect(leftovers(), isEmpty);
  });

  test('an archive without the program leaves nothing behind', () async {
    final empty = buildZip([
      ZipFile('Release/other.exe', [77, 90]),
    ]);
    final wrong = describe(empty);
    final lacking = ModelCatalog(
      Directory('${root.path}/models'),
      packages: [wrong],
    );
    addTearDown(lacking.dispose);
    server.listen((request) async {
      request.response.contentLength = empty.length;
      request.response.add(empty);
      await request.response.close();
    });
    expect(await lacking.download(wrong), isFalse);
    expect(lacking.downloadError, 'modelDownloadInvalid');
    expect(lacking.availability[wrong.id], ModelAvailability.missing);
    expect(leftovers(), isEmpty);
  });

  test(
    'an interrupted download continues, and a cancelled one is cleared',
    () async {
      final ranges = <String?>[];
      final hold = Completer<void>();
      addTearDown(() => hold.isCompleted ? null : hold.complete());
      server.listen((request) async {
        final range = request.headers.value(HttpHeaders.rangeHeader);
        ranges.add(range);
        final response = request.response;
        if (ranges.length == 1) {
          // Half of it, then the connection breaks.
          response.contentLength = archive.length;
          final socket = await response.detachSocket();
          socket.add(archive.sublist(0, archive.length ~/ 2));
          await socket.flush();
          socket.destroy();
          return;
        }
        if (ranges.length == 2) {
          final from = int.parse(range!.substring(6, range.length - 1));
          response
            ..statusCode = HttpStatus.partialContent
            ..headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $from-${archive.length - 1}/${archive.length}',
            )
            ..contentLength = archive.length - from
            ..add(archive.sublist(from));
          await response.close();
          return;
        }
        // The next download gets its first bytes and then nothing more.
        response
          ..bufferOutput = false
          ..contentLength = archive.length
          ..add(archive.sublist(0, 1000));
        await response.flush();
        await hold.future;
      });
      expect(
        await catalog.download(package),
        isTrue,
        reason: catalog.downloadError,
      );
      // The second request asks for whatever had not arrived yet.
      expect(ranges, [null, matches(RegExp(r'^bytes=[1-9][0-9]*-$'))]);
      expect(catalog.availability[package.id], ModelAvailability.available);
      expect(
        File(catalog.programPath(package)!).readAsBytesSync(),
        hasLength(4002),
      );

      await catalog.remove(package);
      final started = Completer<void>();
      void watch() {
        if (catalog.receivedBytes > 0 && !started.isCompleted) {
          started.complete();
        }
      }

      catalog.addListener(watch);
      final download = catalog.download(package);
      await started.future.timeout(const Duration(seconds: 5));
      catalog.cancelDownload();
      expect(await download, isFalse);
      catalog.removeListener(watch);
      expect(catalog.downloadError, isNull);
      expect(catalog.availability[package.id], ModelAvailability.missing);
      expect(leftovers(), isEmpty);
    },
  );

  test(
    'cancelling while it unpacks leaves nothing and can be tried again',
    () async {
      server.listen((request) async {
        request.response.contentLength = archive.length;
        request.response.add(archive);
        await request.response.close();
      });
      void cancel() {
        if (catalog.downloadingModel != null &&
            catalog.downloadStage == DownloadStage.installing) {
          catalog.cancelDownload();
        }
      }

      catalog.addListener(cancel);
      expect(await catalog.download(package), isFalse);
      catalog.removeListener(cancel);
      // Cancelled, not failed: nothing is reported and nothing is kept.
      expect(catalog.downloadError, isNull);
      expect(catalog.availability[package.id], ModelAvailability.missing);
      expect(catalog.programPath(package), isNull);
      expect(leftovers(), isEmpty);

      expect(await catalog.download(package), isTrue);
      expect(catalog.availability[package.id], ModelAvailability.available);
      expect(leftovers(), ['tool-1.0']);
    },
  );

  test('the published packages are named, sized and addressed as released', () {
    final ids = ModelCatalog.programs.map((p) => p.id).toList();
    expect(ids.toSet().length, ids.length);
    for (final program in ModelCatalog.programs) {
      final uri = Uri.parse(program.url);
      expect(uri.scheme, 'https');
      expect(uri.host, 'github.com');
      expect(uri.path, contains('/releases/download/'));
      expect(uri.path, endsWith('.zip'));
      expect(program.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(program.bytes, greaterThan(1000000));
      expect(program.executable, endsWith('.exe'));
    }
    // One build for an NVIDIA GPU and one for the CPU for Whisper; the
    // GPU build is the one a search for an installed program prefers.
    final whisper = ModelCatalog.programs
        .where((p) => p.engine == ProgramEngine.whisper)
        .toList();
    expect(whisper.map((p) => p.variant), ['NVIDIA GPU', 'CPU']);
    expect(whisper.first.label, 'whisper.cpp 1.9.4 · NVIDIA GPU');
    expect(
      ModelCatalog.programs.where((p) => p.engine == ProgramEngine.transcribe),
      hasLength(1),
    );
    expect(ModelCatalog.programs.first.size, '675 MB');
  });
}
