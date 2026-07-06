import 'package:flutter/material.dart';

import '../theme/datieve_theme.dart';

class SectionLabel extends StatelessWidget {
  final String text;
  final DatieveColors colors;

  const SectionLabel({super.key, required this.text, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 2,
          color: colors.muted,
        ),
      ),
    );
  }
}

class StatusBadge extends StatelessWidget {
  final String label;
  final String kind;
  final DatieveColors colors;

  const StatusBadge({
    super.key,
    required this.label,
    required this.kind,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final online = kind == 'online';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: online ? colors.successBg : colors.warnBg,
        border: Border.all(color: online ? colors.successLine : colors.warnLine),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 8,
          fontWeight: FontWeight.w900,
          letterSpacing: 1,
          color: online ? colors.success : colors.warn,
        ),
      ),
    );
  }
}

class DatieveButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool primary;
  final bool loading;
  final DatieveColors colors;

  const DatieveButton({
    super.key,
    required this.label,
    required this.onPressed,
    required this.colors,
    this.primary = true,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    final bg = primary ? colors.brandSolid : colors.panel;
    final fg = primary ? colors.onBrand : colors.ink;
    return SizedBox(
      height: 44,
      child: ElevatedButton(
        onPressed: loading ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: bg,
          foregroundColor: fg,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: primary ? BorderSide.none : BorderSide(color: colors.line),
          ),
        ),
        child: loading
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: fg),
              )
            : Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
    );
  }
}

class DatieveField extends StatelessWidget {
  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final bool obscure;
  final DatieveColors colors;

  const DatieveField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    required this.colors,
    this.obscure = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
            color: colors.muted,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          obscureText: obscure,
          controller: TextEditingController(text: value)
            ..selection = TextSelection.collapsed(offset: value.length),
          onChanged: onChanged,
          style: TextStyle(color: colors.ink),
          decoration: InputDecoration(
            filled: true,
            fillColor: colors.panelSoft,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: colors.line),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: colors.line),
            ),
          ),
        ),
      ],
    );
  }
}

class ScreenShell extends StatelessWidget {
  final Widget child;
  final DatieveColors colors;
  final Widget? topRight;

  const ScreenShell({
    super.key,
    required this.child,
    required this.colors,
    this.topRight,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomCenter,
          colors: [
            colors.bg,
            colors.panel.withValues(alpha: 0.4),
          ],
        ),
      ),
      child: SafeArea(
        child: Stack(
          children: [
            child,
            if (topRight != null)
              Positioned(top: 12, right: 16, child: topRight!),
          ],
        ),
      ),
    );
  }
}

class ThemeToggle extends StatelessWidget {
  final bool dark;
  final VoidCallback onToggle;
  final DatieveColors colors;

  const ThemeToggle({
    super.key,
    required this.dark,
    required this.onToggle,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: colors.panel.withValues(alpha: 0.84),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onToggle,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: colors.line),
          ),
          child: Icon(
            dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
            color: colors.ink,
            size: 20,
          ),
        ),
      ),
    );
  }
}