import 'dart:convert';
import 'dart:io';

import 'app_dir.dart';

class TrashSettings {
  final int autoDeleteDays;

  const TrashSettings({this.autoDeleteDays = 30});

  bool get autoDeleteEnabled => autoDeleteDays > 0;

  TrashSettings copyWith({int? autoDeleteDays}) =>
      TrashSettings(autoDeleteDays: autoDeleteDays ?? this.autoDeleteDays);

  Map<String, dynamic> toJson() => {'autoDeleteDays': autoDeleteDays};

  factory TrashSettings.fromJson(Map<String, dynamic> json) => TrashSettings(
        autoDeleteDays: (json['autoDeleteDays'] as num?)?.toInt() ?? 30,
      );
}


String _storePath() {
  return '${AppDir.basePath}/settings/trash_settings.json';
}

TrashSettings loadTrashSettings() {
  try {
    final raw = jsonDecode(File(_storePath()).readAsStringSync());
    if (raw is! Map) return const TrashSettings();
    return TrashSettings.fromJson(Map<String, dynamic>.from(raw));
  } catch (_) {
    return const TrashSettings();
  }
}

void saveTrashSettings(TrashSettings settings) {
  try {
    final file = File(_storePath());
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(settings.toJson()));
  } catch (_) {}
}