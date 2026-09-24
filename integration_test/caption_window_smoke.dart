import 'package:altranscribe/data/models/transcript_record.dart';

// Run with dev.ps1 -CaptionsSmoke. Real Windows windows/Flutter engines;
// synthesized text and fake capture/inference keep this test silent and private.
import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:altranscribe/main.dart' as app;
import 'package:altranscribe/app/app.dart';
import 'package:altranscribe/features/captions/caption_app.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:ffi/ffi.dart';
import 'package:material_ui/material_ui.dart';

import '../test/support/fakes.dart';

@pragma('vm:entry-point')
void captionMain() {
  app.captionMain();
  // This entrypoint exists only in the smoke target. Drive the rendered caption
  // widget without adding a test API to the production app.
  registerExtension('ext.captionSmoke', (method, parameters) async {
    StatefulElement? panel;
    void visit(Element element) {
      if (element is StatefulElement && element.widget is CaptionPanel) {
        panel = element;
      } else {
        element.visitChildren(visit);
      }
    }

    visit(WidgetsBinding.instance.rootElement!);
    if (panel == null) {
      return ServiceExtensionResponse.error(
        -32000,
        'Caption panel not mounted',
      );
    }
    final action = parameters['action'];
    if (action == 'snapshot') {
      return ServiceExtensionResponse.result(
        jsonEncode((panel!.widget as CaptionPanel).data),
      );
    }
    if (action == 'cancelDialog' || action == 'confirmDialog') {
      Navigator.of(panel!).pop(action == 'confirmDialog');
    } else {
      unawaited((panel!.state as dynamic).run(action) as Future<void>);
    }
    return ServiceExtensionResponse.result('{}');
  });
}

final user32 = DynamicLibrary.open('user32.dll');
final findWindow = user32
    .lookupFunction<
      IntPtr Function(Pointer<Utf16>, Pointer<Utf16>),
      int Function(Pointer<Utf16>, Pointer<Utf16>)
    >('FindWindowW');
final visible = user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'IsWindowVisible',
    );
final style = user32
    .lookupFunction<IntPtr Function(IntPtr, Int32), int Function(int, int)>(
      'GetWindowLongPtrW',
    );
final show = user32
    .lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>(
      'ShowWindow',
    );
final post = user32
    .lookupFunction<
      Int32 Function(IntPtr, Uint32, IntPtr, IntPtr),
      int Function(int, int, int, int)
    >('PostMessageW');
final opacity = user32
    .lookupFunction<
      Int32 Function(IntPtr, Pointer<Uint32>, Pointer<Uint8>, Pointer<Uint32>),
      int Function(int, Pointer<Uint32>, Pointer<Uint8>, Pointer<Uint32>)
    >('GetLayeredWindowAttributes');

int window(String title) {
  final text = title.toNativeUtf16();
  try {
    return findWindow(nullptr, text);
  } finally {
    calloc.free(text);
  }
}

void check(bool result, String name) {
  if (!result) throw StateError(name);
  stdout.writeln('PASS: $name');
}

