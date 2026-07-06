import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../theme/css_tokens.dart';
import '../theme/datieve_theme.dart';

const _shortcuts = [
  _S.header('Files & Navigation'),
  _S('Move selection up / down', '↑ / ↓'),
  _S('Move selection left / right', '← / →'),
  _S('First / last item', 'Home / End'),
  _S('Open selected item', 'Enter'),
  _S('Navigate back', 'Alt+Left'),
  _S('Navigate forward', 'Alt+Right'),
  _S('Go up one level', 'Alt+Up / Backspace'),
  _S('Refresh current folder', 'F5'),
  _S('Focus search bar', '/'),
  _S('Focus search bar (alternate)', 'Ctrl+F'),
  _S('Edit current path', 'Ctrl+L'),
  _S('Toggle hidden files', 'Ctrl+H'),

  _S.header('File Operations'),
  _S('Select all', 'Ctrl+A'),
  _S('Copy selected', 'Ctrl+C'),
  _S('Cut selected', 'Ctrl+X'),
  _S('Paste', 'Ctrl+V'),
  _S('Undo last action', 'Ctrl+Z'),
  _S('Rename selected', 'F2'),
  _S('Move to Trash', 'Del'),
  _S('Delete Permanently', 'Shift+Del'),
  _S('New folder', 'Ctrl+Shift+N'),
  _S('New file', 'Ctrl+N'),
  _S('Quick preview / Properties', 'Space'),

  _S.header('View'),
  _S('Zoom in', 'Ctrl++'),
  _S('Zoom out', 'Ctrl+–'),
  _S('Reset zoom', 'Ctrl+0'),

  _S.header('Tabs'),
  _S('New tab', 'Ctrl+T'),
  _S('Close tab', 'Ctrl+W'),
  _S('Duplicate tab', 'Ctrl+Shift+K'),
  _S('Reopen closed tab', 'Ctrl+Shift+T'),
  _S('Next tab', 'Ctrl+Tab'),
  _S('Previous tab', 'Ctrl+Shift+Tab'),

  _S.header('App'),
  _S('Command palette', 'Ctrl+Shift+P'),
  _S('Keyboard shortcuts', 'Ctrl+/'),
  _S('Clear selection / close', 'Escape'),
];

class _S {
  final String desc;
  final String? key;
  final bool isHeader;

  const _S(this.desc, this.key) : isHeader = false;
  const _S.header(this.desc)
      : key = null,
        isHeader = true;
}

class FmShortcutsDialog extends StatefulWidget {
  final DatieveColors colors;
  final VoidCallback onClose;
  final FocusNode? searchFocusNode;

  const FmShortcutsDialog({
    super.key,
    required this.colors,
    required this.onClose,
    this.searchFocusNode,
  });

  @override
  State<FmShortcutsDialog> createState() => _FmShortcutsDialogState();
}

class _FmShortcutsDialogState extends State<FmShortcutsDialog> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tw = Tw(widget.colors);
    final q = _query.toLowerCase().trim();

    final filtered = q.isEmpty
        ? _shortcuts
        : _shortcuts.where((s) {
            if (s.isHeader) return false;
            return s.desc.toLowerCase().contains(q) ||
                (s.key?.toLowerCase().contains(q) ?? false);
          }).toList();

    return GestureDetector(
      onTap: widget.onClose,
      child: ColoredBox(
        color: const Color(0x77000000),
        child: Center(
          child: GestureDetector(
            onTap: () {},
            child: Container(
              width: 440,
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height - 48,
              ),
              decoration: BoxDecoration(
                color: tw.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: tw.slate100),
                boxShadow: [
                  BoxShadow(
                    color: widget.colors.ink.withValues(alpha: 0.18),
                    blurRadius: 32,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ── Header ──────────────────────────────────────────
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 12, 0),
                    child: Row(
                      children: [
                        Icon(LucideIcons.keyboard, size: 16, color: widget.colors.brand),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Keyboard Shortcuts',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: tw.ink,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: Icon(LucideIcons.x, size: 15, color: tw.slate300),
                          onPressed: widget.onClose,
                          padding: const EdgeInsets.all(4),
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                  ),
                  // ── Search ──────────────────────────────────────────
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: SizedBox(
                      height: 32,
                      child: TextField(
                        controller: _searchController,
                        focusNode: widget.searchFocusNode,
                        onChanged: (v) => setState(() => _query = v),
                        style: TextStyle(fontSize: 12, color: tw.ink),
                        decoration: InputDecoration(
                          hintText: 'Search shortcuts…',
                          hintStyle: TextStyle(fontSize: 12, color: tw.slate400),
                          prefixIcon: Icon(LucideIcons.search, size: 13, color: tw.slate400),
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                          filled: true,
                          fillColor: tw.slate50,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide(color: tw.slate200),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide(color: tw.slate200),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide(color: tw.slate400),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // ── List ────────────────────────────────────────────
                  Flexible(
                    child: filtered.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              'No shortcuts match "$_query"',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 12, color: tw.slate400),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                            itemCount: filtered.length,
                            itemBuilder: (context, i) {
                              final s = filtered[i];
                              if (s.isHeader) {
                                return Padding(
                                  padding: EdgeInsets.only(
                                    top: i == 0 ? 0 : 14,
                                    bottom: 6,
                                  ),
                                  child: Text(
                                    s.desc.toUpperCase(),
                                    style: TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 1.2,
                                      color: tw.slate400,
                                    ),
                                  ),
                                );
                              }
                              return Padding(
                                padding: const EdgeInsets.symmetric(vertical: 3),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        s.desc,
                                        style: TextStyle(fontSize: 12, color: tw.slate600),
                                      ),
                                    ),
                                    if (s.key != null)
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 3,
                                        ),
                                        decoration: BoxDecoration(
                                          color: tw.slate100,
                                          borderRadius: BorderRadius.circular(5),
                                          border: Border.all(color: tw.slate200),
                                        ),
                                        child: Text(
                                          s.key!,
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontFamily: 'monospace',
                                            fontWeight: FontWeight.w700,
                                            color: tw.slate700,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Keep the old list for backward-compat exports
const fmShortcuts = _shortcuts;
