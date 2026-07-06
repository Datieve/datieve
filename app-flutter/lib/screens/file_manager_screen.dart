import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../src/rust/bridge.dart';
import '../state/datieve_state.dart';
import '../theme/css_tokens.dart';
import '../theme/datieve_theme.dart';
import '../models/local_tab.dart';
import '../utils/format_bytes.dart';

import '../widgets/file_compact_grid.dart';
import '../widgets/fm_drag_drop.dart';
import '../widgets/file_list_view.dart';
import '../models/bookmark.dart';
import '../models/fm_menu_state.dart';
import '../widgets/fm_admin_dashboard.dart';
import '../widgets/fm_command_palette.dart';
import '../widgets/fm_context_menus.dart';
import '../widgets/fm_info_pane.dart';
import '../widgets/fm_properties_dialog.dart';
import '../widgets/fm_rename_dialog.dart';
import '../widgets/fm_settings_panel.dart';
import '../widgets/fm_shortcuts_dialog.dart';
import '../widgets/fm_status_bar.dart';
import '../widgets/fm_filters_panel.dart';
import '../widgets/fm_open_with_dialog.dart';
import '../widgets/fm_folder_icon_picker.dart';
import '../widgets/ui/spinners.dart';
import '../utils/settings_helpers.dart';
import 'demo_screen.dart';
import 'discovery_screen.dart';
import 'login_screen.dart';
import 'setup_screen.dart';

/// File manager shell — layout matches App.tsx sidebar + toolbar + info pane.
class FileManagerScreen extends StatefulWidget {
  final DatieveState state;

  const FileManagerScreen({super.key, required this.state});

  @override
  State<FileManagerScreen> createState() => _FileManagerScreenState();
}

class _FileManagerScreenState extends State<FileManagerScreen> {
  final _focusNode = FocusNode();
  final _searchFocusNode = FocusNode();
  final _shortcutSearchFocusNode = FocusNode();
  final _scrollToIndex = ValueNotifier<int>(-1);
  final _gridCols = ValueNotifier<int>(4);
  int _navCursor = -1;
  bool _autoSelectFirst = false;
  String _lastNavPath = '';

