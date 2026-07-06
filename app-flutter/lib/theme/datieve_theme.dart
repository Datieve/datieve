import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class DatieveColors {
  final Color bg;
  final Color panel;
  final Color panelSoft;
  final Color panelMuted;
  final Color ink;
  final Color muted;
  final Color faint;
  final Color line;
  final Color lineStrong;
  final Color brand;
  final Color brandHover;
  final Color brandSolid;
  final Color onBrand;
  final Color success;
  final Color successBg;
  final Color successLine;
  final Color warn;
  final Color warnBg;
  final Color warnLine;
  final Color danger;
  final Color dangerBg;
  final Color dangerLine;

  const DatieveColors({
    required this.bg,
    required this.panel,
    required this.panelSoft,
    required this.panelMuted,
    required this.ink,
    required this.muted,
    required this.faint,
    required this.line,
    required this.lineStrong,
    required this.brand,
    required this.brandHover,
    required this.brandSolid,
    required this.onBrand,
    required this.success,
    required this.successBg,
    required this.successLine,
    required this.warn,
    required this.warnBg,
    required this.warnLine,
    required this.danger,
    required this.dangerBg,
    required this.dangerLine,
  });

  static const light = DatieveColors(
    bg: Color(0xFFFAF9F7),
    panel: Color(0xFFFFFFFF),
    panelSoft: Color(0xFFF5F4F2),
    panelMuted: Color(0xFFEDE9E6),
    ink: Color(0xFF1C1917),
    muted: Color(0xFF78716C),
    faint: Color(0xFFA8A29E),
    line: Color(0xFFE7E5E4),
    lineStrong: Color(0xFFD6D3D1),
    brand: Color(0xFF0EA5E9),
    brandHover: Color(0xFF0284C7),
    brandSolid: Color(0xFF075985),
    onBrand: Color(0xFFFFFFFF),
    success: Color(0xFF16A34A),
    successBg: Color(0xFFF0FDF4),
    successLine: Color(0xFFBBF7D0),
    warn: Color(0xFFB45309),
    warnBg: Color(0xFFFFFBEB),
    warnLine: Color(0xFFFDE68A),
    danger: Color(0xFFB91C1C),
    dangerBg: Color(0xFFFEF2F2),
    dangerLine: Color(0xFFFECACA),
  );

  static const dark = DatieveColors(
    bg: Color(0xFF141211),
    panel: Color(0xFF1C1917),
    panelSoft: Color(0xFF292524),
    panelMuted: Color(0xFF3D3835),
    ink: Color(0xFFFAF9F7),
    muted: Color(0xFFA8A29E),
    faint: Color(0xFF78716C),
    line: Color(0xFF3D3835),
    lineStrong: Color(0xFF57534E),
    brand: Color(0xFF38BDF8),
    brandHover: Color(0xFF7DD3FC),
    brandSolid: Color(0xFF0C4A6E),
    onBrand: Color(0xFFFFFFFF),
    success: Color(0xFF4ADE80),
    successBg: Color(0xFF14240E),
    successLine: Color(0xFF1F4522),
    warn: Color(0xFFFBBF24),
    warnBg: Color(0xFF2A1F08),
    warnLine: Color(0xFF4A3612),
    danger: Color(0xFFF87171),
    dangerBg: Color(0xFF2D1212),
    dangerLine: Color(0xFF521E1E),
  );
}

class DatieveTheme {
  static ThemeData material(bool dark) {
    final c = dark ? DatieveColors.dark : DatieveColors.light;
    final scheme = ColorScheme(
      brightness: dark ? Brightness.dark : Brightness.light,
      primary: c.brand,
      onPrimary: c.onBrand,
      secondary: c.brandSolid,
      onSecondary: c.onBrand,
      error: c.danger,
      onError: c.onBrand,
      surface: c.panel,
      onSurface: c.ink,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: c.bg,
      fontFamily: GoogleFonts.inter().fontFamily,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.panelSoft,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: c.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: c.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: c.brand, width: 2),
        ),
        labelStyle: TextStyle(
          color: c.muted,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.2,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      cardTheme: CardThemeData(
        color: c.panel,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: c.line),
        ),
      ),
    );
  }
}