import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:altranscribe/data/services/cloud/cloud_provider.dart';
import 'package:altranscribe/data/services/cloud/credential_store.dart';

class CloudLiveText {
  const CloudLiveText({
    required this.id,
    required this.source,
    required this.text,
    required this.startMs,
    required this.endMs,
    this.translation,
    this.finalized = false,
    this.continuous = false,
    this.serverConfirmed = true,
    this.continues = false,
    this.translationFinalized,
    this.timingEstimated = false,
  });
  final String id, source, text;
  final String? translation;
  final int startMs, endMs;
  final bool finalized, continuous, continues;
  final bool serverConfirmed;
  final bool? translationFinalized;
  final bool timingEstimated;
}

class _TranslationWindow {
  String input = '', output = '';
}

typedef CloudSocketConnector = Future<WebSocket> Function(
  Uri uri,
  Map<String, String> headers,
);

/// One connection per audio source: no microphone/system mixing, no assistant
/// prompts, and no replay of captured audio after a failed connection.
class CloudLive {
  CloudLive({
    required this.credentials,
    required this.provider,
    required this.directTranslation,
    required this.source,
    required this.language,
    required this.targetLanguage,
    required this.onText,
    required this.onError,
    this.onExpiring,
    CloudSocketConnector? connect,
    this.drainTimeout = const Duration(seconds: 20),
  }) : connect =
           connect ??
           ((uri, headers) =>
               WebSocket.connect(uri.toString(), headers: headers));
  final CredentialStore credentials;
  final SpeechProvider provider;
  final bool directTranslation;
  final String source, language;
  final String? targetLanguage;
  final void Function(CloudLiveText) onText;
  final void Function(String) onError;
  final void Function(Duration?)? onExpiring;
  final CloudSocketConnector connect;
  final Duration drainTimeout;
  int get sampleRate => provider == SpeechProvider.openAI ? 24000 : 16000;
  bool get atQuietBoundary => _firstMs < 0 || _quietBytes >= sampleRate * 2;
  WebSocket? _socket;
  final _ready = Completer<bool>();
  Completer<void> _changed = Completer<void>();
  bool _cancelled = false, _finishing = false, _closedByServer = false;
  String? _failure;
  int _lastMs = 0, _firstMs = -1, _windowStart = 0, _windowBytes = 0;
  int _quietBytes = 0, _sequence = 0, _pendingCommits = 0;
  bool _windowHasVoice = false, _awaitingOutput = false;
  String _input = '', _output = '';
  DateTime? _lastTranscriptAt;
  bool _generationCompleted = false;
  final _texts = <String, String>{};
  final _ranges = <String, (int, int)>{};
  final _commits = Queue<(int, int, bool)>();
  final _continuations = <String>{};
  final _completed = <String>{};
  final _eventIds = <String>{};
  final _translationWindows = <int, _TranslationWindow>{};
  int _inputWindow = -1, _outputWindow = -1;
  static const _translationWindowMs = 5000;

  Uri endpoint(String key) => provider == SpeechProvider.openAI
      ? Uri.parse(
          directTranslation
              ? 'wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate'
              : 'wss://api.openai.com/v1/realtime?intent=transcription',
        )
      : Uri.https(
          'generativelanguage.googleapis.com',
          '/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent',
          {'key': key},
        ).replace(scheme: 'wss');

  Map<String, Object?> setup() {
    if (provider == SpeechProvider.openAI) {
      return {
        'type': 'session.update',
        'session': directTranslation
            ? {
                'audio': {
                  'input': {
                    'transcription': {'model': 'gpt-realtime-whisper'},
                  },
                  'output': {'language': targetLanguage},
                },
              }
            : {
                'type': 'transcription',
                'audio': {
                  'input': {
                    'format': {'type': 'audio/pcm', 'rate': 24000},
                    'transcription': {
                      'model': 'gpt-live-transcribe',
                      if (language != 'auto') 'languages': [language],
                    },
                    // Commit at a quiet boundary (or 20 s); deltas still arrive live.
                    'turn_detection': null,
                  },
                },
              },
      };
    }
    return {
      'setup': {
        'model': 'models/${provider.liveModel(directTranslation)}',
        'generationConfig': directTranslation
            ? {
                'responseModalities': ['AUDIO'],
                'translationConfig': {
                  'targetLanguageCode': targetLanguage == 'zh'
                      ? 'zh-Hans'
                      : targetLanguage,
                  'echoTargetLanguage': true,
                },
              }
            : {
                'responseModalities': ['TEXT'],
              },
        // These fields belong to setup, as serialized by Google's SDK.
        // The live-translate guide's nested example is rejected by the API.
        'inputAudioTranscription': directTranslation
            ? <String, Object?>{}
            : {
                'languageCodes': [
                  if (language != 'auto') geminiLanguage(language),
                ],
              },
        if (directTranslation) 'outputAudioTranscription': <String, Object?>{},
      },
    };
  }

