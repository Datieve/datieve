import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HardwareKeyboard;
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../state/datieve_state.dart';
import '../src/rust/bridge.dart';

// Ctrl (Windows/Linux) or Option/Alt (macOS) held during an internal drag
// forces a copy instead of the default move, matching Explorer/Finder.
bool _copyModifierPressed() {
  final hw = HardwareKeyboard.instance;
  return hw.isControlPressed || hw.isAltPressed;
}

// ──────────────────────────────────────────────────────────────────────────────
// Drop target for folders – accepts both internal (Datieve) and external drags.
// ──────────────────────────────────────────────────────────────────────────────

class SpringLoadedDragTarget extends StatefulWidget {
  final DatieveState state;
  final String dropPath;
  final bool enabled;
  final Widget child;
  final VoidCallback? onHoverOpen;

  const SpringLoadedDragTarget({
    super.key,
    required this.state,
    required this.dropPath,
    required this.enabled,
    required this.child,
    this.onHoverOpen,
  });

  @override
  State<SpringLoadedDragTarget> createState() => _SpringLoadedDragTargetState();
}

class _SpringLoadedDragTargetState extends State<SpringLoadedDragTarget> {
  Timer? _hoverTimer;
  bool _isOver = false;

  void _cancelTimer() {
    _hoverTimer?.cancel();
    _hoverTimer = null;
  }

  @override
  void dispose() {
    _cancelTimer();
    super.dispose();
  }

  Future<Uri?> _readUri(DropItem item) {
    final reader = item.dataReader;
    if (reader == null) return Future.value(null);
    final completer = Completer<Uri?>();
    final progress = reader.getValue<Uri>(
      Formats.fileUri,
      (uri) {
        if (!completer.isCompleted) completer.complete(uri);
      },
      onError: (_) {
        if (!completer.isCompleted) completer.complete(null);
      },
    );
    if (progress == null && !completer.isCompleted) completer.complete(null);
    return completer.future;
  }

  Future<List<String>> _extractExternalPaths(PerformDropEvent event) async {
    final paths = <String>{};
    for (final item in event.session.items) {
      if (item.canProvide(Formats.fileUri)) {
        final uri = await _readUri(item);
        if (uri != null) paths.add(uri.toFilePath());
      }
    }
    return paths.toList();
  }

  bool _hasDroppable(DropOverEvent event) {
    if (widget.state.draggingPaths.isNotEmpty) return true;
    return event.session.items.any((item) => item.canProvide(Formats.fileUri));
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;

    final colors = widget.state.colors;

    return DropRegion(
      formats: [Formats.fileUri],
      // deferToChild only registers a hit where a descendant actually paints
      // something — the gaps between grid/list tiles and the padding around
      // the edges of the browse area are empty space with nothing painted,
      // so under deferToChild this whole-panel "drop into current directory"
      // target silently had no hit box there. opaque makes it a valid drop
      // target across its entire bounds, margins and inter-tile gaps included.
      hitTestBehavior: HitTestBehavior.opaque,
      onDropOver: (event) {
        if (!_hasDroppable(event)) return DropOperation.none;
        if (!_isOver) setState(() => _isOver = true);
        if (_hoverTimer == null && widget.onHoverOpen != null) {
          _hoverTimer = Timer(const Duration(milliseconds: 700), () {
            if (mounted) {
              widget.onHoverOpen!();
              _cancelTimer();
            }
          });
        }
        // Internal drags move by default (copy-modifier held overrides to
        // copy); external OS drag-ins always copy. Reflect the operation the
        // drop will actually perform so the OS cursor/icon isn't misleading.
        final internal = widget.state.draggingPaths.isNotEmpty;
        if (internal) {
          return _copyModifierPressed() ? DropOperation.copy : DropOperation.move;
        }
        return DropOperation.copy;
      },
      onDropLeave: (_) {
        _cancelTimer();
        if (_isOver) setState(() => _isOver = false);
      },
      onDropEnded: (_) {
        _cancelTimer();
        if (_isOver) setState(() => _isOver = false);
      },
      onPerformDrop: (event) async {
        _cancelTimer();
        if (_isOver) setState(() => _isOver = false);
        // Internal drag: state.draggingPaths is set by startDragging() and is
        // always reliable. Avoids depending on localData surviving OLE on Windows.
        final internal = widget.state.draggingPaths.isNotEmpty;
        final forceCopy = internal && _copyModifierPressed();
        final paths = internal
            ? List<String>.from(widget.state.draggingPaths)
            : await _extractExternalPaths(event);
        if (paths.isNotEmpty) {
          widget.state.dropPathsIntoDir(paths, widget.dropPath, internal: internal, forceCopy: forceCopy);
        }
      },
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _isOver ? colors.successBg : Colors.transparent,
          border: _isOver ? Border.all(color: colors.successLine) : null,
        ),
        child: widget.child,
      ),
    );
  }
}

