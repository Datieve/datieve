import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/fm_menu_state.dart';
import '../state/datieve_state.dart';
import '../theme/css_tokens.dart';
import '../utils/file_type_helpers.dart';
import '../utils/menu_position.dart';
import '../utils/settings_helpers.dart';

class FmContextMenus extends StatelessWidget {
  final DatieveState state;

  const FmContextMenus({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final hasMenu = state.fmLocalCtxMenu != null ||
        state.fmEmptyCtxMenu != null ||
        state.fmSidebarCtxMenu != null ||
        state.fmNasCtxMenu != null ||
        state.tabCtxMenu != null;
    if (!hasMenu) return const SizedBox.shrink();

    return Stack(
      children: [
        Positioned.fill(
          child: ModalBarrier(
            color: Colors.transparent,
            dismissible: false,
          ),
        ),
        if (state.fmLocalCtxMenu != null)
          _LocalItemMenu(state: state, menu: state.fmLocalCtxMenu!),
        if (state.fmEmptyCtxMenu != null)
          _EmptyAreaMenu(state: state, menu: state.fmEmptyCtxMenu!),
        if (state.fmSidebarCtxMenu != null)
          _SidebarMenu(state: state, menu: state.fmSidebarCtxMenu!),
        if (state.fmNasCtxMenu != null)
          _NasItemMenu(state: state, menu: state.fmNasCtxMenu!),
        if (state.tabCtxMenu != null)
          _TabContextMenu(state: state, menu: state.tabCtxMenu!),
      ],
    );
  }
}

class _MenuShell extends StatelessWidget {
  final DatieveState state;
  final double x;
  final double y;
  final double width;
  final VoidCallback onClose;
  final List<Widget> children;
  final Widget? subMenuOverlay;

  const _MenuShell({
    required this.state,
    required this.x,
    required this.y,
    required this.width,
    required this.onClose,
    required this.children,
    this.subMenuOverlay,
  });

  @override
  Widget build(BuildContext context) {
    final tw = Tw(state.colors);
    final placement = computeMenuPlacement(
      x: x,
      y: y,
      menuW: width,
      viewport: MediaQuery.sizeOf(context),
    );

    return SizedBox.expand(
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: onClose,
        onSecondaryTap: onClose,
        child: Stack(
          children: [
            Positioned(
              left: placement.left,
              top: placement.top,
              bottom: placement.bottom,
              child: GestureDetector(
                onTap: () {},
                child: Material(
                  elevation: 12,
                  borderRadius: BorderRadius.circular(12),
                  color: tw.white,
                  shadowColor: Colors.black26,
                  child: Container(
                    width: width,
                    constraints: BoxConstraints(maxHeight: placement.maxHeight),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: tw.slate100),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: children,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Submenu panel rendered outside ClipRRect so it is not clipped.
            if (subMenuOverlay != null) subMenuOverlay!,
          ],
        ),
      ),
    );
  }
}

class _MenuItem extends StatefulWidget {
  final DatieveState state;
  final String label;
  final VoidCallback onTap;
  final String? shortcut;
  final bool danger;
  final bool submenu;
  final bool submenuOpen;
  final bool enabled;

  const _MenuItem({
    required this.state,
    required this.label,
    required this.onTap,
    this.shortcut,
    this.danger = false,
    this.submenu = false,
    this.submenuOpen = false,
    this.enabled = true,
  });

  @override
  State<_MenuItem> createState() => _MenuItemState();
}

class _MenuItemState extends State<_MenuItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tw = Tw(widget.state.colors);
    final Color labelColor;
    if (!widget.enabled) {
      labelColor = tw.slate300;
    } else if (widget.danger) {
      labelColor = tw.red600;
    } else {
      labelColor = tw.slate700;
    }
    return Material(
      color: (_hovered && widget.enabled) ? tw.slate50 : tw.white,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.enabled ? widget.onTap : null,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: widget.danger ? FontWeight.w500 : FontWeight.w400,
                      color: labelColor,
                    ),
                  ),
                ),
                if (widget.submenu)
                  Text('›', style: TextStyle(fontSize: 13, color: tw.slate400))
                else if (widget.shortcut != null && widget.enabled)
                  Text(widget.shortcut!, style: TextStyle(fontSize: 10, color: tw.slate400)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuSectionLabel extends StatelessWidget {
  final DatieveState state;
  final String label;

  const _MenuSectionLabel({required this.state, required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
          color: Tw(state.colors).slate400,
        ),
      ),
    );
  }
}

