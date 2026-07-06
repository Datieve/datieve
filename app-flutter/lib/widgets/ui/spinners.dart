import 'package:flutter/material.dart';

import '../../theme/css_tokens.dart';
import '../../theme/datieve_theme.dart';

/// `border-4 border-slate-200 border-t-slate-900 rounded-full animate-spin`
class SlateSpinner extends StatefulWidget {
  final double size;
  final double stroke;
  final DatieveColors colors;

  const SlateSpinner({
    super.key,
    this.size = 48,
    this.stroke = 4,
    required this.colors,
  });

  @override
  State<SlateSpinner> createState() => _SlateSpinnerState();
}

class _SlateSpinnerState extends State<SlateSpinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tw = Tw(widget.colors);
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return Transform.rotate(
            angle: _controller.value * 6.28318,
            child: child,
          );
        },
        child: CircularProgressIndicator(
          strokeWidth: widget.stroke,
          color: tw.slate900,
          backgroundColor: tw.slate200,
        ),
      ),
    );
  }
}