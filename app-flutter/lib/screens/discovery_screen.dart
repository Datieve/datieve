import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../src/rust/bridge.dart';
import '../state/datieve_state.dart';
import '../theme/css_tokens.dart';
import '../theme/datieve_theme.dart';
import '../widgets/ui/auth_shell.dart';
import '../widgets/ui/button.dart';
import '../widgets/ui/spinners.dart';
import '../widgets/datieve_widgets.dart';

/// Exact port of `Discovery` from App.tsx (lines 402–545).
class DiscoveryScreen extends StatelessWidget {
  final DatieveState state;
  final bool embedded;

  const DiscoveryScreen({super.key, required this.state, this.embedded = false});

  @override
  Widget build(BuildContext context) {
    final c = state.colors;
    final tw = Tw(c);
    final port = state.settings.scanPort;

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
              child: Icon(LucideIcons.server, color: tw.onBrand, size: 22),
            ),
            const SizedBox(height: 20),
            Text(
              'Datieve',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.5,
                color: tw.ink,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Connect to an indexing agent and open the file manager.',
              style: TextStyle(
                fontSize: 13,
                height: 1.6,
                color: tw.slate500,
              ),
            ),
          ],
        ),
        asideBottom: Text(
          'Port $port',
          style: TextStyle(
            fontSize: 11,
            fontFamily: 'monospace',
            color: tw.slate400,
          ),
        ),
        main: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (MediaQuery.sizeOf(context).width < 768) ...[
              Center(
                child: Column(
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: tw.slate900,
                        borderRadius: BorderRadius.circular(Tw.radiusXl),
                        boxShadow: [
                          BoxShadow(
                            color: tw.slate900.withValues(alpha: 0.2),
                            blurRadius: 16,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Icon(LucideIcons.server, color: tw.onBrand, size: 32),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Datieve',
                      style: TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.5,
                        color: tw.ink,
                      ),
                    ),
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 0),
            Padding(
              padding: const EdgeInsets.only(bottom: 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'AGENT DISCOVERY',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2.4,
                      color: tw.slate400,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Searching your network for indexing agents.',
                    style: TextStyle(fontSize: 14, height: 1.6, color: tw.slate500),
                  ),
                ],
              ),
            ),
            if (state.scanning)
              _ScanningState(port: port, colors: c)
            else if (state.agents.isNotEmpty)
              _AgentList(state: state)
            else
              _EmptyState(state: state, port: port),
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

class _ScanningState extends StatelessWidget {
  final int port;
  final DatieveColors colors;

  const _ScanningState({required this.port, required this.colors});

  @override
  Widget build(BuildContext context) {
    final tw = Tw(colors);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 64),
      decoration: BoxDecoration(
        color: tw.slate50,
        borderRadius: BorderRadius.circular(Tw.radiusXl),
        border: Border.all(color: tw.slate200, style: BorderStyle.solid),
      ),
      child: Column(
        children: [
          SlateSpinner(size: 48, colors: colors),
          const SizedBox(height: 24),
          Text(
            'SCANNING PORT $port...',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 2,
              color: tw.slate400,
            ),
          ),
        ],
      ),
    );
  }
}

class _AgentList extends StatelessWidget {
  final DatieveState state;

  const _AgentList({required this.state});

  @override
  Widget build(BuildContext context) {
    final c = state.colors;
    final tw = Tw(c);
    final connecting = state.connectingIp;

    return Column(
      children: [
        for (final a in state.agents) ...[
          _AgentButton(
            agent: a,
            colors: c,
            connecting: connecting == a.ip,
            disabled: connecting != null,
            onTap: () => state.selectAgent(a.ip, fingerprint: a.fingerprint),
          ),
          const SizedBox(height: 16),
        ],
        if (state.discoveryError.isNotEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: tw.red50,
              border: Border.all(color: tw.red100),
              borderRadius: BorderRadius.circular(Tw.radiusXl),
            ),
            child: Text(
              state.discoveryError,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: tw.red700,
              ),
            ),
          ),
        TextButton(
          onPressed: connecting != null ? null : () => state.refreshDiscovery(autoSelect: true),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
            foregroundColor: tw.slate400,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(LucideIcons.refreshCw, size: 14, color: tw.slate400),
              const SizedBox(width: 8),
              Text(
                'RESCAN',
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
      ],
    );
  }
}

class _AgentButton extends StatefulWidget {
  final AgentItemDto agent;
  final DatieveColors colors;
  final bool connecting;
  final bool disabled;
  final VoidCallback onTap;

  const _AgentButton({
    required this.agent,
    required this.colors,
    required this.connecting,
    required this.disabled,
    required this.onTap,
  });

  @override
  State<_AgentButton> createState() => _AgentButtonState();
}

