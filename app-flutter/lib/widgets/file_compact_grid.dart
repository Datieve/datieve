import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../src/rust/bridge.dart';
import '../state/datieve_state.dart';
import '../theme/css_tokens.dart';
import '../theme/datieve_theme.dart';
import '../models/file_tag.dart';
import '../utils/tag_store.dart';
import '../utils/file_type_helpers.dart';
import 'fm_drag_drop.dart';
import 'fm_file_icon.dart';
import 'fm_thumbnail.dart';
import 'tag_badges.dart';

class FileCompactGrid extends StatefulWidget {
  static DateTime? _lastTapTime;
  static String? _lastTapPath;

  final List<FileItemDto> files;
  final DatieveColors colors;
  final Set<String> selectedPaths;
  final bool showThumbnails;
  final bool showExtensions;
  final Map<String, List<String>> tagAssignments;
  final List<FileTag> fileTags;
  final Map<String, String> customFolderIcons;
  final double gridZoom;
  final ValueChanged<FileItemDto>? onOpen;
  final void Function(FileItemDto file, {bool additive})? onSelect;
  final void Function(FileItemDto file, {required bool ctrl, required bool shift})?
      onSelectWithModifiers;
  final void Function(FileItemDto file, Offset position)? onSecondaryTap;
  final VoidCallback? onEmptyTap;
  final void Function(Offset position)? onEmptySecondaryTap;
  final bool singleClickOpen;
  final DatieveState? dragState;
  final ValueNotifier<int>? scrollToIndex;
  final ValueNotifier<int>? reportCols;

  const FileCompactGrid({
    super.key,
    required this.files,
    required this.colors,
    this.selectedPaths = const {},
    this.showThumbnails = false,
    this.showExtensions = true,
    this.tagAssignments = const {},
    this.fileTags = const [],
    this.customFolderIcons = const {},
    this.gridZoom = 1.0,
    this.onOpen,
    this.onSelect,
    this.onSelectWithModifiers,
    this.onSecondaryTap,
    this.onEmptyTap,
    this.onEmptySecondaryTap,
    this.singleClickOpen = false,
    this.dragState,
    this.scrollToIndex,
    this.reportCols,
  });

  @override
  State<FileCompactGrid> createState() => _FileCompactGridState();
}

