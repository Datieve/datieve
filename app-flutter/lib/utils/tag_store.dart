import 'dart:convert';
import 'dart:io';

import '../models/file_tag.dart';

import 'app_dir.dart';

String _tagStorePath(String file) {
  return '${AppDir.basePath}/settings/$file';
}

List<FileTag> loadFileTags() {
  try {
    final raw = jsonDecode(File(_tagStorePath('file_tags.json')).readAsStringSync());
    if (raw is! List || raw.isEmpty) return defaultFileTags();
    return raw
        .whereType<Map>()
        .map((e) => FileTag.fromJson(Map<String, dynamic>.from(e)))
        .where((t) => t.id.isNotEmpty)
        .toList();
  } catch (_) {
    return defaultFileTags();
  }
}

void saveFileTags(List<FileTag> tags) {
  try {
    final file = File(_tagStorePath('file_tags.json'));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(tags.map((t) => t.toJson()).toList()));
  } catch (_) {}
}

Map<String, List<String>> loadTagAssignments() {
  try {
    final raw = jsonDecode(File(_tagStorePath('tag_assignments.json')).readAsStringSync());
    if (raw is! Map) return {};
    return raw.map(
      (key, value) => MapEntry(
        key.toString(),
        (value as List?)?.map((e) => e.toString()).toList() ?? [],
      ),
    );
  } catch (_) {
    return {};
  }
}

void saveTagAssignments(Map<String, List<String>> assignments) {
  try {
    final file = File(_tagStorePath('tag_assignments.json'));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(assignments));
  } catch (_) {}
}

String normalizeTagPath(String path) {
  final trimmed = path.trim().replaceAll(RegExp(r'/+$'), '');
  return trimmed.isEmpty ? '/' : trimmed;
}