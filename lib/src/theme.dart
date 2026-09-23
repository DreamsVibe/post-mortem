import 'package:flutter/material.dart';

const kInk = Color(0xFF1E1B18);
const kInkRaised = Color(0xFF2A2622);
const kIvory = Color(0xFFF3EDE2);
const kIvoryMuted = Color(0xFFBDB5A8);
const kAmber = Color(0xFFE0A43A);
const kWin = Color(0xFF8CC08A);
const kLoss = Color(0xFFE08A7A);

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: kAmber,
    brightness: Brightness.dark,
    surface: kInk,
  ).copyWith(primary: kAmber, onPrimary: kInk);

  return ThemeData(
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: kInk,
    useMaterial3: true,
    appBarTheme: const AppBarTheme(
      backgroundColor: kInk,
      foregroundColor: kIvory,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: kInkRaised,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    ),
    dividerColor: Colors.white10,
  );
}
