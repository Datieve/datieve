import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../theme/css_tokens.dart';
import '../../theme/datieve_theme.dart';

/// Exact port of `Input` from App.tsx (lines 356–364).
class DatieveUiInput extends StatefulWidget {
  final String? label;
  final String? value;
  final String? placeholder;
  final bool obscure;
  // When obscure is true and showToggle is true, shows an eye icon to reveal.
  final bool showToggle;
  final bool autofocus;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;
  final DatieveColors colors;
  final TextStyle? style;
  final EdgeInsetsGeometry? contentPadding;
  final bool monospace;

  const DatieveUiInput({
    super.key,
    this.label,
    this.value,
    this.placeholder,
    this.obscure = false,
    this.showToggle = false,
    this.autofocus = false,
    this.keyboardType,
    this.onChanged,
    required this.colors,
    this.style,
    this.contentPadding,
    this.monospace = false,
  });

  @override
  State<DatieveUiInput> createState() => _DatieveUiInputState();
}

class _DatieveUiInputState extends State<DatieveUiInput> {
  bool _visible = false;

  @override
  Widget build(BuildContext context) {
    final tw = Tw(widget.colors);
    final actuallyObscure = widget.obscure && !_visible;
    final defaultStyle = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w500,
      color: tw.ink,
      fontFamily: widget.monospace ? GoogleFonts.jetBrainsMono().fontFamily : null,
    );
    // Merge: default supplies color + fontFamily; caller's style overrides size/weight.
    final baseStyle = widget.style != null ? defaultStyle.merge(widget.style) : defaultStyle;
    final showEye = widget.showToggle && widget.obscure;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.label != null) ...[
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              widget.label!.toUpperCase(),
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 2,
                color: tw.slate400,
              ),
            ),
          ),
        ],
        TextField(
          controller: widget.value != null
              ? (TextEditingController(text: widget.value)
                ..selection =
                    TextSelection.collapsed(offset: widget.value!.length))
              : null,
          onChanged: widget.onChanged,
          obscureText: actuallyObscure,
          autofocus: widget.autofocus,
          keyboardType: widget.keyboardType,
          style: baseStyle,
          decoration: InputDecoration(
            hintText: widget.placeholder,
            hintStyle: TextStyle(
              color: colorMix(widget.colors.faint, widget.colors.panel, 0.72),
              fontWeight: FontWeight.w500,
            ),
            filled: true,
            fillColor: tw.slate50,
            contentPadding: widget.contentPadding ??
                const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(Tw.radiusLg),
              borderSide: BorderSide(color: tw.line),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(Tw.radiusLg),
              borderSide: BorderSide(color: tw.line),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(Tw.radiusLg),
              borderSide: BorderSide(color: tw.slate900, width: 1),
            ),
            suffixIcon: showEye
                ? IconButton(
                    icon: Icon(
                      _visible ? LucideIcons.eye : LucideIcons.eyeOff,
                      size: 16,
                      color: tw.slate400,
                    ),
                    splashRadius: 16,
                    onPressed: () => setState(() => _visible = !_visible),
                  )
                : null,
          ),
        ),
      ],
    );
  }
}