class _MenuDivider extends StatelessWidget {
  final DatieveState state;

  const _MenuDivider({required this.state});

  @override
  Widget build(BuildContext context) {
    return Divider(height: 8, color: Tw(state.colors).slate100);
  }
}

class _LocalItemMenu extends StatelessWidget {
  final DatieveState state;
  final LocalCtxMenu menu;

  const _LocalItemMenu({required this.state, required this.menu});

  Widget? _buildSubMenuOverlay(BuildContext context, DatieveState s) {
    final anchor = s.fmItemSubMenuAnchor;
    if (s.fmItemSubMenu.isEmpty || anchor == null) return null;
    final file = menu.file;
    List<Widget> items;
    switch (s.fmItemSubMenu) {
      case 'tags':
        items = [
          for (final tag in s.fileTags)
            _SubMenuChoice(
              state: s,
              label: tag.name,
              selected: s.tagsForPath(file.path).any((t) => t.id == tag.id),
              onTap: () {
                final paths = s.fmSelectedPaths.isNotEmpty ? s.fmSelectedPaths.toList() : [file.path];
                final enabled = !s.tagsForPath(file.path).any((t) => t.id == tag.id);
                for (final p in paths) { s.setTagOnPath(p, tag.id, enabled); }
                s.closeAllMenus();
              },
            ),
        ];
      default:
        return null;
    }
    return _buildSubMenuPanel(context, s, anchor, items, isItem: true);
  }

  @override
  Widget build(BuildContext context) {
    final file = menu.file;
    final s = state;
    final multi = s.fmSelectedPaths.length > 1;
    final single = s.fmSelectedPaths.length <= 1;
    final settings = s.settings;

    return _MenuShell(
      state: s,
      x: menu.x,
      y: menu.y,
      width: 208,
      onClose: s.closeAllMenus,
      subMenuOverlay: _buildSubMenuOverlay(context, s),
      children: [
        if (single)
          _MenuItem(
            state: s,
            label: 'Open',
            onTap: () {
              s.closeAllMenus();
              if (file.isDir) {
                s.openFile(file);
              } else {
                s.openNativeFile(file.path);
              }
            },
          ),
        if (single && file.isDir)
          _MenuItem(
            state: s,
            label: 'Open in New Tab',
            onTap: () {
              s.closeAllMenus();
              s.openPathInNewTab(file.path, file.name);
            },
          ),
        if (single && !file.isDir)
          _MenuItem(
            state: s,
            label: 'Open With…',
            onTap: () => s.openOpenWithDialog(file.path),
          ),
        if (single && file.isDir && settings.contextOpenTerminal)
          _MenuItem(
            state: s,
            label: 'Open in Terminal',
            onTap: () {
              s.closeAllMenus();
              s.openTerminalAt(file.path);
            },
          ),
        _MenuDivider(state: s),
        _MenuItem(state: s, label: 'Cut', shortcut: 'Ctrl+X', onTap: () {
          s.cutSelected();
          s.closeAllMenus();
        }),
        _MenuItem(state: s, label: 'Copy', shortcut: 'Ctrl+C', onTap: () {
          s.copySelected();
          s.closeAllMenus();
        }),
        _MenuItem(
          state: s,
          label: 'Paste',
          shortcut: 'Ctrl+V',
          enabled: s.fmClipboard != null,
          onTap: () { s.closeAllMenus(); s.pasteClipboard(); },
        ),
        _MenuDivider(state: s),
        if (single)
          _MenuItem(
            state: s,
            label: 'Rename',
            shortcut: 'F2',
            onTap: () => s.startRename(file),
          ),
        if (multi)
          _MenuItem(
            state: s,
            label: 'Bulk Rename',
            shortcut: 'F2',
            onTap: s.startBulkRename,
          ),
        _MenuItem(
          state: s,
          label: 'Duplicate',
          onTap: () {
            s.closeAllMenus();
            s.duplicateSelected(file.path);
          },
        ),
        if (s.fileTags.isNotEmpty)
          _ItemSubMenuTrigger(state: s, id: 'tags', label: 'Tags'),
        if (s.viewMode == 'local')
          _MenuItem(
            state: s,
            label: 'Create Symlink',
            onTap: () {
              s.closeAllMenus();
              s.createSymlink(target: file.path, linkName: file.name);
            },
          ),
        _MenuDivider(state: s),
        if (settings.contextCopyPath) ...[
          _MenuItem(
            state: s,
            label: 'Copy Path',
            onTap: () {
              s.closeAllMenus();
              s.copyPathToClipboard();
            },
          ),
          _MenuItem(
            state: s,
            label: 'Copy Path with Quotes',
            onTap: () {
              s.closeAllMenus();
              s.copyPathToClipboard(quoted: true);
            },
          ),
        ],
        _MenuItem(
          state: s,
          label: 'Copy Name',
          onTap: () {
            s.closeAllMenus();
            s.copyNamesToClipboard();
          },
        ),
        if (settings.contextArchive) ...[
          _MenuDivider(state: s),
          _MenuItem(
            state: s,
            label: 'Compress to .zip',
            onTap: () {
              s.closeAllMenus();
              s.compressSelected('zip');
            },
          ),
          _MenuItem(
            state: s,
            label: 'Compress to .7z',
            onTap: () {
              s.closeAllMenus();
              s.compressSelected('7z');
            },
          ),
          if (single && !file.isDir && isArchive(file.name))
            _MenuItem(
              state: s,
              label: 'Extract Here',
              onTap: () {
                s.closeAllMenus();
                s.extractHere(file.path);
              },
            ),
        ],
        if (single && file.isDir) ...[
          _MenuDivider(state: s),
          _MenuItem(
            state: s,
            label: 'Add to Places',
            onTap: () {
              s.closeAllMenus();
              s.addToPlaces(file.path, file.name);
            },
          ),
          _MenuItem(
            state: s,
            label: 'Add to Bookmarks',
            onTap: () {
              s.closeAllMenus();
              s.addBookmarkFromPath(file.name, file.path);
            },
          ),
          _MenuItem(
            state: s,
            label: 'Change folder icon',
            onTap: () => s.openFolderIconPicker(file.path, file.name),
          ),
        ],
        _MenuDivider(state: s),
        if (s.isTrashView) ...[
          _MenuItem(
            state: s,
            label: 'Restore from Trash',
            onTap: () {
              s.closeAllMenus();
              s.restoreFromTrash();
            },
          ),
          _MenuItem(
            state: s,
            label: 'Delete Permanently',
            shortcut: '⇧Del',
            danger: true,
            onTap: () {
              s.closeAllMenus();
              s.deleteSelectedPermanently();
            },
          ),
        ] else
          _MenuItem(
            state: s,
            label: 'Move to Trash',
            shortcut: 'Del',
            danger: true,
            onTap: () {
              s.closeAllMenus();
              s.trashSelected();
            },
          ),
        if (single) ...[
          _MenuDivider(state: s),
          _MenuItem(
            state: s,
            label: 'Properties',
            onTap: () => s.openProperties(file),
          ),
        ],
      ],
    );
  }
}