  Future<void> start() async {
    try {
      final key = await credentials.read(provider.cloud);
      if (_cancelled) throw StateError('cloudCancelled');
      if (key.isEmpty) throw StateError('cloudKeyMissing');
      final connection = connect(endpoint(key), {
        if (provider == SpeechProvider.openAI) 'Authorization': 'Bearer $key',
      });
      // Close late connections even if startup was cancelled or timed out.
      unawaited(
        connection.then((socket) {
          if (_cancelled) unawaited(socket.close());
        }, onError: (Object _) {}),
      );
      _socket = await connection.timeout(const Duration(seconds: 15));
      if (_cancelled) throw StateError('cloudCancelled');
      _socket!.pingInterval = const Duration(seconds: 15);
      _socket!.listen(
        (data) {
          try {
            handle(
              jsonDecode(data is String ? data : utf8.decode(data as List<int>))
                  as Map<String, dynamic>,
            );
          } catch (_) {
            _fail('cloudInvalidResponse');
          }
        },
        onError: (Object _) => _fail('cloudConnectionFailed'),
        onDone: () {
          if (_cancelled || _closedByServer) return;
          if (provider == SpeechProvider.gemini &&
              _finishing &&
              _generationCompleted) {
            // A completed drain may be followed immediately by server expiry.
            _closedByServer = true;
            _signal();
          } else {
            _fail('cloudDisconnected');
          }
        },
      );
      _send(setup());
      if (!await _ready.future.timeout(const Duration(seconds: 15))) {
        throw StateError(_failure ?? 'cloudCancelled');
      }
    } catch (e) {
      cancel();
      if (e is StateError) rethrow;
      throw StateError('cloudConnectionFailed');
    }
  }

  void _send(Map<String, Object?> message) {
    if (_cancelled) return;
    if (_socket?.readyState != WebSocket.open) {
      _fail('cloudDisconnected');
      return;
    }
    _socket!.add(jsonEncode(message));
  }

  void add(Uint8List pcm, int startMs, int endMs) {
    if (_cancelled || _finishing || _failure != null) return;
    if (_firstMs < 0) {
      _firstMs = startMs;
      _windowStart = startMs;
    }
    _lastMs = endMs;
    var energy = 0.0;
    final data = ByteData.sublistView(pcm);
    for (var i = 0; i + 1 < pcm.length; i += 2) {
      final sample = data.getInt16(i, Endian.little) / 32768;
      energy += sample * sample;
    }
    final voice = pcm.isNotEmpty && sqrt(energy / (pcm.length / 2)) >= 0.002;
    if (voice) {
      _windowHasVoice = true;
      _awaitingOutput = true;
    }
    _quietBytes = voice ? 0 : _quietBytes + pcm.length;
    _windowBytes += pcm.length;
    _send(
      provider == SpeechProvider.openAI
          ? {
              'type': directTranslation
                  ? 'session.input_audio_buffer.append'
                  : 'input_audio_buffer.append',
              'audio': base64Encode(pcm),
            }
          : {
              'realtimeInput': {
                'audio': {
                  'data': base64Encode(pcm),
                  'mimeType': 'audio/pcm;rate=16000',
                },
              },
            },
    );
    if (provider == SpeechProvider.openAI &&
        !directTranslation &&
        (_windowBytes >= sampleRate * 2 * 4 ||
            (_windowHasVoice && _quietBytes >= sampleRate * 2 * 0.6))) {
      _commit(continues: _quietBytes < sampleRate * 2 * 0.6);
    }
  }

  void _commit({bool continues = false}) {
    if (_windowBytes == 0) return;
    // Pad sub-100 ms final buffers to the documented minimum commit length.
    final padding = sampleRate ~/ 5 - _windowBytes;
    if (padding > 0) {
      _send({
        'type': 'input_audio_buffer.append',
        'audio': base64Encode(Uint8List(padding)),
      });
    }
    _commits.add((_windowStart, _lastMs, continues));
    _pendingCommits++;
    _windowStart = _lastMs;
    _windowBytes = _quietBytes = 0;
    _windowHasVoice = false;
    _send({'type': 'input_audio_buffer.commit'});
    if (_pendingCommits > 8) _fail('cloudTooSlow');
  }

  void _emit(
    String id,
    String text, {
    bool finalized = false,
    String? translation,
    bool continuous = false,
    bool serverConfirmed = true,
    bool? translationFinalized,
    bool timingEstimated = false,
    (int, int)? range,
  }) {
    onText(
      CloudLiveText(
        id: '$source:$id',
        source: source,
        text: text,
        startMs: range?.$1 ?? max(0, _firstMs),
        endMs: range?.$2 ?? _lastMs,
        translation: translation,
        finalized: finalized,
        continuous: continuous,
        serverConfirmed: serverConfirmed,
        translationFinalized: translationFinalized,
        timingEstimated: timingEstimated,
        continues: _continuations.contains(id),
      ),
    );
  }

