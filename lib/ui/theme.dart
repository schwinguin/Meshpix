import 'package:flutter/material.dart';

const meshInk = Color(0xFF141418);
const meshPaper = Color(0xFFF4F1DE);
const meshAmber = Color(0xFFE8A838);
const meshTeal = Color(0xFF2A9D8F);

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
    ),
    scaffoldBackgroundColor: meshInk,
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF1B1C22),
      foregroundColor: meshPaper,
    ),
  );
}