class _EmptyAreaMenu extends StatelessWidget {
  final DatieveState state;
  final EmptyCtxMenu menu;

  const _EmptyAreaMenu({required this.state, required this.menu});

  List<Widget> _layoutItems(DatieveState s) => [
        _SubMenuChoice(
          state: s, label: 'List View',
          selected: s.settings.localViewStyle == 'list',
          onTap: () { s.updateSettings(s.settings.copyWith(localViewStyle: 'list')); s.closeAllMenus(); },
        ),
        _SubMenuChoice(
          state: s, label: 'Compact View',
          selected: s.settings.localViewStyle == 'compact',
          onTap: () { s.updateSettings(s.settings.copyWith(localViewStyle: 'compact')); s.closeAllMenus(); },
        ),
      ];

  List<Widget> _sortItems(DatieveState s) => [
        for (final v in ['name', 'modified', 'created', 'size', 'type', 'tag'])
          _SubMenuChoice(
            state: s, label: _sortLabel(v),
            selected: s.settings.sortBy == v,
            onTap: () { s.updateSettings(s.settings.copyWith(sortBy: v)); s.closeAllMenus(); },
          ),
        _MenuDivider(state: s),
        _SubMenuChoice(state: s, label: 'Ascending', selected: s.settings.sortDir == 'asc',
            onTap: () { s.updateSettings(s.settings.copyWith(sortDir: 'asc')); s.closeAllMenus(); }),
        _SubMenuChoice(state: s, label: 'Descending', selected: s.settings.sortDir == 'desc',
            onTap: () { s.updateSettings(s.settings.copyWith(sortDir: 'desc')); s.closeAllMenus(); }),
      ];

