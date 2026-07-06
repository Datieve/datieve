import 'dart:ui';

Offset menuPosition({
  required double x,
  required double y,
  required double menuW,
  required Size viewport,
  double bottomMargin = 160,
}) {
  final flipX = x + menuW > viewport.width - 4;
  final left = (flipX ? x - menuW : x).clamp(4.0, viewport.width - menuW - 4);
  final flipY = viewport.height - y < bottomMargin;
  final top = flipY ? null : y;
  final bottom = flipY ? viewport.height - y : null;
  return Offset(left, top ?? (bottom != null ? 0 : y));
}

class MenuPlacement {
  final double left;
  final double? top;
  final double? bottom;
  final double maxHeight;

  const MenuPlacement({
    required this.left,
    this.top,
    this.bottom,
    required this.maxHeight,
  });
}

MenuPlacement computeMenuPlacement({
  required double x,
  required double y,
  required double menuW,
  required Size viewport,
}) {
  final flipX = x + menuW > viewport.width - 4;
  final flipY = viewport.height - y < 160;
  final left = (flipX ? x - menuW : x).clamp(4.0, viewport.width - menuW - 4);
  final maxHeight = flipY ? y - 8 : viewport.height - y - 8;
  if (flipY) {
    return MenuPlacement(left: left, bottom: viewport.height - y, maxHeight: maxHeight);
  }
  return MenuPlacement(left: left, top: y, maxHeight: maxHeight);
}