  DatieveState get state => widget.state;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onStateChange);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    widget.state.removeListener(_onStateChange);
    _focusNode.dispose();
    _searchFocusNode.dispose();
    _shortcutSearchFocusNode.dispose();
    _scrollToIndex.dispose();
    _gridCols.dispose();
    super.dispose();
  }

  void _triggerAutoSelect() {
    _autoSelectFirst = true;
    _lastNavPath = state.fmMeta.currentPath;
  }

  void _onStateChange() {
    if (!mounted || !_autoSelectFirst) return;
    final s = widget.state;
    if (!s.fmLoading && s.visibleFmFiles.isNotEmpty) {
      _autoSelectFirst = false;
      _lastNavPath = '';
      _navCursor = 0;
      s.fmSelectedFile = s.visibleFmFiles.first;
      s.setSelectedPaths({s.visibleFmFiles.first.path});
    }
  }

  void _navigateSelection(LogicalKeyboardKey key, bool shift) {
    final files = state.visibleFmFiles;
    if (files.isEmpty) return;

    // Sync cursor with mouse-based selection.
    final sel = state.fmSelectedFile;
    final selIndex = sel != null ? files.indexWhere((f) => f.path == sel.path) : -1;
    if (selIndex >= 0) _navCursor = selIndex;
    if (_navCursor >= files.length) _navCursor = -1;

    int delta;
    if (key == LogicalKeyboardKey.arrowDown) {
      delta = state.isCompactView ? _estimatedGridCols() : 1;
    } else if (key == LogicalKeyboardKey.arrowUp) {
      delta = state.isCompactView ? -_estimatedGridCols() : -1;
    } else if (key == LogicalKeyboardKey.arrowRight) {
      delta = 1;
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      delta = -1;
    } else {
      return;
    }

    if (_navCursor < 0) {
      _navCursor = delta > 0 ? 0 : files.length - 1;
    } else {
      _navCursor = (_navCursor + delta).clamp(0, files.length - 1);
    }

    final target = files[_navCursor];
    if (!shift) {
      state.fmSelectedFile = target;
      state.setSelectedPaths({target.path});
    } else {
      state.setSelectedPaths({...state.fmSelectedPaths, target.path});
    }
    // Trigger auto-scroll in whichever list/grid is displayed.
    _scrollToIndex.value = _navCursor;
  }

  int _estimatedGridCols() => _gridCols.value;

  bool get _textEditorFocused {
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null || primary == _focusNode) return false;
    final context = primary.context;
    if (context == null) return false;
    // The focus node lives INSIDE EditableText (attached to the Focus widget
    // that EditableText creates internally). Walk UP to find the EditableText.
    if (context.widget is EditableText) return true;
    bool found = false;
    context.visitAncestorElements((element) {
      if (element.widget is EditableText) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  // ─── Shortcut map — one place, one key combo per command ─────────────────
  //
  // SingleActivator requires EXACT modifier state: specifying alt:true means
  // Alt must be pressed; not specifying alt (default false) means Alt must NOT
  // be pressed. So arrowLeft and alt+arrowLeft never conflict.
  static const Map<ShortcutActivator, Intent> _shortcutMap = {
    // History navigation
    SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): _BackIntent(),
    SingleActivator(LogicalKeyboardKey.arrowRight, alt: true): _ForwardIntent(),
    SingleActivator(LogicalKeyboardKey.arrowUp, alt: true): _UpDirIntent(),
    SingleActivator(LogicalKeyboardKey.backspace): _BackspaceNavIntent(),

    // App-level (always active)
    SingleActivator(LogicalKeyboardKey.f5): _RefreshIntent(),
    SingleActivator(LogicalKeyboardKey.escape): _EscapeIntent(),
    SingleActivator(LogicalKeyboardKey.keyF, control: true): _SearchFocusIntent(),
    SingleActivator(LogicalKeyboardKey.slash, control: true): _ShortcutsDialogIntent(),
    SingleActivator(LogicalKeyboardKey.slash): _SlashSearchIntent(),
    SingleActivator(LogicalKeyboardKey.keyP, control: true, shift: true): _CommandPaletteIntent(),
    SingleActivator(LogicalKeyboardKey.keyL, control: true): _PathBarFocusIntent(),

    // Zoom
    SingleActivator(LogicalKeyboardKey.equal, control: true): _ZoomInIntent(),
    SingleActivator(LogicalKeyboardKey.equal, control: true, shift: true): _ZoomInIntent(),
    SingleActivator(LogicalKeyboardKey.numpadAdd, control: true): _ZoomInIntent(),

    SingleActivator(LogicalKeyboardKey.minus, control: true): _ZoomOutIntent(),
    SingleActivator(LogicalKeyboardKey.numpadSubtract, control: true): _ZoomOutIntent(),
    SingleActivator(LogicalKeyboardKey.digit0, control: true): _ZoomResetIntent(),

    // Tab management
    SingleActivator(LogicalKeyboardKey.keyT, control: true): _NewTabIntent(),
    SingleActivator(LogicalKeyboardKey.keyW, control: true): _CloseTabIntent(),
    SingleActivator(LogicalKeyboardKey.keyK, control: true, shift: true): _DupTabIntent(),
    SingleActivator(LogicalKeyboardKey.keyT, control: true, shift: true): _ReopenTabIntent(),
    SingleActivator(LogicalKeyboardKey.tab, control: true): _NextTabIntent(),
    SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true): _PrevTabIntent(),

    // Edit / clipboard
    SingleActivator(LogicalKeyboardKey.keyZ, control: true): _UndoIntent(),
    SingleActivator(LogicalKeyboardKey.keyA, control: true): _SelectAllIntent(),
    SingleActivator(LogicalKeyboardKey.keyC, control: true): _CopyIntent(),
    SingleActivator(LogicalKeyboardKey.keyX, control: true): _CutIntent(),
    SingleActivator(LogicalKeyboardKey.keyV, control: true): _PasteIntent(),
    SingleActivator(LogicalKeyboardKey.keyH, control: true): _ToggleHiddenIntent(),

    // Arrow navigation (includeRepeats lets user hold key to scroll)
    SingleActivator(LogicalKeyboardKey.arrowDown, includeRepeats: true): _NavArrowIntent(LogicalKeyboardKey.arrowDown),
    SingleActivator(LogicalKeyboardKey.arrowDown, shift: true, includeRepeats: true): _NavArrowIntent(LogicalKeyboardKey.arrowDown, shift: true),
    SingleActivator(LogicalKeyboardKey.arrowUp, includeRepeats: true): _NavArrowIntent(LogicalKeyboardKey.arrowUp),
    SingleActivator(LogicalKeyboardKey.arrowUp, shift: true, includeRepeats: true): _NavArrowIntent(LogicalKeyboardKey.arrowUp, shift: true),
    SingleActivator(LogicalKeyboardKey.arrowLeft, includeRepeats: true): _NavArrowIntent(LogicalKeyboardKey.arrowLeft),
    SingleActivator(LogicalKeyboardKey.arrowRight, includeRepeats: true): _NavArrowIntent(LogicalKeyboardKey.arrowRight),
    SingleActivator(LogicalKeyboardKey.home): _HomeNavIntent(),
    SingleActivator(LogicalKeyboardKey.end): _EndNavIntent(),

    // File operations
    SingleActivator(LogicalKeyboardKey.delete): _DeleteIntent(),
    SingleActivator(LogicalKeyboardKey.delete, shift: true): _DeleteIntent(permanent: true),
    SingleActivator(LogicalKeyboardKey.enter): _OpenFileIntent(),
    SingleActivator(LogicalKeyboardKey.numpadEnter): _OpenFileIntent(),
    SingleActivator(LogicalKeyboardKey.f2): _RenameIntent(),
    SingleActivator(LogicalKeyboardKey.space): _PropertiesIntent(),
    SingleActivator(LogicalKeyboardKey.keyN, control: true, shift: true): _NewFolderIntent(),
    SingleActivator(LogicalKeyboardKey.keyN, control: true): _NewFileIntent(),
  };

  // ─── Action map — one implementation per intent ───────────────────────────
  //
  // "always"  → fires even when a text field is focused (app-level commands)
  // "fileOp"  → disabled when a text field is focused; key propagates to the
  //             field instead of being consumed (isEnabled returns false)
  late final Map<Type, Action<Intent>> _actionMap = _buildActionMap();

  Map<Type, Action<Intent>> _buildActionMap() {
    Action<T> always<T extends Intent>(Object? Function(T) fn) =>
        CallbackAction<T>(onInvoke: fn);

    Action<T> fileOp<T extends Intent>(Object? Function(T) fn) =>
        _TextGuardedAction<T>(onInvoke: fn, isText: () => _textEditorFocused);

    String _parentDir(String dir) {
      if (!dir.contains('/') || dir == '/') return '/';
      final p = dir.substring(0, dir.lastIndexOf('/'));
      return p.isEmpty ? '/' : p;
    }

    return {
      // ── Arrow navigation ─────────────────────────────────────────────────
      _NavArrowIntent: fileOp<_NavArrowIntent>(
        (i) { _navigateSelection(i.key, i.shift); return null; },
      ),
      _HomeNavIntent: fileOp<_HomeNavIntent>((_) {
        if (state.visibleFmFiles.isNotEmpty) {
          _navCursor = 0;
          state.fmSelectedFile = state.visibleFmFiles.first;
          state.setSelectedPaths({state.visibleFmFiles.first.path});
        }
        return null;
      }),
      _EndNavIntent: fileOp<_EndNavIntent>((_) {
        if (state.visibleFmFiles.isNotEmpty) {
          _navCursor = state.visibleFmFiles.length - 1;
          state.fmSelectedFile = state.visibleFmFiles.last;
          state.setSelectedPaths({state.visibleFmFiles.last.path});
        }
        return null;
      }),

      // ── History ──────────────────────────────────────────────────────────
      _BackIntent: fileOp<_BackIntent>((_) {
        if (state.viewMode == 'local' && state.fmMeta.canBack) {
          _triggerAutoSelect();
          state.fmBack();
        } else if (state.viewMode == 'nas' && state.nasBackStack.isNotEmpty) {
          _triggerAutoSelect();
          state.nasNavigateBack();
        }
        return null;
      }),
      _ForwardIntent: fileOp<_ForwardIntent>((_) {
        if (state.viewMode == 'local' && state.fmMeta.canForward) {
          _triggerAutoSelect();
          state.fmForward();
        } else if (state.viewMode == 'nas' && state.nasForwardStack.isNotEmpty) {
          _triggerAutoSelect();
          state.nasNavigateForward();
        }
        return null;
      }),
      _UpDirIntent: fileOp<_UpDirIntent>((_) {
        if (state.viewMode == 'local' && state.localCurrentDir.isNotEmpty) {
          _triggerAutoSelect();
          state.fmNavigateTo(_parentDir(state.localCurrentDir));
        } else if (state.viewMode == 'nas' && state.nasBackStack.isNotEmpty) {
          _triggerAutoSelect();
          state.nasNavigateBack();
        }
        return null;
      }),
      _BackspaceNavIntent: fileOp<_BackspaceNavIntent>((_) {
        if (state.viewMode == 'local' && state.localCurrentDir.isNotEmpty) {
          _triggerAutoSelect();
          state.fmNavigateTo(_parentDir(state.localCurrentDir));
        } else if (state.viewMode == 'nas' && state.nasBackStack.isNotEmpty) {
          _triggerAutoSelect();
          state.nasNavigateBack();
        }
        return null;
      }),

      // ── Escape ───────────────────────────────────────────────────────────
      _EscapeIntent: always<_EscapeIntent>((_) {
        if (state.fmShowDeleteConfirm)  { state.cancelDeleteConfirm();  return null; }
        if (state.fmShowPasteConflict)  { state.cancelPasteConflict();  return null; }
        if (state.fmShowExtWarn)        { state.cancelExtWarn();        return null; }
        if (state.fmShowCommandPalette) { state.closeCommandPalette();  return null; }
        if (state.fmShowShortcuts)      { state.closeShortcuts();       return null; }
        if (state.fmShowAddBookmark)    { state.closeAddBookmark();     return null; }
        if (state.fmShowSettings)       { state.closeFmSettings();      return null; }
        if (state.fmShowRename)         { state.closeRename();          return null; }
        if (state.fmPropertiesFile != null)  { state.closeProperties();       return null; }
        if (state.folderIconPicker != null)  { state.closeFolderIconPicker(); return null; }
        if (state.fmLocalCtxMenu != null || state.fmEmptyCtxMenu != null ||
            state.fmSidebarCtxMenu != null  || state.tabCtxMenu != null) {
          state.closeAllMenus();
          return null;
        }
        if (_textEditorFocused) { _focusNode.requestFocus(); return null; }
        state.clearSelection();
        return null;
      }),

      // ── Focus helpers ────────────────────────────────────────────────────
      _SearchFocusIntent: fileOp<_SearchFocusIntent>(
        (_) { _searchFocusNode.requestFocus(); return null; },
      ),
      _SlashSearchIntent: fileOp<_SlashSearchIntent>((_) {
        if (state.fmShowShortcuts) {
          _shortcutSearchFocusNode.requestFocus();
        } else {
          _searchFocusNode.requestFocus();
        }
        return null;
      }),
      _PathBarFocusIntent: fileOp<_PathBarFocusIntent>(
        (_) { state.requestPathEdit(); return null; },
      ),

      // ── Dialogs ──────────────────────────────────────────────────────────
      _ShortcutsDialogIntent: fileOp<_ShortcutsDialogIntent>((_) {
        if (state.fmShowShortcuts) {
          state.closeShortcuts();
        } else {
          state.openShortcuts();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _shortcutSearchFocusNode.requestFocus();
          });
        }
        return null;
      }),
      _CommandPaletteIntent: fileOp<_CommandPaletteIntent>(
        (_) { state.openCommandPalette(); return null; },
      ),

      // ── Zoom ─────────────────────────────────────────────────────────────
      _ZoomInIntent:    fileOp<_ZoomInIntent>((_)    { state.zoomIn();    return null; }),
      _ZoomOutIntent:   fileOp<_ZoomOutIntent>((_)   { state.zoomOut();   return null; }),
      _ZoomResetIntent: fileOp<_ZoomResetIntent>((_) { state.resetZoom(); return null; }),

      // ── Tabs ─────────────────────────────────────────────────────────────
      _NewTabIntent:    fileOp<_NewTabIntent>((_)    { state.newLocalTab(); return null; }),
      _CloseTabIntent:  fileOp<_CloseTabIntent>((_)  {
        if (state.localTabs.length > 1) state.closeLocalTab(state.activeLocalTabId);
        return null;
      }),
      _NextTabIntent:   fileOp<_NextTabIntent>((_)   { state.nextLocalTab();    return null; }),
      _PrevTabIntent:   fileOp<_PrevTabIntent>((_)   { state.prevLocalTab();    return null; }),
      _DupTabIntent:    fileOp<_DupTabIntent>((_)    { state.duplicateLocalTab(state.activeLocalTabId); return null; }),
      _ReopenTabIntent: fileOp<_ReopenTabIntent>((_) { state.reopenClosedLocalTab(); return null; }),

      // ── Undo ─────────────────────────────────────────────────────────────
      _UndoIntent: fileOp<_UndoIntent>((_) { state.undoLast(); return null; }),

      // ── Refresh ──────────────────────────────────────────────────────────
      _RefreshIntent: fileOp<_RefreshIntent>((_) { state.refreshFileManager(); return null; }),

      // ── File operations ──────────────────────────────────────────────────
      _SelectAllIntent: fileOp<_SelectAllIntent>((_) { state.selectAllFiles(); return null; }),
      _CopyIntent: fileOp<_CopyIntent>((_) { state.copySelected(); return null; }),
      _CutIntent:  fileOp<_CutIntent>((_)  { state.cutSelected();  return null; }),
      _PasteIntent: fileOp<_PasteIntent>((_) {
        if (state.viewMode == 'nas' && state.fmClipboard?.scope == 'nas') {
          state.nasPasteClipboard();
        } else {
          state.pasteClipboard();
        }
        return null;
      }),
      _DeleteIntent: fileOp<_DeleteIntent>((i) {
        if (state.viewMode == 'nas') {
          if (i.permanent) state.nasDeleteSelected(); else state.nasTrashSelected();
        } else if (i.permanent || state.isTrashView) {
          state.deleteSelectedPermanently();
        } else {
          state.trashSelected();
        }
        return null;
      }),
      _OpenFileIntent: fileOp<_OpenFileIntent>((_) {
        // Also advances the setup wizard while it is active.
        if (state.nasInlinePhase == 'setup' && !state.setupLoading) {
          if (state.setup.step >= 7) state.setupFinish(); else state.setupNext();
          return null;
        }
        if (state.fmSelectedFile != null) {
          if (state.fmSelectedFile!.isDir) _triggerAutoSelect();
          state.openFile(state.fmSelectedFile!);
        }
        return null;
      }),
      _RenameIntent: fileOp<_RenameIntent>((_) {
        if (state.fmSelectedPaths.length > 1) {
          state.startBulkRename();
        } else if (state.fmSelectedFile != null) {
          state.startRename(state.fmSelectedFile!);
        }
        return null;
      }),
      _PropertiesIntent: fileOp<_PropertiesIntent>((_) {
        if (state.fmSelectedFile != null) state.openProperties(state.fmSelectedFile!);
        return null;
      }),
      _ToggleHiddenIntent: fileOp<_ToggleHiddenIntent>((_) {
        if (state.viewMode == 'local') state.fmToggleHidden();
        return null;
      }),
      _NewFolderIntent: fileOp<_NewFolderIntent>((_) {
        if (state.viewMode == 'nas') state.nasCreateNewFolder(); else state.createNewFolder();
        return null;
      }),
      _NewFileIntent: fileOp<_NewFileIntent>((_) {
        if (state.viewMode == 'nas') state.nasCreateNewFile(); else state.createNewFile();
        return null;
      }),
    };
  }

  @override
  Widget build(BuildContext context) {
    final c = state.colors;
    final tw = Tw(c);
    final propFile = state.fmPropertiesFile;
    final folderIconPicker = state.folderIconPicker;

    return Actions(
      actions: _actionMap,
      child: Shortcuts(
        shortcuts: _shortcutMap,
        child: Focus(
          focusNode: _focusNode,
          autofocus: true,
          child: ColoredBox(
        color: tw.white,
        child: Stack(
          children: [
            Column(
              children: [
                _LocalTabBar(state: state),
                _TopHeader(state: state, browserFocus: _focusNode, searchFocus: _searchFocusNode),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Sidebar(state: state),
                      Expanded(
                        child: Listener(
                          // Clicking anywhere in the file area returns keyboard focus
                          // to the browser so shortcuts work after using the search bar.
                          onPointerDown: (_) => _focusNode.requestFocus(),
                          behavior: HitTestBehavior.translucent,
                          child: _ContentColumn(state: state, scrollToIndex: _scrollToIndex, gridCols: _gridCols),
                        ),
                      ),
                      if (state.settings.showInfoPane) FmInfoPane(state: state),
                    ],
                  ),
                ),
                FmStatusBar(state: state),
              ],
            ),

            if (state.fmShowSettings) FmSettingsPanel(state: state),
            if (state.fmShowCommandPalette)
              FmCommandPalette(
                colors: c,
                commands: state.buildPaletteCommands(),
                onClose: state.closeCommandPalette,
              ),
            if (state.fmShowShortcuts)
              FmShortcutsDialog(
                colors: c,
                onClose: state.closeShortcuts,
                searchFocusNode: _shortcutSearchFocusNode,
              ),
            if (state.fmShowAddBookmark) _AddBookmarkDialog(state: state),
            if (state.fmShowRename) FmRenameDialog(state: state),
            if (propFile != null)
              FmPropertiesDialog(state: state, file: propFile),
            if (state.fmShowDeleteConfirm) _DeleteConfirmDialog(state: state),
            if (state.fmShowPasteConflict) _PasteConflictDialog(state: state),
            if (state.fmShowExtWarn) _ExtWarnDialog(state: state),
            Positioned.fill(child: FmContextMenus(state: state)),
            if (state.fmShowDeviceManager) _DeviceManagerDialog(state: state),
            if (state.fmShowAdmin)
              Positioned.fill(child: FmAdminDashboard(state: state)),
            if (state.openWithDialog != null)
              FmOpenWithDialog(state: state),
            if (folderIconPicker != null)
              FmFolderIconPicker(
                state: state,
                path: folderIconPicker.path,
                name: folderIconPicker.name,
              ),
          ],
        ),
        ),
      ),
    ),
  );
  }
}

// ─── Delete-permanently confirmation ─────────────────────────────────────────

class _DeleteConfirmDialog extends StatefulWidget {
  final DatieveState state;
  const _DeleteConfirmDialog({required this.state});
  @override
  State<_DeleteConfirmDialog> createState() => _DeleteConfirmDialogState();
}

class _DeleteConfirmDialogState extends State<_DeleteConfirmDialog> {
  bool _dontAskAgain = false;

