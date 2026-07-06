import '../src/rust/bridge.dart';

class LocalCtxMenu {
  final FileItemDto file;
  final double x;
  final double y;

  const LocalCtxMenu({
    required this.file,
    required this.x,
    required this.y,
  });
}

class EmptyCtxMenu {
  final double x;
  final double y;

  const EmptyCtxMenu({required this.x, required this.y});
}

class NasCtxMenu {
  final FileItemDto file;
  final String type;
  final double x;
  final double y;

  const NasCtxMenu({
    required this.file,
    required this.type,
    required this.x,
    required this.y,
  });
}

class TabCtxMenu {
  final String id;
  final double x;
  final double y;

  const TabCtxMenu({required this.id, required this.x, required this.y});
}

class SidebarCtxMenu {
  final String type;
  final String key;
  final String label;
  final String? path;
  final double x;
  final double y;

  const SidebarCtxMenu({
    required this.type,
    required this.key,
    required this.label,
    this.path,
    required this.x,
    required this.y,
  });
}