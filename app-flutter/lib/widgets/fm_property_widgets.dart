import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/css_tokens.dart';

/// Files-style label | value row used across properties surfaces.
class FmPropertyRow extends StatelessWidget {
  final Tw tw;
  final String label;
  final String value;
  final bool monospace;
  final bool copyable;
  final Widget? trailing;

  const FmPropertyRow({
    super.key,
    required this.tw,
    required this.label,
    required this.value,
    this.monospace = false,
    this.copyable = false,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    if (value.isEmpty || value == '—') return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 132,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: tw.slate500,
                height: 1.35,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                fontSize: 13,
                color: tw.slate800,
                fontFamily: monospace ? 'monospace' : null,
                height: 1.35,
              ),
            ),
          ),
          if (trailing != null) trailing!,
          if (copyable)
            IconButton(
              icon: Icon(LucideIcons.copy, size: 14, color: tw.slate400),
              visualDensity: VisualDensity.compact,
              tooltip: 'Copy',
              onPressed: () => Clipboard.setData(ClipboardData(text: value)),
            ),
        ],
      ),
    );
  }
}

/// Collapsible section — mirrors Files Expander headers.
class FmPropertySection extends StatefulWidget {
  final Tw tw;
  final String title;
  final List<Widget> children;
  final bool initiallyExpanded;
  final Widget? trailing;

  const FmPropertySection({
    super.key,
    required this.tw,
    required this.title,
    required this.children,
    this.initiallyExpanded = true,
    this.trailing,
  });

  @override
  State<FmPropertySection> createState() => _FmPropertySectionState();
}

class _FmPropertySectionState extends State<FmPropertySection> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    if (widget.children.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: widget.tw.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: widget.tw.slate100),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    _expanded ? LucideIcons.chevronDown : LucideIcons.chevronRight,
                    size: 14,
                    color: widget.tw.slate400,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.title,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: widget.tw.ink,
                      ),
                    ),
                  ),
                  if (widget.trailing != null) widget.trailing!,
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: widget.children,
              ),
            ),
        ],
      ),
    );
  }
}

/// Drive / volume usage card with ring indicator (Files GeneralPage pattern).
class FmVolumeUsageCard extends StatelessWidget {
  final Tw tw;
  final String device;
  final String mountPath;
  final String fsType;
  final int totalBytes;
  final int usedBytes;
  final int availableBytes;
  final String Function(int) fmtSize;

  const FmVolumeUsageCard({
    super.key,
    required this.tw,
    required this.device,
    required this.mountPath,
    required this.fsType,
    required this.totalBytes,
    required this.usedBytes,
    required this.availableBytes,
    required this.fmtSize,
  });

  @override
  Widget build(BuildContext context) {
    final pct = totalBytes > 0 ? (usedBytes / totalBytes).clamp(0.0, 1.0) : 0.0;
    final pctLabel = '${(pct * 100).round()}%';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tw.slate50,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: tw.slate100),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            height: 64,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(
                  value: pct > 0 ? pct : null,
                  strokeWidth: 5,
                  backgroundColor: tw.slate200,
                  color: pct > 0.9 ? tw.red500 : tw.slate700,
                ),
                Text(
                  pctLabel,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: tw.slate700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _legendRow(tw, 'Used space', fmtSize(usedBytes), tw.slate700),
                const SizedBox(height: 6),
                _legendRow(tw, 'Free space', fmtSize(availableBytes), tw.slate300),
                const SizedBox(height: 6),
                _legendRow(tw, 'Capacity', fmtSize(totalBytes), tw.slate500),
                const SizedBox(height: 10),
                Text(
                  '$device · $fsType',
                  style: TextStyle(fontSize: 11, color: tw.slate400),
                ),
                Text(
                  mountPath,
                  style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: tw.slate500),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _legendRow(Tw tw, String label, String value, Color dot) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: dot,
            borderRadius: BorderRadius.circular(2),
            border: Border.all(color: tw.slate200),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 72,
          child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: tw.slate600)),
        ),
        Text(value, style: TextStyle(fontSize: 12, color: tw.slate800)),
      ],
    );
  }
}

/// Linux rwx permission grid.
class FmPermissionsGrid extends StatelessWidget {
  final Tw tw;
  final String permissions;

  const FmPermissionsGrid({super.key, required this.tw, required this.permissions});

  @override
  Widget build(BuildContext context) {
    if (permissions.length != 9) {
      return SelectableText(
        permissions,
        style: TextStyle(fontSize: 12, fontFamily: 'monospace', color: tw.slate700),
      );
    }

    Widget group(String title, String bits) {
      return Expanded(
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: tw.slate50,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: tw.slate100),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: tw.slate400)),
              const SizedBox(height: 8),
              Row(
                children: [
                  _chip(tw, 'R', bits[0] == 'r'),
                  const SizedBox(width: 4),
                  _chip(tw, 'W', bits[1] == 'w'),
                  const SizedBox(width: 4),
                  _chip(tw, 'X', bits[2] == 'x'),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            group('Owner', permissions.substring(0, 3)),
            const SizedBox(width: 8),
            group('Group', permissions.substring(3, 6)),
            const SizedBox(width: 8),
            group('Others', permissions.substring(6, 9)),
          ],
        ),
        const SizedBox(height: 10),
        Text('Octal: $permissions', style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: tw.slate500)),
      ],
    );
  }

  Widget _chip(Tw tw, String label, bool on) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: on ? tw.green50 : tw.slate100,
        borderRadius: BorderRadius.circular(4),
        border: on ? Border.all(color: tw.green100) : null,
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: on ? tw.green600 : tw.slate400,
        ),
      ),
    );
  }
}

String fmFormatPropertyDate(int secs) {
  if (secs <= 0) return '—';
  final dt = DateTime.fromMillisecondsSinceEpoch(secs * 1000);
  String pad(int n) => n.toString().padLeft(2, '0');
  return '${dt.year}-${pad(dt.month)}-${pad(dt.day)}  ${pad(dt.hour)}:${pad(dt.minute)}:${pad(dt.second)}';
}

String fmParentPath(String path) {
  final parts = path.split('/').where((s) => s.isNotEmpty).toList();
  if (parts.isEmpty) return '/';
  parts.removeLast();
  return parts.isEmpty ? '/' : '/${parts.join('/')}';
}