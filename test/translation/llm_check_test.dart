import 'dart:async';

import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fakes.dart';

Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 600 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue);
}

void main() {
  test('preparing the LLM loads it and lasts while its settings do', () async {
    final controller = fakeController()..translationModel = 'test-model';
    addTearDown(controller.dispose);
    final translator = controller.translator as FakeTranslator;
    translator.response = Completer<String>();
    final checking = controller.checkLlm();
    expect(controller.llmCheck!.state, LlmCheckState.checking);
    // Asking again while the model loads joins the same check.
    expect(controller.checkLlm(), same(checking));
    translator.response!.complete('你好');
    await checking;
    expect(controller.llmCheck!.state, LlmCheckState.ready);
    expect(translator.prepared, 1);
    expect(translator.calls, hasLength(1));
    controller.translationModel = 'another-model';
    expect(controller.llmCheck, isNull);
    controller.translationModel = 'test-model';
    expect(controller.llmCheck!.state, LlmCheckState.ready);
  });

  test('a check that fails says why', () async {
    final controller = fakeController();
    addTearDown(controller.dispose);
    (controller.translator as FakeTranslator).prepareFailure =
        'translationModelMissing';
    await controller.checkLlm();
    expect(controller.llmCheck!.state, LlmCheckState.failed);
    expect(controller.llmCheck!.error, contains('translationModelMissing'));
  });

  test('a session that starts while the model loads joins the check', () async {
    final controller = fakeController();
    addTearDown(controller.dispose);
    final translator = controller.translator as FakeTranslator;
    translator.response = Completer<String>();
    final checking = controller.checkLlm();
    await until(() => translator.calls.isNotEmpty);
    await controller.start(
      microphone: true,
      system: false,
      language: 'en',
      targetLanguage: 'zh',
    );
    expect(controller.phase, SessionPhase.listening);
    // The session did not restart the connection the check is loading on.
    expect(translator.prepared, 1);
    translator.response!.complete('你好');
    await checking;
    expect(controller.llmCheck!.state, LlmCheckState.ready);
    await controller.stop();
  });

  test('a session that translated leaves the model marked ready', () async {
    final controller = fakeController();
    addTearDown(controller.dispose);
    expect(controller.llmCheck, isNull);
    await controller.start(
      microphone: true,
      system: false,
      language: 'en',
      targetLanguage: 'zh',
    );
    (controller.audio as FakeAudio).events.add(chunk('microphone', 0));
    await until(
      () => controller.record?.lines.singleOrNull?.translationStatus == 'done',
    );
    await controller.stop();
    expect(controller.llmCheck!.state, LlmCheckState.ready);
  });
}