  void _continuous({bool finalized = false, bool serverConfirmed = true}) =>
      _emit(
        'stream',
        _input,
        translation: _output,
        continuous: true,
        finalized: finalized,
        serverConfirmed: serverConfirmed,
      );

  void _translationDelta(Map<String, dynamic> event, {required bool input}) {
    final delta = event['delta'] as String;
    final elapsed = event['elapsed_ms'];
    if (elapsed is! num || !elapsed.isFinite || elapsed < 0) {
      // Without alignment metadata there is no safe sentence-to-sentence match.
      // Keep these fragments in a separate continuous stream, never guess a row.
      if (input) {
        _input += delta;
      } else {
        _output += delta;
      }
      _continuous();
      return;
    }
    final index = elapsed ~/ _translationWindowMs;
    final window = _translationWindows.putIfAbsent(
      index,
      _TranslationWindow.new,
    );
    final previous = input ? _inputWindow : _outputWindow;
    if (input) {
      window.input += delta;
      _inputWindow = max(_inputWindow, index);
    } else {
      window.output += delta;
      _outputWindow = max(_outputWindow, index);
    }
    if (previous >= 0 && index > previous) _translationWindow(previous);
    _translationWindow(index);
  }

  void _translationWindow(int index) {
    final window = _translationWindows[index]!;
    final start = max(0, _firstMs) + index * _translationWindowMs;
    _emit(
      'window:$index',
      window.input,
      translation: window.output,
      // A closed reading window is not a provider-confirmed speech turn.
      finalized: _closedByServer || index < _inputWindow,
      translationFinalized: _closedByServer || index < _outputWindow,
      serverConfirmed: _closedByServer,
      continuous: true,
      timingEstimated: true,
      range: (start, max(start, min(_lastMs, start + _translationWindowMs))),
    );
  }

  void handle(Map<String, dynamic> event) {
    if (_cancelled) return;
    final eventId = event['event_id'] as String?;
    if (eventId != null && !_eventIds.add(eventId)) return;
    if (_eventIds.length > 4096) _eventIds.remove(_eventIds.first);
    if (event['type'] == 'error' || event['error'] != null) {
      final code = (event['error'] as Map?)?['code'];
      _fail(
        code == 'insufficient_quota' ||
                code == 'rate_limit_exceeded' ||
                code == 429
            ? 'cloudHttp429'
            : 'cloudResponseFailed',
      );
      return;
    }
    if (event['type'] == 'session.updated' ||
        event.containsKey('setupComplete')) {
      if (!_ready.isCompleted) _ready.complete(true);
    }
    if (provider == SpeechProvider.openAI) {
      switch (event['type']) {
        case 'input_audio_buffer.committed':
          final id = event['item_id'] as String;
          if (_commits.isEmpty) {
            _fail('cloudInvalidResponse');
            break;
          }
          final committed = _commits.removeFirst();
          _ranges[id] = (committed.$1, committed.$2);
          if (committed.$3) _continuations.add(id);
          if (_texts.containsKey(id)) {
            _emit(
              id,
              _texts[id]!,
              finalized: _completed.contains(id),
              range: _ranges[id],
            );
          }
        case 'conversation.item.input_audio_transcription.delta':
          final id = event['item_id'] as String;
          if (_completed.contains(id)) break;
          _texts[id] = '${_texts[id] ?? ''}${event['delta'] as String}';
          _emit(id, _texts[id]!, range: _ranges[id] ?? (_windowStart, _lastMs));
        case 'conversation.item.input_audio_transcription.completed':
          final id = event['item_id'] as String;
          if (!_completed.add(id)) break;
          _texts[id] = event['transcript'] as String;
          _pendingCommits = max(0, _pendingCommits - 1);
          _emit(
            id,
            _texts[id]!,
            finalized: true,
            range: _ranges[id] ?? (_windowStart, _lastMs),
          );
        case 'conversation.item.input_audio_transcription.failed':
          _fail('cloudResponseFailed');
        case 'session.input_transcript.delta':
          _translationDelta(event, input: true);
        case 'session.output_transcript.delta':
          _translationDelta(event, input: false);
        case 'session.closed':
          _closedByServer = true;
          for (final index in _translationWindows.keys) {
            _translationWindow(index);
          }
          if (_input.isNotEmpty || _output.isNotEmpty) {
            _continuous(finalized: true);
          }
      }
    } else {
      if (event.containsKey('goAway') && !_finishing) {
        final timeLeft = (event['goAway'] as Map?)?['timeLeft'];
        final match = RegExp(r'^(\d+(?:\.\d{1,9})?)s$')
            .firstMatch(timeLeft is String ? timeLeft : '');
        final remaining = match == null
            ? null
            : Duration(milliseconds: (double.parse(match[1]!) * 1000).floor());
        if (onExpiring != null) {
          onExpiring!(remaining);
        } else {
          _fail('cloudSessionExpiring');
        }
      }
      final content = event['serverContent'] as Map?;
      if (content != null) {
        final interim =
            (content['interimInputTranscription'] as Map?)?['text'] as String?;
        final input =
            (content['inputTranscription'] as Map?)?['text'] as String?;
        final output =
            (content['outputTranscription'] as Map?)?['text'] as String?;
        if (directTranslation) {
          if (input != null) _input += input;
          if (output != null) _output += output;
          if (input?.isNotEmpty == true || output?.isNotEmpty == true) {
            _lastTranscriptAt = DateTime.now();
          }
          if (input != null || output != null) _continuous();
        } else {
          if (interim != null) {
            _emit(
              '$_sequence',
              interim,
              range: (_windowStart, _lastMs),
            ); // Replacement, never append.
          }
          if (input != null) {
            _emit(
              '${_sequence++}',
              input,
              finalized: true,
              range: (_windowStart, _lastMs),
            );
            _windowStart = _lastMs;
          }
        }
        // Transcribe Live sends generationComplete without turnComplete.
        // We consume text and do not wait for generated audio to be played.
        if (content['generationComplete'] == true ||
            content['turnComplete'] == true) {
          _awaitingOutput = false;
          _generationCompleted = true;
        }
        if (content['interrupted'] == true) _fail('cloudIncomplete');
      }
    }
    _signal();
  }

