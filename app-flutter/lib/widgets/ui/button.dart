import 'package:flutter/material.dart';

import '../../theme/css_tokens.dart';
import '../../theme/datieve_theme.dart';

enum DatieveButtonVariant { primary, secondary, outline, ghost, danger }

/// Exact port of `Button` from App.tsx (lines 301–315).
class DatieveUiButton extends StatefulWidget {
  final String? label;
  final Widget? child;
  final DatieveButtonVariant variant;
  final VoidCallback? onPressed;
  final bool disabled;
  final EdgeInsetsGeometry? padding;
  final double? width;
  final DatieveColors colors;

  const DatieveUiButton({
    super.key,
    this.label,
    this.child,
    this.variant = DatieveButtonVariant.primary,
    this.onPressed,
    this.disabled = false,
    required this.colors,
    this.padding,
    this.width,
  }) : assert(label != null || child != null);

  @override
  State<DatieveUiButton> createState() => _DatieveUiButtonState();
}

class _DatieveUiButtonState extends State<DatieveUiButton> {
  bool _pressed = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tw = Tw(widget.colors);
    final enabled = widget.onPressed != null && !widget.disabled;

    Color bg;
    Color fg;
    BorderSide border = BorderSide.none;
    List<BoxShadow> shadows = [];

    switch (widget.variant) {
      case DatieveButtonVariant.primary:
        bg = _hovered && enabled ? tw.slate800 : tw.slate900;
        fg = tw.onBrand;
        shadows = [
          BoxShadow(
            color: tw.slate900.withValues(alpha: 0.1),
            blurRadius: 2,
            offset: const Offset(0, 1),
          ),
        ];
      case DatieveButtonVariant.secondary:
        bg = _hovered && enabled ? tw.slate200 : tw.slate100;
        fg = tw.ink;
      case DatieveButtonVariant.outline:
        bg = _hovered && enabled ? tw.slate50 : Colors.transparent;
        fg = tw.slate600;
        border = BorderSide(
          color: _hovered && enabled ? tw.slate300 : tw.slate200,
        );
      case DatieveButtonVariant.ghost:
        bg = _hovered && enabled ? tw.slate50 : Colors.transparent;
        fg = _hovered && enabled ? tw.ink : tw.slate500;
      case DatieveButtonVariant.danger:
        bg = _hovered && enabled ? tw.red100 : tw.red50;
        fg = tw.red700;
        border = const BorderSide(color: Colors.transparent);
        border = BorderSide(color: tw.red100);
    }

    final scale = _pressed && enabled ? 0.98 : 1.0;

    return SizedBox(
      width: widget.width,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
          onTapUp: enabled
              ? (_) {
                  setState(() => _pressed = false);
                  widget.onPressed?.call();
                }
              : null,
          onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
          child: AnimatedScale(
            scale: scale,
            duration: const Duration(milliseconds: 200),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: widget.padding ??
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                color: enabled ? bg : bg.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(Tw.radiusLg),
                border: border == BorderSide.none ? null : Border.fromBorderSide(border),
                boxShadow: shadows,
              ),
              child: DefaultTextStyle(
                style: TextStyle(
                  color: enabled ? fg : fg.withValues(alpha: 0.5),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
                child: IconTheme(
                  data: IconThemeData(
                    color: enabled ? fg : fg.withValues(alpha: 0.5),
                    size: 16,
                  ),
                  child: Center(
                    child: widget.child ??
                        Text(
                          widget.label!,
                          textAlign: TextAlign.center,
                        ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}