  void _confirm() {
    if (_dontAskAgain) {
      widget.state.updateSettings(
        widget.state.settings.copyWith(confirmPermanentDelete: false),
      );
    }
    widget.state.confirmDeletePermanently();
  }

  @override
  Widget build(BuildContext context) {
    final tw = Tw(widget.state.colors);
    final count = widget.state.fmDeleteConfirmPaths.length;
    final label = count == 1 ? '1 item' : '$count items';
    return _ModalOverlay(
      onDismiss: widget.state.cancelDeleteConfirm,
      child: _DeleteCard(
        colors: widget.state.colors,
        tw: tw,
        label: label,
        dontAskAgain: _dontAskAgain,
        onDontAskChanged: (v) => setState(() => _dontAskAgain = v),
        onCancel: widget.state.cancelDeleteConfirm,
        onConfirm: _confirm,
      ),
    );
  }
}

class _DeleteCard extends StatelessWidget {
  final DatieveColors colors;
  final Tw tw;
  final String label;
  final bool dontAskAgain;
  final ValueChanged<bool> onDontAskChanged;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  const _DeleteCard({
    required this.colors,
    required this.tw,
    required this.label,
    required this.dontAskAgain,
    required this.onDontAskChanged,
    required this.onCancel,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.numpadEnter) {
            onConfirm();
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.escape) {
            onCancel();
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: Container(
        width: 360,
        decoration: BoxDecoration(
          color: tw.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: tw.slate100),
          boxShadow: [
            BoxShadow(
              color: colors.ink.withValues(alpha: 0.14),
              blurRadius: 32,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(Icons.delete_forever_rounded, size: 18, color: tw.red600),
                const SizedBox(width: 10),
                Text('Delete Permanently', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: tw.ink)),
              ]),
              const SizedBox(height: 12),
              Text('Delete $label permanently? This cannot be undone.', style: TextStyle(fontSize: 13, color: tw.slate600)),
              const SizedBox(height: 16),
              GestureDetector(
                onTap: () => onDontAskChanged(!dontAskAgain),
                child: Row(children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: Checkbox(
                      value: dontAskAgain,
                      onChanged: (v) => onDontAskChanged(v ?? false),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      side: BorderSide(color: tw.slate300),
                      activeColor: tw.slate700,
                      checkColor: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text("Don't ask again", style: TextStyle(fontSize: 12, color: tw.slate500)),
                ]),
              ),
              const SizedBox(height: 20),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(
                  onPressed: onCancel,
                  child: Text('Cancel', style: TextStyle(fontSize: 13, color: tw.slate500)),
                ),
                const SizedBox(width: 8),
                _PrimaryButton(
                  label: 'Delete',
                  danger: true,
                  colors: colors,
                  onTap: onConfirm,
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Paste-conflict resolution ────────────────────────────────────────────────

class _PasteConflictDialog extends StatelessWidget {
  final DatieveState state;
  const _PasteConflictDialog({required this.state});

  @override
  Widget build(BuildContext context) {
    final tw = Tw(state.colors);
    final names = state.fmPasteConflictNames;
    final preview = names.take(3).join(', ');
    final extra = names.length > 3 ? ' and ${names.length - 3} more' : '';
    return _ModalOverlay(
      onDismiss: state.cancelPasteConflict,
      child: Container(
        width: 380,
        decoration: BoxDecoration(
          color: tw.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: tw.slate100),
          boxShadow: [
            BoxShadow(
              color: state.colors.ink.withValues(alpha: 0.14),
              blurRadius: 32,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(Icons.copy_all_rounded, size: 18, color: state.colors.brand),
                const SizedBox(width: 10),
                Text('Name Conflict', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: tw.ink)),
              ]),
              const SizedBox(height: 12),
              Text(
                '$preview$extra already exist in this folder.',
                style: TextStyle(fontSize: 13, color: tw.slate600),
              ),
              const SizedBox(height: 20),
              _ConflictButton(
                tw: tw,
                label: 'Keep Both',
                sublabel: 'Rename new file(s) to avoid overwriting',
                onTap: () => state.confirmPasteWithCollision('rename'),
              ),
              const SizedBox(height: 8),
              _ConflictButton(
                tw: tw,
                label: 'Replace',
                sublabel: 'Overwrite existing file(s)',
                onTap: () => state.confirmPasteWithCollision('replace'),
              ),
              const SizedBox(height: 8),
              _ConflictButton(
                tw: tw,
                label: 'Skip',
                sublabel: 'Leave existing file(s) unchanged',
                onTap: () => state.confirmPasteWithCollision('skip'),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: state.cancelPasteConflict,
                  child: Text('Cancel', style: TextStyle(fontSize: 13, color: tw.slate500)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConflictButton extends StatefulWidget {
  final Tw tw;
  final String label;
  final String sublabel;
  final VoidCallback onTap;
  const _ConflictButton({required this.tw, required this.label, required this.sublabel, required this.onTap});
  @override
  State<_ConflictButton> createState() => _ConflictButtonState();
}
class _ConflictButtonState extends State<_ConflictButton> {
  bool _hovered = false;
  @override
  Widget build(BuildContext context) {
    final tw = widget.tw;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: _hovered ? tw.slate50 : tw.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: tw.slate200),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: tw.ink)),
            const SizedBox(height: 2),
            Text(widget.sublabel, style: TextStyle(fontSize: 11, color: tw.slate500)),
          ]),
        ),
      ),
    );
  }
}

// ─── Extension-change warning ─────────────────────────────────────────────────

class _ExtWarnDialog extends StatelessWidget {
  final DatieveState state;
  const _ExtWarnDialog({required this.state});

  @override
  Widget build(BuildContext context) {
    final tw = Tw(state.colors);
    final pending = state.fmExtWarnPendingName;
    final oldExt = _extOf(state.fmRenamePath);
    final newExt = _extOf(pending);
    return _ModalOverlay(
      onDismiss: state.cancelExtWarn,
      child: _ConfirmCard(
        colors: state.colors,
        icon: Icons.warning_amber_rounded,
        iconColor: const Color(0xFFD97706),
        title: 'Change File Extension?',
        body: 'You\'re changing the extension from .$oldExt to .$newExt. '
            'The file may become unusable. Continue?',
        cancelLabel: 'Cancel',
        confirmLabel: 'Change',
        confirmDanger: false,
        onCancel: state.cancelExtWarn,
        onConfirm: state.confirmExtWarn,
      ),
    );
  }

