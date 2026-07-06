import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../src/rust/api/fs.dart' as fs_api;
import '../src/rust/bridge.dart';
import '../state/datieve_state.dart';
import '../theme/css_tokens.dart';
import '../utils/format_bytes.dart';
import '../widgets/fm_file_icon.dart';
import 'fm_property_widgets.dart';

enum _PropertiesTab { general, advanced, storage }

class FmPropertiesDialog extends StatefulWidget {
  final DatieveState state;
  final FileItemDto file;

  const FmPropertiesDialog({
    super.key,
    required this.state,
    required this.file,
  });

  @override
  State<FmPropertiesDialog> createState() => _FmPropertiesDialogState();
}

class _FmPropertiesDialogState extends State<FmPropertiesDialog> {
  bool _loading = true;
  String? _error;
  FilePropertiesDto? _props;
  VolumeInfoDto? _volume;

  // Tabs navigation
  _PropertiesTab _activeTab = _PropertiesTab.general;

  // General Tab state
  late final TextEditingController _nameController = TextEditingController();
  bool _isReadOnly = false;
  bool _isHidden = false;
  FolderSummaryDto? _folderSummary;
  bool _folderSummaryLoading = false;

  // Advanced & Permissions Tab state
  String _ownerInfo = 'Loading...';
  String _groupInfo = 'Loading...';
  final Map<String, Map<String, bool>> _permissionsGrid = {
    'owner': {'r': false, 'w': false, 'x': false},
    'group': {'r': false, 'w': false, 'x': false},
    'others': {'r': false, 'w': false, 'x': false},
  };

  // Storage & Integrity Tab state
  FileHashesDto? _hashes;
  bool _hashesLoading = false;
  String? _hashesError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  String _fmtSize(int bytes) {
    if (bytes == 0) return '0 B';
    return formatBytes(bytes, binary: widget.state.settings.sizeUnit == 'binary');
  }

  static String _fmtCount(int n) =>
      n.toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');

  static String _humanFileType(String mimeType, String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    final extLabel = ext.isNotEmpty ? ' (.$ext)' : '';
    final parts = mimeType.split('/');
    if (parts.length < 2) return ext.isNotEmpty ? '${ext.toUpperCase()} File' : 'File';
    final sub = parts[1].toLowerCase();
    final label = switch (sub) {
      'jpeg' || 'jpg'  => 'JPEG Image',
      'png'            => 'PNG Image',
      'gif'            => 'GIF Image',
      'webp'           => 'WebP Image',
      'svg+xml'        => 'SVG Image',
      'mp4'            => 'MPEG-4 Video',
      'x-matroska'     => 'Matroska Video',
      'webm'           => 'WebM Video',
      'mpeg'           => 'MPEG Video',
      'quicktime'      => 'QuickTime Video',
      'mpeg' || 'mp3'  => 'MP3 Audio',
      'ogg'            => 'OGG Audio',
      'flac'           => 'FLAC Audio',
      'wav'            => 'WAV Audio',
      'x-wav'          => 'WAV Audio',
      'aac'            => 'AAC Audio',
      'pdf'            => 'PDF Document',
      'zip'            => 'ZIP Archive',
      'x-tar'          => 'TAR Archive',
      'gzip'           => 'GZIP Archive',
      'x-7z-compressed' => '7-Zip Archive',
      'x-rar-compressed' || 'vnd.rar' => 'RAR Archive',
      'json'           => 'JSON File',
      'xml'            => 'XML File',
      'html' || 'xhtml+xml' => 'HTML File',
      'javascript'     => 'JavaScript File',
      'x-sh'           => 'Shell Script',
      'x-python'       => 'Python Script',
      'x-rust'         => 'Rust Source File',
      'x-c'            => 'C Source File',
      'x-c++'          => 'C++ Source File',
      'plain'          => 'Plain Text',
      'rtf'            => 'Rich Text',
      'vnd.ms-excel' || 'vnd.openxmlformats-officedocument.spreadsheetml.sheet' => 'Spreadsheet',
      'vnd.ms-powerpoint' || 'vnd.openxmlformats-officedocument.presentationml.presentation' => 'Presentation',
      'msword' || 'vnd.openxmlformats-officedocument.wordprocessingml.document' => 'Word Document',
      'x-executable' || 'x-elf' => 'Executable',
      _                => parts[0] == 'image'
          ? 'Image'
          : parts[0] == 'video'
              ? 'Video'
              : parts[0] == 'audio'
                  ? 'Audio'
                  : parts[0] == 'text'
                      ? 'Text File'
                      : ext.isNotEmpty
                          ? '${ext.toUpperCase()} File'
                          : 'File',
    };
    return '$label$extLabel';
  }