  List<Widget> _groupItems(DatieveState s) => [
        for (final v in ['none', 'name', 'modified', 'created', 'size', 'type', 'tag'])
          _SubMenuChoice(
            state: s, label: _groupLabel(v),
            selected: s.settings.groupBy == v,
            onTap: () { s.updateSettings(s.settings.copyWith(groupBy: v)); s.closeAllMenus(); },
          ),
      ];

  List<Widget> _newItems(DatieveState s) => s.viewMode == 'nas'
      ? [
          _SubMenuChoice(state: s, label: 'Folder', selected: false, shortcut: 'Ctrl+⇧N',
              onTap: () { s.closeAllMenus(); s.nasCreateNewFolder(); }),
          _SubMenuChoice(state: s, label: 'File', selected: false, shortcut: 'Ctrl+N',
              onTap: () { s.closeAllMenus(); s.nasCreateNewFile(); }),
        ]
      : [
          _SubMenuChoice(state: s, label: 'Folder', selected: false, shortcut: '⌘⇧N',
              onTap: () { s.closeAllMenus(); s.createNewFolder(); }),
          _SubMenuChoice(state: s, label: 'File', selected: false,
              onTap: () { s.closeAllMenus(); s.createNewFile(); }),
          _SubMenuChoice(state: s, label: 'Text File', selected: false,
              onTap: () { s.closeAllMenus(); s.createTextTemplate('New Text', 'txt', ''); }),
          _SubMenuChoice(state: s, label: 'Markdown File', selected: false,
              onTap: () { s.closeAllMenus(); s.createTextTemplate('New Markdown', 'md', '# New Markdown\n'); }),
          _SubMenuChoice(state: s, label: 'JSON File', selected: false,
              onTap: () { s.closeAllMenus(); s.createTextTemplate('New JSON', 'json', '{\n  \n}\n'); }),
        ];

  Widget? _buildSubMenuOverlay(BuildContext context, DatieveState s) {
    final anchor = s.fmEmptySubMenuAnchor;
    if (s.fmEmptySubMenu.isEmpty || anchor == null) return null;
    final items = switch (s.fmEmptySubMenu) {
      'layout' => _layoutItems(s),
      'sort' => _sortItems(s),
      'group' => _groupItems(s),
      'new' => _newItems(s),
      _ => <Widget>[],
    };
    if (items.isEmpty) return null;
    return _buildSubMenuPanel(context, s, anchor, items, isItem: false);
  }

  @override
  Widget build(BuildContext context) {
    final s = state;
    final settings = s.settings;
    return _MenuShell(
      state: s,
      x: menu.x,
      y: menu.y,
      width: 208,
      onClose: s.closeAllMenus,
      subMenuOverlay: _buildSubMenuOverlay(context, s),
      children: [
        _EmptySubMenuTrigger(state: s, id: 'layout', label: 'Layout'),
        _EmptySubMenuTrigger(state: s, id: 'sort', label: 'Sort By'),
        _EmptySubMenuTrigger(state: s, id: 'group', label: 'Group By'),
        _MenuItem(
          state: s,
          label: 'Refresh',
          shortcut: 'F5',
          onTap: () {
            s.closeAllMenus();
            s.refreshFileManager();
          },
        ),
        _MenuDivider(state: s),
        if (s.viewMode != 'nas' || s.fmMeta.currentPath.isNotEmpty)
          _EmptySubMenuTrigger(state: s, id: 'new', label: 'New'),
        if (s.viewMode == 'local')
          _MenuItem(
            state: s,
            label: 'Create Symlink...',
            onTap: () {
              s.closeAllMenus();
              _showSymlinkTargetDialog(context, s);
            },
          ),
        _MenuItem(
          state: s,
          label: 'Paste',
          shortcut: 'Ctrl+V',
          enabled: s.fmClipboard != null,
          onTap: () {
            s.closeAllMenus();
            if (s.viewMode == 'nas' && s.fmClipboard?.scope == 'nas') {
              s.nasPasteClipboard();
            } else {
              s.pasteClipboard();
            }
          },
        ),
        _MenuDivider(state: s),
        _MenuItem(state: s, label: 'Select All', shortcut: 'Ctrl+A',
            onTap: () { s.closeAllMenus(); s.selectAllFiles(); }),
        _MenuItem(state: s, label: 'Invert Selection',
            onTap: () { s.closeAllMenus(); s.invertSelection(); }),
        if (s.fmSelectedPaths.isNotEmpty)
          _MenuItem(state: s, label: 'Clear Selection',
              onTap: () { s.closeAllMenus(); s.clearSelection(); }),
        if (s.isTrashView) ...[
          _MenuDivider(state: s),
          if (s.fmSelectedPaths.isNotEmpty)
            _MenuItem(state: s, label: 'Restore Selected',
                onTap: () { s.closeAllMenus(); s.restoreFromTrash(); }),
          _MenuItem(state: s, label: 'Empty Trash', danger: true,
              onTap: () { s.closeAllMenus(); s.emptyTrash(); }),
        ],
        if (settings.contextOpenTerminal && s.viewMode == 'local') ...[
          _MenuDivider(state: s),
          _MenuItem(state: s, label: 'Open Terminal Here',
              onTap: () { s.closeAllMenus(); s.openTerminalAt(s.localCurrentDir); }),
        ],
      ],
    );
  }

