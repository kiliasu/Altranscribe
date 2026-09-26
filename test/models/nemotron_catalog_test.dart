import 'dart:convert';
import 'dart:io';

import 'package:altranscribe/data/services/models/model_catalog.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// A tiny two-file model served from loopback, so the multi-file download,
/// verification and resume paths run without the real 650 MB.
class TinyNemotron extends NemotronModel {
  TinyNemotron(this.base, List<ModelFile> files)
    : super(
        'tiny-nemotron',
        'Tiny',
        'Tiny',
        repo: 'test/tiny',
        revision: 'main',
        files: files,
        multilingual: false,
        licenseName: 'Test',
        licenseUrl: 'https://example.test/license',
        modelCard: 'https://example.test/card',
      );
  final Uri base;
  @override
  Uri downloadUri(ModelFile file) => base.resolve(file.name);
}

void main() {
  late Directory directory;
  late HttpServer server;
  final contents = {
    'encoder.int8.onnx': List<int>.generate(5000, (i) => i % 251),
    'decoder.int8.onnx': List<int>.generate(700, (i) => (i * 7) % 253),
  };
  var corruptDecoder = false;
  final requests = <String>[];

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('altranscribe-nemotron');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final name = request.uri.pathSegments.last;
      requests.add(name);
      final body = contents[name];
      if (body == null) {
        request.response.statusCode = 404;
      } else {
        final bytes = corruptDecoder && name.startsWith('decoder')
            ? [...body.take(body.length - 1), 0]
            : body;
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
      }
      await request.response.close();
    });
    corruptDecoder = false;
    requests.clear();
  });
  tearDown(() async {
    await server.close(force: true);
    await directory.delete(recursive: true);
  });

  NemotronModel model() => TinyNemotron(
    Uri.parse('http://127.0.0.1:${server.port}/'),
    [
      for (final entry in contents.entries)
        ModelFile(
          entry.key,
          entry.value.length,
          sha256.convert(entry.value).toString(),
        ),
    ],
  );

  test('downloads every file into the model folder, verifying each one', () async {
    final catalog = ModelCatalog(directory);
    addTearDown(catalog.dispose);
    final tiny = model();
    final progress = <int>[];
    catalog.addListener(() => progress.add(catalog.receivedBytes));
    expect(await catalog.download(tiny), isTrue);
    expect(catalog.downloadError, isNull);
    expect(progress.last, tiny.bytes);
    final folder = Directory(catalog.folder(tiny));
    expect(
      folder.listSync().map((f) => f.uri.pathSegments.last).toSet(),
      contents.keys.toSet(),
    );
    expect(
      utf8.decode(
        File('${folder.path}/decoder.int8.onnx').readAsBytesSync(),
        allowMalformed: true,
      ).length,
      700,
    );
    expect(catalog.downloadingModel, isNull);

    // A second download only fetches what is missing.
    File('${folder.path}/decoder.int8.onnx').deleteSync();
    requests.clear();
    expect(await catalog.download(tiny), isTrue);
    expect(requests, ['decoder.int8.onnx']);
  });

  test('a corrupt file is rejected and leaves nothing behind', () async {
    final catalog = ModelCatalog(directory);
    addTearDown(catalog.dispose);
    corruptDecoder = true;
    final tiny = model();
    expect(await catalog.download(tiny), isFalse);
    expect(catalog.downloadError, 'modelDownloadInvalid');
    final folder = Directory(catalog.folder(tiny));
    expect(File('${folder.path}/encoder.int8.onnx').existsSync(), isTrue);
    expect(File('${folder.path}/decoder.int8.onnx').existsSync(), isFalse);
    expect(
      folder.listSync().where((f) => f.path.endsWith('.part')),
      isEmpty,
    );
  });

  test('scan reports folders as missing, incomplete or available', () async {
    final catalog = ModelCatalog(directory);
    addTearDown(catalog.dispose);
    final real = ModelCatalog.nemotronModels.first;
    expect((await catalog.scan())[real.id], ModelAvailability.missing);
    final folder = Directory(catalog.folder(real))..createSync(recursive: true);
    File('${folder.path}/tokens.txt').writeAsBytesSync(
      List.filled(real.files.last.bytes, 1),
    );
    expect((await catalog.scan())[real.id], ModelAvailability.incomplete);
    for (final file in real.files) {
      // Sparse files keep this cheap: length is what scan checks.
      final target = File('${folder.path}/${file.name}');
      final handle = target.openSync(mode: FileMode.write);
      handle.truncateSync(file.bytes);
      handle.closeSync();
    }
    expect((await catalog.scan())[real.id], ModelAvailability.available);
    expect((await catalog.scan())['large-v3-turbo'], ModelAvailability.missing);
  });
}