  static String _extOf(String path) {
    final name = path.split('/').last;
    final dot = name.lastIndexOf('.');
    if (dot <= 0) return '';
    return name.substring(dot + 1);
  }
}

// ─── Shared primitives ────────────────────────────────────────────────────────

class _ModalOverlay extends StatelessWidget {
  final Widget child;
  final VoidCallback onDismiss;
  const _ModalOverlay({required this.child, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onDismiss,
      child: ColoredBox(
        color: const Color(0x55000000),
        child: Center(
          child: GestureDetector(onTap: () {}, child: child),
        ),
      ),
    );
  }
}

class _ConfirmCard extends StatelessWidget {
  final DatieveColors colors;
  final IconData icon;
  final Color iconColor;
  final String title;
  final String body;
  final String cancelLabel;
  final String confirmLabel;
  final bool confirmDanger;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  const _ConfirmCard({
    required this.colors,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.body,
    required this.cancelLabel,
    required this.confirmLabel,
    required this.confirmDanger,
    required this.onCancel,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    final tw = Tw(colors);
    return Container(
      width: 360,
      decoration: BoxDecoration(
        color: tw.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: tw.slate100),
        boxShadow: [
          BoxShadow(
            color: colors.ink.withValues(alpha: 0.14),
            blurRadius: 32,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, size: 18, color: iconColor),
              const SizedBox(width: 10),
              Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: tw.ink)),
            ]),
            const SizedBox(height: 12),
            Text(body, style: TextStyle(fontSize: 13, color: tw.slate600)),
            const SizedBox(height: 24),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(
                onPressed: onCancel,
                child: Text(cancelLabel, style: TextStyle(fontSize: 13, color: tw.slate500)),
              ),
              const SizedBox(width: 8),
              _PrimaryButton(
                label: confirmLabel,
                danger: confirmDanger,
                colors: colors,
                onTap: onConfirm,
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

class _PrimaryButton extends StatefulWidget {
  final String label;
  final bool danger;
  final DatieveColors colors;
  final VoidCallback onTap;
  const _PrimaryButton({required this.label, required this.danger, required this.colors, required this.onTap});
  @override
  State<_PrimaryButton> createState() => _PrimaryButtonState();
}
class _PrimaryButtonState extends State<_PrimaryButton> {
  bool _hovered = false;
  @override
  Widget build(BuildContext context) {
    final tw = Tw(widget.colors);
    final bg = widget.danger ? tw.red600 : widget.colors.brand;
    final bgHover = widget.danger ? tw.red700 : widget.colors.brand;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: _hovered ? bgHover : bg,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            widget.label,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

// ─── Add-bookmark dialog ──────────────────────────────────────────────────────

class _AddBookmarkDialog extends StatefulWidget {
  final DatieveState state;

  const _AddBookmarkDialog({required this.state});

  @override
  State<_AddBookmarkDialog> createState() => _AddBookmarkDialogState();
}

class _AddBookmarkDialogState extends State<_AddBookmarkDialog> {
  late final TextEditingController _labelController;
  late final TextEditingController _pathController;

  @override
  void initState() {
    super.initState();
    _labelController = TextEditingController(text: widget.state.bookmarkDraftLabel);
    _pathController = TextEditingController(text: widget.state.bookmarkDraftPath);
  }

  @override
  void dispose() {
    _labelController.dispose();
    _pathController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final tw = Tw(state.colors);
    return GestureDetector(
      onTap: state.closeAddBookmark,
      child: ColoredBox(
        color: const Color(0x660F172A),
        child: Center(
          child: GestureDetector(
            onTap: () {},
            child: Container(
              width: 360,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: tw.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: tw.slate100),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Add Bookmark',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: tw.ink,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _labelController,
                    onChanged: state.setBookmarkDraftLabel,
                    decoration: InputDecoration(
                      labelText: 'Label',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _pathController,
                    onChanged: state.setBookmarkDraftPath,
                    decoration: InputDecoration(
                      labelText: 'Path',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: state.closeAddBookmark,
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: state.addBookmark,
                        child: const Text('Add'),
                      ),
                    ],
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

class _TopHeader extends StatelessWidget {
  final DatieveState state;
  final FocusNode browserFocus;
  final FocusNode? searchFocus;

  const _TopHeader({required this.state, required this.browserFocus, this.searchFocus});

  @override
  Widget build(BuildContext context) {
    final c = state.colors;
    final tw = Tw(c);
    final session = state.session;
    final isAdmin = session?.isAdmin ?? false;
    final displayName = session?.username ?? 'User';
    final meta = state.fmMeta;
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: tw.white,
        border: Border(bottom: BorderSide(color: tw.slate100)),
      ),
      child: Row(
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 20,
                height: 20,
                margin: const EdgeInsets.only(right: 4),
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
              if (state.viewMode == 'local') ...[
                _ToolbarIcon(
                  icon: LucideIcons.arrowLeft,
                  enabled: meta.canBack,
                  colors: c,
                  onPressed: state.fmBack,
                ),
                _ToolbarIcon(
                  icon: LucideIcons.arrowRight,
                  enabled: meta.canForward,
                  colors: c,
                  onPressed: state.fmForward,
                ),
                _ToolbarIcon(
                  icon: LucideIcons.house,
                  enabled: true,
                  colors: c,
                  onPressed: state.fmHome,
                ),
                _ToolbarIcon(
                  icon: LucideIcons.refreshCw,
                  enabled: true,
                  colors: c,
                  onPressed: () => state.refreshFileManager(),
                ),
              ] else if (state.viewMode == 'nas') ...[
                _ToolbarIcon(
                  icon: LucideIcons.arrowLeft,
                  enabled: state.nasBackStack.isNotEmpty,
                  colors: c,
                  onPressed: state.nasNavigateBack,
                ),
                _ToolbarIcon(
                  icon: LucideIcons.arrowRight,
                  enabled: state.nasForwardStack.isNotEmpty,
                  colors: c,
                  onPressed: state.nasNavigateForward,
                ),
                _ToolbarIcon(
                  icon: LucideIcons.house,
                  enabled: state.nasBackStack.isNotEmpty,
                  colors: c,
                  onPressed: state.nasNavigateHome,
                ),
                _ToolbarIcon(
                  icon: LucideIcons.refreshCw,
                  enabled: true,
                  colors: c,
                  onPressed: () => state.refreshFileManager(),
                ),
              ] else
                _ToolbarIcon(
                  icon: LucideIcons.refreshCw,
                  enabled: true,
                  colors: c,
                  onPressed: () => state.refreshFileManager(),
                ),
            ],
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _BreadcrumbBar(state: state),
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: SizedBox(
              height: 30,
              child: TextField(
                focusNode: searchFocus,
                onChanged: state.viewMode == 'local'
                    ? state.setLocalSearchQuery
                    : state.setFmSearchQuery,
                onSubmitted: (value) {
                  if (state.viewMode == 'local') {
                    state.doRecursiveSearch();
                  } else {
                    // TextField is uncontrolled — fmSearchQuery may have been
                    // cleared by navigation while the field retained old text.
                    // Always sync from the actual field value before searching.
                    if (value.trim().isNotEmpty) {
                      state.setFmSearchQuery(value.trim());
                    }
                    state.submitNasSearch();
                  }
                  browserFocus.requestFocus();
                },
                style: TextStyle(fontSize: 12, color: tw.ink),
                decoration: InputDecoration(
                  hintText: 'Search...',
                  prefixIcon: Icon(LucideIcons.search, size: 12, color: tw.slate400),
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                  filled: true,
                  fillColor: tw.slate50,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6.0),
                    borderSide: BorderSide(color: tw.slate200),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6.0),
                    borderSide: BorderSide(color: tw.slate200),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6.0),
                    borderSide: BorderSide(color: tw.slate400),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          if (state.settings.toolbarShowFilters &&
              (state.viewMode == 'local' || state.viewMode == 'nas')) ...[
            IconButton(
              icon: Icon(LucideIcons.slidersHorizontal, size: 12),
              style: IconButton.styleFrom(
                backgroundColor: state.fmShowFilters ? tw.slate900 : tw.white,
                foregroundColor: state.fmShowFilters ? tw.white : tw.slate400,
                side: BorderSide(
                  color: state.fmShowFilters ? tw.slate900 : tw.slate200,
                ),
                minimumSize: const Size(28, 28),
                padding: EdgeInsets.zero,
              ),
              onPressed: state.toggleFmFilters,
              tooltip: 'Filters',
            ),
            const SizedBox(width: 6),
          ],
          if (state.viewMode == 'local' || state.viewMode == 'nas') ...[
            _ToolbarIcon(
              icon: state.isCompactView ? LucideIcons.list : LucideIcons.layoutGrid,
              enabled: true,
              colors: c,
              onPressed: state.toggleViewStyle,
            ),
            const SizedBox(width: 4),
            if (state.viewMode == 'local') ...[
              _ToolbarIcon(
                icon: state.fmMeta.showHidden ? LucideIcons.eye : LucideIcons.eyeOff,
                enabled: true,
                colors: c,
                onPressed: state.fmToggleHidden,
              ),
            ],
            const SizedBox(width: 6),
          ],
          if (state.isTrashView) ...[
            TextButton.icon(
              onPressed: state.emptyTrash,
              icon: Icon(LucideIcons.trash2, size: 12, color: tw.red600),
              label: Text(
                'Empty Trash',
                style: TextStyle(fontSize: 11, color: tw.red600),
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            const SizedBox(width: 8),
            Text('Auto-delete:', style: TextStyle(fontSize: 11, color: tw.slate400)),
            const SizedBox(width: 4),
            DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                isDense: true,
                itemHeight: 32,
                value: state.trashSettings.autoDeleteDays,
                style: TextStyle(fontSize: 11, color: tw.slate600),
                items: const [
                  DropdownMenuItem(value: 0, child: Text('Off', style: TextStyle(fontSize: 11))),
                  DropdownMenuItem(value: 7, child: Text('7d', style: TextStyle(fontSize: 11))),
                  DropdownMenuItem(value: 30, child: Text('30d', style: TextStyle(fontSize: 11))),
                  DropdownMenuItem(value: 60, child: Text('60d', style: TextStyle(fontSize: 11))),
                  DropdownMenuItem(value: 90, child: Text('90d', style: TextStyle(fontSize: 11))),
                ],
                onChanged: (v) {
                  if (v != null) state.setTrashAutoDeleteDays(v);
                },
              ),
            ),
            if (state.fmSelectedPaths.isNotEmpty) ...[
              const SizedBox(width: 8),
              TextButton(
                onPressed: state.restoreFromTrash,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  'Restore',
                  style: TextStyle(fontSize: 11, color: tw.slate600),
                ),
              ),
            ],
            const SizedBox(width: 8),
          ],
          if (state.viewMode == 'nas') ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: state.syncing ? const Color(0xFFFBBF24) : tw.green600,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 80),
              child: Text(
                displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: tw.slate400),
              ),
            ),
            if (isAdmin) ...[
              Text(' · ', style: TextStyle(fontSize: 11, color: tw.slate300)),
              TextButton(
                onPressed: state.openFmAdmin,
                style: TextButton.styleFrom(
                  foregroundColor: tw.slate400,
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('Admin', style: TextStyle(fontSize: 11)),
              ),
            ],
            TextButton(
              onPressed: state.softLogout,
              style: TextButton.styleFrom(
                foregroundColor: tw.slate400,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.logOut, size: 13),
                  const SizedBox(width: 4),
                  const Text('Logout', style: TextStyle(fontSize: 11)),
                ],
              ),
            ),
          ],
          IconButton(
            icon: Icon(LucideIcons.settings, size: 14, color: tw.slate400),
            onPressed: state.openFmSettings,
            padding: const EdgeInsets.all(6),
            constraints: const BoxConstraints(),
            tooltip: 'Settings',
          ),
        ],
      ),
    );
  }
}



class _BreadcrumbBar extends StatefulWidget {
  final DatieveState state;

  const _BreadcrumbBar({required this.state});

