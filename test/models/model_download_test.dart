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
      request.response.statusCode = 503;
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
