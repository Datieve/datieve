import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/css_tokens.dart';
import '../theme/datieve_theme.dart';
import 'ui/button.dart';

/// Exact port of `AppErrorBoundary` from App.tsx (lines 317–354).
class AppErrorBoundary extends StatefulWidget {
  final Widget child;

  const AppErrorBoundary({super.key, required this.child});

  @override
  State<AppErrorBoundary> createState() => _AppErrorBoundaryState();
}

class _AppErrorBoundaryState extends State<AppErrorBoundary> {
  Object? _error;

  @override
  void initState() {
    super.initState();
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      setState(() => _error = details.exception);
    };
  }

  @override
  Widget build(BuildContext context) {
    if (_error == null) return widget.child;

    const colors = DatieveColors.dark;
    final tw = Tw(colors);
    final message = _error.toString();

    return Material(
      color: const Color(0xFF020617),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 672),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(Tw.radiusLg),
                border: Border.all(color: tw.red500.withValues(alpha: 0.3)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.45),
                    blurRadius: 24,
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(LucideIcons.shield, color: Color(0xFFFCA5A5), size: 24),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Datieve could not render this screen',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFFF1F5F9),
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'The app caught a UI error instead of leaving the window blank. Restart the app after updating, or share this message if it repeats.',
                            style: TextStyle(fontSize: 14, color: Color(0xFFCBD5E1)),
                          ),
                          const SizedBox(height: 16),
                          Container(
                            constraints: const BoxConstraints(maxHeight: 224),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.4),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: SingleChildScrollView(
                              child: Text(
                                message,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFFFECACA),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                          DatieveUiButton(
                            label: 'Reload',
                            variant: DatieveButtonVariant.secondary,
                            colors: DatieveColors.light,
                            onPressed: () => setState(() => _error = null),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}