class _FileCompactGridState extends State<FileCompactGrid> {
  late final ScrollController _scrollController;
  bool _isDraggingSelection = false;
  Offset _startPoint = Offset.zero;
  Offset _currentPoint = Offset.zero;
  Set<String> _initialSelection = {};
  int _cachedCols = 4;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    widget.scrollToIndex?.addListener(_scrollToSelected);
  }

  @override
  void didUpdateWidget(FileCompactGrid old) {
    super.didUpdateWidget(old);
    if (old.scrollToIndex != widget.scrollToIndex) {
      old.scrollToIndex?.removeListener(_scrollToSelected);
      widget.scrollToIndex?.addListener(_scrollToSelected);
    }
  }

  @override
  void dispose() {
    widget.scrollToIndex?.removeListener(_scrollToSelected);
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToSelected() {
    final idx = widget.scrollToIndex?.value ?? -1;
    if (idx < 0 || idx >= widget.files.length || !_scrollController.hasClients) return;
    final rowH = 108.0 * widget.gridZoom;
    final row = idx ~/ _cachedCols;
    final top = row * rowH;
    final bottom = top + rowH;
    final viewH = _scrollController.position.viewportDimension;
    final offset = _scrollController.offset;
    if (top < offset) {
      _scrollController.jumpTo(top.clamp(0.0, _scrollController.position.maxScrollExtent));
    } else if (bottom > offset + viewH) {
      _scrollController.jumpTo((bottom - viewH).clamp(0.0, _scrollController.position.maxScrollExtent));
    }
  }

  String _displayName(String name) {
    if (widget.showExtensions) return name;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  List<FileTag> _tagsFor(String path) {
    final ids = widget.tagAssignments[normalizeTagPath(path)] ?? [];
    return ids
        .map((id) => widget.fileTags.where((t) => t.id == id).firstOrNull)
        .whereType<FileTag>()
        .toList();
  }

  void _handleTap(FileItemDto file) {
    final ctrl = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (widget.singleClickOpen && widget.onOpen != null && !ctrl && !shift) {
      widget.onOpen!(file);
    } else if (widget.onSelectWithModifiers != null) {
      widget.onSelectWithModifiers!(file, ctrl: ctrl, shift: shift);
    } else if (widget.onSelect != null) {
      widget.onSelect!(file, additive: ctrl);
    } else {
      widget.onOpen?.call(file);
    }
  }

  // Mirrors SliverGridDelegateWithFixedCrossAxisCount's own layout math
  // (SliverPadding.all(8) + crossAxisSpacing/mainAxisSpacing: 6) so hit
  // testing lines up with where tiles are actually painted. A naive
  // `constraints.maxWidth / cols` division (the previous approach) ignores
  // both the edge padding and inter-tile spacing, so it treated every pixel
  // between tiles as if it belonged to one of them — rubber-band selection
  // could then only ever start past the last row, never in a gap or margin.
  static const double _gridEdgePadding = 14.0;
  static const double _gridSpacing = 16.0;

  ({int cols, double cellWidth, double cellHeight, double pitchX, double pitchY}) _gridGeometry(
      BoxConstraints constraints) {
    final tileWidth = 104.0 * widget.gridZoom;
    final cols = (constraints.maxWidth / tileWidth).floor().clamp(2, 24);
    final crossAxisExtent = (constraints.maxWidth - _gridEdgePadding * 2).clamp(0.0, double.infinity);
    final usable = (crossAxisExtent - _gridSpacing * (cols - 1)).clamp(0.0, double.infinity);
    final cellWidth = usable / cols;
    final cellHeight = 108.0 * widget.gridZoom;
    return (
      cols: cols,
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      pitchX: cellWidth + _gridSpacing,
      pitchY: cellHeight + _gridSpacing,
    );
  }

  /// Maps a point (in the grid's local coordinate space) to the cell it
  /// falls in, and whether it's actually within the gap/padding around that
  /// cell rather than on the tile itself.
  ({int col, int row, int index, bool isGap}) _hitTestGrid(
      ({int cols, double cellWidth, double cellHeight, double pitchX, double pitchY}) geo,
      double dx,
      double dy) {
    final lx = dx - _gridEdgePadding;
    final ly = dy - _gridEdgePadding;
    if (lx < 0 || ly < 0 || geo.pitchX <= 0 || geo.pitchY <= 0) {
      return (col: -1, row: -1, index: -1, isGap: true);
    }
    final col = (lx / geo.pitchX).floor();
    final row = (ly / geo.pitchY).floor();
    final withinX = lx - col * geo.pitchX;
    final withinY = ly - row * geo.pitchY;
    final isGap = col >= geo.cols || withinX > geo.cellWidth || withinY > geo.cellHeight;
    return (col: col, row: row, index: row * geo.cols + col, isGap: isGap);
  }

  void _onPointerDown(PointerDownEvent event, BoxConstraints constraints) {
    if (event.buttons == kSecondaryMouseButton) {
      if (widget.onEmptySecondaryTap == null) return;
      final geo = _gridGeometry(constraints);
      final hit = _hitTestGrid(geo, event.localPosition.dx, event.localPosition.dy + _scrollController.offset);
      if (hit.isGap || hit.index >= widget.files.length) {
        widget.onEmptySecondaryTap!(event.position);
      }
      return;
    }
    if (event.buttons != kPrimaryMouseButton) return;

    final geo = _gridGeometry(constraints);
    final hit = _hitTestGrid(geo, event.localPosition.dx, event.localPosition.dy + _scrollController.offset);
    final clickedEmpty = hit.isGap || hit.index >= widget.files.length;

    if (clickedEmpty) {
      final ctrl = HardwareKeyboard.instance.isControlPressed ||
          HardwareKeyboard.instance.isMetaPressed;
      final shift = HardwareKeyboard.instance.isShiftPressed;

      setState(() {
        _isDraggingSelection = true;
        _startPoint = event.localPosition;
        _currentPoint = event.localPosition;
        _initialSelection = ctrl || shift ? Set<String>.from(widget.selectedPaths) : <String>{};
      });

      if (!ctrl && !shift) {
        widget.dragState?.clearSelection();
      }
    }
  }

  void _onPointerMove(PointerMoveEvent event, BoxConstraints constraints) {
    if (!_isDraggingSelection) return;

    setState(() {
      _currentPoint = event.localPosition;
    });

    final viewportHeight = constraints.maxHeight;
    const scrollThreshold = 40.0;
    const scrollSpeed = 12.0;
    if (event.localPosition.dy < scrollThreshold) {
      final target = (_scrollController.offset - scrollSpeed).clamp(0.0, _scrollController.position.maxScrollExtent);
      _scrollController.jumpTo(target);
    } else if (event.localPosition.dy > viewportHeight - scrollThreshold) {
      final target = (_scrollController.offset + scrollSpeed).clamp(0.0, _scrollController.position.maxScrollExtent);
      _scrollController.jumpTo(target);
    }

    _updateSelection(constraints);
  }

  void _onPointerUp(PointerUpEvent event) {
    if (!_isDraggingSelection) return;
    setState(() {
      _isDraggingSelection = false;
    });
  }

  void _updateSelection(BoxConstraints constraints) {
    final selectionRect = Rect.fromPoints(_startPoint, _currentPoint);
    final rectInScroll = Rect.fromLTRB(
      selectionRect.left,
      selectionRect.top + _scrollController.offset,
      selectionRect.right,
      selectionRect.bottom + _scrollController.offset,
    );

    final geo = _gridGeometry(constraints);

    final newlySelected = <String>{};
    for (int i = 0; i < widget.files.length; i++) {
      final row = i ~/ geo.cols;
      final col = i % geo.cols;

      final itemLeft = _gridEdgePadding + col * geo.pitchX;
      final itemRight = itemLeft + geo.cellWidth;
      final itemTop = _gridEdgePadding + row * geo.pitchY;
      final itemBottom = itemTop + geo.cellHeight;

      final intersectsX = itemLeft < rectInScroll.right && itemRight > rectInScroll.left;
      final intersectsY = itemTop < rectInScroll.bottom && itemBottom > rectInScroll.top;

      if (intersectsX && intersectsY) {
        newlySelected.add(widget.files[i].path);
      }
    }

    final finalSelection = Set<String>.from(_initialSelection)..addAll(newlySelected);
    if (widget.dragState != null) {
      widget.dragState!.setSelectedPaths(finalSelection);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tw = Tw(widget.colors);
    if (widget.files.isEmpty) {
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: widget.onEmptyTap,
        onSecondaryTapDown: widget.onEmptySecondaryTap == null
            ? null
            : (d) => widget.onEmptySecondaryTap!(d.globalPosition),
        child: Center(child: Text('No items', style: TextStyle(color: tw.slate400))),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final tileWidth = 104.0 * widget.gridZoom;
        final cols = (constraints.maxWidth / tileWidth).floor().clamp(2, 24);
        if (cols != _cachedCols) {
          _cachedCols = cols;
          widget.reportCols?.value = cols;
        }

        Widget scrollView = CustomScrollView(
          controller: _scrollController,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.all(_gridEdgePadding),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: cols,
                  mainAxisExtent: 108.0 * widget.gridZoom,
                  crossAxisSpacing: _gridSpacing,
                  mainAxisSpacing: _gridSpacing,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final file = widget.files[index];
                    final selected = widget.selectedPaths.contains(file.path);
                    final dragPaths = widget.dragState != null &&
                            widget.selectedPaths.contains(file.path)
                        ? widget.selectedPaths.toList()
                        : [file.path];

                    Widget tile = Material(
                      color: selected ? tw.slate100 : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        splashColor: tw.slate100,
                        highlightColor: tw.slate50,
                        canRequestFocus: false,
                        onTap: () => _handleTap(file),
                        onDoubleTap: null,
                        onTapDown: (details) {
                          final now = DateTime.now();
                          if (FileCompactGrid._lastTapPath == file.path &&
                              FileCompactGrid._lastTapTime != null &&
                              now.difference(FileCompactGrid._lastTapTime!) < const Duration(milliseconds: 280)) {
                            if (!widget.singleClickOpen && widget.onOpen != null) {
                              widget.onOpen!(file);
                            }
                          }
                          FileCompactGrid._lastTapTime = now;
                          FileCompactGrid._lastTapPath = file.path;
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.start,
                            children: [
                              LayoutBuilder(
                                builder: (context, c) {
                                  final iconSize = (56.0 * widget.gridZoom).clamp(24.0, 128.0);
                                  return SizedBox(
                                    width: c.maxWidth,
                                    height: iconSize,
                                    child: Center(
                                      child: widget.showThumbnails && !file.isDir && isImage(file.name)
                                          ? FmThumbnail(
                                              path: file.path,
                                              size: iconSize,
                                              fallback: FmFileIcon(
                                                name: file.name,
                                                isDir: file.isDir,
                                                isSymlink: file.isSymlink,
                                                folderPath: file.path,
                                                customFolderIcons: widget.customFolderIcons,
                                                size: iconSize,
                                                square: true,
                                              ),
                                            )
                                          : FmFileIcon(
                                              name: file.name,
                                              isDir: file.isDir,
                                              isSymlink: file.isSymlink,
                                              folderPath: file.path,
                                              customFolderIcons: widget.customFolderIcons,
                                              size: iconSize,
                                              square: true,
                                            ),
                                    ),
                                  );
                                },
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _displayName(file.name),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: (11.0 * widget.gridZoom).clamp(9.0, 14.0), color: tw.slate800, height: 1.2),
                              ),
                              TagBadges(
                                tags: _tagsFor(file.path),
                                colors: widget.colors,
                                compact: true,
                              ),
                            ],
                          ),
                        ),
                      ),
                    );

                    if (widget.onSecondaryTap != null) {
                      tile = GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onSecondaryTapDown: (d) => widget.onSecondaryTap!(file, d.globalPosition),
                        child: tile,
                      );
                    }
                    if (widget.dragState != null) {
                      tile = wrapFileDraggable(
                        state: widget.dragState!,
                        file: file,
                        dragPaths: dragPaths,
                        child: tile,
                      );
                      if (file.isDir) {
                        tile = wrapFileDragTarget(
                          state: widget.dragState!,
                          dropPath: file.path,
                          enabled: true,
                          onHoverOpen: () => widget.dragState!.openFile(file),
                          child: tile,
                        );
                      }
                    }
                    return tile;
                  },
                  childCount: widget.files.length,
                ),
              ),
            ),
            SliverFillRemaining(
              hasScrollBody: false,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onEmptyTap,
                onSecondaryTapDown: widget.onEmptySecondaryTap == null
                    ? null
                    : (d) => widget.onEmptySecondaryTap!(d.globalPosition),
                child: const SizedBox.expand(),
              ),
            ),
          ],
        );

        return Listener(
          // Defaults to deferToChild, which only fires where a descendant
          // actually paints something — the gaps between tiles and the
          // padding around the grid's edges are empty layout space, so
          // rubber-band selection silently never started there. opaque makes
          // this Listener see pointer events across its entire bounds.
          behavior: HitTestBehavior.opaque,
          onPointerDown: (e) => _onPointerDown(e, constraints),
          onPointerMove: (e) => _onPointerMove(e, constraints),
          onPointerUp: _onPointerUp,
          child: Stack(
            children: [
              Positioned.fill(child: scrollView),
              if (_isDraggingSelection)
                Positioned.fromRect(
                  rect: Rect.fromPoints(_startPoint, _currentPoint),
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        color: widget.colors.brand.withOpacity(0.12),
                        border: Border.all(color: widget.colors.brand, width: 1.5),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}