import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../models/file_tag.dart';
import '../src/rust/bridge.dart';
import '../state/datieve_state.dart';
import '../theme/css_tokens.dart';
import '../theme/datieve_theme.dart';
import '../utils/settings_helpers.dart';
import 'fm_settings_widgets.dart';

/// Full-screen settings overlay — exact port of App.tsx lines 4960–5515.
class FmSettingsPanel extends StatefulWidget {
  final DatieveState state;

  const FmSettingsPanel({super.key, required this.state});

  @override
  State<FmSettingsPanel> createState() => _FmSettingsPanelState();
}

class _FmSettingsPanelState extends State<FmSettingsPanel> {
  String _view = 'appearance';
  String _search = '';
  final _searchController = TextEditingController();
  final _mountNasController = TextEditingController();
  final _mountLocalController = TextEditingController();

  DatieveColors get c => widget.state.colors;
  Tw get tw => Tw(c);

  void _patch(AppSettingsDto Function(AppSettingsDto) fn) {
    widget.state.updateSettings(fn(widget.state.settings));
  }

  static const _shortcuts = [
    ('Space', 'Quick preview selected local item'),
    ('F5', 'Refresh current folder'),
    ('Ctrl+F or /', 'Focus search bar'),
    ('Ctrl+H', 'Toggle hidden files'),
    ('Ctrl+Shift+N', 'New folder'),
    ('Ctrl+Shift+P', 'Open command palette'),
    ('Ctrl+L', 'Edit current path'),
    ('Ctrl+T', 'New tab'),
    ('Ctrl+W', 'Close current tab'),
    ('Ctrl+Shift+K', 'Duplicate current tab'),
    ('Ctrl+Shift+T', 'Reopen closed tab'),
    ('Ctrl+Tab', 'Next tab'),
    ('Ctrl+Shift+Tab', 'Previous tab'),
    ('Ctrl+N', 'New file'),
    ('Alt+Left', 'Navigate back'),
    ('Alt+Right', 'Navigate forward'),
    ('Alt+Up / Backspace', 'Go up one level'),
    ('Ctrl++', 'Zoom in'),
    ('Ctrl+-', 'Zoom out'),
    ('Ctrl+0', 'Reset zoom'),
    ('Escape', 'Clear selection / cancel / close'),
    ('Enter', 'Open selected item'),
    ('↑ / ↓', 'Move selection up / down'),
    ('Home / End', 'Jump to first / last item'),
    ('Ctrl+S', 'Open settings'),
    ('Ctrl+Q', 'Exit to agent selection'),
  ];

  List<({String id, String label, String keywords})> get _pages {
    final isAdmin = widget.state.session?.isAdmin ?? false;
    return [
      (id: 'appearance', label: 'Appearance', keywords: 'theme dark light system interface scale zoom startup restore tabs session info pane preview details metadata toolbar buttons filters hidden deleted view toggle'),
      (id: 'view', label: 'File View', keywords: 'folder view layout list compact sort direction group hidden files extensions thumbnails size units calculate folders'),
      (id: 'tags', label: 'Tags', keywords: 'file tags labels colors classify organize'),
      (id: 'behavior', label: 'Behavior', keywords: 'single click open hover selection double click blank space go up parent folder scroll previous folder trash delete confirm rename extension terminal'),
      (id: 'mounts', label: 'Mount Mappings', keywords: 'mount mapping nas remote local prefix translation path'),
      (id: 'context', label: 'Context Menu', keywords: 'right click menu terminal copy path compress extract archive symlink pin sidebar'),
      (id: 'loading', label: 'File Loading', keywords: 'lazy loading page size large folders'),
      (id: 'shortcuts', label: 'Shortcuts', keywords: 'keyboard hotkeys command palette navigation selection'),
      if (isAdmin)
        (id: 'admin', label: 'Administration', keywords: 'management console users folders exclusions maintenance admin'),
      (id: 'about', label: 'About', keywords: 'open source license apache files community dolphin credits updates version reset settings'),
    ];
  }

