import 'dart:io';

import 'package:altranscribe/app/app.dart';
import 'package:altranscribe/data/services/remote/paired_devices.dart';
import 'package:altranscribe/data/services/remote/remote_protocol.dart';
import 'package:altranscribe/data/services/remote/shared_host.dart';
import 'package:altranscribe/data/services/translation/translation_service.dart';
import 'package:altranscribe/data/services/transcription/whisper_service.dart';
import 'package:altranscribe/features/remote/remote_dialogs.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:altranscribe/shared/ui/qr_code.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../cloud/cloud_test.dart' show MemoryCredentials;
import '../support/fakes.dart';

RealtimeController controllerWithHost(SharedHost? host) => RealtimeController(
  audio: FakeAudio(),
  engine: FakeEngine(),
  store: MemoryStore(),
  translator: FakeTranslator(),
  recordSummarizer: FakeTranslator(),
  catalog: FakeModelCatalog(),
  credentials: MemoryCredentials(),
  sharedHost: host,
)..initialized = true;

void main() {
  testWidgets(
    'host shows a QR code and pairing code; a client pairs, is listed, and loses access when removed',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // Widget tests stub HttpClient with a 400 responder; pairing needs the real one.
      final overrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = overrides);
      final host = SharedHost(
        engine: FakeEngine(),
        translator: FakeTranslator(),
      );
      final server = controllerWithHost(host);
      addTearDown(server.dispose);
      await tester.runAsync(
        () => host.start(
          bindAddress: InternetAddress.loopbackIPv4,
          port: 0,
          name: 'Study PC',
          executable: 'test.exe',
          model: 'models/ggml-test.bin',
          compute: ComputeMode.cpu,
          directory: Directory('unused-test-data'),
          shareTranslation: true,
          llmProvider: LlmProvider.ollama,
          llmAddress: 'http://127.0.0.1:11434',
          llmModel: 'test-llm',
        ),
      );
      addTearDown(() => host.stop());
      await tester.pumpWidget(AltranscribeApp(realtime: server));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav-2')));
      await tester.pumpAndSettle();
      expect(find.text('已配对设备'), findsOneWidget);
      expect(find.textContaining('还没有配对的设备'), findsOneWidget);

      await tester.tap(find.byKey(const Key('add-device')));
      // The open panel repaints its countdown every second, so settle by time.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(SharedHostDialog), findsOneWidget);
      final code = host.devices.pairingCode;
      expect(code, isNotNull);
      expect(find.byKey(const Key('pairing-qr')), findsOneWidget);
      final qr = tester.widget<AltQrCode>(find.byKey(const Key('pairing-qr')));
      final invite = PairingInvite.parse(qr.data);
      expect(invite.address, host.address);
      expect(invite.code, code);
      expect(invite.name, 'Study PC');
      expect(invite.hostId, host.devices.hostId);
      expect(
        tester
            .widget<SelectableText>(find.byKey(const Key('pairing-code')))
            .data,
        '${code!.substring(0, 3)} ${code.substring(3)}',
      );
      await tester.tap(find.text('完成'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      // Closing the panel ends the pairing window; the sharing itself stays on.
      expect(host.devices.pairingCode, isNull);
      expect(host.running, isTrue);

      // A client pairs by typing the code the host displayed.
      host.devices.beginPairing();
      final client = controllerWithHost(null);
      addTearDown(client.dispose);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(AltranscribeApp(realtime: client));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('connect-manually')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('remote-address')),
        host.address,
      );
      // Pairing talks to the host over real HTTP, so wait for it in real time.
      Future<void> connectUntil(bool Function() done) =>
          tester.runAsync(() async {
            await tester.tap(find.byKey(const Key('connect-remote')));
            for (var i = 0; i < 100 && !done(); i++) {
              await Future<void>.delayed(const Duration(milliseconds: 50));
              await tester.pump();
            }
          });
      await tester.enterText(find.byKey(const Key('remote-token')), '000000');
      await connectUntil(
        () => find.textContaining('配对码错误').evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('配对码错误'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('remote-token')),
        host.devices.pairingCode!,
      );
      await connectUntil(
        () => find.byType(RemoteConnectionDialog).evaluate().isEmpty,
      );
      await tester.pumpAndSettle();
      expect(find.byType(RemoteConnectionDialog), findsNothing);
      expect(client.remoteConnection.token.length, greaterThanOrEqualTo(32));
      expect(client.remoteConnection.hostId, host.devices.hostId);
      expect(client.remoteConnection.name, 'Study PC');
      expect(client.hostStatus, HostStatus.online);
      expect(client.useRemote, isTrue);
      expect(host.devices.devices.single.name, Platform.localHostname);
      expect(host.devices.devices.single.platform, 'windows');
      expect(find.textContaining('已配对并选用主机'), findsOneWidget);
      expect(find.text('Study PC'), findsWidgets);
      expect(find.textContaining('在线'), findsWidgets);

      // The host lists the device and can remove it, which ends its access.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(AltranscribeApp(realtime: server));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav-2')));
      await tester.pumpAndSettle();
      final device = host.devices.devices.single;
      expect(find.byKey(ValueKey('paired-${device.id}')), findsOneWidget);
      expect(find.text('刚刚在线'), findsOneWidget);
      await tester.tap(find.byTooltip('移除设备'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-remove-device')));
      await tester.pumpAndSettle();
      expect(host.devices.devices, isEmpty);
      expect(find.textContaining('还没有配对的设备'), findsOneWidget);
      await tester.runAsync(() async {
        final probe = RemoteClient(
          RemoteConnection(
            address: host.address,
            token: client.remoteConnection.token,
          ),
        );
        await expectLater(
          probe.connect(),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              'remoteUnauthorized',
            ),
          ),
        );
        probe.close();
      });
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  test('pairing invites round-trip through the QR text and reject junk', () {
    const invite = PairingInvite(
      address: 'http://192.168.1.20:8178',
      code: '123456',
      name: 'Study PC',
      hostId: 'abc',
    );
    final parsed = PairingInvite.parse(invite.toUri().toString());
    expect(parsed.address, invite.address);
    expect(parsed.code, invite.code);
    expect(parsed.name, invite.name);
    expect(parsed.hostId, invite.hostId);
    for (final junk in [
      'https://example.com',
      'altranscribe://pair?address=http://192.168.1.20:8178&code=12',
      'altranscribe://pair?address=https://192.168.1.20:8178&code=123456',
      'altranscribe://other?address=http://192.168.1.20:8178&code=123456',
      '',
    ]) {
      expect(
        () => PairingInvite.parse(junk),
        throwsFormatException,
        reason: junk,
      );
    }
    expect(PairedDevices.constantTimeEquals('123456', '123456'), isTrue);
    expect(PairedDevices.constantTimeEquals('123456', '123457'), isFalse);
  });
}
