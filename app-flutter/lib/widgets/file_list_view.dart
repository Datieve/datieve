import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/file_tag.dart';
import '../src/rust/bridge.dart';
import '../utils/tag_store.dart';
import '../theme/css_tokens.dart';
import '../theme/datieve_theme.dart';
import '../utils/file_type_helpers.dart';
import '../state/datieve_state.dart';
import 'fm_drag_drop.dart';
import 'fm_file_icon.dart';
import 'fm_thumbnail.dart';
import 'tag_badges.dart';

/// Fixed layout constants — rows must not self-size during stream load.
abstract final class FileListLayout {
  static const double fileRowExtent = 52;
  static const double placeRowExtent = 40;
  static const double agentRowExtent = 98;
}

class FixedFileRow extends StatelessWidget {
  static DateTime? _lastTapTime;
  static String? _lastTapPath;

  final FileItemDto file;
  final DatieveColors colors;
  final bool selected;
  final bool showThumbnail;
  final List<FileTag> tags;
  final Map<String, String> customFolderIcons;
  final double gridZoom;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final VoidCallback? onSecondaryTap;
  final void Function(TapDownDetails details)? onSecondaryTapDown;

  const FixedFileRow({
    super.key,
    required this.file,
    required this.colors,
    this.selected = false,
    this.showThumbnail = false,
    this.tags = const [],
    this.customFolderIcons = const {},
    this.gridZoom = 1.4,
    this.onTap,
    this.onDoubleTap,
    this.onSecondaryTap,
    this.onSecondaryTapDown,
  });

  @override
  Widget build(BuildContext context) {
    final tw = Tw(colors);
    final scale = gridZoom / 1.4;
    final rowHeight = FileListLayout.fileRowExtent * scale;
    final thumbSize = 28.0 * scale;
    final iconSize = 34.0 * scale;
    final nameFontSize = (13.0 * scale).clamp(9.0, 24.0);
    final detailFontSize = (11.0 * scale).clamp(8.0, 18.0);

    return SizedBox(
      height: rowHeight,
      child: Material(
        color: selected ? tw.slate100 : Colors.transparent,
        child: InkWell(
          canRequestFocus: false,
          onTap: onTap,
          onDoubleTap: null,
          onTapDown: (details) {
            final now = DateTime.now();
            if (FixedFileRow._lastTapPath == file.path &&
                FixedFileRow._lastTapTime != null &&
                now.difference(FixedFileRow._lastTapTime!) < const Duration(milliseconds: 280)) {
              if (onDoubleTap != null) {
                onDoubleTap!();
              }
            }
            FixedFileRow._lastTapTime = now;
            FixedFileRow._lastTapPath = file.path;
          },

          splashColor: tw.slate100,
          highlightColor: selected ? tw.slate100 : tw.slate50,
          hoverColor: selected ? tw.slate100 : tw.slate50,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: colorMix(tw.line, tw.white, 0.48))),
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: (8.0 * scale).clamp(4.0, 24.0)),
              child: Row(
                children: [
                  showThumbnail && !file.isDir && isImage(file.name)
                      ? FmThumbnail(
                          path: file.path,
                          size: thumbSize,
                          fallback: FmFileIcon(
                            name: file.name,
                            isDir: file.isDir,
                            isSymlink: file.isSymlink,
                            folderPath: file.path,
                            customFolderIcons: customFolderIcons,
                            size: iconSize,
                          ),
                        )
                      : FmFileIcon(
                          name: file.name,
                          isDir: file.isDir,
                          isSymlink: file.isSymlink,
                          folderPath: file.path,
                          customFolderIcons: customFolderIcons,
                          size: iconSize,
                        ),
                  SizedBox(width: 10 * scale),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                file.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: tw.ink,
                                  fontSize: nameFontSize,
                                  height: 1.25,
                                ),
                              ),
                            ),
                            if (file.isSymlink)
                              Text('↗', style: TextStyle(fontSize: 10 * scale, color: tw.slate400)),
                          ],
                        ),
                        Text(
                          file.detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: tw.slate400, fontSize: detailFontSize, height: 1.33),
                        ),
                        TagBadges(tags: tags, colors: colors, compact: true),
                      ],
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

class FixedFileListView extends StatefulWidget {
  final List<FileItemDto> files;
  final DatieveColors colors;
  final Set<String> selectedPaths;
  final ValueChanged<FileItemDto>? onOpen;
  final void Function(FileItemDto file, {bool additive})? onSelect;
  final void Function(FileItemDto file, {required bool ctrl, required bool shift})?
      onSelectWithModifiers;
  final void Function(FileItemDto file, Offset position)? onSecondaryTap;
  final VoidCallback? onEmptyTap;
  final void Function(Offset position)? onEmptySecondaryTap;
  final Map<String, String> customFolderIcons;
  final bool showThumbnails;
  final bool showExtensions;
  final Map<String, List<String>> tagAssignments;
  final List<FileTag> fileTags;
  final double gridZoom;
  final bool loading;
  final DatieveState? dragState;
  final List<String> Function(FileItemDto file)? dragPathsFor;
  final bool singleClickOpen;
  final ValueNotifier<int>? scrollToIndex;