  @override
  State<_BreadcrumbBar> createState() => _BreadcrumbBarState();
}

class _BreadcrumbBarState extends State<_BreadcrumbBar> {
  bool _isEditing = false;
  bool _homeExpanded = false;
  late final TextEditingController _controller = TextEditingController();
  late final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller.text = widget.state.fmMeta.currentPath;
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) {
        setState(() => _isEditing = false);
      }
    });
    widget.state.addListener(_onStateChange);
  }

  void _onStateChange() {
    if (!mounted) return;
    if (widget.state.fmRequestPathEdit && !_isEditing) {
      widget.state.clearPathEditRequest();
      _controller.text = widget.state.fmMeta.currentPath;
      setState(() => _isEditing = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  @override
  void didUpdateWidget(_BreadcrumbBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.state.fmMeta.currentPath != oldWidget.state.fmMeta.currentPath) {
      _controller.text = widget.state.fmMeta.currentPath;
      _homeExpanded = false;
    }
  }

  @override
  void dispose() {
    widget.state.removeListener(_onStateChange);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _showSiblingMenu(BuildContext context, String parentPath, Offset tapPosition) async {
    final parentDir = Directory(parentPath);
    if (!parentDir.existsSync()) return;

    final tw = Tw(widget.state.colors);

    try {
      final entities = await parentDir.list().toList();
      if (!mounted) return;
      final dirs = entities
          .where((entity) => entity is Directory && !entity.path.split('/').last.startsWith('.'))
          .map((entity) => entity.path)
          .toList();
      dirs.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

      if (dirs.isEmpty) return;

      final RenderBox overlay = Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
      final RelativeRect position = RelativeRect.fromRect(
        Rect.fromLTWH(tapPosition.dx, tapPosition.dy, 0, 0),
        Offset.zero & overlay.size,
      );

      final selected = await showMenu<String>(
        context: context,
        position: position,
        color: tw.slate50,
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        items: dirs.map((dirPath) {
          final name = dirPath.split('/').last;
          return PopupMenuItem<String>(
            value: dirPath,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.folder, size: 14, color: tw.slate500),
                const SizedBox(width: 8),
                Text(name, style: TextStyle(fontSize: 12, color: tw.ink)),
              ],
            ),
          );
        }).toList(),
      );

      if (selected != null) {
        widget.state.fmNavigateTo(selected);
      }
    } catch (e) {
      // ignore
    }
  }

  @override
  Widget build(BuildContext context) {
    final tw = Tw(widget.state.colors);
    final path = widget.state.fmMeta.currentPath;

    if (widget.state.viewMode == 'nas') {
      if (_isEditing) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 480,
              height: 28,
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                style: TextStyle(fontSize: 12, color: tw.ink),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  filled: true,
                  fillColor: tw.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(color: tw.slate200),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(color: tw.slate400),
                  ),
                ),
                onSubmitted: (value) {
                  final target = value.trim();
                  if (target.isNotEmpty) {
                    widget.state.fmNavigateTo(target);
                  }
                  setState(() => _isEditing = false);
                },
              ),
            ),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _isEditing = false),
                child: const SizedBox(height: 32),
              ),
            ),
          ],
        );
      }

      final agentName = widget.state.agent?.hostname ?? 'NAS';
      final backStack = widget.state.nasBackStack;
      final currentName = widget.state.nasCurrentName.isEmpty ? agentName : widget.state.nasCurrentName;
      // Build breadcrumb: all back stack entries + current
      final nasCrumbs = <({String label, bool isRoot, int stackIndex})>[
        ...backStack.asMap().entries.map((e) => (
          label: e.value.name.isEmpty ? agentName : e.value.name,
          isRoot: e.key == 0 && e.value.id == null,
          stackIndex: e.key,
        )),
        (label: currentName, isRoot: backStack.isEmpty, stackIndex: backStack.length),
      ];

      return Container(
        decoration: BoxDecoration(
          color: tw.slate100,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: tw.slate200),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: SizedBox(
          height: 32,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < nasCrumbs.length; i++) ...[
                if (i > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Icon(LucideIcons.chevronRight, size: 11, color: tw.slate300),
                  ),
                _Crumb(
                  label: nasCrumbs[i].label,
                  active: i == nasCrumbs.length - 1,
                  icon: i == 0 ? LucideIcons.network : null,
                  colors: widget.state.colors,
                  onTap: i == nasCrumbs.length - 1
                      ? null
                      : () => widget.state.nasNavigateToBreadcrumb(nasCrumbs[i].stackIndex),
                ),
              ],
            ],
          ),
        ),
      );
    }

    final homePlace = widget.state.places.firstWhere(
      (p) => p.label == 'Home',
      orElse: () => PlaceDto(label: 'Home', path: Platform.environment['HOME'] ?? ''),
    );
    final homePath = homePlace.path.isNotEmpty ? homePlace.path : (Platform.environment['HOME'] ?? '');

    List<({String label, String path})> crumbs = [];
    if (widget.state.viewMode == 'local') {
      if (!_homeExpanded && path.startsWith(homePath)) {
        crumbs.add((label: 'Home', path: homePath));
        final relative = path.substring(homePath.length);
        final segments = relative.split('/').where((s) => s.isNotEmpty).toList();
        var acc = homePath;
        for (final seg in segments) {
          acc = acc == '/' ? '/$seg' : '$acc/$seg';
          crumbs.add((label: seg, path: acc));
        }
      } else {
        crumbs.add((label: 'System', path: '/'));
        final segments = path.split('/').where((s) => s.isNotEmpty).toList();
        var acc = '';
        for (final seg in segments) {
          acc += '/$seg';
          crumbs.add((label: seg, path: acc));
        }
      }
    }

    if (crumbs.isEmpty) {
      return const SizedBox.shrink();
    }

    if (_isEditing) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 480,
            height: 28,
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              style: TextStyle(fontSize: 12, color: tw.ink),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                filled: true,
                fillColor: tw.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide(color: tw.slate200),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide(color: tw.slate400),
                ),
              ),
              onSubmitted: (value) {
                final target = value.trim();
                if (target.isNotEmpty) {
                  widget.state.fmNavigateTo(target);
                }
                setState(() => _isEditing = false);
              },
            ),
          ),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _isEditing = false),
              child: const SizedBox(height: 32),
            ),
          ),
        ],
      );
    }

    final List<Widget> crumbWidgets = [];
    if (crumbs.length <= 5) {
      for (var i = 0; i < crumbs.length; i++) {
        if (i > 0) {
          crumbWidgets.add(
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (details) {
                _showSiblingMenu(context, crumbs[i - 1].path, details.globalPosition);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: Icon(LucideIcons.chevronRight, size: 11, color: tw.slate300),
              ),
            ),
          );
        }

        final idx = i;
        final isActive = i == crumbs.length - 1;
        final isHome = crumbs[i].label == 'Home';
        // Active Home crumb: clicking toggles path expansion temporarily.
        // Non-active Home crumb: clicking navigates to home (not expands).
        // All other crumbs: navigate normally.
        VoidCallback? tapHandler;
        if (isActive && isHome) {
          tapHandler = () => setState(() => _homeExpanded = !_homeExpanded);
        } else if (!isActive) {
          tapHandler = () {
            widget.state.fmNavigateTo(crumbs[idx].path);
          };
        }
        crumbWidgets.add(
          SpringLoadedDragTarget(
            state: widget.state,
            dropPath: crumbs[i].path,
            enabled: widget.state.viewMode == 'local' && !isActive,
            onHoverOpen: () => widget.state.fmNavigateTo(crumbs[idx].path),
            child: _Crumb(
              label: crumbs[i].label,
              active: isActive,
              colors: widget.state.colors,
              icon: isHome
                  ? LucideIcons.home
                  : crumbs[i].label == 'System'
                      ? LucideIcons.hardDrive
                      : null,
              onTap: tapHandler,
            ),
          ),
        );
      }
    } else {
      crumbWidgets.add(
        SpringLoadedDragTarget(
          state: widget.state,
          dropPath: crumbs[0].path,
          enabled: widget.state.viewMode == 'local',
          onHoverOpen: () => widget.state.fmNavigateTo(crumbs[0].path),
          child: _Crumb(
            label: crumbs[0].label,
            active: false,
            colors: widget.state.colors,
            icon: crumbs[0].label == 'Home'
                ? LucideIcons.home
                : crumbs[0].label == 'System'
                    ? LucideIcons.hardDrive
                    : null,
            onTap: () => widget.state.fmNavigateTo(crumbs[0].path),
          ),
        ),
      );

      crumbWidgets.add(
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) {
            _showSiblingMenu(context, crumbs[0].path, details.globalPosition);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            child: Icon(LucideIcons.chevronRight, size: 11, color: tw.slate300),
          ),
        ),
      );

      final intermediate = crumbs.sublist(1, crumbs.length - 3);
      crumbWidgets.add(
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) async {
            final RenderBox overlay = Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
            final RelativeRect position = RelativeRect.fromRect(
              Rect.fromLTWH(details.globalPosition.dx, details.globalPosition.dy, 0, 0),
              Offset.zero & overlay.size,
            );
            final selected = await showMenu<String>(
              context: context,
              position: position,
              color: tw.slate50,
              elevation: 4,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              items: intermediate.map((crumb) {
                return PopupMenuItem<String>(
                  value: crumb.path,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(LucideIcons.folder, size: 14, color: tw.slate500),
                      const SizedBox(width: 8),
                      Text(crumb.label, style: TextStyle(fontSize: 12, color: tw.ink)),
                    ],
                  ),
                );
              }).toList(),
            );
            if (selected != null) {
              widget.state.fmNavigateTo(selected);
            }
          },
          child: _Crumb(
            label: '...',
            active: false,
            colors: widget.state.colors,
            onTap: () {},
          ),
        ),
      );

      crumbWidgets.add(
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) {
            _showSiblingMenu(context, crumbs[crumbs.length - 4].path, details.globalPosition);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            child: Icon(LucideIcons.chevronRight, size: 11, color: tw.slate300),
          ),
        ),
      );

      for (var i = crumbs.length - 3; i < crumbs.length; i++) {
        if (i > crumbs.length - 3) {
          crumbWidgets.add(
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (details) {
                _showSiblingMenu(context, crumbs[i - 1].path, details.globalPosition);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: Icon(LucideIcons.chevronRight, size: 11, color: tw.slate300),
              ),
            ),
          );
        }

        final idx = i;
        final isActive = i == crumbs.length - 1;
        crumbWidgets.add(
          SpringLoadedDragTarget(
            state: widget.state,
            dropPath: crumbs[i].path,
            enabled: widget.state.viewMode == 'local' && !isActive,
            onHoverOpen: () => widget.state.fmNavigateTo(crumbs[idx].path),
            child: _Crumb(
              label: crumbs[i].label,
              active: isActive,
              colors: widget.state.colors,
              onTap: isActive ? null : () => widget.state.fmNavigateTo(crumbs[idx].path),
            ),
          ),
        );
      }
    }

    return Row(
      mainAxisSize: MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        TapRegion(
          onTapOutside: (_) {
            if (_homeExpanded) setState(() => _homeExpanded = false);
          },
          child: Container(
            decoration: BoxDecoration(
              color: tw.slate100,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: tw.slate200),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            height: 32,
            alignment: Alignment.center,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: crumbWidgets,
              ),
            ),
          ),
        ),
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              setState(() {
                _isEditing = true;
                _controller.text = widget.state.fmMeta.currentPath;
                _focusNode.requestFocus();
              });
            },
            child: const SizedBox(height: 32),
          ),
        ),
      ],
    );
  }
}

class _Crumb extends StatelessWidget {
  final String label;
  final bool active;
  final IconData? icon;
  final DatieveColors colors;
  final VoidCallback? onTap;

  const _Crumb({
    required this.label,
    required this.active,
    required this.colors,
    this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final tw = Tw(colors);
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        // White overlay works in both themes: subtle in light, clearly raised in dark.
        backgroundColor: active ? Colors.white.withValues(alpha: 0.22) : Colors.transparent,
        foregroundColor: active ? tw.ink : tw.slate500,
        disabledForegroundColor: active ? tw.ink : tw.slate400,
        disabledBackgroundColor: active ? Colors.white.withValues(alpha: 0.22) : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: active
              ? BorderSide(color: Colors.white.withValues(alpha: 0.14))
              : BorderSide.none,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11),
            const SizedBox(width: 4),
          ],
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  final DatieveState state;

  const _Sidebar({required this.state});

