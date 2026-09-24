import 'package:material_ui/material_ui.dart';

import 'package:altranscribe/features/home/home_screen.dart';
import 'package:altranscribe/app/theme/app_theme.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';
import 'package:altranscribe/features/captions/caption_host.dart';

class AltranscribeApp extends StatefulWidget {
  const AltranscribeApp({super.key, this.realtime});
  final RealtimeController? realtime;

  @override
  State<AltranscribeApp> createState() => _AltranscribeAppState();
}

class _AltranscribeAppState extends State<AltranscribeApp> {
  late final RealtimeController realtime;

  @override
  void initState() {
    super.initState();
    realtime = widget.realtime ?? RealtimeController.local();
    if (!realtime.initialized) realtime.initialize();
  }

  @override
  void dispose() {
    if (widget.realtime == null) realtime.dispose();
    super.dispose();
  }

  bool english = false;
  ThemeMode themeMode = ThemeMode.system;
  AppPalette palette = AppPalette.amber;
  bool reduceMotion = false;

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
      onLocale: (value) => setState(() => english = value),
      onTheme: (value) => setState(() => themeMode = value),
      onPalette: (value) => setState(() => palette = value),
      onMotion: (value) => setState(() => reduceMotion = value),
    ),
  );
}