  static String _sortLabel(String v) => switch (v) {
        'name' => 'Name',
        'modified' => 'Date Modified',
        'created' => 'Date Created',
        'size' => 'Size',
        'type' => 'Type',
        'tag' => 'Tag',
        _ => v,
      };

  static String _groupLabel(String v) => switch (v) {
        'none' => 'No Grouping',
        'name' => 'Name',
        'modified' => 'Date Modified',
        'created' => 'Date Created',
        'size' => 'Size',
        'type' => 'Type',
        'tag' => 'Tag',
        _ => v,
      };
}

// Renders a floating submenu panel at [anchor] (screen coords = right edge of trigger row).
// Rendered in _MenuShell's outer Stack so it is never clipped by ClipRRect.
// Flips right→left and down→up automatically when near screen edges.
Widget _buildSubMenuPanel(
  BuildContext context,
  DatieveState s,
  Offset anchor,
  List<Widget> items, {
  required bool isItem,
}) {
  final tw = Tw(s.colors);
  final viewport = MediaQuery.sizeOf(context);
  const panelW = 176.0;
  const menuW = 208.0;
  const maxPanelH = 360.0;
  // MenuItem height: 8*2 padding + ~13px text ≈ 33px
  const triggerH = 33.0;

  // Horizontal: flip left if not enough room on the right
  final left = (anchor.dx + panelW > viewport.width)
      ? anchor.dx - menuW - panelW
      : anchor.dx;

  // Vertical: flip upward if not enough room below
  final enoughBelow = anchor.dy + maxPanelH <= viewport.height - 8;
  final panelMaxH = enoughBelow
      ? maxPanelH
      : (anchor.dy + triggerH - 8).clamp(80.0, maxPanelH);

  return Positioned(
    left: left,
    // Open downward from trigger top, or upward from trigger bottom
    top: enoughBelow ? anchor.dy : null,
    bottom: enoughBelow ? null : viewport.height - anchor.dy - triggerH,
    child: MouseRegion(
      onEnter: (_) => isItem ? s.cancelCloseItemSubMenu() : s.cancelCloseEmptySubMenu(),
      onExit: (_) => isItem ? s.delayCloseItemSubMenu() : s.delayCloseEmptySubMenu(),
      child: GestureDetector(
        onTap: () {},
        child: Material(
          elevation: 12,
          borderRadius: BorderRadius.circular(12),
          color: tw.white,
          shadowColor: Colors.black26,
          child: Container(
            width: panelW,
            constraints: BoxConstraints(maxHeight: panelMaxH),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: tw.slate100),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: items,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void _showSymlinkTargetDialog(BuildContext context, DatieveState s) {
  final ctrl = TextEditingController();
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Create Symlink'),
      content: TextField(
        controller: ctrl,
        decoration: const InputDecoration(
          labelText: 'Target path',
          hintText: '/path/to/target',
        ),
        autofocus: true,
        onSubmitted: (_) {
          final target = ctrl.text.trim();
          if (target.isEmpty) return;
          final parts = target.replaceAll(RegExp(r'/+$'), '').split('/');
          final name = parts.lastWhere((p) => p.isNotEmpty, orElse: () => 'symlink');
          Navigator.pop(ctx);
          s.createSymlink(target: target, linkName: name);
        },
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        TextButton(
          onPressed: () {
            final target = ctrl.text.trim();
            if (target.isEmpty) return;
            final parts = target.replaceAll(RegExp(r'/+$'), '').split('/');
            final name = parts.lastWhere((p) => p.isNotEmpty, orElse: () => 'symlink');
            Navigator.pop(ctx);
            s.createSymlink(target: target, linkName: name);
          },
          child: const Text('Create'),
        ),
      ],
    ),
  );
}

class _ItemSubMenuTrigger extends StatefulWidget {
  final DatieveState state;
  final String id;
  final String label;

  const _ItemSubMenuTrigger({
    required this.state,
    required this.id,
    required this.label,
  });

  @override
  State<_ItemSubMenuTrigger> createState() => _ItemSubMenuTriggerState();
}

class _ItemSubMenuTriggerState extends State<_ItemSubMenuTrigger> {
  final _key = GlobalKey();

  void _open() {
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final tl = box.localToGlobal(Offset.zero);
    widget.state.setItemSubMenu(widget.id, Offset(tl.dx + box.size.width, tl.dy));
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    return MouseRegion(
      key: _key,
      onEnter: (_) => _open(),
      onExit: (_) => s.delayCloseItemSubMenu(),
      child: _MenuItem(
        state: s,
        label: widget.label,
        submenu: true,
        submenuOpen: s.fmItemSubMenu == widget.id,
        onTap: () {
          if (s.fmItemSubMenu == widget.id) {
            s.setItemSubMenu('');
          } else {
            _open();
          }
        },
      ),
    );
  }
}

class _EmptySubMenuTrigger extends StatefulWidget {
  final DatieveState state;
  final String id;
  final String label;

  const _EmptySubMenuTrigger({
    required this.state,
    required this.id,
    required this.label,
  });

  @override
  State<_EmptySubMenuTrigger> createState() => _EmptySubMenuTriggerState();
}

class _EmptySubMenuTriggerState extends State<_EmptySubMenuTrigger> {
  final _key = GlobalKey();

  void _open() {
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final tl = box.localToGlobal(Offset.zero);
    widget.state.setEmptySubMenu(widget.id, Offset(tl.dx + box.size.width, tl.dy));
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    return MouseRegion(
      key: _key,
      onEnter: (_) => _open(),
      onExit: (_) => s.delayCloseEmptySubMenu(),
      child: _MenuItem(
        state: s,
        label: widget.label,
        submenu: true,
        submenuOpen: s.fmEmptySubMenu == widget.id,
        onTap: () {
          if (s.fmEmptySubMenu == widget.id) {
            s.setEmptySubMenu('');
          } else {
            _open();
          }
        },
      ),
    );
  }
}

class _SubMenuChoice extends StatelessWidget {
  final DatieveState state;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? shortcut;

  const _SubMenuChoice({
    required this.state,
    required this.label,
    required this.selected,
    required this.onTap,
    this.shortcut,
  });

  @override
  Widget build(BuildContext context) {
    return _MenuItem(
      state: state,
      label: selected ? '✓ $label' : label,
      shortcut: shortcut,
      onTap: onTap,
    );
  }
}

class _NasItemMenu extends StatelessWidget {
  final DatieveState state;
  final NasCtxMenu menu;

  const _NasItemMenu({required this.state, required this.menu});

  @override
  Widget build(BuildContext context) {
    final s = state;
    final file = menu.file;
    final single = s.fmSelectedPaths.length <= 1;
    final multi = s.fmSelectedPaths.length > 1;
    final isAdmin = s.session?.isAdmin ?? false;
    final settings = s.settings;
    final isFolder = menu.type == 'folder' || file.isDir;

    return _MenuShell(
      state: s,
      x: menu.x,
      y: menu.y,
      width: 208,
      onClose: s.closeAllMenus,
      children: [
        if (single)
          _MenuItem(
            state: s,
            label: 'Open',
            onTap: () {
              s.closeAllMenus();
              s.openFile(file);
            },
          ),
        if (single && !isFolder)
          _MenuItem(
            state: s,
            label: 'Open With…',
            onTap: () => s.openOpenWithDialog(file.path),
          ),
        _MenuDivider(state: s),
        _MenuItem(state: s, label: 'Cut', shortcut: 'Ctrl+X', onTap: () {
          s.cutSelected();
          s.closeAllMenus();
        }),
        _MenuItem(state: s, label: 'Copy', shortcut: 'Ctrl+C', onTap: () {
          s.copySelected();
          s.closeAllMenus();
        }),
        _MenuItem(
          state: s,
          label: 'Paste',
          shortcut: 'Ctrl+V',
          enabled: s.fmClipboard != null,
          onTap: () {
            s.closeAllMenus();
            s.nasPasteClipboard();
          },
        ),
        _MenuDivider(state: s),
        if (single)
          _MenuItem(
            state: s,
            label: 'Rename',
            shortcut: 'F2',
            onTap: () => s.startRename(file),
          ),
        if (multi)
          _MenuItem(
            state: s,
            label: 'Bulk Rename',
            shortcut: 'F2',
            onTap: s.startBulkRename,
          ),
        _MenuItem(
          state: s,
          label: 'Duplicate',
          onTap: () {
            s.closeAllMenus();
            s.nasDuplicateSelected(file.path);
          },
        ),
        _MenuDivider(state: s),
        if (single && settings.contextCopyPath) ...[
          _MenuItem(
            state: s,
            label: 'Copy Path',
            onTap: () {
              s.closeAllMenus();
              s.copyPathToClipboard();
            },
          ),
          _MenuItem(
            state: s,
            label: 'Copy Path with Quotes',
            onTap: () {
              s.closeAllMenus();
              s.copyPathToClipboard(quoted: true);
            },
          ),
        ],
        _MenuItem(
          state: s,
          label: 'Copy Name',
          onTap: () {
            s.closeAllMenus();
            Clipboard.setData(ClipboardData(text: file.name));
          },
        ),
        if (single && !isFolder && isImage(file.name)) ...[
          _MenuDivider(state: s),
          _MenuItem(
            state: s,
            label: 'Rotate Left',
            onTap: () {
              s.closeAllMenus();
              s.nasRotateImage(file.path, 'left');
            },
          ),
          _MenuItem(
            state: s,
            label: 'Rotate Right',
            onTap: () {
              s.closeAllMenus();
              s.nasRotateImage(file.path, 'right');
            },
          ),
        ],
        if (settings.contextArchive) ...[
          _MenuDivider(state: s),
          _MenuItem(
            state: s,
            label: 'Compress to .zip',
            onTap: () {
              s.closeAllMenus();
              s.nasCompress(s.selectedLocalPaths.isEmpty ? [file.path] : s.selectedLocalPaths, 'zip');
            },
          ),
          _MenuItem(
            state: s,
            label: 'Compress to .7z',
            onTap: () {
              s.closeAllMenus();
              s.nasCompress(s.selectedLocalPaths.isEmpty ? [file.path] : s.selectedLocalPaths, '7z');
            },
          ),
          if (single && !isFolder && isArchive(file.name)) ...[
            _MenuItem(
              state: s,
              label: 'Extract Here',
              onTap: () {
                s.closeAllMenus();
                s.nasExtractHere(file.path);
              },
            ),
            _MenuItem(
              state: s,
              label: 'Extract to Subfolder',
              onTap: () {
                s.closeAllMenus();
                s.nasExtractToSubfolder(file.path);
              },
            ),
          ],
        ],
        _MenuDivider(state: s),
        _MenuItem(
          state: s,
          label: 'Move to Trash',
          shortcut: 'Del',
          danger: true,
          onTap: () {
            s.closeAllMenus();
            s.nasTrashSelected();
          },
        ),
        _MenuItem(
          state: s,
          label: 'Delete Permanently',
          shortcut: 'Shift+Del',
          danger: true,
          onTap: () {
            s.closeAllMenus();
            s.nasDeleteSelected();
          },
        ),
        if (isAdmin) ...[
          _MenuDivider(state: s),
          _MenuItem(
            state: s,
            label: 'Open Management',
            onTap: () {
              s.closeAllMenus();
              s.openFmAdmin();
            },
          ),
        ],
        if (single) ...[
          _MenuDivider(state: s),
          _MenuItem(
            state: s,
            label: 'Properties',
            onTap: () => s.openProperties(file),
          ),
        ],
      ],
    );
  }
}

class _TabContextMenu extends StatelessWidget {
  final DatieveState state;
  final TabCtxMenu menu;

  const _TabContextMenu({required this.state, required this.menu});

  @override
  Widget build(BuildContext context) {
    final s = state;
    final tabIndex = s.localTabs.indexWhere((t) => t.id == menu.id);
    final canCloseOthers = s.localTabs.length > 1;
    final canCloseRight = tabIndex >= 0 && tabIndex < s.localTabs.length - 1;

    return _MenuShell(
      state: s,
      x: menu.x,
      y: menu.y,
      width: 208,
      onClose: s.closeTabCtxMenu,
      children: [
        _MenuItem(
          state: s,
          label: 'New Tab',
          shortcut: 'Ctrl+T',
          onTap: () {
            s.closeTabCtxMenu();
            s.newLocalTab();
          },
        ),
        _MenuItem(
          state: s,
          label: 'Duplicate Tab',
          shortcut: 'Ctrl+Shift+K',
          onTap: () {
            s.closeTabCtxMenu();
            s.duplicateLocalTab(menu.id);
          },
        ),
        _MenuDivider(state: s),
        _MenuItem(
          state: s,
          label: 'Close Tab',
          shortcut: 'Ctrl+W',
          onTap: canCloseOthers
              ? () {
                  s.closeTabCtxMenu();
                  s.closeLocalTab(menu.id);
                }
              : () {},
        ),
        _MenuItem(
          state: s,
          label: 'Close Other Tabs',
          onTap: canCloseOthers
              ? () {
                  s.closeTabCtxMenu();
                  s.closeOtherLocalTabs(menu.id);
                }
              : () {},
        ),
        _MenuItem(
          state: s,
          label: 'Close Tabs to the Right',
          onTap: canCloseRight
              ? () {
                  s.closeTabCtxMenu();
                  s.closeTabsToRight(menu.id);
                }
              : () {},
        ),
        _MenuDivider(state: s),
        _MenuItem(
          state: s,
          label: 'Reopen Closed Tab',
          onTap: s.closedLocalTabs.isEmpty
              ? () {}
              : () {
                  s.closeTabCtxMenu();
                  s.reopenClosedLocalTab();
                },
        ),
      ],
    );
  }
}

class _SidebarMenu extends StatelessWidget {
  final DatieveState state;
  final SidebarCtxMenu menu;

  const _SidebarMenu({required this.state, required this.menu});

  @override
  Widget build(BuildContext context) {
    final s = state;
    return _MenuShell(
      state: s,
      x: menu.x,
      y: menu.y,
      width: 176,
      onClose: s.closeAllMenus,
      children: [
        if (menu.type != 'nas' && menu.path != null) ...[
          _MenuItem(
            state: s,
            label: 'Open',
            onTap: () => s.openSidebarPath(menu.path, menu.label),
          ),
          _MenuItem(
            state: s,
            label: 'Open in New Tab',
            onTap: () => s.openSidebarPathInNewTab(menu.path!, menu.label),
          ),
          _MenuItem(
            state: s,
            label: 'Copy path',
            onTap: () => s.copySidebarPath(menu.path),
          ),
          _MenuItem(
            state: s,
            label: 'Open terminal here',
            onTap: () => s.openSidebarTerminal(menu.path),
          ),
        ],
        if (menu.type != 'device' && menu.type != 'tag')
          _MenuItem(
            state: s,
            label: 'Rename',
            onTap: () => s.startSidebarRename(menu),
          ),
        if (menu.type == 'place' && s.placesAliases.containsKey(menu.path ?? menu.key))
          _MenuItem(
            state: s,
            label: 'Remove name',
            onTap: () {
              s.closeAllMenus();
              s.savePlaceAlias(menu.path ?? menu.key, '');
            },
          ),
        if (menu.type == 'place')
          _MenuItem(
            state: s,
            label: 'Remove from Places',
            danger: true,
            onTap: () {
              s.closeAllMenus();
              s.hidePlace(menu.path ?? menu.key);
            },
          ),
        if (menu.type == 'custom_place')
          _MenuItem(
            state: s,
            label: 'Remove from Places',
            danger: true,
            onTap: () {
              s.closeAllMenus();
              s.removeCustomPlace(menu.path ?? menu.key);
            },
          ),
        if (menu.type == 'bookmark') ...[
          _MenuItem(
            state: s,
            label: 'Remove bookmark',
            danger: true,
            onTap: () {
              s.closeAllMenus();
              s.removeBookmark(menu.key);
            },
          ),
        ],
        if (menu.type == 'device' && menu.path != null)
          _MenuItem(
            state: s,
            label: 'Hide device',
            danger: true,
            onTap: () {
              s.closeAllMenus();
              s.hideDevice(menu.path!);
            },
          ),
        if (menu.type == 'tag') ...[
          _MenuItem(
            state: s,
            label: 'Rename tag',
            onTap: () => s.startSidebarRename(menu),
          ),
          _MenuItem(
            state: s,
            label: 'Remove tag',
            danger: true,
            onTap: () {
              s.closeAllMenus();
              s.removeFileTag(menu.key);
            },
          ),
        ],
      ],
    );
  }
}