  const FixedFileListView({
    super.key,
    required this.files,
    required this.colors,
    this.selectedPaths = const {},
    this.onOpen,
    this.onSelect,
    this.onSelectWithModifiers,
    this.onSecondaryTap,
    this.onEmptyTap,
    this.onEmptySecondaryTap,
    this.customFolderIcons = const {},
    this.showThumbnails = false,
    this.showExtensions = true,
    this.tagAssignments = const {},
    this.fileTags = const [],
    this.gridZoom = 1.4,
    this.loading = false,
    this.dragState,
    this.dragPathsFor,
    this.singleClickOpen = false,
    this.scrollToIndex,
  });

  @override
  State<FixedFileListView> createState() => _FixedFileListViewState();
}

class _FixedFileListViewState extends State<FixedFileListView> {
  late final ScrollController _scrollController;
  bool _isDraggingSelection = false;
  Offset _startPoint = Offset.zero;
  Offset _currentPoint = Offset.zero;
  Set<String> _initialSelection = {};

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    widget.scrollToIndex?.addListener(_scrollToSelected);
  }

  @override
  void didUpdateWidget(FixedFileListView old) {
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
    final itemH = FileListLayout.fileRowExtent * (widget.gridZoom / 1.4);
    final top = idx * itemH;
    final bottom = top + itemH;
    final viewH = _scrollController.position.viewportDimension;
    final offset = _scrollController.offset;
    if (top < offset) {
      _scrollController.jumpTo(top.clamp(0.0, _scrollController.position.maxScrollExtent));
    } else if (bottom > offset + viewH) {
      _scrollController.jumpTo((bottom - viewH).clamp(0.0, _scrollController.position.maxScrollExtent));
    }
  }

  void _onPointerDown(PointerDownEvent event, BoxConstraints constraints) {
    if (event.buttons != kPrimaryMouseButton) return;

    final itemHeight = FileListLayout.fileRowExtent * (widget.gridZoom / 1.4);
    final yScroll = event.localPosition.dy + _scrollController.offset;
    final totalListHeight = widget.files.length * itemHeight;

    final clickedEmpty = yScroll >= totalListHeight || event.localPosition.dx > 320;

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

    final itemHeight = FileListLayout.fileRowExtent * (widget.gridZoom / 1.4);
    final newlySelected = <String>{};

    for (int i = 0; i < widget.files.length; i++) {
      final itemTop = i * itemHeight;
      final itemBottom = (i + 1) * itemHeight;

      final intersectsY = itemTop < rectInScroll.bottom && itemBottom > rectInScroll.top;
      final intersectsX = rectInScroll.left < 320.0 && rectInScroll.right > 0.0;

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
    if (widget.files.isEmpty && widget.loading) {
      return Center(child: CircularProgressIndicator(color: widget.colors.brand));
    }
    if (widget.files.isEmpty) {
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: widget.onEmptyTap,
        onSecondaryTapDown: widget.onEmptySecondaryTap == null
            ? null
            : (d) => widget.onEmptySecondaryTap!(d.globalPosition),
        child: Center(
          child: Text('No items', style: TextStyle(color: widget.colors.muted)),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final itemHeight = FileListLayout.fileRowExtent * (widget.gridZoom / 1.4);

        Widget scrollView = CustomScrollView(
          controller: _scrollController,
          slivers: [
            SliverFixedExtentList(
              itemExtent: itemHeight,
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final file = widget.files[index];
                  final dragPaths = widget.dragPathsFor?.call(file) ??
                      (widget.selectedPaths.contains(file.path)
                          ? widget.selectedPaths.toList()
                          : [file.path]);
                  Widget row = FixedFileRow(
                    file: file,
                    colors: widget.colors,
                    selected: widget.selectedPaths.contains(file.path),
                    showThumbnail: widget.showThumbnails,
                    tags: widget.fileTags
                        .where((t) =>
                            (widget.tagAssignments[normalizeTagPath(file.path)] ?? []).contains(t.id))
                        .toList(),
                    customFolderIcons: widget.customFolderIcons,
                    gridZoom: widget.gridZoom,
                    onTap: () {
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
                    },
                    onDoubleTap: widget.singleClickOpen || widget.onOpen == null ? null : () => widget.onOpen!(file),
                  );
                  if (widget.onSecondaryTap != null) {
                    row = GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onSecondaryTapDown: (d) => widget.onSecondaryTap!(file, d.globalPosition),
                      child: row,
                    );
                  }
                  if (widget.dragState != null) {
                    row = wrapFileDraggable(
                      state: widget.dragState!,
                      file: file,
                      dragPaths: dragPaths,
                      child: row,
                    );
                    if (file.isDir) {
                      row = wrapFileDragTarget(
                        state: widget.dragState!,
                        dropPath: file.path,
                        enabled: true,
                        onHoverOpen: () => widget.dragState!.openFile(file),
                        child: row,
                      );
                    }
                  }
                  return row;
                },
                childCount: widget.files.length,
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
          // actually paints something — the gaps between rows and the space
          // past the name/detail columns are empty layout space, so
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

class FixedPlaceRow extends StatelessWidget {
  final String label;
  final DatieveColors colors;
  final VoidCallback onTap;

  const FixedPlaceRow({
    super.key,
    required this.label,
    required this.colors,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: FileListLayout.placeRowExtent,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Icon(Icons.folder_outlined, size: 18, color: colors.brand),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colors.ink, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}