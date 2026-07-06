import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../state/datieve_state.dart';
import '../theme/css_tokens.dart';
import '../theme/datieve_theme.dart';
import '../widgets/ui/spinners.dart';

/// Exact port of `DemoFileManager` from App.tsx (lines 8516–8692).
class DemoScreen extends StatefulWidget {
  final DatieveState state;
  final bool embedded;

  const DemoScreen({super.key, required this.state, this.embedded = false});

  @override
  State<DemoScreen> createState() => _DemoScreenState();
}

class _DemoScreenState extends State<DemoScreen> {
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.state.startDemoStream();
    _pollStatus();
  }

  void _pollStatus() {
    Future.delayed(const Duration(seconds: 2), () {
      if (!mounted) return;
      if (widget.state.nasInlinePhase == 'demo') {
        widget.state.startDemoStream();
      }
      _pollStatus();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final c = state.colors;
    final tw = Tw(c);
    final agent = state.agent;
    final folders = state.demoFiles.where((f) => f.isDir).toList();
    final files = state.demoFiles.where((f) => !f.isDir).toList();
    final indexing = state.demoLoading;
    final statusParts = _parseDemoStatus(state.demoStatus);

    final content = Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: tw.slate900,
                            borderRadius: BorderRadius.circular(Tw.radiusXl),
                            boxShadow: [
                              BoxShadow(
                                color: tw.slate900.withValues(alpha: 0.1),
                                blurRadius: 16,
                              ),
                            ],
                          ),
                          child: Center(
                            child: Transform.rotate(
                              angle: 0.785398,
                              child: Container(
                                width: 12,
                                height: 12,
                                decoration: BoxDecoration(
                                  color: tw.white,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 24),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  'Datieve',
                                  style: TextStyle(
                                    fontSize: 30,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: -0.5,
                                    color: tw.ink,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: tw.amber50,
                                    border: Border.all(color: const Color(0xFFFDE68A)),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    'DEMO',
                                    style: TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 2,
                                      color: tw.amber700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Text(
                                  (agent?.hostname ?? 'RAM-only demo').toUpperCase(),
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 2,
                                    color: tw.slate400,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  'RAM-ONLY COMPATIBILITY BUILD',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 2,
                                    color: colorMix(tw.slate400, tw.white, 0.5),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: state.disconnect,
                    style: TextButton.styleFrom(
                      foregroundColor: tw.slate400,
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(LucideIcons.logOut, size: 14),
                        const SizedBox(width: 8),
                        Text(
                          'SWITCH AGENT',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1280),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: tw.white,
                        borderRadius: BorderRadius.circular(Tw.radius2xl),
                        border: Border.all(color: colorMix(tw.line, tw.white, 0.48)),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.22),
                            blurRadius: 70,
                            offset: const Offset(0, 28),
                            spreadRadius: -30,
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(Tw.radius2xl),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 32,
                                vertical: 24,
                              ),
                              decoration: BoxDecoration(
                                color: colorMix(tw.white, tw.white, 0.5),
                                border: Border(bottom: BorderSide(color: colorMix(tw.line, tw.white, 0.48))),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Stack(
                                            alignment: Alignment.centerLeft,
                                            children: [
                                              Padding(
                                                padding: const EdgeInsets.only(left: 56),
                                                child: TextField(
                                                  controller: TextEditingController(
                                                    text: state.demoFolderPath,
                                                  )..selection = TextSelection.collapsed(
                                                      offset: state.demoFolderPath.length,
                                                    ),
                                                  onChanged: state.setDemoFolderPath,
                                                  style: TextStyle(
                                                    fontSize: 14,
                                                    fontWeight: FontWeight.w700,
                                                    color: tw.ink,
                                                  ),
                                                  decoration: InputDecoration(
                                                    hintText: '/volume1/photos',
                                                    filled: true,
                                                    fillColor: tw.slate50,
                                                    border: InputBorder.none,
                                                    contentPadding: const EdgeInsets.symmetric(
                                                      vertical: 20,
                                                      horizontal: 20,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                              Padding(
                                                padding: const EdgeInsets.only(left: 20),
                                                child: Icon(
                                                  LucideIcons.folder,
                                                  size: 18,
                                                  color: tw.slate300,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        _IndexButton(
                                          colors: c,
                                          indexing: indexing,
                                          scanActive: statusParts.state == 'scanning',
                                          hasRoot: statusParts.hasRoot,
                                          enabled: state.demoFolderPath.trim().isNotEmpty,
                                          onPressed: state.demoStart,
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 24),
                                  SizedBox(
                                    width: 320,
                                    child: Stack(
                                      alignment: Alignment.centerLeft,
                                      children: [
                                        Padding(
                                          padding: const EdgeInsets.only(left: 64, right: 32),
                                          child: TextField(
                                            controller: _searchController,
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w700,
                                              color: tw.ink,
                                            ),
                                            decoration: InputDecoration(
                                              hintText: 'Search files...',
                                              filled: true,
                                              fillColor: tw.slate50,
                                              border: InputBorder.none,
                                              contentPadding: const EdgeInsets.symmetric(
                                                vertical: 20,
                                              ),
                                            ),
                                            onSubmitted: (_) {
                                              // Demo search API wired when FRB expands
                                            },
                                          ),
                                        ),
                                        const Padding(
                                          padding: EdgeInsets.only(left: 24),
                                          child: Icon(LucideIcons.search, size: 18, color: Color(0xFFCBD5E1)),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 32,
                                vertical: 16,
                              ),
                              child: Row(
                                children: [
                                  _StatusStat(label: statusParts.state),
                                  _StatusStat(label: '${statusParts.files} files'),
                                  _StatusStat(label: '${statusParts.folders} folders'),
                                  _StatusStat(label: '${statusParts.symlinks} symlinks'),
                                  _StatusStat(label: '${statusParts.skipped} skipped'),
                                ],
                              ),
                            ),
                            if (state.demoError.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(32, 0, 32, 0),
                                child: Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: tw.red50,
                                    border: Border.all(color: tw.red100),
                                    borderRadius: BorderRadius.circular(Tw.radiusXl),
                                  ),
                                  child: Text(
                                    state.demoError,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: tw.red700,
                                    ),
                                  ),
                                ),
                              ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(32, 24, 32, 0),
                              child: Row(
                                children: [
                                  _BreadcrumbChip(
                                    label: 'BASE',
                                    active: true,
                                    colors: c,
                                    icon: LucideIcons.hardDrive,
                                    onTap: () => state.startDemoStream(),
                                  ),
                                ],
                              ),
                            ),
                            Expanded(
                              child: state.demoLoading && state.demoFiles.isEmpty
                                  ? Center(child: SlateSpinner(size: 40, colors: c))
                                  : ListView(
                                      padding: const EdgeInsets.all(32),
                                      children: [
                                        if (folders.isNotEmpty) ...[
                                          LayoutBuilder(
                                            builder: (context, constraints) {
                                              final cols = constraints.maxWidth >= 1024
                                                  ? 4
                                                  : constraints.maxWidth >= 768
                                                      ? 2
                                                      : 1;
                                              return GridView.builder(
                                                shrinkWrap: true,
                                                physics: const NeverScrollableScrollPhysics(),
                                                gridDelegate:
                                                    SliverGridDelegateWithFixedCrossAxisCount(
                                                  crossAxisCount: cols,
                                                  mainAxisSpacing: 24,
                                                  crossAxisSpacing: 24,
                                                  childAspectRatio: 2.8,
                                                ),
                                                itemCount: folders.length,
                                                itemBuilder: (context, i) {
                                                  final f = folders[i];
                                                  return _DemoFolderCard(
                                                    name: f.name,
                                                    detail: f.detail,
                                                    colors: c,
                                                    onTap: () {},
                                                  );
                                                },
                                              );
                                            },
                                          ),
                                          const SizedBox(height: 40),
                                        ],
                                        for (final f in files)
                                          _DemoFileRow(
                                            name: f.name,
                                            detail: f.detail,
                                            colors: c,
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
        ],
      ),
    );

    if (widget.embedded) {
      return ColoredBox(
        color: tw.slate50,
        child: SingleChildScrollView(
          child: ColoredBox(color: tw.white, child: content),
        ),
      );
    }
    return ColoredBox(
      color: tw.white,
      child: SafeArea(child: content),
    );
  }
}

class _DemoStatusParts {
  final String state;
  final int files;
  final int folders;
  final int symlinks;
  final int skipped;
  final bool hasRoot;

  const _DemoStatusParts({
    this.state = 'idle',
    this.files = 0,
    this.folders = 0,
    this.symlinks = 0,
    this.skipped = 0,
    this.hasRoot = false,
  });
}

_DemoStatusParts _parseDemoStatus(String line) {
  if (line.isEmpty) return const _DemoStatusParts();
  final parts = line.split(' · ');
  if (parts.isEmpty) return const _DemoStatusParts();
  int parseCount(String s) {
    final m = RegExp(r'(\d+)').firstMatch(s);
    return m == null ? 0 : int.tryParse(m.group(1)!) ?? 0;
  }
  return _DemoStatusParts(
    state: parts.first.trim(),
    files: parts.length > 1 ? parseCount(parts[1]) : 0,
    folders: parts.length > 2 ? parseCount(parts[2]) : 0,
    hasRoot: !line.contains('0 files') || parts.first != 'idle',
  );
}

class _IndexButton extends StatefulWidget {
  final DatieveColors colors;
  final bool indexing;
  final bool scanActive;
  final bool hasRoot;
  final bool enabled;
  final VoidCallback onPressed;

  const _IndexButton({
    required this.colors,
    required this.indexing,
    required this.scanActive,
    required this.hasRoot,
    required this.enabled,
    required this.onPressed,
  });

  @override
  State<_IndexButton> createState() => _IndexButtonState();
}

class _IndexButtonState extends State<_IndexButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tw = Tw(widget.colors);
    final busy = widget.indexing || widget.scanActive;
    final label = busy
        ? 'Indexing'
        : widget.hasRoot
            ? 'Reindex'
            : 'Index Folder';
    final enabled = widget.enabled && !busy;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: enabled ? widget.onPressed : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          decoration: BoxDecoration(
            color: enabled
                ? (_hovered ? tw.slate800 : tw.slate900)
                : tw.slate900.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(Tw.radius2xl),
          ),
          child: Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w900,
              letterSpacing: 2,
              color: tw.onBrand,
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusStat extends StatelessWidget {
  final String label;

  const _StatusStat({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 24),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w900,
          letterSpacing: 2,
          color: Color(0xFF94A3B8),
        ),
      ),
    );
  }
}

class _BreadcrumbChip extends StatelessWidget {
  final String label;
  final bool active;
  final IconData icon;
  final DatieveColors colors;
  final VoidCallback onTap;

  const _BreadcrumbChip({
    required this.label,
    required this.active,
    required this.icon,
    required this.colors,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tw = Tw(colors);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        decoration: BoxDecoration(
          color: active ? tw.slate900 : Colors.transparent,
          borderRadius: BorderRadius.circular(Tw.radiusXl),
          boxShadow: active
              ? [
                  BoxShadow(
                    color: tw.slate900.withValues(alpha: 0.2),
                    blurRadius: 16,
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: active ? tw.onBrand : tw.slate400),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w900,
                letterSpacing: 2,
                color: active ? tw.onBrand : tw.slate400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DemoFolderCard extends StatefulWidget {
  final String name;
  final String detail;
  final DatieveColors colors;
  final VoidCallback onTap;

  const _DemoFolderCard({
    required this.name,
    required this.detail,
    required this.colors,
    required this.onTap,
  });

  @override
  State<_DemoFolderCard> createState() => _DemoFolderCardState();
}

class _DemoFolderCardState extends State<_DemoFolderCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tw = Tw(widget.colors);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: _hovered ? tw.white : colorMix(tw.slate50, tw.white, 0.5),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: _hovered ? tw.line : Colors.transparent,
            ),
            boxShadow: _hovered
                ? [
                    BoxShadow(
                      color: tw.slate200.withValues(alpha: 0.5),
                      blurRadius: 24,
                    ),
                  ]
                : null,
          ),
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: _hovered ? tw.slate900 : tw.white,
                  borderRadius: BorderRadius.circular(Tw.radius2xl),
                  boxShadow: [
                    BoxShadow(
                      color: widget.colors.ink.withValues(alpha: 0.06),
                      blurRadius: 4,
                    ),
                  ],
                ),
                child: Icon(
                  LucideIcons.folder,
                  size: 20,
                  color: _hovered ? tw.onBrand : tw.slate500,
                ),
              ),
              const SizedBox(width: 24),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      widget.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: _hovered ? tw.ink : tw.slate600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.detail.toUpperCase(),
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2,
                        color: tw.slate300,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DemoFileRow extends StatelessWidget {
  final String name;
  final String detail;
  final DatieveColors colors;

  const _DemoFileRow({
    required this.name,
    required this.detail,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final tw = Tw(colors);
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: tw.white,
        borderRadius: BorderRadius.circular(Tw.radius3xl),
        border: Border.all(color: colorMix(tw.line, tw.white, 0.48)),
      ),
      child: Row(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: tw.slate50,
              borderRadius: BorderRadius.circular(Tw.radius2xl),
            ),
            child: Icon(LucideIcons.file, size: 24, color: tw.slate400),
          ),
          const SizedBox(width: 32),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                    color: tw.ink,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  detail.toUpperCase(),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2,
                    color: tw.slate400,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}