import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:altranscribe/app/theme/app_theme.dart';
import 'package:altranscribe/shared/platform/mobile_platform.dart';
import 'package:altranscribe/data/models/caption_preferences.dart';

const captionChannel = MethodChannel('altranscribe/captions');

/// The main engine owns the session. The other engine receives display data only.
class CaptionHost extends StatefulWidget {
  const CaptionHost({
    super.key,
    required this.controller,
    required this.english,
    required this.palette,
    required this.child,
  });
  final RealtimeController controller;
  final bool english;
  final AppPalette palette;
  final Widget child;
  @override
  State<CaptionHost> createState() => _CaptionHostState();
}

class _CaptionHostState extends State<CaptionHost> {
  bool nativeVisible = false, syncing = false, dirty = false;
  bool overlayConfirming = false;
  int visibilityRevision = 0;
  Brightness brightness = Brightness.light;
  bool reduceMotion = false;
  String? lastSnapshot;
  RealtimeController get live => widget.controller;

  @override
  void initState() {
    super.initState();
    live.addListener(requestSync);
    captionChannel.setMethodCallHandler(handle);
    if (MobilePlatform.android) MobilePlatform.onSessionAction = sessionAction;
  }

  Future<void> sessionAction(String action) async {
    if (action == 'interrupted' && live.active) {
      live.error = 'androidBackgroundInterrupted';
      await live.stop();
      return;
    }
    if (!live.active || live.discardConfirmationPending) return;
    if (action == 'captions') {
      live.setCaptionsVisible(!live.captionsVisible);
    } else if (action == 'pause') {
      await live.togglePause();
    } else if (action == 'stop') {
      await live.stopAndSave();
    }
  }

  void requestSync() {
    dirty = true;
    if (!syncing) unawaited(sync());
  }

  Map<String, Object?> snapshot() => {
    'english': widget.english,
    'palette': widget.palette.name,
    'dark': brightness == Brightness.dark,
    'reduceMotion': reduceMotion,
    'phase': live.phase.name,
    'pausePending': live.pausePending,
    'confirming': live.discardConfirmationPending,
    'hasTranslation': live.record?.targetLanguage != null,
    'preferences': live.captionPreferences.toJson(),
    'rows': captionRows(live.record, live.captionPreferences.sentences),
  };

  Future<void> sync() async {
    syncing = true;
    try {
      while (dirty && mounted) {
        dirty = false;
        final visible =
            live.captionsVisible && live.active && !live.processingFiles;
        if (!visible) {
          visibilityRevision++;
          if (overlayConfirming) {
            overlayConfirming = false;
            live.endDiscardConfirmation();
          }
          if (nativeVisible) await captionChannel.invokeMethod<void>('hide');
          nativeVisible = false;
          lastSnapshot = null;
          continue;
        }
        final data = snapshot();
        final encoded = jsonEncode(data);
        if (encoded != lastSnapshot) {
          await captionChannel.invokeMethod<void>(
            nativeVisible ? 'update' : 'show',
            data,
          );
          nativeVisible = true;
          lastSnapshot = encoded;
        }
      }
    } on Exception {
      // Do not leave a checked toggle when the native window could not open.
      if (mounted) {
        live.error = 'captionWindowFailed';
        live.setCaptionsVisible(false);
      }
    } finally {
      syncing = false;
    }
  }

  Future<Object?> handle(MethodCall call) async {
    if (call.method == 'closed') {
      if (overlayConfirming) live.endDiscardConfirmation();
      overlayConfirming = false;
      live.setCaptionsVisible(false);
      return null;
    }
    if (call.method != 'action') throw MissingPluginException();
    final action = call.arguments as String;
    if (action == 'close') {
      if (overlayConfirming) live.endDiscardConfirmation();
      overlayConfirming = false;
      live.setCaptionsVisible(false);
      return null;
    }
    if (action == 'cancelDiscard') {
      if (overlayConfirming) live.endDiscardConfirmation();
      overlayConfirming = false;
      return null;
    }
    if (!live.active || live.processingFiles) return false;
    switch (action) {
      case 'larger':
      case 'smaller':
        await live.setCaptionPreferences(
          live.captionPreferences.copyWith(
            fontSize:
                live.captionPreferences.fontSize +
                (action == 'larger' ? 2 : -2),
          ),
        );
      case 'pause':
        if (!live.discardConfirmationPending) await live.togglePause();
      case 'stop':
        if (!live.discardConfirmationPending) await live.stopAndSave();
      case 'prepareDiscard':
        final revision = visibilityRevision;
        overlayConfirming = await live.beginDiscardConfirmation();
        if (revision != visibilityRevision || !live.captionsVisible) {
          if (overlayConfirming) live.endDiscardConfirmation();
          overlayConfirming = false;
        }
        return overlayConfirming;
      case 'discard':
        if (overlayConfirming && live.phase == SessionPhase.paused) {
          try {
            await live.discard();
            if (live.error != null) throw StateError(live.error!);
          } finally {
            overlayConfirming = false;
            live.endDiscardConfirmation();
          }
        }
      default:
        throw MissingPluginException('Unknown caption action');
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    brightness = Theme.of(context).brightness;
    reduceMotion = MediaQuery.disableAnimationsOf(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) requestSync();
    });
    return widget.child;
  }

  @override
  void dispose() {
    live.removeListener(requestSync);
    captionChannel.setMethodCallHandler(null);
    if (MobilePlatform.android) MobilePlatform.onSessionAction = null;
    if (nativeVisible) unawaited(captionChannel.invokeMethod<void>('hide'));
    super.dispose();
  }
}