Widget wrapFileDragTarget({
  required DatieveState state,
  required String dropPath,
  required bool enabled,
  required Widget child,
  VoidCallback? onHoverOpen,
}) {
  return SpringLoadedDragTarget(
    state: state,
    dropPath: dropPath,
    enabled: enabled,
    onHoverOpen: onHoverOpen,
    child: child,
  );
}

// ──────────────────────────────────────────────────────────────────────────────
// Per-tile draggable: DragItemWidget + DraggableWidget (standard pattern)
// ──────────────────────────────────────────────────────────────────────────────

// A stable GlobalKey per file path, reused across rebuilds, so a multi-file
// drag session can look up the DragItemWidgetState of every selected tile
// (not just the one under the pointer) and add each as its own native drag
// item. This matters for external drag-out: Windows' shell drop target only
// recognizes one file per native item — packing several URIs into a single
// item's text/uri-list (the previous approach) is a GTK/Nautilus convention
// that Windows Explorer doesn't understand, so multi-file drag-out (and,
// since the whole native session can fail to initialize, sometimes even the
// in-app drop) silently only ever carried one file on Windows.
final Map<String, GlobalKey<DragItemWidgetState>> _dragItemKeys = {};

GlobalKey<DragItemWidgetState> _dragItemKeyFor(String path) =>
    _dragItemKeys.putIfAbsent(path, () => GlobalKey<DragItemWidgetState>());

List<DragItemWidgetState> _resolveDragItemStates(BuildContext context, List<String> dragPaths) {
  final states = <DragItemWidgetState>[
    for (final path in dragPaths)
      if (_dragItemKeys[path]?.currentState case final s?) s,
  ];
  if (states.isNotEmpty) return states;
  // Fallback: at least drag the tile under the pointer if none of the
  // selected paths currently have a mounted, registered widget.
  final ancestor = context.findAncestorStateOfType<DragItemWidgetState>();
  return ancestor != null ? [ancestor] : const [];
}

/// Wraps [child] so it participates in a super_drag_and_drop session.
///
/// [dragPaths] is all paths that move in this session (either just [file.path]
/// or all selected paths when this tile is part of a selection). They are
/// stored in [DragItem.localData] so internal drops receive all paths. Each
/// path also becomes its own native drag item (see [_resolveDragItemStates])
/// so external drop targets see a real multi-file drag, not one bundled item.
Widget wrapFileDraggable({
  required DatieveState state,
  required FileItemDto file,
  required List<String> dragPaths,
  required Widget child,
}) {
  if (state.viewMode != 'local') return child;

  return DragItemWidget(
    key: _dragItemKeyFor(file.path),
    dragBuilder: (context, child) => _DragBadge(
      name: file.name,
      count: dragPaths.length,
    ),
    allowedOperations: () => [DropOperation.copy, DropOperation.move],
    dragItemProvider: (DragItemRequest request) async {
      state.startDragging(dragPaths);

      late final VoidCallback listener;
      listener = () {
        if (request.session.dragCompleted.value != null) {
          request.session.dragCompleted.removeListener(listener);
          state.finishDragging();
        }
      };
      request.session.dragCompleted.addListener(listener);

      final item = DragItem(localData: dragPaths);
      item.add(Formats.fileUri(Uri.file(file.path)));
      return item;
    },
    child: DraggableWidget(
      hitTestBehavior: HitTestBehavior.deferToChild,
      dragItemsProvider: (context) => _resolveDragItemStates(context, dragPaths),
      child: child,
    ),
  );
}

class _DragBadge extends StatelessWidget {
  final String name;
  final int count;

  const _DragBadge({required this.name, required this.count});

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 8,
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.description_outlined, size: 16, color: Colors.black54),
            const SizedBox(width: 8),
            Text(
              count > 1 ? '$count items' : name,
              style: const TextStyle(fontSize: 13, color: Colors.black87),
            ),
          ],
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Cancel zone – drop here to discard the drag without moving files.
// ──────────────────────────────────────────────────────────────────────────────

class DragCancelZone extends StatelessWidget {
  final DatieveState state;

  const DragCancelZone({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return DropRegion(
      formats: [Formats.fileUri],
      hitTestBehavior: HitTestBehavior.opaque,
      onDropOver: (_) => DropOperation.copy,
      onPerformDrop: (_) async => state.finishDragging(),
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(20),
        color: Colors.red.shade600,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cancel_outlined, color: Colors.white, size: 18),
              SizedBox(width: 8),
              Text('Drop here to Cancel',
                  style: TextStyle(color: Colors.white, fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}
