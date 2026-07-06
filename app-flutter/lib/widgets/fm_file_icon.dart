import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../utils/custom_folder_icons_store.dart';
import '../utils/file_icon_helpers.dart';

class FmFileIcon extends StatelessWidget {
  final String name;
  final bool isDir;
  final bool isSymlink;
  final String? folderPath;
  final Map<String, String> customFolderIcons;
  final double size;
  final bool square;

  const FmFileIcon({
    super.key,
    required this.name,
    required this.isDir,
    this.isSymlink = false,
    this.folderPath,
    this.customFolderIcons = const {},
    this.size = 28,
    this.square = false,
  });

  @override
  Widget build(BuildContext context) {
    final folderIconId = isDir
        ? resolveFolderIconId(
            path: folderPath ?? '',
            name: name,
            customIcons: customFolderIcons,
          )
        : null;
    final asset = fileIconAssetPath(
      name,
      isDir: isDir,
      folderIconId: folderIconId,
    );

    final icon = SvgPicture.asset(
      asset,
      width: size,
      height: size,
      fit: BoxFit.contain,
      placeholderBuilder: (_) => Icon(
        isDir ? LucideIcons.folder : LucideIcons.file,
        size: size * 0.85,
      ),
    );

    Widget result = icon;
    if (isSymlink) {
      final badgeSize = (size * 0.38).clamp(10.0, 20.0);
      result = Stack(
        clipBehavior: Clip.none,
        children: [
          icon,
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: badgeSize,
              height: badgeSize,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Icon(
                  LucideIcons.link,
                  size: badgeSize * 0.7,
                  color: const Color(0xFF64748B),
                ),
              ),
            ),
          ),
        ],
      );
    }

    if (!square) return result;

    return SizedBox(
      width: size,
      height: size,
      child: Center(child: result),
    );
  }
}