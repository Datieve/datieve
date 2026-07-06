import 'dart:convert';
import 'dart:io';

import 'app_dir.dart';

String _aliasesPath() {
  return '${AppDir.basePath}/settings/places-aliases.json';
}

String _hiddenPath() {
  return '${AppDir.basePath}/settings/hidden-places.json';
}

Map<String, String> loadPlacesAliases() {
  try {
    final file = File(_aliasesPath());
    if (!file.existsSync()) return {};
    final raw = jsonDecode(file.readAsStringSync());
    if (raw is! Map) return {};
    return raw.map((k, v) => MapEntry(k.toString(), v.toString()));
  } catch (_) {
    return {};
  }
}

void savePlacesAliases(Map<String, String> aliases) {
  try {
    final file = File(_aliasesPath());
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(aliases));
  } catch (_) {}
}

Set<String> loadHiddenPlaces() {
  try {
    final file = File(_hiddenPath());
    if (!file.existsSync()) return {};
    final raw = jsonDecode(file.readAsStringSync());
    if (raw is! List) return {};
    return raw.map((e) => e.toString()).toSet();
  } catch (_) {
    return {};
  }
}

void saveHiddenPlaces(Set<String> paths) {
  try {
    final file = File(_hiddenPath());
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(paths.toList()));
  } catch (_) {}
}