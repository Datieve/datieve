import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../state/datieve_state.dart';
import '../theme/css_tokens.dart';
import '../theme/datieve_theme.dart';
import '../widgets/ui/auth_shell.dart';
import '../widgets/ui/input.dart';
import '../widgets/ui/spinners.dart';
import '../widgets/datieve_widgets.dart';

/// Exact port of `Login` from App.tsx (lines 549–670).
class LoginScreen extends StatelessWidget {
  final DatieveState state;
  final bool embedded;

  const LoginScreen({super.key, required this.state, this.embedded = false});

  @override
  Widget build(BuildContext context) {
    final c = state.colors;
    final tw = Tw(c);
    final agent = state.agent;
    final wide = MediaQuery.sizeOf(context).width >= 768;
    final showCode = state.loginShowCode ||
        state.loginAccounts.isEmpty ||
        state.revokedUsername.isNotEmpty;
    final visibleAccounts = state.revokedUsername.isNotEmpty
        ? state.loginAccounts
            .where((a) => a.username != state.revokedUsername)
            .toList()
        : state.loginAccounts;

    final shell = AuthShell(
        colors: c,
        asideTop: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: tw.slate900,
                borderRadius: BorderRadius.circular(Tw.radiusLg),
              ),
              child: Icon(LucideIcons.shield, color: tw.onBrand, size: 21),
            ),
            const SizedBox(height: 8),
            Text(
              'SELECTED AGENT',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 2.4,
                color: tw.slate400,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              agent?.hostname ?? 'Agent',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.5,
                color: tw.ink,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              agent?.ip ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                color: tw.slate400,
              ),
            ),
          ],
        ),
        asideBottom: TextButton(
          onPressed: state.disconnect,
          style: TextButton.styleFrom(
            padding: EdgeInsets.zero,
            foregroundColor: tw.slate500,
            alignment: Alignment.centerLeft,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Transform.rotate(
                angle: 3.14159,
                child: Icon(LucideIcons.chevronRight, size: 14),
              ),
              const SizedBox(width: 8),
              const Text(
                'All Agents',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
        main: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!wide)
              TextButton(
                onPressed: state.disconnect,
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  foregroundColor: tw.slate400,
                  alignment: Alignment.centerLeft,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Transform.rotate(
                      angle: 3.14159,
                      child: Icon(LucideIcons.chevronRight, size: 14),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'ALL AGENTS',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 2,
                      ),
                    ),
                  ],
                ),
              ),
            if (!wide) const SizedBox(height: 32),
            if (!wide)
              Container(
                width: 48,
                height: 48,
                margin: const EdgeInsets.only(bottom: 24),
                decoration: BoxDecoration(
                  color: tw.slate900,
                  borderRadius: BorderRadius.circular(Tw.radiusLg),
                  boxShadow: [
                    BoxShadow(
                      color: tw.slate900.withValues(alpha: 0.1),
                      blurRadius: 4,
                    ),
                  ],
                ),
                child: Center(
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      color: tw.white,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            Text(
              'SIGN IN',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 2.4,
                color: tw.slate400,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Open file manager',
              style: TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.5,
                color: tw.ink,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              visibleAccounts.isNotEmpty && !showCode
                  ? 'Choose an account or enter a new code.'
                  : 'Enter your admin or user code.',
              style: TextStyle(fontSize: 14, color: tw.slate500),
            ),
            const SizedBox(height: 32),
            if (state.loginError.isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                margin: const EdgeInsets.only(bottom: 24),
                decoration: BoxDecoration(
                  color: tw.red50,
                  border: Border.all(color: tw.red100),
                  borderRadius: BorderRadius.circular(Tw.radiusXl),
                ),
                child: Text(
                  state.loginError,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: tw.red900,
                  ),
                ),
              ),
            if (visibleAccounts.isNotEmpty && !showCode) ...[
              for (final acc in visibleAccounts) ...[
                _AccountButton(
                  username: acc.username,
                  role: acc.role,
                  colors: c,
                  loading: state.loginLoading,
                  onTap: () => state.login(acc.code),
                  onDelete: () => state.forgetStoredAccount(acc.code),
                ),
                const SizedBox(height: 12),
              ],
              TextButton(
                onPressed: () => state.setLoginShowCode(true),
                child: Text(
                  'USE A DIFFERENT CODE',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2,
                    color: tw.slate400,
                  ),
                ),
              ),
            ],
            if (showCode) ...[
              if (visibleAccounts.isNotEmpty && state.revokedUsername.isEmpty)
                TextButton(
                  onPressed: () => state.setLoginShowCode(false),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.only(bottom: 8),
                    alignment: Alignment.centerLeft,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Transform.rotate(
                        angle: 3.14159,
                        child: Icon(LucideIcons.chevronRight, size: 14, color: tw.slate400),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'BACK TO ACCOUNTS',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 2,
                          color: tw.slate400,
                        ),
                      ),
                    ],
                  ),
                ),
              DatieveUiInput(
                label: 'Admin or user code',
                value: state.loginCode,
                placeholder: '••••••••••',
                obscure: true,
                showToggle: true,
                autofocus: true,
                colors: c,
                monospace: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
                onChanged: state.setLoginCode,
              ),
              const SizedBox(height: 16),
              _SubmitButton(state: state),
            ],
            if (state.loginLoading && visibleAccounts.isNotEmpty && !showCode)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: SlateSpinner(size: 24, stroke: 2, colors: c),
                ),
              ),
          ],
        ),
    );

    if (embedded) {
      return LayoutBuilder(
        builder: (context, constraints) {
          return ColoredBox(
            color: tw.slate50,
            child: SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: shell,
                  ),
                ),
              ),
            ),
          );
        },
      );
    }
    return AuthPageScaffold(
      colors: c,
      themeToggle: ThemeToggle(
        dark: state.isDark,
        colors: c,
        onToggle: () => state.setTheme(state.isDark ? 'light' : 'dark'),
      ),
      child: shell,
    );
  }
}

