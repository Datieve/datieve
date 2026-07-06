import 'dart:io';
import 'dart:typed_data';

/// Permanently deletes trash items older than [maxAgeDays]. Returns count removed.
/// Supports Linux (XDG Trash), Windows ($Recycle.Bin), and macOS (~/.Trash).
int purgeOldTrashItems({required int maxAgeDays}) {
  if (maxAgeDays <= 0) return 0;
  final cutoff = DateTime.now().subtract(Duration(days: maxAgeDays));

  if (Platform.isLinux) return _purgeLinux(cutoff);
  if (Platform.isWindows) return _purgeWindows(cutoff);
  if (Platform.isMacOS) return _purgeMacos(cutoff);
  return 0;
}

// ── Linux / XDG ───────────────────────────────────────────────────────────────

int _purgeLinux(DateTime cutoff) {
  final home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) return 0;

  final base = Directory('$home/.local/share/Trash');
  final filesDir = Directory('${base.path}/files');
  final infoDir = Directory('${base.path}/info');
  if (!infoDir.existsSync()) return 0;

  var removed = 0;
  for (final entity in infoDir.listSync()) {
    if (entity is! File || !entity.path.endsWith('.trashinfo')) continue;
    final deletion = _parseXdgDeletionDate(entity.readAsStringSync());
    if (deletion == null || !deletion.isBefore(cutoff)) continue;

    final baseName = entity.uri.pathSegments.last.replaceAll('.trashinfo', '');
    final itemPath = '${filesDir.path}/$baseName';
    try {
      final kind = FileSystemEntity.typeSync(itemPath);
      if (kind == FileSystemEntityType.directory) {
        Directory(itemPath).deleteSync(recursive: true);
      } else if (kind == FileSystemEntityType.file) {
        File(itemPath).deleteSync();
      }
      entity.deleteSync();
      removed++;
    } catch (_) {}
  }
  return removed;
}

DateTime? _parseXdgDeletionDate(String content) {
  for (final line in content.split('\n')) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('DeletionDate=')) continue;
    final raw = trimmed.substring('DeletionDate='.length).trim();
    if (raw.length < 15) continue;
    try {
      return DateTime(
        int.parse(raw.substring(0, 4)),
        int.parse(raw.substring(4, 6)),
        int.parse(raw.substring(6, 8)),
        int.parse(raw.substring(9, 11)),
        int.parse(raw.substring(11, 13)),
        int.parse(raw.substring(13, 15)),
      );
    } catch (_) {
      return null;
    }
  }
  return null;
}

// ── Windows / $Recycle.Bin ────────────────────────────────────────────────────

int _purgeWindows(DateTime cutoff) {
  final sysDrive = Platform.environment['SYSTEMDRIVE'] ?? 'C:';
  final base = Directory('$sysDrive\\\$Recycle.Bin');
  if (!base.existsSync()) return 0;

  // Find the current user's SID subdirectory (first readable one).
  Directory? sidDir;
  try {
    for (final entry in base.listSync()) {
      if (entry is Directory) {
        try {
          entry.listSync(); // probe readability
          sidDir = entry;
          break;
        } catch (_) {}
      }
    }
  } catch (_) {}
  if (sidDir == null) return 0;

  var removed = 0;
  try {
    for (final entity in sidDir.listSync()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      // $I files hold metadata; $R files hold content.
      if (!name.startsWith('\$I') && !name.startsWith('\$i')) continue;

      final deletion = _parseWindowsIFileDeletion(entity);
      if (deletion == null || !deletion.isBefore(cutoff)) continue;

      // Corresponding content file: replace $I prefix with $R
      final rName = '\$R${name.substring(2)}';
      final rPath = '${sidDir!.path}\\$rName';
      try {
        final kind = FileSystemEntity.typeSync(rPath);
        if (kind == FileSystemEntityType.directory) {
          Directory(rPath).deleteSync(recursive: true);
        } else if (kind == FileSystemEntityType.file) {
          File(rPath).deleteSync();
        }
        entity.deleteSync(); // delete $I after $R
        removed++;
      } catch (_) {}
    }
  } catch (_) {}
  return removed;
}

// Windows FILETIME epoch: 100-ns intervals since 1601-01-01.
// Unix epoch offset: 11644473600 seconds.
const _windowsEpochOffset = 11644473600;

DateTime? _parseWindowsIFileDeletion(File iFile) {
  try {
    final bytes = iFile.readAsBytesSync();
    if (bytes.length < 24) return null;
    final byteData = ByteData.sublistView(Uint8List.fromList(bytes));
    final filetime = byteData.getUint64(16, Endian.little);
    if (filetime == 0) return null;
    final unixSeconds = (filetime ~/ 10000000) - _windowsEpochOffset;
    return DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000, isUtc: true).toLocal();
  } catch (_) {
    return null;
  }
}

// ── macOS / ~/.Trash ──────────────────────────────────────────────────────────

int _purgeMacos(DateTime cutoff) {
  final home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) return 0;

  final trashDir = Directory('$home/.Trash');
  if (!trashDir.existsSync()) return 0;

  var removed = 0;
  try {
    for (final entity in trashDir.listSync()) {
      // macOS doesn't store deletion metadata; use file mtime as a proxy.
      final stat = entity.statSync();
      if (!stat.modified.isBefore(cutoff)) continue;
      try {
        if (entity is Directory) {
          entity.deleteSync(recursive: true);
        } else {
          entity.deleteSync();
        }
        removed++;
      } catch (_) {}
    }
  } catch (_) {}
  return removed;
}
