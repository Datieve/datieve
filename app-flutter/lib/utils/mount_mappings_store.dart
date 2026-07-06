import 'dart:convert';
import 'dart:io';

import 'app_dir.dart';

class MountMapping {
  final String nasPath;
  final String localPath;

  const MountMapping({required this.nasPath, required this.localPath});

  Map<String, String> toJson() => {'nasPath': nasPath, 'localPath': localPath};

  factory MountMapping.fromJson(Map<String, dynamic> json) => MountMapping(
        nasPath: json['nasPath']?.toString() ?? '',
        localPath: json['localPath']?.toString() ?? '',
      );
}


String _path() {
  return '${AppDir.basePath}/settings/mount-mappings.json';
}

List<MountMapping> loadMountMappings() {
  try {
    final file = File(_path());
    if (!file.existsSync()) return [];
    final raw = jsonDecode(file.readAsStringSync());
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((e) => MountMapping.fromJson(Map<String, dynamic>.from(e)))
        .where((m) => m.nasPath.isNotEmpty && m.localPath.isNotEmpty)
        .toList();
  } catch (_) {
    return [];
  }
}

void saveMountMappings(List<MountMapping> mappings) {
  try {
    final file = File(_path());
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(mappings.map((m) => m.toJson()).toList()));
  } catch (_) {}
}