class _AccountButton extends StatefulWidget {
  final String username;
  final String role;
  final DatieveColors colors;
  final bool loading;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _AccountButton({
    required this.username,
    required this.role,
    required this.colors,
    required this.loading,
    required this.onTap,
    required this.onDelete,
  });

  @override
  State<_AccountButton> createState() => _AccountButtonState();
}

class _AccountButtonState extends State<_AccountButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tw = Tw(widget.colors);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Stack(
        children: [
          GestureDetector(
            onTap: widget.loading ? null : widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 14, 48, 14),
              decoration: BoxDecoration(
                color: tw.slate50,
                borderRadius: BorderRadius.circular(Tw.radiusLg),
                border: Border.all(
                  color: _hovered && !widget.loading ? tw.slate900 : tw.slate200,
                ),
              ),
              child: Opacity(
                opacity: widget.loading ? 0.5 : 1,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.username,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: tw.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.role == 'admin' ? 'ADMINISTRATOR' : 'USER',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 2,
                        color: tw.slate400,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            right: 4,
            top: 0,
            bottom: 0,
            child: Center(
              child: IconButton(
                icon: Icon(LucideIcons.x, size: 14, color: tw.slate400),
                tooltip: 'Remove saved account',
                onPressed: widget.onDelete,
                padding: const EdgeInsets.all(8),
                constraints: const BoxConstraints(),
                style: IconButton.styleFrom(
                  foregroundColor: tw.slate500,
                  hoverColor: tw.red50,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SubmitButton extends StatefulWidget {
  final DatieveState state;

  const _SubmitButton({required this.state});

  @override
  State<_SubmitButton> createState() => _SubmitButtonState();
}

class _SubmitButtonState extends State<_SubmitButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final tw = Tw(widget.state.colors);
    final loading = widget.state.loginLoading;
    final enabled = !loading;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
        onTapUp: enabled
            ? (_) {
                setState(() => _pressed = false);
                widget.state.login(widget.state.loginCode);
              }
            : null,
        onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
        child: AnimatedScale(
          scale: _pressed && enabled ? 0.98 : 1,
          duration: const Duration(milliseconds: 200),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(
              color: enabled
                  ? (_hovered ? tw.slate800 : tw.slate900)
                  : tw.slate900.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(Tw.radiusLg),
              boxShadow: [
                BoxShadow(
                  color: tw.slate900.withValues(alpha: 0.1),
                  blurRadius: 2,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: Text(
              loading ? 'Verifying...' : 'Open file browser',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: tw.onBrand,
              ),
            ),
          ),
        ),
      ),
    );
  }
}