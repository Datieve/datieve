import 'dart:convert';
import 'dart:io';

import '../models/bookmark.dart';
import 'app_dir.dart';

String _bookmarksPath() {
  return '${AppDir.basePath}/settings/bookmarks.json';
}

List<Bookmark> loadBookmarks() {
  try {
    final file = File(_bookmarksPath());
    if (!file.existsSync()) return [];
    final raw = jsonDecode(file.readAsStringSync());
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((e) => Bookmark.fromJson(Map<String, dynamic>.from(e)))
        .where((b) => b.path.isNotEmpty)
        .toList();
  } catch (_) {
    return [];
  }
}

void saveBookmarks(List<Bookmark> bookmarks) {
  try {
    final path = _bookmarksPath();
    final file = File(path);
    file.parent.createSync(recursive: true);
    final json = jsonEncode(bookmarks.map((b) => b.toJson()).toList());
    file.writeAsStringSync(json);
  } catch (_) {}
}