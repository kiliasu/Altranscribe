import 'dart:async';
import 'dart:io';

import 'package:altranscribe/data/services/models/model_catalog.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

class DownloadFixture extends WhisperModel {
  DownloadFixture(this.uri, List<int> bytes)
    : super(
        'fixture',
        'Fixture',
        bytes.length,
        sha256.convert(bytes).toString(),
      );
  final Uri uri;
  @override
  Uri get downloadUri => uri;
}

void main() {
  final bytes = [0x6c, 0x6d, 0x67, 0x67, ...List.filled(128 * 1024, 42)];
  late Directory directory;
  late HttpServer server;
  late ModelCatalog catalog;
  late DownloadFixture model;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('model-download-');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    model = DownloadFixture(
      Uri.parse('http://127.0.0.1:${server.port}/model'),
      bytes,
    );
    catalog = ModelCatalog(directory);
  });
  tearDown(() async {
    catalog.dispose();
    await server.close(force: true);
    await directory.delete(recursive: true);
  });

  test(
    'streams and verifies a model before publishing its final filename',
    () async {
      final release = Completer<void>();
      server.listen((request) async {
        request.response.bufferOutput = false;
        request.response.contentLength = bytes.length;
        request.response.add(bytes.take(64 * 1024).toList());
        await request.response.flush();
        await release.future;
        request.response.add(bytes.skip(64 * 1024).toList());
        await request.response.close();
      });
      final started = Completer<void>();
      catalog.addListener(() {
        if (catalog.receivedBytes > 0 && !started.isCompleted) {
          started.complete();
        }
      });
      final download = catalog.download(model);
      await Future.any([
        started.future,
        download.then(
          (_) =>
              throw StateError(catalog.downloadError ?? 'Download ended early'),
        ),
      ]).timeout(const Duration(seconds: 5));
      expect(await File(catalog.path(model)).exists(), isFalse);
      expect(catalog.downloadingModel, model);
      release.complete();
      expect(await download, isTrue);
      expect(await File(catalog.path(model)).readAsBytes(), bytes);
      expect(catalog.downloadingModel, isNull);
      expect(directory.listSync().length, 1);
    },
  );

  test('same-length corrupt response is rejected and retry succeeds', () async {
    var attempts = 0;
    server.listen((request) async {
      request.response.contentLength = bytes.length;
      request.response.add(attempts++ == 0 ? [0, ...bytes.skip(1)] : bytes);
      await request.response.close();
    });
    expect(await catalog.download(model), isFalse);
    expect(catalog.downloadError, 'modelDownloadInvalid');
    expect(directory.listSync(), isEmpty);
    expect(await catalog.download(model), isTrue);
    expect(catalog.downloadError, isNull);
  });

  test('HTTP failure leaves no model or temporary download', () async {
    server.listen((request) async {
      request.response.statusCode = 403;
      await request.response.close();
    });
    expect(await catalog.download(model), isFalse);
    expect(catalog.downloadError, 'modelDownloadFailed');
    expect(directory.listSync(), isEmpty);
  });

  test('truncated transfer cannot become an available model', () async {
    server.listen((request) async {
      request.response.add(bytes.take(32).toList());
      await request.response.close();
    });
    expect(await catalog.download(model), isFalse);
    expect(catalog.downloadError, 'modelDownloadInvalid');
    expect(directory.listSync(), isEmpty);
  });

  test(
    'cancel interrupts a stalled response and removes the partial file',
    () async {
      final requested = Completer<void>();
      server.listen((request) {
        requested.complete();
      });
      final download = catalog.download(model);
      await requested.future;
      catalog.cancelDownload();
      expect(await download.timeout(const Duration(seconds: 2)), isFalse);
      expect(catalog.downloadError, isNull);
      expect(catalog.downloadingModel, isNull);
      expect(directory.listSync(), isEmpty);
    },
  );

  test('a second download is refused while one is active', () async {
    final first = catalog.download(model);
    await expectLater(catalog.download(model), throwsStateError);
    catalog.cancelDownload();
    expect(await first, isFalse);
    expect(directory.listSync(), isEmpty);
  });

  /// A catalog that reconnects at once and treats 300 ms of silence as a
  /// stall.
  ModelCatalog quick() {
    final value = ModelCatalog(
      directory,
      stallTimeout: const Duration(milliseconds: 300),
      retryDelay: Duration.zero,
    );
    addTearDown(value.dispose);
    return value;
  }

  /// Serves the model, honoring Range unless [ranges] is false. [drop] gives
  /// how many bytes the request with that index gets before its connection
  /// breaks; null sends the rest. Returns each request's Range header.
  List<String?> serve(int? Function(int index) drop, {bool ranges = true}) {
    final seen = <String?>[];
    server.listen((request) async {
      final index = seen.length;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      seen.add(range);
      final start = ranges && range != null
          ? int.parse(range.substring(6, range.length - 1))
          : 0;
      if (start > 0) {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${bytes.length - 1}/${bytes.length}',
        );
      }
      request.response.contentLength = bytes.length - start;
      final limit = drop(index);
      if (limit == null) {
        request.response.add(bytes.sublist(start));
        await request.response.close();
        return;
      }
      final socket = await request.response.detachSocket();
      socket.add(bytes.sublist(start, start + limit));
      await socket.flush();
      socket.destroy();
    });
    return seen;
  }

  test('a dropped connection resumes where it stopped', () async {
    final ranges = serve((index) => index == 0 ? 50000 : null);
    final catalog = quick();
    expect(await catalog.download(model), isTrue);
    expect(ranges, [null, matches(RegExp(r'^bytes=[1-9][0-9]*-$'))]);
    expect(await File(catalog.path(model)).readAsBytes(), bytes);
    expect(directory.listSync(), hasLength(1));
  });

  test('a stalled response reconnects and resumes', () async {
    final hold = Completer<void>();
    addTearDown(() => hold.isCompleted ? null : hold.complete());
    final ranges = <String?>[];
    server.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      ranges.add(range);
      if (range == null) {
        request.response.bufferOutput = false;
        request.response.contentLength = bytes.length;
        request.response.add(bytes.sublist(0, 40000));
        await request.response.flush();
        // Nothing more arrives on this connection.
        await hold.future;
        return;
      }
      final start = int.parse(range.substring(6, range.length - 1));
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-${bytes.length - 1}/${bytes.length}',
      );
      request.response.contentLength = bytes.length - start;
      request.response.add(bytes.sublist(start));
      await request.response.close();
    });
    final catalog = quick();
    final stages = <DownloadStage>{};
    catalog.addListener(() => stages.add(catalog.downloadStage));
    expect(await catalog.download(model), isTrue);
    // The second request asks for whatever had not arrived yet.
    expect(ranges, [null, matches(RegExp(r'^bytes=[1-9][0-9]*-$'))]);
    expect(stages, contains(DownloadStage.retrying));
    expect(await File(catalog.path(model)).readAsBytes(), bytes);
  });

  test('a server that ignores the range sends the file again', () async {
    final ranges = serve((index) => index == 0 ? 50000 : null, ranges: false);
    final catalog = quick();
    expect(await catalog.download(model), isTrue);
    expect(ranges, [null, matches(RegExp(r'^bytes=[1-9][0-9]*-$'))]);
    expect(await File(catalog.path(model)).readAsBytes(), bytes);
  });

  test(
    'a connection that keeps dropping fails, and downloading again continues',
    () async {
      final ranges = serve((index) => index < 4 ? 20000 : null);
      final catalog = quick();
      expect(await catalog.download(model), isFalse);
      expect(catalog.downloadError, 'modelDownloadFailed');
      final partial = File('${catalog.path(model)}.part');
      final kept = await partial.length();
      expect(kept, inInclusiveRange(1, 80000));
      expect(await File(catalog.path(model)).exists(), isFalse);
      expect(await catalog.download(model), isTrue);
      expect(ranges.last, 'bytes=$kept-');
      expect(await File(catalog.path(model)).readAsBytes(), bytes);
      expect(await partial.exists(), isFalse);
    },
  );

  /// Writes the first [length] bytes of the model where an interrupted
  /// download leaves them.
  Future<File> interrupted(ModelCatalog catalog, int length) =>
      File('${catalog.path(model)}.part')
          .writeAsBytes(bytes.sublist(0, length));

  /// Answers [status] with Retry-After: 0 to the requests [refuse] picks, and
  /// the rest of the file to the others.
  List<String?> refuse(int status, bool Function(int index) refuse) {
    final seen = <String?>[];
    server.listen((request) async {
      final index = seen.length;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      seen.add(range);
      if (refuse(index)) {
        request.response.statusCode = status;
        request.response.headers.set(HttpHeaders.retryAfterHeader, '0');
        await request.response.close();
        return;
      }
      final start = range == null
          ? 0
          : int.parse(range.substring(6, range.length - 1));
      if (start > 0) {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${bytes.length - 1}/${bytes.length}',
        );
      }
      request.response.contentLength = bytes.length - start;
      request.response.add(bytes.sublist(start));
      await request.response.close();
    });
    return seen;
  }

  test(
    'a busy server is tried again and the downloaded part is kept',
    () async {
      final catalog = quick();
      await interrupted(catalog, 50000);
      final ranges = refuse(503, (index) => index < 2);
      expect(await catalog.download(model), isTrue);
      expect(ranges, List.filled(3, 'bytes=50000-'));
      expect(await File(catalog.path(model)).readAsBytes(), bytes);
    },
  );

  test(
    'a server that stays unavailable keeps the partial file for later',
    () async {
      final catalog = quick();
      final partial = await interrupted(catalog, 50000);
      final ranges = refuse(503, (_) => true);
      expect(await catalog.download(model), isFalse);
      expect(catalog.downloadError, 'modelDownloadFailed');
      expect(ranges, hasLength(ModelCatalog.retries + 1));
      expect(await partial.readAsBytes(), bytes.sublist(0, 50000));
    },
  );

  test('a refused request keeps what was downloaded', () async {
    final catalog = quick();
    final partial = await interrupted(catalog, 50000);
    final ranges = refuse(404, (_) => true);
    expect(await catalog.download(model), isFalse);
    expect(ranges, hasLength(1));
    expect(await partial.length(), 50000);
  });

  test('a range the server cannot serve starts the file over', () async {
    final catalog = quick();
    await interrupted(catalog, 50000);
    final ranges = refuse(416, (index) => index == 0);
    expect(await catalog.download(model), isTrue);
    expect(ranges, ['bytes=50000-', null]);
    expect(await File(catalog.path(model)).readAsBytes(), bytes);
  });

  test(
    'remove deletes the model and anything a download left behind',
    () async {
      final path = catalog.path(model);
      await File(path).writeAsBytes(bytes);
      await File('$path.part').writeAsBytes([1]);
      // The partial name older builds used.
      await File('$path.4242.1790000000000.part').writeAsBytes([2]);
      await File('${directory.path}/ggml-other.bin').writeAsBytes([3]);
      await catalog.remove(model);
      expect(directory.listSync().map((entry) => entry.uri.pathSegments.last), [
        'ggml-other.bin',
      ]);
    },
  );

  test('a failed replacement preserves the existing file', () async {
    final original = [1, 2, 3];
    await File(catalog.path(model)).writeAsBytes(original);
    server.listen((request) async {
      request.response.statusCode = 404;
      await request.response.close();
    });
    expect(await catalog.download(model), isFalse);
    expect(await File(catalog.path(model)).readAsBytes(), original);
  });
}