Future<void> until(bool Function() ready) async {
  for (var i = 0; i < 150; i++) {
    if (ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('Timed out waiting for native caption state');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final live = fakeController()..generateSummary = false;
  final client = HttpClient();
  try {
    await live.start(
      microphone: true,
      system: true,
      language: 'en',
      targetLanguage: 'zh',
    );
    live.record!.lines.add(
      TranscriptLine(
        source: 'system',
        startMs: 0,
        endMs: 1000,
        text: 'Native caption window test.',
        translation: '原生悬浮字幕窗口测试。',
        translationStatus: 'done',
      ),
    );
    runApp(AltranscribeApp(realtime: live));
    await WidgetsBinding.instance.endOfFrame;
    live.setCaptionsVisible(true);
    await until(() => visible(window('Altranscribe · Captions')) != 0);
    final caption = window('Altranscribe · Captions');
    final mainWindow = window('Altranscribe');
    check(style(caption, -20) & 8 != 0, 'Caption is topmost');
    check(style(caption, -20) & 0x80 != 0, 'Caption is a tool window');
    show(mainWindow, 6);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    check(
      visible(caption) != 0,
      'Caption remains visible when main window is minimized',
    );
    show(mainWindow, 9);

    // Exercise the real secondary engine's UI callbacks through the debug VM.
    // No production test hooks or secondary recording/controller are involved.
    final service = (await Service.getInfo()).serverUri!;
    Future<Map> rpc(
      String method, [
      Map<String, String> query = const {},
    ]) async {
      final response = await (await client.getUrl(
        service.resolve(method).replace(queryParameters: query),
      )).close();
      final data =
          jsonDecode(await response.transform(utf8.decoder).join()) as Map;
      if (data['error'] != null) {
        throw StateError('VM $method failed: ${data['error']}');
      }
      return data['result'] as Map;
    }

    final isolates = (await rpc('getVM'))['isolates'] as List;
    final captionIsolate =
        isolates.firstWhere(
              (item) => item['id'] != Service.getIsolateId(Isolate.current),
            )['id']
            as String;
    Future<Map> action(String name) =>
        rpc('ext.captionSmoke', {'isolateId': captionIsolate, 'action': name});
    check(
      (await action('snapshot'))['rows'][0]['translation'] == '原生悬浮字幕窗口测试。',
      'Original and translation reach the secondary engine',
    );
    await action('pause');
    await until(() => live.phase == SessionPhase.paused);
    check(
      (live.audio as FakeAudio).paused,
      'Secondary pause reaches main capture',
    );
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await action('larger');
    await until(() => live.captionPreferences.fontSize == 26);
    check(true, 'Secondary font controls update shared preferences');
    await live.setCaptionPreferences(
      live.captionPreferences.copyWith(opacity: .7),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final alpha = calloc<Uint8>();
    final flags = calloc<Uint32>();
    try {
      check(
        opacity(caption, nullptr, alpha, flags) != 0 &&
            (alpha.value - 178).abs() <= 1,
        'Opacity applies to the real Windows window',
      );
    } finally {
      calloc.free(alpha);
      calloc.free(flags);
    }
    await action('discard');
    await until(() => live.discardConfirmationPending);
    await Future<void>.delayed(const Duration(milliseconds: 350));
    await action('cancelDialog');
    await until(() => !live.discardConfirmationPending);
    check(live.phase == SessionPhase.paused, 'Cancel discard remains paused');
    post(caption, 0x10, 0, 0);
    await until(() => !live.captionsVisible);
    check(
      live.active && visible(caption) == 0,
      'Native close hides captions without ending capture',
    );
    live.setCaptionsVisible(true);
    await until(() => visible(caption) != 0);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await action('discard');
    await until(() => live.discardConfirmationPending);
    await Future<void>.delayed(const Duration(milliseconds: 350));
    post(caption, 0x10, 0, 0);
    await until(
      () => !live.captionsVisible && !live.discardConfirmationPending,
    );
    check(
      live.phase == SessionPhase.paused,
      'Closing a discard dialog releases the lock and remains paused',
    );
    live.setCaptionsVisible(true);
    await until(() => visible(caption) != 0);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await action('stop');
    await until(() => !live.active && visible(caption) == 0);
    check(
      live.records.single.lines.single.translation != null,
      'Secondary stop saves text and closes caption window',
    );
    check(
      (live.engine as FakeEngine).starts == 1,
      'Second engine never starts inference',
    );
    await live.start(microphone: true, system: false, language: 'en');
    final discardedId = live.record!.id;
    live.setCaptionsVisible(true);
    await until(() => visible(caption) != 0);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await action('discard');
    await until(
      () =>
          live.discardConfirmationPending && live.phase == SessionPhase.paused,
    );
    await Future<void>.delayed(const Duration(milliseconds: 350));
    await action('confirmDialog');
    await until(() => !live.active && visible(caption) == 0);
    check(
      !(live.store as MemoryStore).values.containsKey(discardedId) &&
          live.records.length == 1,
      'Confirmed caption discard removes only the current transcript',
    );
    stdout.writeln('CAPTION_SMOKE_PASSED');
    exit(0);
  } catch (e, stack) {
    stderr.writeln('CAPTION_SMOKE_FAILED: $e\n$stack');
    exit(1);
  } finally {
    client.close(force: true);
    live.dispose();
  }
}
