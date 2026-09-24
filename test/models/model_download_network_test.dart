import 'dart:io';

import 'package:altranscribe/data/services/models/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'official Tiny download passes the pinned SHA-256 and catalog scan',
    () async {
      final directory = await Directory('build').createTemp('model-network-');
      final catalog = ModelCatalog(directory);
      try {
        final model = ModelCatalog.models.firstWhere(
          (item) => item.id == 'tiny',
        );
        expect(
          await catalog.download(model),
          isTrue,
          reason: catalog.downloadError,
        );
        expect((await catalog.scan())[model.id], ModelAvailability.available);
      } finally {
        catalog.dispose();
        await directory.delete(recursive: true);
      }
    },
    skip: !const bool.fromEnvironment('MODEL_DOWNLOAD_SMOKE'),
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
