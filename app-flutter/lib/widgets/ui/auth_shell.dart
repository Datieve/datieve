import 'package:flutter/material.dart';

import '../../theme/css_tokens.dart';
import '../../theme/datieve_theme.dart';

/// Two-column auth card shell from Discovery/Login/Setup in App.tsx.
class AuthShell extends StatelessWidget {
  final DatieveColors colors;
  final Widget asideTop;
  final Widget? asideBottom;
  final Widget main;
  final bool scrollableMain;
  final double minHeight;

  const AuthShell({
    super.key,
    required this.colors,
    required this.asideTop,
    this.asideBottom,
    required this.main,
    this.scrollableMain = false,
    this.minHeight = 640,
  });

  @override
  Widget build(BuildContext context) {
    final tw = Tw(colors);
    final wide = MediaQuery.sizeOf(context).width >= 768;

    final aside = Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: tw.slate50,
        border: Border(
          right: wide ? BorderSide(color: tw.slate200) : BorderSide.none,
          bottom: wide ? BorderSide.none : BorderSide(color: tw.slate200),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          asideTop,
          if (asideBottom != null) ...[
            const Spacer(),
            asideBottom!,
          ],
        ],
      ),
    );

    final mainContent = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: wide ? 40 : 32,
        vertical: wide ? 40 : 32,
      ),
      child: main,
    );

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1024),
        child: Container(
          constraints: BoxConstraints(minHeight: minHeight),
          margin: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: tw.white,
            borderRadius: BorderRadius.circular(Tw.radiusXl),
            border: Border.all(color: tw.slate200),
            boxShadow: [
              BoxShadow(
                color: colors.ink.withValues(alpha: 0.04),
                blurRadius: 4,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: wide
              ? IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: 280, child: aside),
                      Expanded(
                        child: scrollableMain
                            ? SingleChildScrollView(child: mainContent)
                            : Center(child: mainContent),
                      ),
                    ],
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    aside,
                    scrollableMain
                        ? Expanded(child: SingleChildScrollView(child: mainContent))
                        : mainContent,
                  ],
                ),
        ),
      ),
    );
  }
}

/// `min-h-full flex items-center justify-center bg-slate-50 p-6`
class AuthPageScaffold extends StatelessWidget {
  final DatieveColors colors;
  final Widget child;
  final Widget? themeToggle;

  const AuthPageScaffold({
    super.key,
    required this.colors,
    required this.child,
    this.themeToggle,
  });

  @override
  Widget build(BuildContext context) {
    final tw = Tw(colors);
    return Container(
      color: tw.slate50,
      child: Stack(
        children: [
          Positioned.fill(child: child),
          if (themeToggle != null)
            Positioned(top: 20, right: 20, child: themeToggle!),
        ],
      ),
    );
  }
}