  List<({String id, String label, String keywords})> get _filteredPages {
    final q = _search.trim().toLowerCase();
    if (q.isEmpty) return _pages;
    return _pages
        .where((p) => '${p.label} ${p.keywords}'.toLowerCase().contains(q))
        .toList();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _mountNasController.dispose();
    _mountLocalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state.settings;
    final pages = _filteredPages;

    return Positioned.fill(
      child: Material(
        color: tw.white,
        child: Column(
          children: [
            Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: tw.slate50,
                border: Border(bottom: BorderSide(color: tw.line)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: tw.slate900,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Center(
                      child: Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: tw.white,
                          borderRadius: BorderRadius.circular(1),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('Settings', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: tw.ink)),
                  const Spacer(),
                  IconButton(
                    icon: Icon(LucideIcons.x, size: 14, color: tw.slate400),
                    onPressed: widget.state.closeFmSettings,
                    padding: const EdgeInsets.all(6),
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 176,
                    child: ColoredBox(
                      color: tw.slate50,
                      child: Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                            child: Container(
                              height: 32,
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              decoration: BoxDecoration(
                                color: tw.white,
                                border: Border.all(color: tw.slate200),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Row(
                                children: [
                                  Icon(LucideIcons.search, size: 12, color: tw.slate400),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: TextField(
                                      controller: _searchController,
                                      onChanged: (v) => setState(() => _search = v),
                                      style: TextStyle(fontSize: 12, color: tw.slate700),
                                      decoration: InputDecoration(
                                        hintText: 'Search settings',
                                        hintStyle: TextStyle(fontSize: 12, color: tw.slate400),
                                        border: InputBorder.none,
                                        isDense: true,
                                        contentPadding: EdgeInsets.zero,
                                      ),
                                    ),
                                  ),
                                  if (_search.isNotEmpty)
                                    GestureDetector(
                                      onTap: () {
                                        _searchController.clear();
                                        setState(() => _search = '');
                                      },
                                      child: Icon(LucideIcons.x, size: 11, color: tw.slate300),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          if (pages.isEmpty)
                            Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text('No settings found', style: TextStyle(fontSize: 11, color: tw.slate400)),
                            ),
                          Expanded(
                            child: ListView(
                              children: [
                                for (final page in pages)
                                  Material(
                                    color: _view == page.id ? tw.white : Colors.transparent,
                                    child: InkWell(
                                      onTap: () => setState(() => _view = page.id),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                        decoration: BoxDecoration(
                                          border: Border(
                                            bottom: BorderSide(color: tw.line),
                                            right: _view == page.id
                                                ? BorderSide(color: tw.slate900, width: 2)
                                                : BorderSide.none,
                                          ),
                                        ),
                                        child: Text(
                                          page.label,
                                          style: TextStyle(
                                            fontSize: 13,
                                            fontWeight: _view == page.id ? FontWeight.w600 : FontWeight.w400,
                                            color: _view == page.id ? tw.ink : tw.slate500,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  VerticalDivider(width: 1, color: tw.line),
                  Expanded(
                    child: ListView(
                      children: _buildContent(s),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildContent(AppSettingsDto s) {
    switch (_view) {
      case 'appearance':
        return _appearance(s);
      case 'view':
        return _fileView(s);
      case 'loading':
        return _loading(s);
      case 'behavior':
        return _behavior(s);
      case 'context':
        return _context(s);
      case 'shortcuts':
        return _shortcutsView();
      case 'about':
        return _about();
      case 'admin':
        return _admin();
      case 'tags':
        return [
          SettingsSectionHeader(title: 'File Tags'),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
            child: Text(
              'Tags are stored locally. Add tags from the sidebar, assign them via right-click on files, and filter or group by tag in the file list.',
              style: TextStyle(fontSize: 12, color: tw.slate500),
            ),
          ),
          for (final tag in widget.state.fileTags)
            _TagSettingsRow(tag: tag, state: widget.state, colors: c),
          Padding(
            padding: const EdgeInsets.all(24),
            child: OutlinedButton.icon(
              onPressed: () => _showAddTagDialogInSettings(context),
              icon: Icon(LucideIcons.plus, size: 14, color: tw.slate600),
              label: const Text('Add tag'),
            ),
          ),
        ];
      case 'mounts':
        return _mountMappings();
      default:
        return [];
    }
  }

  List<Widget> _appearance(AppSettingsDto s) {
    final dark = widget.state.isDark;
    return [
      SettingsRow(
        colors: c,
        title: 'Dark mode',
        subtitle: 'Switch between light and dark theme',
        trailing: SettingsToggle(
          colors: c,
          value: dark,
          onChanged: (v) => _patch((x) => x.copyWith(theme: v ? 'dark' : 'light')),
        ),
      ),
      SettingsRow(
        colors: c,
        title: 'Theme source',
        subtitle: 'Use system theme or force light/dark',
        trailing: SettingsDropdown(
          colors: c,
          value: s.theme,
          options: const [('system', 'System'), ('light', 'Light'), ('dark', 'Dark')],
          onChanged: (v) => _patch((x) => x.copyWith(theme: v)),
        ),
      ),
      SettingsRow(
        colors: c,
        title: 'Interface scale',
        subtitle: 'Scale the file list and toolbar density',
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _scaleBtn('-', () => _patch((x) => x.copyWith(uiScale: (x.uiScale - 0.1).clamp(0.5, 2.0)))),
            SizedBox(
              width: 40,
              child: Text(
                '${(s.uiScale * 100).round()}%',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: tw.slate700),
              ),
            ),
            _scaleBtn('+', () => _patch((x) => x.copyWith(uiScale: (x.uiScale + 0.1).clamp(0.5, 2.0)))),
          ],
        ),
      ),
      SettingsRow(
        colors: c,
        title: 'Sidebar width',
        subtitle: 'Set the Places and Datieve agent navigation width',
        trailing: SizedBox(
          width: 180,
          child: Row(
            children: [
              Expanded(
                child: Slider(
                  value: s.sidebarWidth.toDouble().clamp(160, 360),
                  min: 160,
                  max: 360,
                  divisions: 20,
                  activeColor: tw.slate900,
                  onChanged: (v) => _patch((x) => x.copyWith(sidebarWidth: v.round())),
                ),
              ),
              Text('${s.sidebarWidth}px', style: TextStyle(fontSize: 12, fontFamily: 'monospace', color: tw.slate500)),
            ],
          ),
        ),
      ),
      SettingsRow(
        colors: c,
        title: 'Info pane',
        subtitle: 'Reserve space for file metadata details',
        trailing: SettingsToggle(
          colors: c,
          value: s.showInfoPane,
          onChanged: (v) => _patch((x) => x.copyWith(showInfoPane: v)),
        ),
      ),
      SettingsSectionHeader(title: 'Startup'),
      SettingsRow(
        colors: c,
        title: 'Restore local tabs',
        subtitle: 'Open the previous local tab set when Datieve starts',
        trailing: SettingsToggle(
          colors: c,
          value: s.restoreTabsOnStartup,
          onChanged: (v) => _patch((x) => x.copyWith(restoreTabsOnStartup: v)),
        ),
      ),
      SettingsSectionHeader(title: 'Toolbar'),
      SettingsRow(
        colors: c,
        title: 'View toggle',
        subtitle: 'Show the list/compact view switch in the toolbar',
        trailing: SettingsToggle(
          colors: c,
          value: s.toolbarShowViewToggle,
          onChanged: (v) => _patch((x) => x.copyWith(toolbarShowViewToggle: v)),
        ),
      ),
      SettingsRow(
        colors: c,
        title: 'Hidden/deleted toggle',
        subtitle: 'Show quick visibility toggles for local and Datieve views',
        trailing: SettingsToggle(
          colors: c,
          value: s.toolbarShowHiddenToggle,
          onChanged: (v) => _patch((x) => x.copyWith(toolbarShowHiddenToggle: v)),
        ),
      ),
      SettingsRow(
        colors: c,
        title: 'Datieve filters',
        subtitle: 'Show the indexed-search filter button for Datieve folders',
        trailing: SettingsToggle(
          colors: c,
          value: s.toolbarShowFilters,
          onChanged: (v) => _patch((x) => x.copyWith(toolbarShowFilters: v)),
        ),
      ),
    ];
  }

  Widget _scaleBtn(String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          border: Border.all(color: tw.slate200),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(label, style: TextStyle(fontSize: 12, color: tw.slate600)),
      ),
    );
  }

  List<Widget> _fileView(AppSettingsDto s) {
    return [
      SettingsSectionHeader(title: 'Layout'),
      SettingsRow(
        colors: c,
        title: 'Folder view',
        subtitle: 'List shows details. Compact shows icons in a grid.',
        trailing: SettingsSegmented(
          colors: c,
          options: const ['List', 'Compact'],
          value: s.localViewStyle == 'compact' ? 'Compact' : 'List',
          onChanged: (v) => _patch((x) => x.copyWith(localViewStyle: v.toLowerCase())),
        ),
      ),
      SettingsSectionHeader(title: 'Sorting'),
      SettingsRow(
        colors: c,
        title: 'Sort by',
        subtitle: 'Default sort column for local folders',
        trailing: SettingsDropdown(
          colors: c,
          value: s.sortBy,
          options: const [
            ('name', 'Name'),
            ('modified', 'Date Modified'),
            ('created', 'Date Created'),
            ('size', 'Size'),
            ('type', 'Type'),
            ('tag', 'Tag'),
          ],
          onChanged: (v) => _patch((x) => x.copyWith(sortBy: v)),
        ),
      ),
      SettingsRow(
        colors: c,
        title: 'Sort direction',
        subtitle: 'Ascending or descending order',
        trailing: SettingsSegmented(
          colors: c,
          options: const ['A→Z', 'Z→A'],
          value: s.sortDir == 'desc' ? 'Z→A' : 'A→Z',
          onChanged: (v) => _patch((x) => x.copyWith(sortDir: v == 'Z→A' ? 'desc' : 'asc')),
        ),
      ),
      SettingsRow(
        colors: c,
        title: 'Group by',
        subtitle: 'Show section headers in list view',
        trailing: SettingsDropdown(
          colors: c,
          value: s.groupBy,
          options: const [
            ('none', 'None'),
            ('name', 'Name'),
            ('modified', 'Date Modified'),
            ('created', 'Date Created'),
            ('size', 'Size'),
            ('type', 'Type'),
            ('tag', 'Tag'),
          ],
          onChanged: (v) => _patch((x) => x.copyWith(groupBy: v)),
        ),
      ),
      SettingsRow(
        colors: c,
        title: 'Folders first',
        subtitle: 'Always list folders before files',
        trailing: SettingsToggle(
          colors: c,
          value: s.foldersFirst,
          onChanged: (v) => _patch((x) => x.copyWith(foldersFirst: v)),
        ),
      ),
      SettingsSectionHeader(title: 'Display'),
      SettingsRow(
        colors: c,
        title: 'Show hidden files',
        subtitle: 'Files and folders starting with a dot',
        trailing: SettingsToggle(
          colors: c,
          value: s.showHidden,
          onChanged: (v) {
            _patch((x) => x.copyWith(showHidden: v));
            if (widget.state.viewMode == 'local') widget.state.fmToggleHidden();
          },
        ),
      ),
      SettingsRow(
        colors: c,
        title: 'Show file extensions',
        subtitle: 'Display .jpg, .pdf etc. in file names',
        trailing: SettingsToggle(
          colors: c,
          value: s.showExtensions,
          onChanged: (v) => _patch((x) => x.copyWith(showExtensions: v)),
        ),
      ),
      SettingsRow(
        colors: c,
        title: 'Image thumbnails',
        subtitle: 'Show actual image previews for .jpg, .png, .webp etc.',
        trailing: SettingsToggle(
          colors: c,
          value: s.showThumbnails,
          onChanged: (v) => _patch((x) => x.copyWith(showThumbnails: v)),
        ),
      ),
      SettingsSectionHeader(title: 'File Sizes'),
      SettingsRow(
        colors: c,
        title: 'Size units',
        subtitle: 'Binary (KiB/MiB) or Decimal (KB/MB)',
        trailing: SettingsSegmented(
          colors: c,
          options: const ['Binary', 'Decimal'],
          value: s.sizeUnit == 'decimal' ? 'Decimal' : 'Binary',
          onChanged: (v) => _patch((x) => x.copyWith(sizeUnit: v.toLowerCase())),
        ),
      ),
      SettingsRow(
        colors: c,
        title: 'Calculate folder sizes',
        subtitle: 'Shows disk usage for folders (may slow large dirs)',
        trailing: SettingsToggle(
          colors: c,
          value: s.calculateFolderSizes,
          onChanged: (v) => _patch((x) => x.copyWith(calculateFolderSizes: v)),
        ),
      ),
    ];
  }

  List<Widget> _loading(AppSettingsDto s) {
    return [
      SettingsSectionHeader(title: 'File loading'),
      SettingsRow(
        colors: c,
        title: 'Lazy loading (NAS)',
        subtitle: 'Load files in pages — useful for large folders',
        trailing: SettingsToggle(
          colors: c,
          value: s.nasLazyLoading,
          onChanged: (v) => _patch((x) => x.copyWith(nasLazyLoading: v)),
        ),
      ),
      if (s.nasLazyLoading)
        SettingsRow(
          colors: c,
          title: 'Files per page',
          subtitle: '',
          trailing: SettingsDropdown(
            colors: c,
            value: s.nasPageSize.toString(),
            options: const [('100', '100'), ('200', '200'), ('500', '500'), ('1000', '1000')],
            onChanged: (v) => _patch((x) => x.copyWith(nasPageSize: int.parse(v))),
          ),
        ),
    ];
  }

  List<Widget> _behavior(AppSettingsDto s) {
    return [
      SettingsSectionHeader(title: 'Navigation'),
      SettingsRow(
        colors: c,
        title: 'Single-click to open',
        subtitle: 'One click opens folders and files (like a browser)',
        trailing: SettingsToggle(colors: c, value: s.singleClickOpen, onChanged: (v) => _patch((x) => x.copyWith(singleClickOpen: v))),
      ),
      SettingsRow(
        colors: c,
        title: 'Double-click blank space to go up',
        subtitle: 'Navigate to the parent folder from empty list space',
        trailing: SettingsToggle(colors: c, value: s.doubleClickBlankGoUp, onChanged: (v) => _patch((x) => x.copyWith(doubleClickBlankGoUp: v))),
      ),
      SettingsRow(
        colors: c,
        title: 'Select previous folder when going up',
        subtitle: 'Keep the folder you came from visible in its parent',
        trailing: SettingsToggle(colors: c, value: s.scrollToPreviousFolderOnUp, onChanged: (v) => _patch((x) => x.copyWith(scrollToPreviousFolderOnUp: v))),
      ),
      SettingsSectionHeader(title: 'Selection'),
      SettingsRow(
        colors: c,
        title: 'Select file on hover',
        subtitle: 'Hovering a row automatically selects it',
        trailing: SettingsToggle(colors: c, value: s.selectOnHover, onChanged: (v) => _patch((x) => x.copyWith(selectOnHover: v))),
      ),
      SettingsSectionHeader(title: 'Deletion'),
      SettingsRow(
        colors: c,
        title: 'Confirm before trash',
        subtitle: 'Ask before moving items to the trash',
        trailing: SettingsToggle(colors: c, value: s.confirmTrash, onChanged: (v) => _patch((x) => x.copyWith(confirmTrash: v))),
      ),
      SettingsRow(
        colors: c,
        title: 'Confirm permanent delete',
        subtitle: 'Ask before permanently deleting files',
        trailing: SettingsToggle(colors: c, value: s.confirmPermanentDelete, onChanged: (v) => _patch((x) => x.copyWith(confirmPermanentDelete: v))),
      ),
      SettingsSectionHeader(title: 'Renaming'),
      SettingsRow(
        colors: c,
        title: 'Warn on extension change',
        subtitle: 'Alert when renaming changes the file extension',
        trailing: SettingsToggle(colors: c, value: s.warnExtensionRename, onChanged: (v) => _patch((x) => x.copyWith(warnExtensionRename: v))),
      ),
      SettingsSectionHeader(title: 'Terminal'),
      SettingsRow(
        colors: c,
        title: 'Default terminal',
        subtitle: 'Leave blank to auto-detect (alacritty, kitty, …)',
        trailing: SizedBox(
          width: 128,
          child: TextField(
            controller: TextEditingController(text: s.defaultTerminal)
              ..selection = TextSelection.collapsed(offset: s.defaultTerminal.length),
            onChanged: (v) => _patch((x) => x.copyWith(defaultTerminal: v)),
            style: TextStyle(fontSize: 12, color: tw.slate700),
            decoration: InputDecoration(
              hintText: 'auto',
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              border: OutlineInputBorder(borderSide: BorderSide(color: tw.slate200)),
            ),
          ),
        ),
      ),
    ];
  }

  List<Widget> _context(AppSettingsDto s) {
    const items = [
      ('Open Terminal', 'Open folder in terminal emulator', 'contextOpenTerminal'),
      ('Copy Path', 'Copy the full path to clipboard', 'contextCopyPath'),
      ('Compress / Extract', 'Archive tools (zip, 7z, extract)', 'contextArchive'),
      ('Create Symlink', 'Create a symbolic link to the item', 'contextSymlink'),
      ('Pin to Sidebar', 'Pin folder to the sidebar Places', 'contextPinSidebar'),
    ];
    return [
      SettingsSectionHeader(title: 'Show in Right-Click Menu'),
      for (final item in items)
        SettingsRow(
          colors: c,
          title: item.$1,
          subtitle: item.$2,
          trailing: SettingsToggle(
            colors: c,
            value: _contextValue(s, item.$3),
            onChanged: (v) => _patch((x) => _contextPatch(x, item.$3, v)),
          ),
        ),
    ];
  }

  bool _contextValue(AppSettingsDto s, String key) {
    switch (key) {
      case 'contextOpenTerminal':
        return s.contextOpenTerminal;
      case 'contextCopyPath':
        return s.contextCopyPath;
      case 'contextArchive':
        return s.contextArchive;
      case 'contextSymlink':
        return s.contextSymlink;
      case 'contextPinSidebar':
        return s.contextPinSidebar;
      default:
        return false;
    }
  }

  AppSettingsDto _contextPatch(AppSettingsDto s, String key, bool v) {
    switch (key) {
      case 'contextOpenTerminal':
        return s.copyWith(contextOpenTerminal: v);
      case 'contextCopyPath':
        return s.copyWith(contextCopyPath: v);
      case 'contextArchive':
        return s.copyWith(contextArchive: v);
      case 'contextSymlink':
        return s.copyWith(contextSymlink: v);
      case 'contextPinSidebar':
        return s.copyWith(contextPinSidebar: v);
      default:
        return s;
    }
  }

  List<Widget> _shortcutsView() {
    return [
      for (final sc in _shortcuts)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: tw.line)),
          ),
          child: Row(
            children: [
              Expanded(child: Text(sc.$2, style: TextStyle(fontSize: 13, color: tw.slate700))),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: tw.slate100,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  sc.$1,
                  style: TextStyle(fontSize: 11, fontFamily: 'monospace', fontWeight: FontWeight.w600, color: tw.slate700),
                ),
              ),
            ],
          ),
        ),
    ];
  }

  List<Widget> _about() {
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Datieve', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: tw.ink)),
            const SizedBox(height: 4),
            Text(
              'Desktop file manager with Datieve agent integration.',
              style: TextStyle(fontSize: 12, color: tw.slate500),
            ),
          ],
        ),
      ),
      Divider(height: 1, color: tw.line),
      Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('License', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: tw.ink)),
            const SizedBox(height: 4),
            Text(
              'Datieve is licensed under the Apache License 2.0.',
              style: TextStyle(fontSize: 12, color: tw.slate500),
            ),
          ],
        ),
      ),
      Divider(height: 1, color: tw.line),
      Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Credits', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: tw.ink)),
            const SizedBox(height: 8),
            Text(
              'Files — files-community/Files',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: tw.slate700),
            ),
            const SizedBox(height: 2),
            Text(
              'Basic file manager behaviors and UX patterns were studied from the Files app (MIT licensed). This project adapts suitable concepts rather than porting Windows-only integrations.',
              style: TextStyle(fontSize: 12, color: tw.slate500),
            ),
            const SizedBox(height: 12),
            Text(
              'Dolphin — KDE file manager',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: tw.slate700),
            ),
            const SizedBox(height: 2),
            Text(
              'Dolphin served as the primary design reference for layout, information density, and navigation patterns in this file manager.',
              style: TextStyle(fontSize: 12, color: tw.slate500),
            ),
          ],
        ),
      ),
      Divider(height: 1, color: tw.line),
      Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Updates', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: tw.ink)),
            const SizedBox(height: 4),
            Text(
              'Version ${DatieveState.kAppVersion}',
              style: TextStyle(fontSize: 12, color: tw.slate500),
            ),
            if (widget.state.updateAvailableVersion != null) ...[
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: widget.state.openReleasePage,
                child: Text('Update available: v${widget.state.updateAvailableVersion}'),
              ),
            ],
          ],
        ),
      ),
      Divider(height: 1, color: tw.line),
      Padding(
        padding: const EdgeInsets.all(24),
        child: OutlinedButton(
          onPressed: widget.state.resetAllSettings,
          child: const Text('Reset app settings'),
        ),
      ),
    ];
  }

  List<Widget> _mountMappings() {
    final s = widget.state;
    return [
      const SettingsSectionHeader(title: 'NAS Mount Mappings'),
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
        child: Text(
          'Map watched folder paths on your NAS (e.g. /volume1/Photos) to local mount points on this computer so you can open files directly from the NAS index.',
          style: TextStyle(fontSize: 12, color: tw.slate500, height: 1.6),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _mountNasController,
                decoration: const InputDecoration(
                  hintText: 'NAS Path Prefix (e.g. /volume1/Photos)',
                  isDense: true,
                ),
                onChanged: s.setMountMappingNasDraft,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _mountLocalController,
                decoration: const InputDecoration(
                  hintText: 'Local Path Prefix (e.g. /media/Photos)',
                  isDense: true,
                ),
                onChanged: s.setMountMappingLocalDraft,
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () {
                s.addMountMapping();
                _mountNasController.clear();
                _mountLocalController.clear();
              },
              style: FilledButton.styleFrom(backgroundColor: tw.slate900),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      for (var i = 0; i < s.mountMappings.length; i++)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: tw.line))),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'NAS: ${s.mountMappings[i].nasPath}',
                      style: TextStyle(fontSize: 13, color: tw.slate600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Local: ${s.mountMappings[i].localPath}',
                      style: TextStyle(fontSize: 13, color: tw.slate600),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => s.deleteMountMapping(i),
                style: TextButton.styleFrom(foregroundColor: tw.red600),
                child: const Text('Delete'),
              ),
            ],
          ),
        ),
      if (s.mountMappings.isEmpty)
        Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'No mount mappings defined. Files opened from the NAS view will use their original NAS paths.',
            style: TextStyle(fontSize: 13, color: tw.slate400),
          ),
        ),
    ];
  }

  List<Widget> _admin() {
    return [
      Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            widget.state.closeFmSettings();
            widget.state.openFmAdmin();
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: tw.line))),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Management Console', style: TextStyle(fontSize: 13, color: tw.ink)),
                      Text(
                        'Users, folders, exclusions, maintenance',
                        style: TextStyle(fontSize: 11, color: tw.slate400),
                      ),
                    ],
                  ),
                ),
                Icon(LucideIcons.chevronRight, size: 14, color: tw.slate400),
              ],
            ),
          ),
        ),
      ),
    ];
  }

  Future<void> _showAddTagDialogInSettings(BuildContext ctx) async {
    final tw = Tw(c);
    final nameCtrl = TextEditingController();
    String selectedColor = _kTagColorsSettings.first.hex;

    await showDialog<void>(
      context: ctx,
      builder: (dCtx) => StatefulBuilder(
        builder: (dCtx, setS) => AlertDialog(
          backgroundColor: tw.white,
          title: Text('Add Tag', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: tw.ink)),
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtrl,
                  autofocus: true,
                  style: TextStyle(fontSize: 13, color: tw.ink),
                  decoration: InputDecoration(
                    hintText: 'Tag name',
                    hintStyle: TextStyle(color: tw.slate400),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    filled: true,
                    fillColor: tw.slate50,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: tw.slate200)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: tw.slate200)),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: tw.slate400)),
                  ),
                  onSubmitted: (_) {
                    final name = nameCtrl.text.trim();
                    if (name.isNotEmpty) {
                      widget.state.addFileTag(name: name, color: selectedColor);
                      Navigator.of(dCtx).pop();
                    }
                  },
                ),
                const SizedBox(height: 16),
                Text('Color', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: tw.slate500, letterSpacing: 1)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _kTagColorsSettings.map((col) {
                    final isSelected = selectedColor == col.hex;
                    return Tooltip(
                      message: col.label,
                      child: GestureDetector(
                        onTap: () => setS(() => selectedColor = col.hex),
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: _parseTagHex(col.hex),
                            shape: BoxShape.circle,
                            border: isSelected
                                ? Border.all(color: tw.ink, width: 2.5)
                                : Border.all(color: Colors.transparent, width: 2.5),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dCtx).pop(),
              child: Text('Cancel', style: TextStyle(color: tw.slate500)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: tw.slate900),
              onPressed: () {
                final name = nameCtrl.text.trim();
                if (name.isNotEmpty) {
                  widget.state.addFileTag(name: name, color: selectedColor);
                  Navigator.of(dCtx).pop();
                }
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Tag color helpers ─────────────────────────────────────────────────────────

const List<({String hex, String label})> _kTagColorsSettings = [
  (hex: '#64748b', label: 'Slate'),
  (hex: '#ef4444', label: 'Red'),
  (hex: '#f97316', label: 'Orange'),
  (hex: '#eab308', label: 'Yellow'),
  (hex: '#22c55e', label: 'Green'),
  (hex: '#14b8a6', label: 'Teal'),
  (hex: '#3b82f6', label: 'Blue'),
  (hex: '#8b5cf6', label: 'Purple'),
  (hex: '#ec4899', label: 'Pink'),
  (hex: '#f43f5e', label: 'Rose'),
  (hex: '#10b981', label: 'Emerald'),
  (hex: '#f59e0b', label: 'Amber'),
];

Color _parseTagHex(String hex) {
  final h = hex.replaceFirst('#', '');
  return Color(int.parse(h.length == 6 ? 'FF$h' : h, radix: 16));
}

// ─── Tag settings row with inline color picker ─────────────────────────────────

class _TagSettingsRow extends StatefulWidget {
  final FileTag tag;
  final DatieveState state;
  final DatieveColors colors;

  const _TagSettingsRow({required this.tag, required this.state, required this.colors});

  @override
  State<_TagSettingsRow> createState() => _TagSettingsRowState();
}

class _TagSettingsRowState extends State<_TagSettingsRow> {
  bool _showPicker = false;

  @override
  Widget build(BuildContext context) {
    final tw = Tw(widget.colors);
    final tag = widget.tag;
    return Column(
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: null,
            hoverColor: tw.slate50,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: tw.line)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(tag.name, style: TextStyle(fontSize: 13, color: tw.ink)),
                      ],
                    ),
                  ),
                  Tooltip(
                    message: 'Change color',
                    child: GestureDetector(
                      onTap: () => setState(() => _showPicker = !_showPicker),
                      child: Container(
                        width: 22,
                        height: 22,
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          color: _parseTagHex(tag.color),
                          shape: BoxShape.circle,
                          border: Border.all(color: tw.slate200),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(LucideIcons.trash2, size: 14, color: tw.red500),
                    onPressed: () => widget.state.removeFileTag(tag.id),
                    tooltip: 'Remove tag',
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_showPicker)
          Container(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
            decoration: BoxDecoration(
              color: tw.slate50,
              border: Border(bottom: BorderSide(color: tw.line)),
            ),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _kTagColorsSettings.map((col) {
                final isSelected = tag.color == col.hex;
                return Tooltip(
                  message: col.label,
                  child: GestureDetector(
                    onTap: () {
                      widget.state.changeFileTagColor(tag.id, col.hex);
                      setState(() => _showPicker = false);
                    },
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: _parseTagHex(col.hex),
                        shape: BoxShape.circle,
                        border: isSelected
                            ? Border.all(color: tw.ink, width: 2.5)
                            : Border.all(color: Colors.transparent, width: 2.5),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
      ],
    );
  }
}