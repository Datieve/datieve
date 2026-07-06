import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../src/rust/api/fs.dart' as fs_api;
import '../src/rust/bridge.dart';
import '../state/datieve_state.dart';
import '../theme/css_tokens.dart';
import '../theme/datieve_theme.dart';
import '../utils/file_type_helpers.dart';
import '../utils/format_bytes.dart';
import 'fm_file_icon.dart';
import 'fm_property_widgets.dart';
import 'fm_thumbnail.dart';

class FmInfoPane extends StatelessWidget {
  final DatieveState state;

  const FmInfoPane({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final c = state.colors;
    final tw = Tw(c);
    final tab = state.settings.infoPaneTab;
    final selected = state.fmSelectedFile;
    final viewMode = state.viewMode;

    return SizedBox(
      width: 288,
      child: ColoredBox(
        color: tw.slate50,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: tw.white,
                border: Border(bottom: BorderSide(color: tw.slate100)),
              ),
              child: Row(
                children: [
                  Text(
                    'Details',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: tw.ink,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: Icon(LucideIcons.x, size: 13, color: tw.slate300),
                    onPressed: state.closeInfoPane,
                    padding: const EdgeInsets.all(4),
                    constraints: const BoxConstraints(),
                    tooltip: 'Hide details pane',
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  _TabButton(
                    label: 'Details',
                    active: tab == 'details',
                    colors: c,
                    onTap: () => state.setInfoPaneTab('details'),
                  ),
                  const SizedBox(width: 4),
                  _TabButton(
                    label: 'Preview',
                    active: tab == 'preview',
                    colors: c,
                    onTap: () => state.setInfoPaneTab('preview'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: tab == 'details'
                    ? _DetailsTab(
                        colors: c,
                        viewMode: viewMode,
                        file: selected,
                        state: state,
                      )
                    : _PreviewTab(
                        colors: c,
                        viewMode: viewMode,
                        file: selected,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  final String label;
  final bool active;
  final DatieveColors colors;
  final VoidCallback onTap;

  const _TabButton({
    required this.label,
    required this.active,
    required this.colors,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tw = Tw(colors);
    return Expanded(
      child: Material(
        color: active ? tw.white : Colors.transparent,
        borderRadius: BorderRadius.circular(4),
        elevation: active ? 1 : 0,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: active ? tw.ink : tw.slate400,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DetailsTab extends StatefulWidget {
  final DatieveColors colors;
  final String viewMode;
  final FileItemDto? file;
  final DatieveState state;

  const _DetailsTab({
    required this.colors,
    required this.viewMode,
    required this.file,
    required this.state,
  });

  @override
  State<_DetailsTab> createState() => _DetailsTabState();
}

class _DetailsTabState extends State<_DetailsTab> {
  String? _loadedPath;
  bool _loading = false;
  FilePropertiesDto? _props;

  @override
  void didUpdateWidget(covariant _DetailsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    _maybeLoad();
  }

  @override
  void initState() {
    super.initState();
    _maybeLoad();
  }

  void _maybeLoad() {
    final file = widget.file;
    if (widget.viewMode != 'local' || file == null) {
      setState(() {
        _loadedPath = null;
        _props = null;
        _loading = false;
      });
      return;
    }
    if (_loadedPath == file.path) return;
    _loadedPath = file.path;
    setState(() => _loading = true);
    try {
      final props = fs_api.getFileProperties(path: file.path);
      if (!mounted || _loadedPath != file.path) return;
      setState(() {
        _props = props;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _props = null;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tw = Tw(widget.colors);
    final file = widget.file;
    if (file == null) {
      return Center(
        child: Text(
          'Select an item to view details.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: tw.slate400),
        ),
      );
    }

    final binary = widget.state.settings.sizeUnit == 'binary';
    String fmtSize(int bytes) => formatBytes(bytes, binary: binary);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: tw.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: tw.slate100),
            ),
            child: Center(
              child: FmFileIcon(
                name: file.name,
                isDir: file.isDir,
                folderPath: file.path,
                customFolderIcons: widget.state.customFolderIcons,
                size: 40,
                square: true,
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          file.name,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: tw.ink),
        ),
        const SizedBox(height: 4),
        Text(
          widget.viewMode == 'local' ? 'LOCAL' : 'DATIEVE INDEX',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 10, letterSpacing: 2, color: tw.slate400),
        ),
        const SizedBox(height: 16),
        if (_loading)
          Center(child: Text('Loading…', style: TextStyle(fontSize: 11, color: tw.slate400)))
        else if (widget.viewMode == 'local' && _props != null) ...[
          FmPropertyRow(
            tw: tw,
            label: 'Type',
            value: _props!.isDir ? 'Folder' : (_props!.mimeType.isNotEmpty ? _props!.mimeType : 'File'),
          ),
          if (!file.isDir)
            FmPropertyRow(tw: tw, label: 'Size', value: fmtSize(_props!.size.toInt())),
          FmPropertyRow(tw: tw, label: 'Modified', value: fmFormatPropertyDate(_props!.modifiedSecs.toInt())),
          FmPropertyRow(
            tw: tw,
            label: 'Location',
            value: fmParentPath(_props!.absolutePath),
            monospace: true,
          ),
        ] else ...[
          FmPropertyRow(tw: tw, label: 'Type', value: file.isDir ? 'Folder' : 'File'),
          if (file.detail.isNotEmpty) FmPropertyRow(tw: tw, label: 'Details', value: file.detail),
          FmPropertyRow(tw: tw, label: 'Path', value: file.path, monospace: true),
          if (file.isSymlink) FmPropertyRow(tw: tw, label: 'Symlink', value: 'Yes'),
        ],
      ],
    );
  }
}

class _PreviewTab extends StatefulWidget {
  final DatieveColors colors;
  final String viewMode;
  final FileItemDto? file;

  const _PreviewTab({
    required this.colors,
    required this.viewMode,
    required this.file,
  });

  @override
  State<_PreviewTab> createState() => _PreviewTabState();
}

class _PreviewTabState extends State<_PreviewTab> {
  String? _path;
  bool _loading = false;
  String _content = '';
  String _error = '';
  Uint8List? _imageBytes;

  @override
  void didUpdateWidget(covariant _PreviewTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    _loadPreview();
  }

  @override
  void initState() {
    super.initState();
    _loadPreview();
  }

  Future<void> _loadPreview() async {
    final file = widget.file;
    if (widget.viewMode != 'local' || file == null || file.isDir) {
      setState(() {
        _path = null;
        _loading = false;
        _content = '';
        _error = '';
        _imageBytes = null;
      });
      return;
    }
    if (_path == file.path) return;
    _path = file.path;
    setState(() {
      _loading = true;
      _content = '';
      _error = '';
      _imageBytes = null;
    });
    try {
      if (isImage(file.name)) {
        final thumb = await fs_api.readImageThumbnail(path: file.path);
        if (_path != file.path) return;
        final data = thumb.contains(',') ? thumb.split(',').last : thumb;
        setState(() {
          _imageBytes = base64Decode(data);
          _loading = false;
        });
      } else if (isTextPreviewable(file.name)) {
        final text = fs_api.readTextPreview(path: file.path);
        setState(() {
          _content = text;
          _loading = false;
        });
      } else if (isVideo(file.name)) {
        setState(() {
          _loading = false;
          _error = 'Video preview requires native playback.';
        });
      } else {
        setState(() => _loading = false);
      }
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tw = Tw(widget.colors);
    if (widget.viewMode != 'local') {
      return Center(
        child: Text(
          'NAS previews require an agent file-stream endpoint. Indexed metadata is available in Details.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: tw.slate400),
        ),
      );
    }
    final file = widget.file;
    if (file == null) {
      return Center(
        child: Text(
          'Select a file to preview.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: tw.slate400),
        ),
      );
    }
    if (file.isDir) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(LucideIcons.folder, size: 28, color: tw.slate300),
          const SizedBox(height: 12),
          Text(
            'Folders do not have inline previews.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: tw.slate400),
          ),
        ],
      );
    }
    if (_loading) {
      return Center(
        child: CircularProgressIndicator(strokeWidth: 2, color: tw.slate400),
      );
    }
    if (_error.isNotEmpty) {
      return Center(
        child: Text(_error, textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: tw.red600)),
      );
    }
    if (_imageBytes != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(_imageBytes!, fit: BoxFit.contain),
      );
    }
    if (_content.isNotEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: tw.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: tw.slate100),
        ),
        child: SelectableText(
          _content,
          style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: tw.slate700, height: 1.4),
        ),
      );
    }
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (isImage(file.name))
          FmThumbnail(path: file.path, size: 120, fallback: Icon(LucideIcons.image, color: tw.slate300))
        else
          Icon(LucideIcons.file, size: 28, color: tw.slate300),
        const SizedBox(height: 12),
        Text(
          'No preview available for this file type.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: tw.slate400),
        ),
      ],
    );
  }
}