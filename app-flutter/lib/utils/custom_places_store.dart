import 'dart:convert';
import 'dart:io';

import 'app_dir.dart';

class CustomPlace {
  final String label;
  final String path;
  const CustomPlace({required this.label, required this.path});
  Map<String, dynamic> toJson() => {'label': label, 'path': path};
  static CustomPlace fromJson(Map<String, dynamic> e) => CustomPlace(
        label: e['label'] as String? ?? '',
        path: e['path'] as String? ?? '',
      );
}

String _customPlacesPath() =>
    '${AppDir.basePath}/settings/custom-places.json';

List<CustomPlace> loadCustomPlaces() {
  try {
    final file = File(_customPlacesPath());
    if (!file.existsSync()) return [];
    final raw = jsonDecode(file.readAsStringSync());
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((e) => CustomPlace.fromJson(Map<String, dynamic>.from(e)))
        .where((p) => p.path.isNotEmpty)
        .toList();
  } catch (_) {
    return [];
  }
}

void saveCustomPlaces(List<CustomPlace> places) {
  try {
    final file = File(_customPlacesPath());
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(places.map((p) => p.toJson()).toList()));
  } catch (_) {}
}
