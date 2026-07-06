import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../models/palette_command.dart';
import '../theme/css_tokens.dart';
import '../theme/datieve_theme.dart';

class FmCommandPalette extends StatefulWidget {
  final DatieveColors colors;
  final List<PaletteCommand> commands;
  final VoidCallback onClose;

  const FmCommandPalette({
    super.key,
    required this.colors,
    required this.commands,
    required this.onClose,
  });

  @override
  State<FmCommandPalette> createState() => _FmCommandPaletteState();
}

class _FmCommandPaletteState extends State<FmCommandPalette> {
  final _queryController = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _focusNode.requestFocus();
  }

  @override
  void dispose() {
    _queryController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  List<PaletteCommand> get _filtered {
    final q = _queryController.text.trim().toLowerCase();
    return widget.commands
        .where((c) => c.enabled)
        .where((c) {
          if (q.isEmpty) return true;
          return '${c.label} ${c.detail} ${c.category}'.toLowerCase().contains(q);
        })
        .take(12)
        .toList();
  }

  void _run(PaletteCommand command) {
    widget.onClose();
    command.run();
  }

  @override
  Widget build(BuildContext context) {
    final tw = Tw(widget.colors);
    final filtered = _filtered;

    return GestureDetector(
      onTap: widget.onClose,
      child: ColoredBox(
        color: const Color(0x660F172A),
        child: Align(
          alignment: const Alignment(0, -0.5),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 96, 16, 16),
            child: GestureDetector(
              onTap: () {},
              child: Container(
                constraints: const BoxConstraints(maxWidth: 576),
                decoration: BoxDecoration(
                  color: tw.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: tw.slate100),
                  boxShadow: [
                    BoxShadow(
                      color: widget.colors.ink.withValues(alpha: 0.2),
                      blurRadius: 32,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      height: 48,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        border: Border(bottom: BorderSide(color: tw.slate100)),
                      ),
                      child: Row(
                        children: [
                          Icon(LucideIcons.search, size: 16, color: tw.slate400),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextField(
                              controller: _queryController,
                              focusNode: _focusNode,
                              onChanged: (_) => setState(() {}),
                              onSubmitted: (_) {
                                if (filtered.isNotEmpty) _run(filtered.first);
                              },
                              style: TextStyle(fontSize: 14, color: tw.ink),
                              decoration: InputDecoration(
                                hintText: 'Run command...',
                                hintStyle: TextStyle(color: tw.slate300),
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: tw.slate100,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'Esc',
                              style: TextStyle(
                                fontSize: 10,
                                fontFamily: 'monospace',
                                color: tw.slate500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.sizeOf(context).height * 0.5,
                      ),
                      child: filtered.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.symmetric(vertical: 32),
                              child: Text(
                                'No commands found.',
                                style: TextStyle(fontSize: 13, color: tw.slate400),
                              ),
                            )
                          : ListView.builder(
                              shrinkWrap: true,
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              itemCount: filtered.length,
                              itemBuilder: (context, index) {
                                final command = filtered[index];
                                return Material(
                                  color: Colors.transparent,
                                  child: InkWell(
                                    onTap: () => _run(command),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                        vertical: 10,
                                      ),
                                      child: Row(
                                        children: [
                                          Container(
                                            width: 32,
                                            height: 32,
                                            decoration: BoxDecoration(
                                              color: tw.slate50,
                                              borderRadius: BorderRadius.circular(8),
                                              border: Border.all(color: tw.slate100),
                                            ),
                                            child: Icon(
                                              LucideIcons.chevronRight,
                                              size: 14,
                                              color: tw.slate400,
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  command.label,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.w600,
                                                    color: tw.ink,
                                                  ),
                                                ),
                                                Text(
                                                  command.detail,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    color: tw.slate400,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          Text(
                                            command.category.toUpperCase(),
                                            style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.w900,
                                              letterSpacing: 1.5,
                                              color: tw.slate300,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
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
      ),
    );
  }
}