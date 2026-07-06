import 'dart:convert';
import 'dart:io';
import 'app_dir.dart';

String _hiddenDevicesPath() {
  return '${AppDir.basePath}/settings/hidden-devices.json';
}

Set<String> loadHiddenDevices() {
  try {
    final file = File(_hiddenDevicesPath());
    if (!file.existsSync()) return {};
    final raw = jsonDecode(file.readAsStringSync());
    if (raw is! List) return {};
    return raw.map((e) => e.toString()).toSet();
  } catch (_) {
    return {};
  }
}

void saveHiddenDevices(Set<String> paths) {
  try {
    final file = File(_hiddenDevicesPath());
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(paths.toList()));
  } catch (_) {}
}