class _AgentButtonState extends State<_AgentButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tw = Tw(widget.colors);
    final enabled = !widget.disabled;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: enabled ? widget.onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: tw.white,
            borderRadius: BorderRadius.circular(Tw.radiusXl),
            border: Border.all(
              color: _hovered && enabled ? tw.slate900 : tw.slate200,
            ),
            boxShadow: [
              BoxShadow(
                color: widget.colors.ink.withValues(alpha: _hovered && enabled ? 0.08 : 0.04),
                blurRadius: _hovered && enabled ? 8 : 2,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: Opacity(
            opacity: enabled ? 1 : 0.6,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      widget.agent.hostname.isEmpty ? 'Unsetup Agent' : widget.agent.hostname,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: tw.ink,
                      ),
                    ),
                    widget.connecting
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: SlateSpinner(size: 18, stroke: 2, colors: widget.colors),
                          )
                        : Icon(
                            LucideIcons.chevronRight,
                            size: 18,
                            color: _hovered && enabled ? tw.ink : tw.slate300,
                          ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _StatusPill(agent: widget.agent, colors: widget.colors),
                    const SizedBox(width: 12),
                    Text(
                      widget.agent.ip.toUpperCase(),
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 2,
                        color: tw.slate400,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final AgentItemDto agent;
  final DatieveColors colors;

  const _StatusPill({required this.agent, required this.colors});

  @override
  Widget build(BuildContext context) {
    final tw = Tw(colors);
    final isDemo = agent.statusKind == 'demo';
    final isOnline = agent.statusKind == 'online';

    Color bg;
    Color fg;
    Color border;
    if (isDemo || isOnline) {
      bg = tw.green50;
      fg = tw.green600;
      border = tw.green100;
    } else {
      bg = tw.amber50;
      fg = tw.amber600;
      border = const Color(0xFFFDE68A);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        agent.statusLabel.toUpperCase(),
        style: TextStyle(
          fontSize: 8,
          fontWeight: FontWeight.w900,
          letterSpacing: 2,
          color: fg,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final DatieveState state;
  final int port;

  const _EmptyState({required this.state, required this.port});

  @override
  Widget build(BuildContext context) {
    final c = state.colors;
    final tw = Tw(c);

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 48),
      decoration: BoxDecoration(
        color: tw.slate50,
        borderRadius: BorderRadius.circular(Tw.radiusXl),
        border: Border.all(color: tw.slate200, style: BorderStyle.solid),
      ),
      child: Column(
        children: [
          Icon(LucideIcons.activity, size: 32, color: tw.slate300),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              children: [
                Text(
                  'No agents found on port $port.',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: tw.ink,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Make sure the Datieve Agent is running and on the same network.',
                  style: TextStyle(fontSize: 12, color: tw.slate400),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            alignment: WrapAlignment.center,
            children: [
              DatieveUiButton(
                label: 'Retry',
                variant: DatieveButtonVariant.secondary,
                colors: c,
                onPressed: () => state.refreshDiscovery(autoSelect: true),
              ),
              DatieveUiButton(
                label: 'Change port',
                variant: DatieveButtonVariant.outline,
                colors: c,
                onPressed: state.togglePortInput,
              ),
            ],
          ),
          if (state.showPortInput) ...[
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: tw.amber50,
                      border: Border.all(color: const Color(0xFFFDE68A)),
                      borderRadius: BorderRadius.circular(Tw.radiusXl),
                    ),
                    child: Text(
                      "Enter the port your agent is listening on. The default is $port. You can change the port in Settings → Network once connected.",
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                        color: tw.amber800,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _PortInputRow(state: state, colors: c),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PortInputRow extends StatefulWidget {
  final DatieveState state;
  final DatieveColors colors;

  const _PortInputRow({required this.state, required this.colors});

  @override
  State<_PortInputRow> createState() => _PortInputRowState();
}

class _PortInputRowState extends State<_PortInputRow> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.state.portDraft);
  }

  @override
  void didUpdateWidget(_PortInputRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state.portDraft != widget.state.portDraft &&
        _controller.text != widget.state.portDraft) {
      _controller.text = widget.state.portDraft;
      _controller.selection = TextSelection.collapsed(
        offset: widget.state.portDraft.length,
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tw = Tw(widget.colors);
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            onChanged: (v) => widget.state.portDraft = v,
            keyboardType: TextInputType.number,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              fontFamily: 'monospace',
              color: tw.ink,
            ),
            decoration: InputDecoration(
              filled: true,
              fillColor: tw.white,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(Tw.radiusXl),
                borderSide: BorderSide(color: tw.slate200),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(Tw.radiusXl),
                borderSide: BorderSide(color: tw.slate200),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(Tw.radiusXl),
                borderSide: BorderSide(color: tw.slate900),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        DatieveUiButton(
          label: 'Scan',
          colors: widget.colors,
          onPressed: widget.state.applyPort,
        ),
      ],
    );
  }
}