  Future<void> _load() async {
    final isNas = widget.state.viewMode == 'nas';
    if (widget.file.path.isEmpty) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = isNas
            ? 'File path unavailable. Trigger a rescan to update metadata.'
            : 'File path is empty.';
      });
      return;
    }
    try {
      final raw = await fs_api.getFileProperties(path: widget.file.path);
      VolumeInfoDto? vol;
      try {
        vol = await fs_api.getVolumeInfoForPath(path: widget.file.path);
      } catch (_) {}

      if (!mounted) return;
      setState(() {
        _props = raw;
        _volume = vol;
        _nameController.text = raw.name;
        _isReadOnly = !raw.permissions.contains('w');
        _isHidden = raw.name.startsWith('.');

        final p = raw.permissions;
        if (p.length == 9) {
          _permissionsGrid['owner'] = {'r': p[0] == 'r', 'w': p[1] == 'w', 'x': p[2] == 'x'};
          _permissionsGrid['group'] = {'r': p[3] == 'r', 'w': p[4] == 'w', 'x': p[5] == 'x'};
          _permissionsGrid['others'] = {'r': p[6] == 'r', 'w': p[7] == 'w', 'x': p[8] == 'x'};
        }
        _loading = false;
      });

      _loadOwnerGroup();

      if (raw.isDir) {
        _loadFolderSummary();
      }
    } catch (e) {
      if (!mounted) return;
      if (isNas) {
        // Show what we already know from the NAS listing instead of an error.
        final f = widget.file;
        setState(() {
          _props = FilePropertiesDto(
            name: f.name,
            absolutePath: f.path,
            isDir: f.isDir,
            isSymlink: f.isSymlink,
            symlinkTarget: null,
            size: f.size,
            modifiedSecs: f.modifiedSecs,
            createdSecs: f.createdSecs,
            accessedSecs: f.accessedSecs,
            permissions: '',
            mimeType: '',
          );
          _nameController.text = f.name;
          _isReadOnly = false;
          _isHidden = f.name.startsWith('.');
          _loading = false;
        });
        return;
      }
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _loadOwnerGroup() async {
    if (Platform.isWindows) return; // POSIX ownership not applicable on Windows
    try {
      // Linux uses -c with %U/%G; macOS uses -f with %Su/%Sg
      final args = Platform.isLinux
          ? ['-c', '%U (%u)|%G (%g)', widget.file.path]
          : ['-f', '%Su (%u)|%Sg (%g)', widget.file.path];
      final res = await Process.run('stat', args);
      if (res.exitCode == 0 && mounted) {
        final parts = res.stdout.toString().trim().split('|');
        if (parts.length == 2) {
          setState(() {
            _ownerInfo = parts[0];
            _groupInfo = parts[1];
          });
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _ownerInfo = 'unknown';
          _groupInfo = 'unknown';
        });
      }
    }
  }

  Future<void> _loadFolderSummary() async {
    setState(() => _folderSummaryLoading = true);
    try {
      final s = await fs_api.calculateFolderSummary(path: widget.file.path);
      if (!mounted) return;
      setState(() {
        _folderSummary = s;
        _folderSummaryLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _folderSummaryLoading = false);
    }
  }

  Future<void> _calculateHashes() async {
    setState(() {
      _hashesLoading = true;
      _hashesError = null;
    });
    try {
      final h = await fs_api.calculateFileHashes(path: widget.file.path);
      if (!mounted) return;
      setState(() {
        _hashes = h;
        _hashesLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _hashesError = e.toString();
        _hashesLoading = false;
      });
    }
  }

  Future<void> _save() async {
    final oldPath = widget.file.path;
    var finalName = _nameController.text.trim();
    if (finalName.isEmpty) finalName = widget.file.name;

    // Check hidden attribute dot prefix
    if (_isHidden && !finalName.startsWith('.')) {
      finalName = '.$finalName';
    } else if (!_isHidden && finalName.startsWith('.')) {
      while (finalName.startsWith('.')) {
        finalName = finalName.substring(1);
      }
      if (finalName.isEmpty) finalName = 'unnamed';
    }

    var currentPath = oldPath;
    if (finalName != widget.file.name) {
      try {
        final newPath = fs_api.fsRename(oldPath: oldPath, newName: finalName);
        currentPath = newPath;
      } catch (e) {
        // rename failed
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Rename failed: $e')),
        );
      }
    }

    // Convert permission grid checkboxes to octal chmod
    final oR = _permissionsGrid['owner']!['r']! ? 4 : 0;
    final oW = _permissionsGrid['owner']!['w']! ? 2 : 0;
    final oX = _permissionsGrid['owner']!['x']! ? 1 : 0;

    final gR = _permissionsGrid['group']!['r']! ? 4 : 0;
    final gW = _permissionsGrid['group']!['w']! ? 2 : 0;
    final gX = _permissionsGrid['group']!['x']! ? 1 : 0;

    final aR = _permissionsGrid['others']!['r']! ? 4 : 0;
    final aW = _permissionsGrid['others']!['w']! ? 2 : 0;
    final aX = _permissionsGrid['others']!['x']! ? 1 : 0;

    // If Read-only is checked, we drop all write flags
    var finalOW = _isReadOnly ? 0 : oW;
    var finalGW = _isReadOnly ? 0 : gW;
    var finalAW = _isReadOnly ? 0 : aW;

    final octal = '${oR + finalOW + oX}${gR + finalGW + gX}${aR + finalAW + aX}';

    if (Platform.isLinux || Platform.isMacOS) {
      try {
        await Process.run('chmod', [octal, currentPath]);
      } catch (_) {}
    }

    widget.state.refreshFileManager();
    widget.state.closeProperties();
  }

  String _formatDate(int secs) {
    if (secs == 0) return '—';
    final dt = DateTime.fromMillisecondsSinceEpoch(secs * 1000);
    // Format: Thursday, July 2, 2026, 03:15 PM
    final months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    final weekdays = [
      'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'
    ];

    final hour = dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    final minStr = dt.minute.toString().padLeft(2, '0');

    return '${weekdays[dt.weekday - 1]}, ${months[dt.month - 1]} ${dt.day}, ${dt.year}, ${hour.toString().padLeft(2, '0')}:$minStr $ampm';
  }

  @override
  Widget build(BuildContext context) {
    final tw = Tw(widget.state.colors);
    final colors = widget.state.colors;

    return GestureDetector(
      onTap: widget.state.closeProperties,
      child: ColoredBox(
        color: const Color(0x66000000),
        child: Center(
          child: GestureDetector(
            onTap: () {},
            child: Container(
              width: 520,
              constraints: const BoxConstraints(maxHeight: 620),
              margin: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: colors.panel,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: colors.line),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.25),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: _loading
                  ? Container(
                      height: 240,
                      alignment: Alignment.center,
                      child: CircularProgressIndicator(color: colors.brand),
                    )
                  : _error != null
                      ? Container(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(LucideIcons.alertTriangle, color: tw.red500, size: 40),
                              const SizedBox(height: 16),
                              Text(_error!, style: TextStyle(color: tw.red600, fontSize: 13)),
                              const SizedBox(height: 24),
                              ElevatedButton(
                                onPressed: widget.state.closeProperties,
                                child: const Text('Close'),
                              ),
                            ],
                          ),
                        )
                      : Column(
                          children: [
                            _buildHeader(tw),
                            const Divider(height: 1, thickness: 1),
                            _buildTabBar(tw),
                            const Divider(height: 1, thickness: 1),
                            Expanded(
                              child: Container(
                                color: colors.panel,
                                child: _buildTabBody(tw),
                              ),
                            ),
                            const Divider(height: 1, thickness: 1),
                            _buildFooter(tw),
                          ],
                        ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(Tw tw) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          FmFileIcon(
            name: widget.file.name,
            isDir: widget.file.isDir,
            folderPath: widget.file.path,
            customFolderIcons: widget.state.customFolderIcons,
            size: 48,
            square: true,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: TextField(
              controller: _nameController,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: tw.ink),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar(Tw tw) {
    return Container(
      color: tw.slate50,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          _buildTabButton(_PropertiesTab.general, 'General', tw),
          _buildTabButton(_PropertiesTab.advanced, 'Advanced & Permissions', tw),
          _buildTabButton(_PropertiesTab.storage, 'Storage & Integrity', tw),
        ],
      ),
    );
  }

  Widget _buildTabButton(_PropertiesTab tabType, String label, Tw tw) {
    final active = _activeTab == tabType;
    return InkWell(
      onTap: () => setState(() => _activeTab = tabType),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: active ? widget.state.colors.brand : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: active ? FontWeight.bold : FontWeight.w500,
            color: active ? widget.state.colors.brand : tw.slate500,
          ),
        ),
      ),
    );
  }

  Widget _buildTabBody(Tw tw) {
    switch (_activeTab) {
      case _PropertiesTab.general:
        return _buildGeneralTab(tw);
      case _PropertiesTab.advanced:
        return _buildAdvancedTab(tw);
      case _PropertiesTab.storage:
        return _buildStorageTab(tw);
    }
  }

  Widget _buildGeneralTab(Tw tw) {
    final p = _props!;
    final typeLabel = p.isDir
        ? 'Folder'
        : _humanFileType(p.mimeType, p.name);

    final totalSizeBytes = p.isDir ? _folderSummary?.totalSize.toInt() : p.size.toInt();
    final sizeStr = p.isDir
        ? (_folderSummaryLoading
            ? 'Calculating...'
            : (totalSizeBytes != null
                ? '${_fmtSize(totalSizeBytes)} (${_fmtCount(totalSizeBytes)} bytes)'
                : '—'))
        : '${_fmtSize(p.size.toInt())} (${_fmtCount(p.size.toInt())} bytes)';

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildInfoPair('Type of File', typeLabel, tw),
        _buildInfoPair('Location', p.absolutePath, tw, copyable: true),
        _buildInfoPair('Size', sizeStr, tw),
        if (p.isDir)
          _buildInfoPair(
            'Contains',
            _folderSummaryLoading
                ? 'Scanning subfolders...'
                : (_folderSummary != null
                    ? '${_fmtCount(_folderSummary!.fileCount.toInt())} files, ${_fmtCount(_folderSummary!.folderCount.toInt())} folders'
                    : '—'),
            tw,
          ),
        const SizedBox(height: 8),
        const Divider(),
        const SizedBox(height: 8),
        _buildInfoPair('Created', _formatDate(p.createdSecs.toInt()), tw),
        _buildInfoPair('Modified', _formatDate(p.modifiedSecs.toInt()), tw),
        _buildInfoPair('Accessed', _formatDate(p.accessedSecs.toInt()), tw),
        const SizedBox(height: 8),
        const Divider(),
        const SizedBox(height: 8),
        Row(
          children: [
            SizedBox(
              width: 120,
              child: Text(
                'Attributes',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: tw.slate500),
              ),
            ),
            Row(
              children: [
                Checkbox(
                  value: _isReadOnly,
                  onChanged: (val) => setState(() => _isReadOnly = val ?? false),
                ),
                Text('Read-only', style: TextStyle(fontSize: 12, color: tw.ink)),
                const SizedBox(width: 16),
                Checkbox(
                  value: _isHidden,
                  onChanged: (val) => setState(() => _isHidden = val ?? false),
                ),
                Text('Hidden', style: TextStyle(fontSize: 12, color: tw.ink)),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildAdvancedTab(Tw tw) {
    final p = _props!;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (Platform.isWindows) ...[
          Text(
            'POSIX permissions are not available on Windows.',
            style: TextStyle(fontSize: 12, color: tw.slate500),
          ),
        ] else ...[
          Row(
            children: [
              Expanded(child: _buildInfoPair('Owner', _ownerInfo, tw)),
              Expanded(child: _buildInfoPair('Group', _groupInfo, tw)),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Permissions Grid',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: tw.slate500),
          ),
          const SizedBox(height: 8),
          _buildPermissionsTable(tw),
        ],
        if (p.symlinkTarget != null) ...[
          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 8),
          _buildInfoPair('Symlink Target', p.symlinkTarget!, tw, copyable: true),
        ],
      ],
    );
  }

  Widget _buildPermissionsTable(Tw tw) {
    final borderCol = tw.slate200;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: borderCol),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Table(
        columnWidths: const {
          0: FlexColumnWidth(1.2),
          1: FlexColumnWidth(1.0),
          2: FlexColumnWidth(1.0),
          3: FlexColumnWidth(1.0),
        },
        border: TableBorder.symmetric(inside: BorderSide(color: borderCol)),
        children: [
          TableRow(
            decoration: BoxDecoration(color: tw.slate50),
            children: [
              _buildTableCell('', tw, header: true),
              _buildTableCell('Read', tw, header: true),
              _buildTableCell('Write', tw, header: true),
              _buildTableCell('Execute', tw, header: true),
            ],
          ),
          _buildPermissionTableRow('Owner', 'owner', tw),
          _buildPermissionTableRow('Group', 'group', tw),
          _buildPermissionTableRow('Others', 'others', tw),
        ],
      ),
    );
  }

  TableRow _buildPermissionTableRow(String label, String key, Tw tw) {
    return TableRow(
      children: [
        _buildTableCell(label, tw, bold: true),
        _buildCheckboxCell(key, 'r'),
        _buildCheckboxCell(key, 'w'),
        _buildCheckboxCell(key, 'x'),
      ],
    );
  }

  Widget _buildTableCell(String text, Tw tw, {bool header = false, bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Text(
        text,
        textAlign: header ? TextAlign.center : TextAlign.left,
        style: TextStyle(
          fontSize: 12,
          fontWeight: (header || bold) ? FontWeight.bold : FontWeight.normal,
          color: header ? tw.slate500 : tw.ink,
        ),
      ),
    );
  }

  Widget _buildCheckboxCell(String role, String permission) {
    return Center(
      child: SizedBox(
        height: 32,
        width: 32,
        child: Checkbox(
          value: _permissionsGrid[role]![permission],
          onChanged: (val) {
            setState(() {
              _permissionsGrid[role]![permission] = val ?? false;
            });
          },
        ),
      ),
    );
  }

  Widget _buildStorageTab(Tw tw) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'DISK / PARTITION INFO',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1.5, color: tw.slate400),
        ),
        const SizedBox(height: 12),
        if (_volume != null)
          FmVolumeUsageCard(
            tw: tw,
            device: _volume!.device,
            mountPath: _volume!.mountPath,
            fsType: _volume!.fsType,
            totalBytes: _volume!.totalBytes.toInt(),
            usedBytes: _volume!.usedBytes.toInt(),
            availableBytes: _volume!.availableBytes.toInt(),
            fmtSize: _fmtSize,
          )
        else
          Text('Partition details unavailable.', style: TextStyle(fontSize: 12, color: tw.slate400)),
        const SizedBox(height: 16),
        const Divider(),
        const SizedBox(height: 16),
        Text(
          'FILE CHECKSUMS (INTEGRITY)',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1.5, color: tw.slate400),
        ),
        const SizedBox(height: 12),
        if (_hashesLoading)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: widget.state.colors.brand),
                ),
                const SizedBox(width: 12),
                Text('Computing hashes...', style: TextStyle(fontSize: 12, color: tw.slate400)),
              ],
            ),
          )
        else if (_hashes != null) ...[
          _buildHashRow('MD5', _hashes!.md5, tw),
          const SizedBox(height: 8),
          _buildHashRow('SHA-256', _hashes!.sha256, tw),
        ] else ...[
          if (_hashesError != null) ...[
            Text(_hashesError!, style: TextStyle(fontSize: 12, color: tw.red500)),
            const SizedBox(height: 8),
          ],
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _calculateHashes,
              icon: Icon(LucideIcons.fingerprint, size: 14, color: widget.state.colors.brand),
              label: const Text('Calculate Checksums'),
              style: OutlinedButton.styleFrom(
                foregroundColor: widget.state.colors.brand,
                side: BorderSide(color: widget.state.colors.brand),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildHashRow(String label, String value, Tw tw) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: tw.slate500),
          ),
        ),
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: tw.slate50,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: tw.slate200),
            ),
            child: SelectableText(
              value,
              style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: tw.ink),
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: Icon(LucideIcons.copy, size: 14, color: tw.slate400),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: value));
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('$label copied to clipboard')),
            );
          },
          tooltip: 'Copy to clipboard',
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }

  Widget _buildInfoPair(String label, String value, Tw tw, {bool copyable = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: tw.slate500),
            ),
          ),
          Expanded(
            child: copyable
                ? Row(
                    children: [
                      Expanded(
                        child: SelectableText(
                          value,
                          style: TextStyle(fontSize: 12, color: tw.ink),
                        ),
                      ),
                      IconButton(
                        icon: Icon(LucideIcons.copy, size: 12, color: tw.slate400),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: value));
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('$label copied to clipboard')),
                          );
                        },
                        tooltip: 'Copy path',
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  )
                : SelectableText(
                    value,
                    style: TextStyle(fontSize: 12, color: tw.ink),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(Tw tw) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: tw.slate50,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          OutlinedButton(
            onPressed: widget.state.closeProperties,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(80, 32),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
            child: Text('Cancel', style: TextStyle(fontSize: 12, color: tw.slate600)),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _save,
            style: FilledButton.styleFrom(
              backgroundColor: widget.state.colors.brand,
              foregroundColor: tw.white,
              minimumSize: const Size(80, 32),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
            child: const Text('OK', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}