  void _signal() {
    final changed = _changed;
    _changed = Completer<void>();
    changed.complete();
  }

  void _fail(String error) {
    if (_failure != null || _cancelled) return;
    _failure = error;
    if (!_ready.isCompleted) _ready.complete(false);
    _signal();
    onError(error);
  }

  /// Flush the final spoken audio before closing; a timeout is an incomplete
  /// record, never a successful stop with silently missing last words.
  Future<void> finish() async {
    if (_cancelled) return;
    _finishing = true;
    _generationCompleted = false;
    if (provider == SpeechProvider.gemini &&
        directTranslation &&
        _firstMs >= 0) {
      // This interpreter advances on audio frames. Give it trailing silence at
      // real-time pace before ending the stream, so final words can be emitted.
      for (var i = 0; i < 30 && !_cancelled && _failure == null; i++) {
        _send({
          'realtimeInput': {
            'audio': {
              'data': base64Encode(Uint8List(sampleRate ~/ 5)),
              'mimeType': 'audio/pcm;rate=16000',
            },
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    if (provider == SpeechProvider.openAI) {
      if (directTranslation) {
        _send({'type': 'session.close'});
      } else {
        _commit();
      }
    } else {
      _send({
        'realtimeInput': {'audioStreamEnd': true},
      });
    }
    final deadline = DateTime.now().add(drainTimeout);
    try {
      if (provider == SpeechProvider.gemini && directTranslation) {
        // The preview interpreter may never emit a completion event. A bounded
        // text drain is useful, but must NOT be presented as server-confirmed.
        final drainStarted = DateTime.now();
        while (!_cancelled && _failure == null && !_generationCompleted) {
          final now = DateTime.now();
          final quietFrom =
              _lastTranscriptAt == null ||
                  _lastTranscriptAt!.isBefore(drainStarted)
              ? drainStarted
              : _lastTranscriptAt!;
          if (now.difference(quietFrom) >= const Duration(seconds: 2) &&
              (_firstMs < 0 || (_input.isNotEmpty && _output.isNotEmpty))) {
            break;
          }
          if (now.isAfter(deadline)) throw TimeoutException('drain');
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        if (_failure != null) throw StateError(_failure!);
        _continuous(finalized: true, serverConfirmed: _generationCompleted);
        return;
      }
      bool pending() => provider == SpeechProvider.openAI
          ? (directTranslation ? !_closedByServer : _pendingCommits > 0)
          : _awaitingOutput;
      while (pending() && _failure == null && !_cancelled) {
        final remaining = deadline.difference(DateTime.now());
        if (remaining.isNegative) throw TimeoutException('drain');
        await _changed.future.timeout(remaining);
      }
      if (_failure != null) throw StateError(_failure!);
    } on TimeoutException {
      throw StateError('cloudIncomplete');
    } finally {
      cancel();
    }
  }

  void cancel() {
    _cancelled = true;
    if (!_ready.isCompleted) _ready.complete(false);
    _signal();
    unawaited(_socket?.close());
  }
}
