// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:altranscribe/app/app.dart';
import 'package:altranscribe/data/services/files/android_audio_decoder.dart';
import 'package:altranscribe/features/files/file_import_panel.dart';
import 'package:altranscribe/shared/platform/mobile_platform.dart';
import 'package:altranscribe/data/services/audio/audio_service.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:altranscribe/data/repositories/record_store.dart';
import 'package:altranscribe/data/services/transcription/whisper_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('Android native document selection and share import', (
    tester,
  ) async {
    await MobilePlatform.initialize();
    final root = Directory(MobilePlatform.dataDirectory!).parent;
    final audio = PlatformAudioService();
    final live = RealtimeController(
      audio: audio,
      engine: WhisperService(audio),
      store: RecordStore(Directory('${root.path}/import-smoke')),
    );
    addTearDown(live.dispose);
    await live.initialize();
    await tester.pumpWidget(AltranscribeApp(realtime: live));
    await tester.pumpAndSettle();
    await tester.tap(find.text('文件').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('choose-files')));
    print('ANDROID_IMPORT_WAIT PICK_TWO_FILES');
    List<String> selected() =>
        tester.widget<FileImportPanel>(find.byType(FileImportPanel)).paths;
    final deadline = DateTime.now().add(const Duration(minutes: 5));
    while (selected().length != 2) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Select both synthetic files in Download/AltranscribeTest');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    final paths = [...selected()];
    expect(paths.every((path) => path.startsWith('content://')), true);
    for (final path in paths) {
      final chunks = await AndroidAudioDecoder()
          .decode(path, chunkSeconds: 2)
          .toList();
      expect(chunks.last.endMs, inInclusiveRange(2900, 3150));
    }
    print('ANDROID_IMPORT_SAF_PASSED');
    final removed = paths.first;
    final share = File('${root.path}/android-share-fixture.json');
    await share.writeAsString(
      jsonEncode({'uri': Uri.parse(removed).replace(fragment: '').toString()}),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('remove-file-0')));
    await tester.pumpAndSettle();
    expect(selected().length, 1);
    print('ANDROID_IMPORT_WAIT SHARE_FILE');
    while (selected().length != 2) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Send the selected test content URI with ACTION_SEND');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    final chunks = await AndroidAudioDecoder().decode(selected().last).toList();
    expect(chunks.last.endMs, inInclusiveRange(2900, 3150));
    await share.delete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    print('ANDROID_IMPORT_SHARE_PASSED');
    await tester.pumpWidget(const SizedBox());
  }, timeout: const Timeout(Duration(minutes: 7)));
}
