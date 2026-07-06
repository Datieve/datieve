import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../src/rust/api/fs.dart' as fs_api;
import '../utils/file_type_helpers.dart';

const _maxThumbCacheEntries = 200;
final _thumbCache = <String, Uint8List>{};

class FmThumbnail extends StatefulWidget {
  final String path;
  final double size;
  final Widget fallback;

  const FmThumbnail({
    super.key,
    required this.path,
    required this.size,
    required this.fallback,
  });

  @override
  State<FmThumbnail> createState() => _FmThumbnailState();
}

class _FmThumbnailState extends State<FmThumbnail> {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(FmThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _failed = false;
      _bytes = _thumbCache[widget.path];
      if (_bytes == null) _load();
    }
  }

  Future<void> _load() async {
    final name = widget.path.split('/').last;
    if (!isImage(name)) return;
    final cached = _thumbCache[widget.path];
    if (cached != null) {
      setState(() => _bytes = cached);
      return;
    }
    final requestedPath = widget.path;
    try {
      final dataUrl = await fs_api.readImageThumbnail(path: requestedPath);
      // The tile may have been recycled to a different path (or disposed)
      // while the decode was in flight — drop stale results.
      if (!mounted || widget.path != requestedPath) return;
      final comma = dataUrl.indexOf(',');
      if (comma < 0) return;
      final bytes = base64Decode(dataUrl.substring(comma + 1));
      if (_thumbCache.length >= _maxThumbCacheEntries) {
        _thumbCache.remove(_thumbCache.keys.first);
      }
      _thumbCache[requestedPath] = bytes;
      setState(() => _bytes = bytes);
    } catch (_) {
      if (mounted && widget.path == requestedPath) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes != null && !_failed) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.memory(
          _bytes!,
          width: widget.size,
          height: widget.size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => widget.fallback,
        ),
      );
    }
    return widget.fallback;
  }
}