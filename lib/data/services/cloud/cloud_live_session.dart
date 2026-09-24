import 'dart:async';
import 'dart:typed_data';

import 'package:altranscribe/data/services/cloud/cloud_live.dart';
import 'package:altranscribe/data/services/cloud/cloud_provider.dart';
import 'package:altranscribe/data/services/cloud/credential_store.dart';

/// Keeps one recording across Gemini connection limits. Each captured frame is
/// sent to exactly one connection; the retiring connection only drains its tail.
class CloudLiveSession {
  CloudLiveSession({
    required this.credentials,
    required this.provider,
    required this.directTranslation,
    required this.source,
    required this.language,
    required this.targetLanguage,
    required this.onText,
    required this.onError,
    this.onRenewed,
    this.connect,
    this.renewAfter = const Duration(minutes: 9),
    this.renewBy = const Duration(minutes: 9, seconds: 30),
    this.drainTimeout = const Duration(seconds: 20),
  });

  final CredentialStore credentials;
  final SpeechProvider provider;
  final bool directTranslation;
  final String source, language;
  final String? targetLanguage;
  final void Function(CloudLiveText) onText;
  final void Function(String) onError;
  final void Function()? onRenewed;
  final CloudSocketConnector? connect;
  final Duration renewAfter, renewBy, drainTimeout;
  int get sampleRate => provider == SpeechProvider.openAI ? 24000 : 16000;

  CloudLive? _active, _candidate;
  Stopwatch _age = Stopwatch();
  Stopwatch? _candidateAge;
  final _retiring = <CloudLive, Future<void>>{};
  Timer? _prepareTimer, _switchTimer, _expiryTimer;
  Duration? _expiryAt;
  bool _candidateReady = false, _urgent = false;
  bool _stopping = false, _cancelled = false;
  String? _failure;
  int _generation = 0;
  Future<void>? _finishing;

  CloudLive _create() {
    final generation = _generation++;
    late final CloudLive connection;
    connection = CloudLive(
      credentials: credentials,
      provider: provider,
      directTranslation: directTranslation,
      source: source,
      language: language,
      targetLanguage: targetLanguage,
      connect: connect,
      drainTimeout: drainTimeout,
      onText: (text) {
        if (_cancelled ||
            (connection != _active && !_retiring.containsKey(connection))) {
          return;
        }
        onText(
          CloudLiveText(
            id: '$generation/${text.id}',
            source: text.source,
            text: text.text,
            translation: text.translation,
            startMs: text.startMs,
            endMs: text.endMs,
            finalized: text.finalized,
            continuous: text.continuous,
            serverConfirmed: text.serverConfirmed,
            continues: text.continues,
            translationFinalized: text.translationFinalized,
            timingEstimated: text.timingEstimated,
          ),
        );
      },
      onError: _fail,
      onExpiring: (remaining) {
        if (_stopping || _cancelled || _retiring.containsKey(connection)) {
          return;
        }
        // An already expiring replacement must not cause an endless retry loop.
        if (connection != _active || remaining == null) {
          _fail('cloudSessionExpiring');
          return;
        }
        final budget = remaining - drainTimeout - const Duration(seconds: 4);
        if (budget <= Duration.zero) {
          _fail('cloudSessionExpiring');
          return;
        }
        _urgent = true;
        // Repeated GoAway messages can only shorten the existing deadline.
        final deadline = _age.elapsed + budget;
        if (_expiryAt == null || deadline < _expiryAt!) {
          _expiryAt = deadline;
          _expiryTimer?.cancel();
          _expiryTimer = Timer(budget, () => _fail('cloudSessionExpiring'));
        }
        unawaited(_prepare());
        _switchIfReady();
      },
    );
    return connection;
  }

  Future<void> start() async {
    _age = Stopwatch()..start();
    _active = _create();
    await _active!.start();
    if (_failure != null) throw StateError(_failure!);
    if (!_stopping && !_cancelled) _schedule();
  }

  void _schedule() {
    _cancelTimers();
    if (provider != SpeechProvider.gemini) return;
    // Connection age includes setup and user pauses, independently per source.
    _prepareTimer = Timer(
      renewAfter - _age.elapsed,
      () => unawaited(_prepare()),
    );
    _switchTimer = Timer(renewBy - _age.elapsed, () {
      _urgent = true;
      if (!_candidateReady) {
        _fail('cloudSessionRenewalFailed');
      } else {
        _switchIfReady();
      }
    });
  }

  Future<void> _prepare() async {
    if (_stopping || _cancelled || _failure != null || _candidate != null) {
      return;
    }
    if (_retiring.isNotEmpty) {
      _fail('cloudSessionRenewalFailed');
      return;
    }
    final next = _candidate = _create();
    _candidateAge = Stopwatch()..start();
    try {
      await next.start();
      if (_stopping || _cancelled || _failure != null) {
        next.cancel();
        return;
      }
      _candidateReady = true;
      _switchIfReady();
    } catch (_) {
      if (!_stopping && !_cancelled) _fail('cloudSessionRenewalFailed');
    }
  }

  void add(Uint8List pcm, int startMs, int endMs) {
    if (_stopping || _cancelled || _failure != null) return;
    _active?.add(pcm, startMs, endMs);
    _switchIfReady();
  }

  void _switchIfReady() {
    if (_stopping || _cancelled || _failure != null || !_candidateReady) return;
    if (!_urgent && !_active!.atQuietBoundary) return;
    final previous = _active!;
    _active = _candidate;
    _candidate = null;
    _candidateReady = _urgent = false;
    _age = _candidateAge!;
    _schedule();
    // Register before finish can emit text, including synchronous completions.
    _retiring[previous] = Future<void>.microtask(previous.finish)
        .catchError((Object _) {
          _fail('cloudIncomplete');
        })
        .whenComplete(() {
          _retiring.remove(previous);
        });
    onRenewed?.call();
  }

  void _fail(String message) {
    if (_cancelled || _failure != null) return;
    _failure = message;
    _cancelTimers();
    _candidate?.cancel();
    onError(message);
  }

  Future<void> finish() => _finishing ??= _finish();

  Future<void> _finish() async {
    if (_cancelled) return;
    _stopping = true;
    _cancelTimers();
    _candidate?.cancel();
    try {
      await Future.wait([
        if (_active != null) _active!.finish(),
        ..._retiring.values,
      ]);
      if (_failure != null) throw StateError(_failure!);
    } finally {
      cancel();
    }
  }

  void _cancelTimers() {
    _prepareTimer?.cancel();
    _switchTimer?.cancel();
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _expiryAt = null;
  }

  void cancel() {
    _cancelled = true;
    _cancelTimers();
    _active?.cancel();
    _candidate?.cancel();
    for (final connection in _retiring.keys) {
      connection.cancel();
    }
  }
}
