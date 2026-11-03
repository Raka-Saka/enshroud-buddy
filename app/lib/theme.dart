import 'package:flutter/material.dart';

/// Flame amber on shroud teal and purple; parchment for lore.
class Palette {
  static const night = Color(0xFF0B1416);
  static const shroud = Color(0xFF13222A);
  static const shroudHigh = Color(0xFF1C2F38);
  static const shroudTop = Color(0xFF243B45);
  static const flame = Color(0xFFF2A33A);
  static const ember = Color(0xFFD9692B);
  static const veil = Color(0xFF8E6BBF);

  /// Veil for text: the plain veil is 3.8:1 on shroud cards, under AA; this is 7:1.
  static const veilText = Color(0xFFB9A0E0);
  static const spring = Color(0xFF3FB8AF);
  static const amber = Color(0xFFFFB74D);
  static const bone = Color(0xFFE6E1D6);
  static const ash = Color(0xFF9AA5A8);
  static const parchment = Color(0xFFE8D9B5);
  static const ink = Color(0xFF3A2A18);

  /// Unique finds and the skill tree's lit nodes.
  static const gold = Color(0xFFFFD54F);

  static Color rarity(String r) => switch (r) {
    'Uncommon' => const Color(0xFF7CC46A),
    'Rare' => const Color(0xFF5AA7E8),
    'Epic' => const Color(0xFFB27BE0),
    'Legendary' => flame,
    _ => ash,
  };

  /// 0 fine, 1 take care, 2 blocked.
  static Color risk(int r) => switch (r) {
    0 => spring,
    1 => amber,
    _ => ember,
  };
}

/// Corner radii: large containers, cards, small controls.
class Radii {
  static const sheet = 28.0;
  static const card = 20.0;
  static const tile = 16.0;
}

ThemeData buildTheme() {
  const scheme = ColorScheme.dark(
    primary: Palette.flame,
    onPrimary: Palette.night,
    primaryContainer: Color(0xFF4A3414),
    onPrimaryContainer: Palette.flame,
    secondary: Palette.veil,
    secondaryContainer: Color(0xFF2E2440),
    onSecondaryContainer: Color(0xFFD8C8F0),
    tertiary: Palette.spring,
    surface: Palette.night,
    onSurface: Palette.bone,
    onSurfaceVariant: Palette.ash,
    surfaceContainerLowest: Palette.night,
    surfaceContainerLow: Color(0xFF101C21),
    surfaceContainer: Palette.shroud,
    surfaceContainerHigh: Palette.shroudHigh,
    surfaceContainerHighest: Palette.shroudTop,
    outline: Color(0xFF34474F),
    outlineVariant: Color(0xFF223740),
  );
  const display = TextStyle(
    fontFamily: 'Cinzel',
    fontWeight: FontWeight.w700,
    letterSpacing: 0.4,
  );
  final rounded = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(Radii.card),
  );
  return ThemeData(
    useMaterial3: true,
    fontFamily: 'Roboto',
    colorScheme: scheme,
    scaffoldBackgroundColor: Palette.night,
    splashFactory: InkSparkle.splashFactory,
    visualDensity: VisualDensity.standard,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
      },
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Palette.night,
      surfaceTintColor: Colors.transparent,
      foregroundColor: Palette.bone,
      centerTitle: false,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(
        fontFamily: 'Cinzel',
        fontSize: 21,
        fontWeight: FontWeight.w700,
        color: Palette.flame,
      ),
    ),
    textTheme: const TextTheme(
      displaySmall: display,
      headlineMedium: display,
      headlineSmall: display,
      titleLarge: display,
      titleMedium: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
      bodySmall: TextStyle(color: Palette.ash),
      labelSmall: TextStyle(color: Palette.ash, letterSpacing: 0.3),
    ),
    cardTheme: CardTheme(
      color: Palette.shroud,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      shape: rounded,
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: Palette.ash,
      contentPadding: EdgeInsets.symmetric(horizontal: 16),
      minVerticalPadding: 10,
      subtitleTextStyle: TextStyle(
        fontFamily: 'Roboto',
        color: Palette.ash,
        fontSize: 12.5,
      ),
    ),
    expansionTileTheme: const ExpansionTileThemeData(
      shape: Border(),
      collapsedShape: Border(),
      iconColor: Palette.flame,
      collapsedIconColor: Palette.ash,
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 70,
      backgroundColor: Palette.shroud,
      surfaceTintColor: Colors.transparent,
      indicatorColor: Palette.flame.withValues(alpha: 0.2),
      indicatorShape: const StadiumBorder(),
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(
          color: s.contains(WidgetState.selected) ? Palette.flame : Palette.ash,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => TextStyle(
          fontFamily: 'Roboto',
          fontSize: 12,
          fontWeight:
              s.contains(WidgetState.selected)
                  ? FontWeight.w700
                  : FontWeight.w500,
          color: s.contains(WidgetState.selected) ? Palette.bone : Palette.ash,
        ),
      ),
    ),
    tabBarTheme: TabBarTheme(
      indicatorSize: TabBarIndicatorSize.label,
      dividerColor: Colors.transparent,
      labelColor: Palette.flame,
      unselectedLabelColor: Palette.ash,
      labelStyle: const TextStyle(
        fontFamily: 'Roboto',
        fontWeight: FontWeight.w700,
        fontSize: 14,
      ),
      unselectedLabelStyle: const TextStyle(fontFamily: 'Roboto', fontSize: 14),
      indicator: UnderlineTabIndicator(
        borderSide: const BorderSide(color: Palette.flame, width: 3),
        borderRadius: BorderRadius.circular(3),
      ),
      tabAlignment: TabAlignment.start,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Palette.shroud,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: Palette.ash,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
      ),
    ),
    dialogTheme: DialogTheme(
      backgroundColor: Palette.shroud,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.sheet),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: Palette.shroudTop,
      contentTextStyle: const TextStyle(
        fontFamily: 'Roboto',
        color: Palette.bone,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.tile),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Palette.shroudHigh,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(28),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
    ),
    chipTheme: const ChipThemeData(
      backgroundColor: Palette.shroudHigh,
      selectedColor: Color(0xFF4A3414),
      side: BorderSide.none,
      shape: StadiumBorder(),
      labelStyle: TextStyle(fontFamily: 'Roboto', fontSize: 13),
      showCheckmark: false,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: const StadiumBorder(),
        side: const BorderSide(color: Color(0xFF34474F)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: const Color(0xFF4A3414),
        selectedForegroundColor: Palette.flame,
        side: const BorderSide(color: Color(0xFF34474F)),
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: Palette.flame,
      linearTrackColor: Palette.shroudHigh,
    ),
    dividerTheme: const DividerThemeData(color: Color(0xFF223740), space: 1),
  );
}
