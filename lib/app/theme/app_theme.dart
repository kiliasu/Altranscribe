import 'package:material_ui/material_ui.dart';

import 'package:altranscribe/shared/ui/expressive.dart';

enum AppPalette { amber, baseline }

ThemeData altranscribeTheme(
  Brightness brightness, {
  AppPalette palette = AppPalette.amber,
}) {
  final dark = brightness == Brightness.dark;
  Color c(int light, int night) => Color(dark ? night : light);
  var colors =
      ColorScheme.fromSeed(
        seedColor: const Color(0xFFF6B849),
        brightness: brightness,
        dynamicSchemeVariant: DynamicSchemeVariant.expressive,
      ).copyWith(
        primary: c(0xFF8E437D, 0xFFFFACE9),
        onPrimary: c(0xFFFFFFFF, 0xFF5A0E4C),
        primaryContainer: c(0xFFFFD7F3, 0xFF742A64),
        onPrimaryContainer: c(0xFF742A64, 0xFFFFD7F3),
        secondary: c(0xFF53643E, 0xFFBBCDA1),
        onSecondary: c(0xFFFEFFFD, 0xFF253512),
        secondaryContainer: c(0xFFD7E9BC, 0xFF3C4C27),
        onSecondaryContainer: c(0xFF3C4C27, 0xFFD7E9BC),
        tertiary: c(0xFF6A5E25, 0xFFD7C687),
        onTertiary: c(0xFFFFFFFE, 0xFF383000),
        tertiaryContainer: c(0xFFF4E2A1, 0xFF51470D),
        onTertiaryContainer: c(0xFF51470D, 0xFFF4E2A1),
        surface: c(0xFFFEF9F0, 0xFF17130A),
        onSurface: c(0xFF1E1B15, 0xFFE7E2D9),
        onSurfaceVariant: c(0xFF4C4639, 0xFFCEC6B6),
        surfaceDim: c(0xFFDEDAD0, 0xFF17130A),
        surfaceBright: c(0xFFFEF9F0, 0xFF3C3932),
        surfaceContainerLowest: c(0xFFFFFFFE, 0xFF120E02),
        surfaceContainerLow: c(0xFFF8F3EA, 0xFF1E1B15),
        surfaceContainer: c(0xFFF2EDE4, 0xFF221F19),
        surfaceContainerHigh: c(0xFFECE8DE, 0xFF2D2A23),
        surfaceContainerHighest: c(0xFFE7E2D9, 0xFF38342D),
        outline: c(0xFF7D7668, 0xFF979081),
        outlineVariant: c(0xFFCEC6B6, 0xFF4C4639),
        inverseSurface: c(0xFF333029, 0xFFE7E2D9),
        onInverseSurface: c(0xFFF5F0E7, 0xFF333029),
        inversePrimary: c(0xFFFFACE9, 0xFF8E437D),
        surfaceTint: c(0xFF8E437D, 0xFFFFACE9),
        error: c(0xFFB3261E, 0xFFF2B8B5),
        onError: c(0xFFFFFFFF, 0xFF601410),
        errorContainer: c(0xFFF9DEDC, 0xFF8C1D18),
        onErrorContainer: c(0xFF852221, 0xFFF9DEDC),
      );
  if (palette == AppPalette.baseline) {
    colors = colors.copyWith(
      primary: c(0xFF6750A4, 0xFFD0BCFF),
      onPrimary: c(0xFFFFFFFF, 0xFF381E72),
      primaryContainer: c(0xFFEADDFF, 0xFF4F378B),
      onPrimaryContainer: c(0xFF4F378B, 0xFFEADDFF),
      secondary: c(0xFF625B71, 0xFFCCC2DC),
      onSecondary: c(0xFFFFFFFF, 0xFF332D41),
      secondaryContainer: c(0xFFE8DEF8, 0xFF4A4458),
      onSecondaryContainer: c(0xFF4A4458, 0xFFE8DEF8),
      tertiary: c(0xFF7D5260, 0xFFEFB8C8),
      onTertiary: c(0xFFFFFFFF, 0xFF492532),
      tertiaryContainer: c(0xFFFFD8E4, 0xFF633B48),
      onTertiaryContainer: c(0xFF633B48, 0xFFFFD8E4),
      surface: c(0xFFFEF7FF, 0xFF141218),
      onSurface: c(0xFF1D1B20, 0xFFE6E0E9),
      onSurfaceVariant: c(0xFF49454F, 0xFFCAC4D0),
      surfaceDim: c(0xFFDED8E1, 0xFF141218),
      surfaceBright: c(0xFFFEF7FF, 0xFF3B383E),
      surfaceContainerLowest: c(0xFFFFFFFF, 0xFF0F0D13),
      surfaceContainerLow: c(0xFFF7F2FA, 0xFF1D1B20),
      surfaceContainer: c(0xFFF3EDF7, 0xFF211F26),
      surfaceContainerHigh: c(0xFFECE6F0, 0xFF2B2930),
      surfaceContainerHighest: c(0xFFE6E0E9, 0xFF36343B),
      outline: c(0xFF79747E, 0xFF938F99),
      outlineVariant: c(0xFFCAC4D0, 0xFF49454F),
      inverseSurface: c(0xFF322F35, 0xFFE6E0E9),
      onInverseSurface: c(0xFFF5EFF7, 0xFF322F35),
      inversePrimary: c(0xFFD0BCFF, 0xFF6750A4),
      surfaceTint: c(0xFF6750A4, 0xFFD0BCFF),
      primaryFixed: const Color(0xFFEADDFF),
      primaryFixedDim: const Color(0xFFD0BCFF),
      onPrimaryFixed: const Color(0xFF21005D),
      onPrimaryFixedVariant: const Color(0xFF4F378B),
      secondaryFixed: const Color(0xFFE8DEF8),
      secondaryFixedDim: const Color(0xFFCCC2DC),
      onSecondaryFixed: const Color(0xFF1D192B),
      onSecondaryFixedVariant: const Color(0xFF4A4458),
      tertiaryFixed: const Color(0xFFFFD8E4),
      tertiaryFixedDim: const Color(0xFFEFB8C8),
      onTertiaryFixed: const Color(0xFF31111D),
      onTertiaryFixedVariant: const Color(0xFF633B48),
    );
  }
  TextStyle style(
    double size,
    double height,
    int weight,
    double spacing, {
    bool emphasized = false,
  }) => TextStyle(
    fontFamily: 'RobotoFlex',
    fontFamilyFallback: const ['NotoSansSC'],
    fontSize: size,
    height: height / size,
    fontWeight: FontWeight.values[weight ~/ 100 - 1],
    letterSpacing: spacing,
    color: colors.onSurface,
    fontVariations: emphasized
        ? const [FontVariation('wdth', 110), FontVariation('GRAD', 20)]
        : null,
  );
  final type = TextTheme(
    displayLarge: style(57, 64, 500, -.25, emphasized: true),
    displayMedium: style(45, 52, 500, 0, emphasized: true),
    displaySmall: style(36, 44, 500, 0, emphasized: true),
    headlineLarge: style(32, 40, 500, 0, emphasized: true),
    headlineMedium: style(28, 36, 500, 0, emphasized: true),
    headlineSmall: style(24, 32, 500, 0),
    titleLarge: style(22, 28, 700, 0, emphasized: true),
    titleMedium: style(16, 24, 700, .15),
    titleSmall: style(14, 20, 700, .1),
    bodyLarge: style(16, 24, 400, .5),
    bodyMedium: style(14, 20, 400, .25),
    bodySmall: style(12, 16, 400, .4),
    labelLarge: style(14, 20, 500, .1),
    labelMedium: style(12, 16, 500, .5),
    labelSmall: style(11, 16, 500, .5),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: colors,
    fontFamily: 'RobotoFlex',
    fontFamilyFallback: const ['NotoSansSC'],
    textTheme: type,
    scaffoldBackgroundColor: colors.surface,
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: colors.surfaceContainer,
      indicatorColor: colors.secondaryContainer,
      height: 80,
      labelTextStyle: WidgetStatePropertyAll(type.labelMedium),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: colors.surfaceContainerLow,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    dialogTheme: DialogThemeData(
      elevation: 6,
      barrierColor: const Color(0x52000000),
      backgroundColor: colors.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      titleTextStyle: style(24, 32, 400, 0),
      contentTextStyle: type.bodyMedium?.copyWith(
        color: colors.onSurfaceVariant,
      ),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      labelStyle: type.labelLarge!.copyWith(
        color: WidgetStateColor.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? colors.onSecondaryContainer
              : colors.onSurfaceVariant,
        ),
      ),
      iconTheme: IconThemeData(color: colors.onSurfaceVariant, size: 18),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      showCheckmark: true,
      selectedColor: colors.secondaryContainer,
      side: BorderSide(color: colors.outlineVariant),
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: colors.surfaceContainerHighest,
      border: const UnderlineInputBorder(),
      enabledBorder: UnderlineInputBorder(
        borderSide: BorderSide(color: colors.onSurfaceVariant),
      ),
      contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(40, 40),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        textStyle: type.labelLarge,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(32, 32),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        textStyle: type.labelLarge,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(40, 40),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        textStyle: type.labelLarge,
        side: BorderSide(color: colors.outline),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    ),
    sliderTheme: SliderThemeData(
      // ignore: deprecated_member_use
      year2023: false,
      trackHeight: 40,
      trackShape: const AltSliderTrack(),
      trackGap: 6,
      padding: const EdgeInsets.symmetric(vertical: 14),
      thumbSize: WidgetStateProperty.resolveWith(
        (states) => Size(states.contains(WidgetState.pressed) ? 2 : 4, 68),
      ),
      tickMarkShape: SliderTickMarkShape.noTickMark,
      activeTrackColor: colors.primary,
      inactiveTrackColor: colors.secondaryContainer,
      inactiveTickMarkColor: colors.onSecondaryContainer,
    ),
  );
}
