import 'package:flutter/material.dart';

const meshInk = Color(0xFF141418);
const meshPaper = Color(0xFFF4F1DE);
const meshAmber = Color(0xFFE8A838);
const meshTeal = Color(0xFF2A9D8F);
const meshCard = Color(0xFF22232B);
const meshCardElevated = Color(0xFF2A2D36);

ThemeData meshTheme() {
  final base = ColorScheme.fromSeed(
    seedColor: meshTeal,
    brightness: Brightness.dark,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: base.copyWith(
      primary: meshTeal,
      secondary: meshAmber,
      surface: const Color(0xFF1B1C22),
      surfaceContainerLow: meshCard,
      surfaceContainer: meshCard,
      surfaceContainerHigh: meshCardElevated,
      error: const Color(0xFFE76F51),
    ),
    scaffoldBackgroundColor: meshInk,
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF1B1C22),
      foregroundColor: meshPaper,
    ),
    cardTheme: CardThemeData(
      color: meshCard,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFF33343E)),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: const Color(0xFF1B1C22),
      indicatorColor: meshTeal.withValues(alpha: 0.22),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 12,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          color: selected ? meshPaper : const Color(0xFF8A8F98),
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          color: selected ? meshTeal : const Color(0xFF8A8F98),
        );
      }),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: meshCardElevated,
      contentTextStyle: const TextStyle(color: meshPaper),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFF33343E)),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.selected) ? meshPaper : meshTeal,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? meshTeal.withValues(alpha: 0.55)
            : const Color(0xFF3A3C46),
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: meshTeal,
      linearTrackColor: Color(0xFF3A3C46),
    ),
    dividerTheme: const DividerThemeData(
      color: Color(0xFF33343E),
      space: 1,
      thickness: 1,
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: Color(0xFF9AA0A6),
      textColor: meshPaper,
      selectedColor: meshTeal,
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFF3A3C46)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: meshTeal, width: 1.5),
      ),
      filled: true,
      fillColor: meshCard,
    ),
    tooltipTheme: const TooltipThemeData(
      decoration: BoxDecoration(
        color: meshCardElevated,
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
    ),
  );
}
