import 'package:altranscribe/app/app.dart';
import 'package:altranscribe/data/services/cloud/cloud_provider.dart';
import 'package:altranscribe/data/services/remote/discovery.dart';
import 'package:altranscribe/data/services/remote/remote_protocol.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

/// A controller whose network answers are scripted: discovery returns
/// [hosts], and a health check only counts itself.
class ScriptedHosts extends RealtimeController {
  ScriptedHosts(this.hosts)
    : super(
        audio: FakeAudio(),
        engine: FakeEngine(),
        store: MemoryStore(),
        translator: FakeTranslator(),
        recordSummarizer: FakeTranslator(),
        catalog: FakeModelCatalog(),
      );
  final List<DiscoveredHost> hosts;
  int probes = 0;

  @override
  Future<List<DiscoveredHost>> findHosts() async => hosts;

  @override
  Future<void> probeHost({bool discover = true}) async => probes++;

  void show(HostStatus status) {
    hostStatus = status;
    notifyListeners();
  }
}

const study = DiscoveredHost(
  id: 'study',
  name: 'Study PC',
  address: 'http://192.168.1.20:8178',
  busy: false,
);
const lab = DiscoveredHost(
  id: 'lab',
  name: 'Lab PC',
  address: 'http://192.168.1.30:8178',
  busy: false,
);

ScriptedHosts pairedWithStudy(List<DiscoveredHost> nearby) {
  final live = ScriptedHosts(nearby)
    ..initialized = true
    ..useRemote = true;
  live.remoteConnection
    ..address = study.address
    ..token = 'x' * 43
    ..name = study.name
    ..hostId = study.id
    ..info = {'llmProvider': 'ollama', 'llmModel': 'gemma-test'};
  live.hostStatus = HostStatus.online;
  live.hostSeen = DateTime.now();
  return live;
}

void main() {
  Future<void> openDevices(WidgetTester tester, ScriptedHosts live) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(live.dispose);
    await tester.pumpWidget(AltranscribeApp(realtime: live));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('find-hosts')));
    await tester.pumpAndSettle();
  }

  String status(WidgetTester tester) => tester
      .widgetList<Text>(
        find.descendant(
          of: find.byKey(const Key('host-status')),
          matching: find.byType(Text),
        ),
      )
      .single
      .data!;

  testWidgets(
    'the connected host shows once, marked connected, with what it does',
    (tester) async {
      final live = pairedWithStudy([study, lab]);
      await openDevices(tester, live);

      expect(status(tester), '已连接 · 同一网络');
      expect(find.text('Study PC'), findsOneWidget);
      expect(find.textContaining('192.168.1.20:8178'), findsOneWidget);
      expect(find.textContaining('负责转录和翻译'), findsOneWidget);
      // Found nearby too, but listed only as the connected host.
      expect(find.byKey(const ValueKey('nearby-study')), findsNothing);
      expect(find.byKey(const ValueKey('nearby-lab')), findsOneWidget);
      expect(find.text('连接其他主机'), findsOneWidget);
      expect(find.byKey(const Key('recheck-host')), findsNothing);

      // Recognizing speech here while the host lends its text model.
      live.speechProvider = SpeechProvider.nemotron;
      live.show(HostStatus.busy);
      await tester.pumpAndSettle();
      expect(status(tester), '已连接 · 忙碌 · 同一网络');
      expect(find.textContaining('负责翻译和摘要'), findsOneWidget);
      live.hostLlm = false;
      live.show(HostStatus.busy);
      await tester.pumpAndSettle();
      expect(find.textContaining('暂未使用'), findsOneWidget);

      // An unreachable host says so and can be checked again.
      live.show(HostStatus.offline);
      await tester.pumpAndSettle();
      expect(status(tester), startsWith('离线 · '));
      final before = live.probes;
      await tester.tap(find.byKey(const Key('recheck-host')));
      await tester.pumpAndSettle();
      expect(live.probes, before + 1);
      // After a restart the last sighting is unknown rather than "never".
      live.hostSeen = null;
      live.show(HostStatus.offline);
      await tester.pumpAndSettle();
      expect(status(tester), '离线');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('a saved host found nearby is checked again rather than listed', (
    tester,
  ) async {
    final live = pairedWithStudy([study])..hostStatus = HostStatus.offline;
    final before = live.probes;
    await openDevices(tester, live);
    // Watching the page checks once; finding the host nearby checks again.
    expect(live.probes, greaterThanOrEqualTo(before + 2));
    expect(find.byKey(const ValueKey('nearby-study')), findsNothing);
    expect(find.text('附近没有其他共享中的主机。'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('without a saved host the page offers hosts to connect to', (
    tester,
  ) async {
    final live = ScriptedHosts([study])..initialized = true;
    await openDevices(tester, live);
    expect(find.byKey(const Key('host-status')), findsNothing);
    expect(find.text('连接主机'), findsOneWidget);
    expect(find.byKey(const ValueKey('nearby-study')), findsOneWidget);
    expect(find.byKey(const Key('connect-manually')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
