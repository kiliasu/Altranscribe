import 'package:material_ui/material_ui.dart';

import 'package:altranscribe/features/home/home_screen.dart';
import 'package:altranscribe/app/theme/app_theme.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:altranscribe/features/captions/caption_host.dart';

class AltranscribeApp extends StatefulWidget {
  const AltranscribeApp({
    super.key,
    this.realtime,
    this.followSystemLanguage = false,
  });
  final RealtimeController? realtime;

  /// Until a language is chosen, use English unless the system's language
  /// is Chinese. Off, the app starts in Chinese.
  final bool followSystemLanguage;

  @override
  State<AltranscribeApp> createState() => _AltranscribeAppState();
}

class _AltranscribeAppState extends State<AltranscribeApp> {
  late final RealtimeController realtime;

  @override
  void initState() {
    super.initState();
    realtime = widget.realtime ?? RealtimeController.local();
    // The saved look is read at once, so the first frame already has it.
    final saved = realtime.interface;
    english =
        saved['english'] as bool? ??
        (widget.followSystemLanguage &&
            WidgetsBinding.instance.platformDispatcher.locale.languageCode !=
                'zh');
    themeMode =
        ThemeMode.values.where((m) => m.name == saved['theme']).firstOrNull ??
        ThemeMode.system;
    palette =
        AppPalette.values
            .where((p) => p.name == saved['palette'])
            .firstOrNull ??
        AppPalette.amber;
    reduceMotion = saved['reduceMotion'] == true;
    if (!realtime.initialized) realtime.initialize();
  }

  @override
  void dispose() {
    if (widget.realtime == null) realtime.dispose();
    super.dispose();
  }

  late bool english;
  late ThemeMode themeMode;
  late AppPalette palette;
  late bool reduceMotion;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Altranscribe',
    debugShowCheckedModeBanner: false,
    locale: english ? const Locale('en') : const Locale('zh', 'CN'),
    supportedLocales: const [Locale('en'), Locale('zh', 'CN')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: altranscribeTheme(Brightness.light, palette: palette),
    darkTheme: altranscribeTheme(Brightness.dark, palette: palette),
    themeMode: themeMode,
    themeAnimationDuration: reduceMotion
        ? Duration.zero
        : kThemeAnimationDuration,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        disableAnimations:
            reduceMotion || MediaQuery.disableAnimationsOf(context),
      ),
      child: CaptionHost(
        controller: realtime,
        english: english,
        palette: palette,
        child: child!,
      ),
    ),
    home: AltranscribeHome(
      realtime: realtime,
      english: english,
      themeMode: themeMode,
      palette: palette,
      reduceMotion: reduceMotion,
      onLocale: (value) {
        setState(() => english = value);
        realtime.remember('english', value);
      },
      onTheme: (value) {
        setState(() => themeMode = value);
        realtime.remember('theme', value.name);
      },
      onPalette: (value) {
        setState(() => palette = value);
        realtime.remember('palette', value.name);
      },
      onMotion: (value) {
        setState(() => reduceMotion = value);
        realtime.remember('reduceMotion', value);
      },
    ),
  );
}