  @override
  Widget build(BuildContext context) {
    final c = state.colors;
    final tw = Tw(c);
    final width = state.settings.sidebarWidth.toDouble().clamp(160.0, 360.0);
    final places = state.places;
    // Find the most-specific mount that contains the current path, so the correct
    // device is highlighted even when breadcrumbs start with "System".
    final _currentPath = state.fmMeta.currentPath;
    String? activeMountPath;
    if (state.viewMode == 'local' && _currentPath.isNotEmpty) {
      for (final m in state.mounts) {
        final mp = m.path;
        // Windows drive roots (e.g. "C:\") already end with a separator, so
        // startsWith(mp) is sufficient; Linux/macOS paths need the "/" appended.
        final endsWithSep = mp.endsWith('/') || mp.endsWith('\\');
        final matches = mp == '/'
            ? _currentPath.startsWith('/')
            : _currentPath == mp ||
              _currentPath.startsWith(endsWithSep ? mp : '$mp/');
        if (matches && (activeMountPath == null || mp.length > activeMountPath!.length)) {
          activeMountPath = mp;
        }
      }
    }

    return SizedBox(
      width: width,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tw.slate50,
          border: Border(right: BorderSide(color: tw.slate100)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  children: [
                  _SidebarSectionHeader(
                    title: 'PLACES',
                    colors: c,
                    trailing: _SidebarActionButton(
                      icon: LucideIcons.plus,
                      colors: c,
                      onPressed: () => _showAddPlaceDialog(context, state),
                      tooltip: 'Add place',
                    ),
                  ),
                  for (final p in places)
                    if (!state.hiddenPlaces.contains(p.path))
                    _SidebarPlaceItem(
                      label: state.placeLabel(p),
                      path: p.path,
                      state: state,
                      colors: c,
                      active: state.viewMode == 'local' && state.fmMeta.currentPath == p.path,
                      onTap: () => state.fmOpenPlace(p.path),
                    ),
                  for (final p in state.customPlaces)
                    _SidebarCustomPlaceItem(
                      label: p.label,
                      path: p.path,
                      state: state,
                      colors: c,
                      active: state.viewMode == 'local' && state.fmMeta.currentPath == p.path,
                      onTap: () => state.fmOpenPlace(p.path),
                    ),
                  const SizedBox(height: 20),
                  _SidebarSectionHeader(
                    title: 'BOOKMARKS',
                    colors: c,
                    trailing: _SidebarActionButton(
                      icon: LucideIcons.plus,
                      colors: c,
                      onPressed: state.openAddBookmark,
                      tooltip: 'Add bookmark',
                    ),
                  ),
                  if (state.bookmarks.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      child: Row(
                        children: [
                          Icon(LucideIcons.bookmark, size: 13, color: tw.slate300),
                          const SizedBox(width: 10),
                          Text(
                            'No bookmarks yet',
                            style: TextStyle(
                              fontSize: 12,
                              fontStyle: FontStyle.italic,
                              color: tw.slate300,
                            ),
                          ),
                        ],
                      ),
                    ),
                  for (final bm in state.bookmarks)
                    _SidebarBookmarkItem(
                      bookmark: bm,
                      state: state,
                      colors: c,
                      active: state.viewMode == 'local' && _currentPath == bm.path,
                    ),
                  const SizedBox(height: 20),
                  _SidebarSectionHeader(
                    title: 'TAGS',
                    colors: c,
                    trailing: _SidebarActionButton(
                      icon: LucideIcons.plus,
                      colors: c,
                      onPressed: () => _showAddTagDialog(context, state),
                      tooltip: 'Add tag',
                    ),
                  ),
                  if (state.fileTags.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      child: Text(
                        'No tags yet',
                        style: TextStyle(
                          fontSize: 12,
                          fontStyle: FontStyle.italic,
                          color: tw.slate300,
                        ),
                      ),
                    ),
                  for (final tag in state.fileTags)
                    GestureDetector(
                      onSecondaryTapDown: (d) {
                        state.openSidebarCtxMenu(
                          SidebarCtxMenu(
                            type: 'tag',
                            key: tag.id,
                            label: tag.name,
                            x: d.globalPosition.dx,
                            y: d.globalPosition.dy,
                          ),
                        );
                      },
                      child: _SidebarItem(
                        label: tag.name,
                        icon: LucideIcons.tag,
                        iconColor: Color(
                          int.parse('FF${tag.color.replaceFirst('#', '')}', radix: 16),
                        ),
                        colors: c,
                        active: state.activeTagId == tag.id,
                        onTap: () => state.openTagView(tag.id),
                      ),
                    ),
                  const SizedBox(height: 20),
                  _NasSidebarSection(state: state, colors: c),
                  if (state.mounts.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    _SidebarSectionHeader(
                      title: 'DEVICES',
                      colors: c,
                      trailing: _SidebarActionButton(
                        icon: LucideIcons.slidersHorizontal,
                        colors: c,
                        onPressed: state.openDeviceManager,
                        tooltip: 'Manage devices',
                      ),
                    ),
                    for (final m in state.mounts)
                      if (!state.hiddenDevices.contains(m.path))
                        _DeviceSidebarItem(
                          mount: m,
                          state: state,
                          colors: c,
                          active: activeMountPath == m.path,
                          onTap: () => state.openMount(m),
                        ),
                  ],
                  if (state.trashPath != null) ...[
                    const SizedBox(height: 12),
                    _SidebarItem(
                      label: 'Trash',
                      icon: LucideIcons.trash2,
                      colors: c,
                      active: state.isTrashView,
                      onTap: state.openTrash,
                    ),
                  ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SidebarActionButton extends StatelessWidget {
  final IconData icon;
  final DatieveColors colors;
  final VoidCallback onPressed;
  final String tooltip;

  const _SidebarActionButton({
    required this.icon,
    required this.colors,
    required this.onPressed,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final tw = Tw(colors);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: tw.slate200,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            width: 24,
            height: 24,
            child: Icon(icon, size: 14, color: tw.slate600),
          ),
        ),
      ),
    );
  }
}

class _SidebarSectionHeader extends StatelessWidget {
  final String title;
  final DatieveColors colors;
  final Widget? trailing;

  const _SidebarSectionHeader({
    required this.title,
    required this.colors,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final tw = Tw(colors);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 2.5,
                color: tw.slate300,
              ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class _SidebarBookmarkItem extends StatelessWidget {
  final Bookmark bookmark;
  final DatieveState state;
  final DatieveColors colors;
  final bool active;

  const _SidebarBookmarkItem({
    required this.bookmark,
    required this.state,
    required this.colors,
    required this.active,
  });

  @override
  Widget build(BuildContext context) {
    return wrapFileDragTarget(
      state: state,
      dropPath: bookmark.path,
      enabled: state.viewMode == 'local',
      onHoverOpen: () => state.openBookmark(bookmark),
      child: GestureDetector(
        onSecondaryTapDown: (d) {
          state.openSidebarCtxMenu(
            SidebarCtxMenu(
              type: 'bookmark',
              key: bookmark.id,
              label: bookmark.label,
              path: bookmark.path,
              x: d.globalPosition.dx,
              y: d.globalPosition.dy,
            ),
          );
        },
        child: _SidebarItem(
          label: bookmark.label,
          icon: LucideIcons.bookmark,
          colors: colors,
          active: active,
          onTap: () => state.openBookmark(bookmark),
        ),
      ),
    );
  }
}

class _SidebarPlaceItem extends StatelessWidget {
  final String label;
  final String path;
  final DatieveState state;
  final DatieveColors colors;
  final bool active;
  final VoidCallback onTap;

  const _SidebarPlaceItem({
    required this.label,
    required this.path,
    required this.state,
    required this.colors,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return wrapFileDragTarget(
      state: state,
      dropPath: path,
      enabled: state.viewMode == 'local',
      onHoverOpen: onTap,
      child: GestureDetector(
        onSecondaryTapDown: (d) {
          state.openSidebarCtxMenu(
            SidebarCtxMenu(
              type: 'place',
              key: path,
              label: label,
              path: path,
              x: d.globalPosition.dx,
              y: d.globalPosition.dy,
            ),
          );
        },
        child: _SidebarItem(
          label: label,
          icon: LucideIcons.folder,
          iconColor: const Color(0xFFFBBF24),
          colors: colors,
          active: active,
          onTap: onTap,
        ),
      ),
    );
  }
}

class _SidebarCustomPlaceItem extends StatelessWidget {
  final String label;
  final String path;
  final DatieveState state;
  final DatieveColors colors;
  final bool active;
  final VoidCallback onTap;

  const _SidebarCustomPlaceItem({
    required this.label,
    required this.path,
    required this.state,
    required this.colors,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return wrapFileDragTarget(
      state: state,
      dropPath: path,
      enabled: state.viewMode == 'local',
      onHoverOpen: onTap,
      child: GestureDetector(
        onSecondaryTapDown: (d) {
          state.openSidebarCtxMenu(
            SidebarCtxMenu(
              type: 'custom_place',
              key: path,
              label: label,
              path: path,
              x: d.globalPosition.dx,
              y: d.globalPosition.dy,
            ),
          );
        },
        child: _SidebarItem(
          label: label,
          icon: LucideIcons.folder,
          iconColor: const Color(0xFFFBBF24),
          colors: colors,
          active: active,
          onTap: onTap,
        ),
      ),
    );
  }
}

class _DeviceSidebarItem extends StatelessWidget {
  final MountEntryDto mount;
  final DatieveState state;
  final DatieveColors colors;
  final bool active;
  final VoidCallback onTap;

  const _DeviceSidebarItem({
    required this.mount,
    required this.state,
    required this.colors,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tw = Tw(colors);
    final total = mount.totalBytes.toDouble();
    final used = mount.usedBytes.toDouble();
    final available = mount.availableBytes.toDouble();
    final pct = total > 0 ? (used / total * 100).round().clamp(0, 100) : 0;
    final barColor = pct >= 90
        ? tw.red500
        : pct >= 75
            ? const Color(0xFFF59E0B)
            : tw.slate500;

    return wrapFileDragTarget(
      state: state,
      dropPath: mount.path,
      enabled: state.viewMode == 'local',
      onHoverOpen: onTap,
      child: GestureDetector(
        onSecondaryTapDown: (d) {
          state.openSidebarCtxMenu(
            SidebarCtxMenu(
              type: 'device',
              key: mount.path,
              label: mount.label,
              path: mount.path,
              x: d.globalPosition.dx,
              y: d.globalPosition.dy,
            ),
          );
        },
        child: _SidebarItem(
          label: mount.label,
          icon: LucideIcons.hardDrive,
          colors: colors,
          active: active,
          onTap: onTap,
          trailing: total > 0
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: pct / 100,
                      minHeight: 4,
                      backgroundColor: tw.slate200,
                      color: barColor,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${formatBytes(available)} free of ${formatBytes(total)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10, color: tw.slate400),
                  ),
                ],
              )
            : null,
        ),
      ),
    );
  }
}

class _NasSidebarSection extends StatelessWidget {
  final DatieveState state;
  final DatieveColors colors;

  const _NasSidebarSection({required this.state, required this.colors});

  @override
  Widget build(BuildContext context) {
    final tw = Tw(colors);
    final agentName = state.agent?.hostname ?? 'NAS';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: state.viewMode == 'nas' ? tw.slate600 : Colors.transparent,
                width: 3,
              ),
            ),
            color: state.viewMode == 'nas' ? tw.slate200 : Colors.transparent,
          ),
          child: TextButton(
            onPressed: () {
              state.toggleNasExpanded();
              state.switchView('nas');
            },
            style: TextButton.styleFrom(
              padding: EdgeInsets.only(
                left: state.viewMode == 'nas' ? 13 : 16,
                right: 16,
                top: 4,
                bottom: 4,
              ),
              foregroundColor: state.viewMode == 'nas' ? tw.ink : tw.slate400,
              alignment: Alignment.centerLeft,
            ),
            child: Row(
              children: [
                Icon(LucideIcons.network, size: 11),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    agentName.toUpperCase(),
                    style: const TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 2,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Transform.rotate(
                  angle: state.nasExpanded ? 0 : -1.5708,
                  child: Icon(LucideIcons.chevronDown, size: 11),
                ),
              ],
            ),
          ),
        ),
        if (state.nasExpanded) ...[
          if (state.nasNavRoots.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Text(
                'No folders indexed',
                style: TextStyle(fontSize: 12, color: tw.slate300),
              ),
            )
          else
            for (final root in state.nasNavRoots)
              GestureDetector(
                onSecondaryTapDown: (d) {
                  state.openSidebarCtxMenu(
                    SidebarCtxMenu(
                      type: 'nas',
                      key: root.path,
                      label: root.name,
                      x: d.globalPosition.dx,
                      y: d.globalPosition.dy,
                    ),
                  );
                },
                child: _SidebarItem(
                  label: root.name,
                  icon: LucideIcons.hardDrive,
                  colors: colors,
                  active: state.viewMode == 'nas',
                  onTap: () {
                    state.switchView('nas');
                    state.nasOpenRoot(root);
                  },
                ),
              ),
        ],
      ],
    );
  }
}

class _DeviceManagerDialog extends StatelessWidget {
  final DatieveState state;

  const _DeviceManagerDialog({required this.state});

