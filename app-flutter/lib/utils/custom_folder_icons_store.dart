import 'dart:convert';
import 'dart:io';
import 'app_dir.dart';

String _storePath() {
  return '${AppDir.basePath}/settings/custom_folder_icons.json';
}

Map<String, String> loadCustomFolderIcons() {
  try {
    final raw = jsonDecode(File(_storePath()).readAsStringSync());
    if (raw is! Map) return {};
    return raw.map((k, v) => MapEntry(k.toString(), v.toString()));
  } catch (_) {
    return {};
  }
}

void saveCustomFolderIcons(Map<String, String> icons) {
  try {
    final file = File(_storePath());
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(icons));
  } catch (_) {}
}

const papirusFolderIcons = <({String id, String label, String description})>[
  (id: 'papirus-folder', label: 'Default', description: 'Standard yellow'),
  (id: 'papirus-folder-documents', label: 'Documents', description: 'Documents'),
  (id: 'papirus-folder-download', label: 'Downloads', description: 'Downloads'),
  (id: 'papirus-folder-pictures', label: 'Pictures', description: 'Photos'),
  (id: 'papirus-folder-music', label: 'Music', description: 'Music'),
  (id: 'papirus-folder-videos', label: 'Videos', description: 'Videos'),
  (id: 'papirus-folder-desktop', label: 'Desktop', description: 'Desktop'),
  (id: 'papirus-folder-public', label: 'Public', description: 'Shared'),
  (id: 'papirus-folder-code', label: 'Code', description: 'Developer'),
  (id: 'papirus-folder-cloud', label: 'Cloud', description: 'Cloud sync'),
  (id: 'papirus-folder-games', label: 'Games', description: 'Games'),
  (id: 'papirus-folder-bookmark', label: 'Bookmark', description: 'Bookmark'),
  (id: 'papirus-folder-templates', label: 'Templates', description: 'Templates'),
];

const _folderNameHeuristics = <String, String>{
  'pictures': 'papirus-folder-pictures',
  'photos': 'papirus-folder-pictures',
  'images': 'papirus-folder-pictures',
  'music': 'papirus-folder-music',
  'audio': 'papirus-folder-music',
  'videos': 'papirus-folder-videos',
  'movies': 'papirus-folder-videos',
  'downloads': 'papirus-folder-download',
  'download': 'papirus-folder-download',
  'documents': 'papirus-folder-documents',
  'docs': 'papirus-folder-documents',
  'desktop': 'papirus-folder-desktop',
  'public': 'papirus-folder-public',
  'cloud': 'papirus-folder-cloud',
  'games': 'papirus-folder-games',
  'code': 'papirus-folder-code',
  'src': 'papirus-folder-code',
  'templates': 'papirus-folder-templates',
};

String normalizeFolderIconId(String? id) {
  var iconId = id ?? 'papirus-folder';
  if (iconId.startsWith('mac-')) {
    iconId = iconId.replaceFirst('mac-', 'papirus-');
  }
  if (!iconId.startsWith('papirus-')) {
    iconId = 'papirus-folder';
  }
  return iconId;
}

String resolveFolderIconId({
  required String path,
  required String name,
  required Map<String, String> customIcons,
}) {
  final custom = customIcons[path];
  if (custom != null && custom.isNotEmpty) {
    return normalizeFolderIconId(custom);
  }
  final lower = name.toLowerCase();
  for (final entry in _folderNameHeuristics.entries) {
    if (lower == entry.key || lower.contains(entry.key)) {
      return entry.value;
    }
  }
  return 'papirus-folder';
}

