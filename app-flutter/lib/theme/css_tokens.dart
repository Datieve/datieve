import 'package:flutter/material.dart';

import 'datieve_theme.dart';

/// Mirrors `color-mix(in srgb, a X%, b)` from index.css.
Color colorMix(Color a, Color b, double ratioA) {
  return Color.lerp(b, a, ratioA.clamp(0.0, 1.0))!;
}

/// Tailwind semantic colors mapped exactly from index.css overrides.
class Tw {
  final DatieveColors c;
  const Tw(this.c);

  Color get slate50 => c.panelSoft;
  Color get slate100 => c.panelMuted;
  Color get slate200 => colorMix(c.line, c.panel, 0.82);
  Color get slate300 => c.lineStrong;
  Color get slate400 => colorMix(c.muted, c.panel, 0.78);
  Color get slate500 => c.muted;
  Color get slate600 => colorMix(c.ink, c.panel, 0.62);
  Color get slate700 => colorMix(c.ink, c.panel, 0.78);
  Color get slate900 => c.brandSolid;
  Color get slate800 => c.brandHover;
  Color get white => c.panel;
  Color get green50 => c.successBg;
  Color get green600 => c.success;
  Color get green100 => c.successLine;
  Color get amber50 => c.warnBg;
  Color get amber600 => c.warn;
  Color get amber800 => colorMix(c.warn, c.ink, 0.82);
  Color get amber700 => colorMix(c.warn, c.ink, 0.7);
  Color get red50 => c.dangerBg;
  Color get red100 => c.dangerLine;
  Color get red500 => c.danger;
  Color get red600 => c.danger;
  Color get red700 => c.danger;
  Color get red900 => c.danger;

  Color get ink => c.ink;
  Color get line => c.line;
  Color get lineStrong => c.lineStrong;
  Color get faint => c.faint;
  Color get onBrand => c.onBrand;

  static const radiusLg = 8.0;
  static const radiusXl = 12.0;
  static const radius2xl = 10.0;
  static const radius3xl = 12.0;

  BoxDecoration appBackground(bool dark) {
    if (dark) {
      return BoxDecoration(
        gradient: LinearGradient(
          begin: const Alignment(-0.9, -1.0),
          end: Alignment.bottomCenter,
          colors: [
            const Color(0x59075985),
            const Color(0xFF141211),
            const Color(0xFF171512),
            c.panel,
          ],
          stops: const [0.0, 0.0, 0.45, 1.0],
        ),
      );
    }
    return BoxDecoration(
      gradient: LinearGradient(
        begin: const Alignment(-0.9, -1.0),
        end: Alignment.bottomCenter,
        colors: [
          const Color(0x73BAE6FD),
          const Color(0xFFF7F6F4),
          c.bg,
          c.panel,
        ],
        stops: const [0.0, 0.0, 0.45, 1.0],
      ),
    );
  }
}