  @override
  Widget build(BuildContext context) {
    final tw = Tw(state.colors);
    return Material(
      color: const Color(0x4D0F172A),
      child: GestureDetector(
        onTap: state.closeDeviceManager,
        child: Center(
          child: GestureDetector(
            onTap: () {},
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 512),
              child: Container(
                margin: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: tw.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: tw.slate100),
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      height: 48,
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      decoration: BoxDecoration(
                        color: tw.slate50,
                        border: Border(bottom: BorderSide(color: tw.slate100)),
                      ),
                      child: Row(
                        children: [
                          Icon(LucideIcons.hardDrive, size: 16, color: tw.slate500),
                          const SizedBox(width: 8),
                          Text(
                            'Devices',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: tw.ink,
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            icon: Icon(LucideIcons.x, size: 14, color: tw.slate400),
                            onPressed: state.closeDeviceManager,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                        ],
                      ),
                    ),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 360),
                      child: ListView(
                        shrinkWrap: true,
                        padding: const EdgeInsets.all(12),
                        children: [
                          for (final m in state.mounts)
                            _DeviceManagerRow(state: state, mount: m),
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

class _DeviceManagerRow extends StatelessWidget {
  final DatieveState state;
  final MountEntryDto mount;

  const _DeviceManagerRow({required this.state, required this.mount});

  @override
  Widget build(BuildContext context) {
    final tw = Tw(state.colors);
    final hidden = state.hiddenDevices.contains(mount.path);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Row(
        children: [
          Icon(LucideIcons.hardDrive, size: 16, color: tw.slate400),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  mount.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: tw.ink,
                  ),
                ),
                Text(
                  '${mount.path} · ${mount.fsType}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: tw.slate400),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: () {
              if (hidden) {
                state.showDevice(mount.path);
              } else {
                state.hideDevice(mount.path);
              }
            },
            child: AnimatedContainer(
              duration: Duration.zero,
              width: 40,
              height: 20,
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: hidden ? tw.slate200 : tw.slate900,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Align(
                alignment: hidden ? Alignment.centerLeft : Alignment.centerRight,
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: tw.white,
                    shape: BoxShape.circle,
                    boxShadow: const [
                      BoxShadow(color: Color(0x1A000000), blurRadius: 2),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarItem extends StatefulWidget {
  final String label;
  final IconData icon;
  final Color? iconColor;
  final DatieveColors colors;
  final bool active;
  final VoidCallback onTap;
  final Widget? trailing;

  const _SidebarItem({
    required this.label,
    required this.icon,
    required this.colors,
    required this.active,
    required this.onTap,
    this.iconColor,
    this.trailing,
  });

  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tw = Tw(widget.colors);
    final bg = widget.active
        ? tw.slate200
        : _hovered
            ? tw.slate100
            : Colors.transparent;
    final fg = widget.active
        ? tw.ink
        : _hovered
            ? colorMix(tw.ink, tw.white, 0.78)
            : tw.slate500;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          // 3 px left accent when active; compensate left padding so content
          // doesn't shift.
          padding: EdgeInsets.only(
            left: widget.active ? 13 : 16,
            right: 16,
            top: 8,
            bottom: 8,
          ),
          decoration: BoxDecoration(
            color: bg,
            border: Border(
              left: BorderSide(
                color: widget.active ? tw.slate600 : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(widget.icon, size: 13,
                      color: widget.active
                          ? tw.slate700
                          : widget.iconColor ?? tw.slate400),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: widget.active ? FontWeight.w600 : FontWeight.w400,
                        color: fg,
                      ),
                    ),
                  ),
                ],
              ),
              if (widget.trailing != null)
                Padding(
                  padding: const EdgeInsets.only(left: 25),
                  child: widget.trailing!,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContentColumn extends StatelessWidget {
  final DatieveState state;
  final ValueNotifier<int>? scrollToIndex;
  final ValueNotifier<int>? gridCols;

  const _ContentColumn({required this.state, this.scrollToIndex, this.gridCols});

  @override
  Widget build(BuildContext context) {
    final c = state.colors;
    final tw = Tw(c);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (state.fmShowFilters &&
            (state.viewMode == 'local' || state.viewMode == 'nas'))
          FmFiltersPanel(state: state),
        if (state.localSearchLoading)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              state.localSearchMode == 'tag'
                  ? 'Loading tagged items…'
                  : 'Searching…',
              style: TextStyle(fontSize: 12, color: tw.slate400),
            ),
          ),
        if (state.fmError.isNotEmpty)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: tw.red50,
              border: Border.all(color: tw.red100),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              state.fmError,
              style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: tw.red700),
            ),
          ),
        Expanded(
          child: _buildBrowseArea(context),
        ),
      ],
    );
  }

  Widget _buildBrowseArea(BuildContext context) {
    final c = state.colors;
    final tw = Tw(c);
    final phase = state.nasInlinePhase;
    if (phase == 'discovery') {
      return DiscoveryScreen(state: state, embedded: true);
    }
    if (phase == 'login') {
      return LoginScreen(state: state, embedded: true);
    }
    if (phase == 'setup') {
      return SetupScreen(state: state, embedded: true);
    }
    if (phase == 'demo') {
      return DemoScreen(state: state, embedded: true);
    }

    final browseKey = ValueKey('${state.viewMode}:${state.fmMeta.currentPath}:${state.localSearchMode}');

    return wrapFileDragTarget(
            state: state,
            dropPath: state.localCurrentDir,
            enabled: state.viewMode == 'local' && state.localCurrentDir.isNotEmpty,
            child: AnimatedSwitcher(
              duration: Duration.zero,
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: child,
              ),
              child: KeyedSubtree(
                key: browseKey,
                child: state.fmLoading && state.visibleFmFiles.isEmpty
              ? Center(child: SlateSpinner(size: 20, stroke: 2, colors: c))
              : (state.localSearchMode != 'browse' || state.nasSearchActive)
                  ? (state.isCompactView
                      ? FileCompactGrid(
                          files: state.visibleFmFiles,
                          colors: c,
                          selectedPaths: state.fmSelectedPaths,
                          showThumbnails: state.settings.showThumbnails,
                          showExtensions: state.settings.showExtensions,
                          tagAssignments: state.tagAssignments,
                          fileTags: state.fileTags,
                          customFolderIcons: state.customFolderIcons,
                          gridZoom: state.gridZoom,
                          dragState: null,
                          singleClickOpen: state.settings.singleClickOpen,
                          onSelectWithModifiers: state.selectFileWithModifiers,
                          onOpen: state.openFile,
                          onEmptyTap: state.clearSelection,
                          onSecondaryTap: (file, pos) {
                            if (state.viewMode == 'nas') {
                              state.openNasCtxMenu(file, pos.dx, pos.dy);
                            } else {
                              state.openLocalCtxMenu(file, pos.dx, pos.dy);
                            }
                          },
                          onEmptySecondaryTap: (pos) =>
                              state.openEmptyCtxMenu(pos.dx, pos.dy),
                          scrollToIndex: scrollToIndex,
                          reportCols: gridCols,
                        )
                      : _SearchResultsList(state: state))
              : state.visibleFmFiles.isEmpty
                  ? GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: state.clearSelection,
                      onSecondaryTapDown: (d) => state.openEmptyCtxMenu(
                        d.globalPosition.dx,
                        d.globalPosition.dy,
                      ),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(LucideIcons.folder, size: 24, color: tw.slate200),
                            const SizedBox(height: 8),
                            Text(
                              _emptyMessage(state),
                              style: TextStyle(fontSize: 14, color: tw.slate400),
                            ),
                          ],
                        ),
                      ),
                    )
                  : state.isCompactView
                      ? FileCompactGrid(
                          files: state.visibleFmFiles,
                          colors: c,
                          selectedPaths: state.fmSelectedPaths,
                          showThumbnails: state.settings.showThumbnails,
                          showExtensions: state.settings.showExtensions,
                          tagAssignments: state.tagAssignments,
                          fileTags: state.fileTags,
                          customFolderIcons: state.customFolderIcons,
                          gridZoom: state.gridZoom,
                          dragState: state.viewMode == 'local' ? state : null,
                          singleClickOpen: state.settings.singleClickOpen,
                          onSelectWithModifiers: state.selectFileWithModifiers,
                          onOpen: state.openFile,
                          onEmptyTap: state.clearSelection,
                          onSecondaryTap: (file, pos) {
                            if (state.viewMode == 'nas') {
                              state.openNasCtxMenu(file, pos.dx, pos.dy);
                            } else {
                              state.openLocalCtxMenu(file, pos.dx, pos.dy);
                            }
                          },
                          onEmptySecondaryTap: (pos) =>
                              state.openEmptyCtxMenu(pos.dx, pos.dy),
                          scrollToIndex: scrollToIndex,
                          reportCols: gridCols,
                        )
                      : FixedFileListView(
                          files: state.visibleFmFiles,
                          colors: c,
                          selectedPaths: state.fmSelectedPaths,
                          loading: state.fmLoading,
                          dragState: state.viewMode == 'local' ? state : null,
                          singleClickOpen: state.settings.singleClickOpen,
                          onSelectWithModifiers: state.selectFileWithModifiers,
                          customFolderIcons: state.customFolderIcons,
                          gridZoom: state.gridZoom,
                          onOpen: state.openFile,
                          onEmptyTap: state.clearSelection,
                          showThumbnails: state.viewMode == 'local' &&
                              state.settings.showThumbnails,
                          showExtensions: state.settings.showExtensions,
                          tagAssignments: state.tagAssignments,
                          fileTags: state.fileTags,
                          onSecondaryTap: (file, pos) {
                            if (state.viewMode == 'nas') {
                              state.openNasCtxMenu(file, pos.dx, pos.dy);
                            } else {
                              state.openLocalCtxMenu(file, pos.dx, pos.dy);
                            }
                          },
                          onEmptySecondaryTap: (pos) =>
                              state.openEmptyCtxMenu(pos.dx, pos.dy),
                          scrollToIndex: scrollToIndex,
                        ),
              ),
            ),
          );
  }

  String _emptyMessage(DatieveState state) {
    if (state.localSearchMode == 'tag') return 'No files with this tag.';
    if (state.localSearchMode == 'recursive') return 'No search results in this folder.';
    if (state.fmShowFilters) return 'No items match the current filters.';
    return 'This folder is empty.';
  }
}

class _SearchResultsList extends StatefulWidget {
  final DatieveState state;
  const _SearchResultsList({required this.state});

  @override
  State<_SearchResultsList> createState() => _SearchResultsListState();
}

class _SearchResultsListState extends State<_SearchResultsList> {
  static DateTime? _lastTap;
  static String? _lastKey; // parentPath:name — unique per file even when path is empty
  final ScrollController _scrollCtrl = ScrollController();

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  String _modifiedLabel(BigInt secs) {
    if (secs == BigInt.zero) return '—';
    final dt = DateTime.fromMillisecondsSinceEpoch(secs.toInt() * 1000);
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year}  $h:$m';
  }

  String _locationOf(FileItemDto file, String viewMode) {
    if (viewMode == 'nas') {
      // file.detail holds the parent directory (computed by bridge from absolute_path)
      if (file.detail.isNotEmpty) return file.detail;
      // Fallback: extract from path if detail is empty for some reason
      final p = file.path;
      if (p.isNotEmpty) {
        final slash = p.lastIndexOf('/');
        return slash > 0 ? p.substring(0, slash) : '/';
      }
      return '—';
    }
    return file.parentPath;
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final c = state.colors;
    final tw = Tw(c);
    final files = state.visibleFmFiles;
    final selected = state.fmSelectedPaths;

    if (files.isEmpty) {
      return Center(
        child: Text(
          state.localSearchMode == 'tag'
              ? 'No files with this tag.'
              : 'No search results.',
          style: TextStyle(fontSize: 14, color: tw.slate400),
        ),
      );
    }

    const double rowH = 30;
    const double headerH = 26;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header
        Container(
          height: headerH,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: tw.slate50,
            border: Border(bottom: BorderSide(color: tw.line)),
          ),
          child: Row(
            children: [
              const SizedBox(width: 22),
              Expanded(
                flex: 3,
                child: Text('Name', style: TextStyle(fontSize: 11, color: tw.slate400, fontWeight: FontWeight.w500)),
              ),
              SizedBox(
                width: 72,
                child: Text('Size', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: tw.slate400, fontWeight: FontWeight.w500)),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 4,
                child: Text('Location', style: TextStyle(fontSize: 11, color: tw.slate400, fontWeight: FontWeight.w500)),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 140,
                child: Text('Modified', style: TextStyle(fontSize: 11, color: tw.slate400, fontWeight: FontWeight.w500)),
              ),
            ],
          ),
        ),
        // Rows
        Expanded(
          child: Listener(
            onPointerDown: (e) {
              // Only handle taps in the empty area BELOW all items.
              final offset = _scrollCtrl.hasClients ? _scrollCtrl.offset : 0.0;
              final vy = e.localPosition.dy + offset;
              if (vy >= files.length * rowH) {
                if (e.buttons == kSecondaryMouseButton) {
                  state.openEmptyCtxMenu(e.position.dx, e.position.dy);
                } else {
                  state.clearSelection();
                }
              }
            },
            child: ListView.builder(
              controller: _scrollCtrl,
              itemCount: files.length,
              itemExtent: rowH,
              itemBuilder: (ctx, i) {
                final file = files[i];
                final isSelected = selected.contains(file.path);
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) {
                    final now = DateTime.now();
                    final fileKey = '${file.parentPath}:${file.name}';
                    final isDouble = _lastKey == fileKey &&
                        _lastTap != null &&
                        now.difference(_lastTap!) < const Duration(milliseconds: 280);
                    _lastTap = now;
                    _lastKey = fileKey;
                    if (isDouble) {
                      state.openFile(file);
                    } else {
                      state.selectFileWithModifiers(
                        file,
                        ctrl: HardwareKeyboard.instance.isControlPressed,
                        shift: HardwareKeyboard.instance.isShiftPressed,
                      );
                    }
                  },
                  onSecondaryTapDown: (d) {
                    state.selectFileWithModifiers(file, ctrl: false, shift: false);
                    if (state.viewMode == 'nas') {
                      state.openNasCtxMenu(file, d.globalPosition.dx, d.globalPosition.dy);
                    } else {
                      state.openLocalCtxMenu(file, d.globalPosition.dx, d.globalPosition.dy);
                    }
                  },
                  child: Container(
                    color: isSelected ? tw.slate100 : Colors.transparent,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    alignment: Alignment.centerLeft,
                    child: Row(
                      children: [
                        Icon(
                          file.isDir
                              ? LucideIcons.folder
                              : (file.isSymlink ? LucideIcons.cornerDownRight : LucideIcons.file),
                          size: 13,
                          color: file.isDir ? tw.slate500 : tw.slate400,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 3,
                          child: Text(
                            file.name,
                            style: TextStyle(fontSize: 12, color: tw.slate700),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        SizedBox(
                          width: 72,
                          child: Text(
                            file.isDir ? '—' : formatBytes(file.size.toInt()),
                            textAlign: TextAlign.right,
                            style: TextStyle(fontSize: 11, color: tw.slate500),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 4,
                          child: Text(
                            _locationOf(file, state.viewMode),
                            style: TextStyle(fontSize: 11, color: tw.slate400),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 140,
                          child: Text(
                            _modifiedLabel(file.modifiedSecs),
                            style: TextStyle(fontSize: 11, color: tw.slate500),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _ToolbarIcon extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final DatieveColors colors;
  final VoidCallback onPressed;

  const _ToolbarIcon({
    required this.icon,
    required this.enabled,
    required this.colors,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final tw = Tw(colors);
    return IconButton(
      icon: Icon(icon, size: 17, color: enabled ? tw.slate600 : tw.slate300),
      onPressed: enabled ? onPressed : null,
      padding: const EdgeInsets.all(6),
      constraints: const BoxConstraints(),
    );
  }
}

class _LocalTabBar extends StatelessWidget {
  final DatieveState state;

  const _LocalTabBar({required this.state});

  @override
  Widget build(BuildContext context) {
    final tw = Tw(state.colors);
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: tw.slate50,
        border: Border(bottom: BorderSide(color: tw.line)),
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(left: 8),
              child: Row(
                children: [
                  for (final tab in state.localTabs)
                    SpringLoadedDragTarget(
                      state: state,
                      dropPath: tab.path,
                      enabled: state.viewMode == 'local',
                      onHoverOpen: () => state.openLocalTab(tab),
                      child: _TabChip(
                        tab: tab,
                        active: tab.id == state.activeLocalTabId,
                        colors: state.colors,
                        closable: state.localTabs.length > 1,
                        onTap: () => state.openLocalTab(tab),
                        onClose: () => state.closeLocalTab(tab.id),
                        onSecondaryTapDown: (d) => state.openTabCtxMenu(
                          tab.id,
                          d.globalPosition.dx,
                          d.globalPosition.dy,
                        ),
                      ),
                    ),
                  _NewTabButton(state: state),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NewTabButton extends StatefulWidget {
  final DatieveState state;
  const _NewTabButton({required this.state});

  @override
  State<_NewTabButton> createState() => _NewTabButtonState();
}

class _NewTabButtonState extends State<_NewTabButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tw = Tw(widget.state.colors);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Tooltip(
        message: 'New tab (Ctrl+T)',
        child: GestureDetector(
          onTap: widget.state.newLocalTab,
          child: Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hovered ? tw.slate200 : Colors.transparent,
              shape: BoxShape.circle,
            ),
            child: Icon(LucideIcons.plus, size: 13, color: tw.slate400),
          ),
        ),
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  final LocalTab tab;
  final bool active;
  final bool closable;
  final DatieveColors colors;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final void Function(TapDownDetails details)? onSecondaryTapDown;

  const _TabChip({
    required this.tab,
    required this.active,
    required this.closable,
    required this.colors,
    required this.onTap,
    required this.onClose,
    this.onSecondaryTapDown,
  });

  @override
  Widget build(BuildContext context) {
    final tw = Tw(colors);
    return GestureDetector(
      onTap: onTap,
      onSecondaryTapDown: onSecondaryTapDown,
      child: Container(
        constraints: const BoxConstraints(minWidth: 128, maxWidth: 224),
        height: 36,
        margin: const EdgeInsets.only(right: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: active ? tw.white : colorMix(tw.slate100, tw.white, 0.7),
          border: Border(
            left: BorderSide(color: active ? tw.slate200 : tw.line),
            right: BorderSide(color: active ? tw.slate200 : tw.line),
            top: BorderSide(color: active ? tw.slate200 : tw.line),
          ),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(Tw.radiusLg)),
          boxShadow: active
              ? [BoxShadow(color: colors.ink.withValues(alpha: 0.04), blurRadius: 2)]
              : null,
        ),
        child: Row(
          children: [
            Icon(LucideIcons.folder, size: 14, color: const Color(0xFFFBBF24)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                tab.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  color: active ? tw.ink : tw.slate500,
                ),
              ),
            ),
            if (closable)
              GestureDetector(
                onTap: onClose,
                child: Icon(LucideIcons.x, size: 12, color: tw.slate300),
              ),
          ],
        ),
      ),
    );
  }
}

// ─── Shortcut intents ─────────────────────────────────────────────────────────
// One class per logical command. Registered in _FileManagerScreenState._shortcutMap.

class _NavArrowIntent extends Intent {
  const _NavArrowIntent(this.key, {this.shift = false});
  final LogicalKeyboardKey key;
  final bool shift;
}
class _HomeNavIntent       extends Intent { const _HomeNavIntent(); }
class _EndNavIntent        extends Intent { const _EndNavIntent(); }
class _BackIntent          extends Intent { const _BackIntent(); }
class _ForwardIntent       extends Intent { const _ForwardIntent(); }
class _UpDirIntent         extends Intent { const _UpDirIntent(); }
class _BackspaceNavIntent  extends Intent { const _BackspaceNavIntent(); }
class _RefreshIntent       extends Intent { const _RefreshIntent(); }
class _EscapeIntent        extends Intent { const _EscapeIntent(); }
class _SearchFocusIntent   extends Intent { const _SearchFocusIntent(); }
class _SlashSearchIntent   extends Intent { const _SlashSearchIntent(); }
class _PathBarFocusIntent  extends Intent { const _PathBarFocusIntent(); }
class _ShortcutsDialogIntent  extends Intent { const _ShortcutsDialogIntent(); }
class _CommandPaletteIntent   extends Intent { const _CommandPaletteIntent(); }
class _ZoomInIntent        extends Intent { const _ZoomInIntent(); }
class _ZoomOutIntent       extends Intent { const _ZoomOutIntent(); }
class _ZoomResetIntent     extends Intent { const _ZoomResetIntent(); }
class _NewTabIntent        extends Intent { const _NewTabIntent(); }
class _CloseTabIntent      extends Intent { const _CloseTabIntent(); }
class _NextTabIntent       extends Intent { const _NextTabIntent(); }
class _PrevTabIntent       extends Intent { const _PrevTabIntent(); }
class _DupTabIntent        extends Intent { const _DupTabIntent(); }
class _ReopenTabIntent     extends Intent { const _ReopenTabIntent(); }
class _UndoIntent          extends Intent { const _UndoIntent(); }
class _SelectAllIntent     extends Intent { const _SelectAllIntent(); }
class _CopyIntent          extends Intent { const _CopyIntent(); }
class _CutIntent           extends Intent { const _CutIntent(); }
class _PasteIntent         extends Intent { const _PasteIntent(); }
class _DeleteIntent extends Intent {
  const _DeleteIntent({this.permanent = false});
  final bool permanent;
}
class _OpenFileIntent      extends Intent { const _OpenFileIntent(); }
class _RenameIntent        extends Intent { const _RenameIntent(); }
class _PropertiesIntent    extends Intent { const _PropertiesIntent(); }
class _ToggleHiddenIntent  extends Intent { const _ToggleHiddenIntent(); }
class _NewFolderIntent     extends Intent { const _NewFolderIntent(); }
class _NewFileIntent       extends Intent { const _NewFileIntent(); }

// ─── Action helper ────────────────────────────────────────────────────────────
// When isEnabled returns false, Shortcuts does NOT consume the key event —
// it propagates to the focused widget (e.g. TextField handles its own keys).
class _TextGuardedAction<T extends Intent> extends Action<T> {
  _TextGuardedAction({required this.onInvoke, required this.isText});
  final Object? Function(T) onInvoke;
  final bool Function() isText;

  @override
  Object? invoke(T intent) => onInvoke(intent);

  @override
  bool isEnabled(T intent, [BuildContext? context]) => !isText();
}

// ─── Tag color presets ────────────────────────────────────────────────────────

const List<({String hex, String label})> _kTagColors = [
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

Color _parseHex(String hex) {
  final h = hex.replaceFirst('#', '');
  return Color(int.parse(h.length == 6 ? 'FF$h' : h, radix: 16));
}

Future<void> _showAddTagDialog(BuildContext context, DatieveState state) async {
  final tw = Tw(state.colors);
  final nameCtrl = TextEditingController();
  String selectedColor = _kTagColors.first.hex;

  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
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
                    state.addFileTag(name: name, color: selectedColor);
                    Navigator.of(ctx).pop();
                  }
                },
              ),
              const SizedBox(height: 16),
              Text('Color', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: tw.slate500, letterSpacing: 1)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _kTagColors.map((c) {
                  final isSelected = selectedColor == c.hex;
                  return Tooltip(
                    message: c.label,
                    child: GestureDetector(
                      onTap: () => setState(() => selectedColor = c.hex),
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: _parseHex(c.hex),
                          shape: BoxShape.circle,
                          border: isSelected
                              ? Border.all(color: tw.ink, width: 2.5)
                              : Border.all(color: Colors.transparent, width: 2.5),
                          boxShadow: isSelected
                              ? [BoxShadow(color: tw.ink.withValues(alpha: 0.2), blurRadius: 4)]
                              : null,
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
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Cancel', style: TextStyle(color: tw.slate500)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: tw.slate900),
            onPressed: () {
              final name = nameCtrl.text.trim();
              if (name.isNotEmpty) {
                state.addFileTag(name: name, color: selectedColor);
                Navigator.of(ctx).pop();
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    ),
  );
}

Future<void> _showAddPlaceDialog(BuildContext context, DatieveState state) async {
  final tw = Tw(state.colors);
  final dir = state.localCurrentDir;
  final defaultName = dir.isNotEmpty && dir.contains('/')
      ? dir.substring(dir.lastIndexOf('/') + 1)
      : dir;
  final nameCtrl = TextEditingController(text: defaultName.isEmpty ? '' : defaultName);
  final pathCtrl = TextEditingController(text: dir);

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: tw.white,
      title: Text('Add Place', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: tw.ink)),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              autofocus: true,
              style: TextStyle(fontSize: 13, color: tw.ink),
              decoration: InputDecoration(
                labelText: 'Name',
                labelStyle: TextStyle(color: tw.slate400, fontSize: 12),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                filled: true,
                fillColor: tw.slate50,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: tw.slate200)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: tw.slate200)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: tw.slate400)),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: pathCtrl,
              style: TextStyle(fontSize: 13, color: tw.ink),
              decoration: InputDecoration(
                labelText: 'Path',
                labelStyle: TextStyle(color: tw.slate400, fontSize: 12),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                filled: true,
                fillColor: tw.slate50,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: tw.slate200)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: tw.slate200)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: tw.slate400)),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text('Cancel', style: TextStyle(color: tw.slate500)),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: tw.slate900),
          onPressed: () {
            final name = nameCtrl.text.trim();
            final path = pathCtrl.text.trim();
            if (path.isNotEmpty) {
              state.addToPlaces(path, name.isEmpty ? path : name);
              Navigator.of(ctx).pop();
            }
          },
          child: const Text('Add'),
        ),
      ],
    ),
  );
}