import '../models/file_tag.dart';
import '../models/fm_search_filters.dart';
import '../src/rust/bridge.dart';
import 'file_type_helpers.dart';

const _unitBytes = {'KB': 1024, 'MB': 1048576, 'GB': 1073741824};

class VisibleFiles {
  final List<FileItemDto> folders;
  final List<FileItemDto> files;

  const VisibleFiles({required this.folders, required this.files});

  List<FileItemDto> get all => [...folders, ...files];
}

({int? after, int? before}) searchRangeToDate(String range) {
  final now = DateTime.now().millisecondsSinceEpoch;
  final today = DateTime.now();
  final todayStart = DateTime(today.year, today.month, today.day).millisecondsSinceEpoch;
  const hours = {
    'last_1h': 1,
    'last_24h': 24,
    'last_3d': 72,
    'last_7d': 168,
    'last_14d': 336,
    'last_30d': 720,
    'last_45d': 1080,
    'last_60d': 1440,
  };
  if (range == 'today') return (after: todayStart, before: null);
  if (hours.containsKey(range)) {
    return (after: now - hours[range]! * 3600000, before: null);
  }
  if (range == 'older_60d') {
    return (after: null, before: now - 60 * 86400000);
  }
  return (after: null, before: null);
}

bool entryMatchesTypeKind(FileItemDto entry, String kind) {
  if (kind == 'all') return true;
  if (kind == 'folders') return entry.isDir;
  if (kind == 'files') return !entry.isDir;
  if (entry.isDir) return false;
  final ext = entry.fileExt ?? entry.name.split('.').lastOrNull?.toLowerCase() ?? '';
  switch (kind) {
    case 'images':
      return isImage(entry.name);
    case 'documents':
      return {
        'pdf', 'txt', 'md', 'rst', 'log', 'doc', 'docx', 'odt', 'rtf',
        'xls', 'xlsx', 'csv', 'ods', 'ppt', 'pptx',
      }.contains(ext);
    case 'media':
      return {
        'mp3', 'flac', 'wav', 'ogg', 'm4a', 'aac', 'opus',
        'mp4', 'mkv', 'avi', 'mov', 'wmv', 'webm', 'm4v',
      }.contains(ext);
    case 'archives':
      return isArchive(entry.name);
    default:
      return true;
  }
}

bool entryMatchesFilters(FileItemDto entry, FmSearchFilters filters) {
  if (!entryMatchesTypeKind(entry, filters.typeKind)) return false;
  final size = entry.size.toInt();
  if (!entry.isDir && filters.sizeMinVal.isNotEmpty) {
    final min = double.tryParse(filters.sizeMinVal);
    final unit = _unitBytes[filters.sizeMinUnit] ?? 1048576;
    if (min != null && size < (min * unit).round()) return false;
  }
  if (!entry.isDir && filters.sizeMaxVal.isNotEmpty) {
    final max = double.tryParse(filters.sizeMaxVal);
    final unit = _unitBytes[filters.sizeMaxUnit] ?? 1048576;
    if (max != null && size > (max * unit).round()) return false;
  }
  final created = entry.createdSecs.toInt() * 1000;
  final modified = entry.modifiedSecs.toInt() * 1000;
  final createdRange = searchRangeToDate(filters.createdRange);
  final modifiedRange = searchRangeToDate(filters.modifiedRange);
  if (createdRange.after != null && (created == 0 || created < createdRange.after!)) {
    return false;
  }
  if (createdRange.before != null && (created == 0 || created > createdRange.before!)) {
    return false;
  }
  if (modifiedRange.after != null && (modified == 0 || modified < modifiedRange.after!)) {
    return false;
  }
  if (modifiedRange.before != null && (modified == 0 || modified > modifiedRange.before!)) {
    return false;
  }
  return true;
}

String firstTagName(
  FileItemDto entry,
  Map<String, List<String>> tagAssignments,
  List<FileTag> fileTags,
) {
  final ids = tagAssignments[entry.path] ?? [];
  if (ids.isEmpty) return '';
  final tag = fileTags.where((t) => t.id == ids.first).firstOrNull;
  return tag?.name ?? '';
}

int compareFiles(
  FileItemDto a,
  FileItemDto b, {
  required String sortBy,
  required String sortDir,
  required Map<String, List<String>> tagAssignments,
  required List<FileTag> fileTags,
}) {
  var cmp = 0;
  switch (sortBy) {
    case 'name':
      cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    case 'modified':
      cmp = a.modifiedSecs.compareTo(b.modifiedSecs);
    case 'created':
      cmp = a.createdSecs.compareTo(b.createdSecs);
    case 'size':
      cmp = a.size.compareTo(b.size);
    case 'type':
      cmp = (a.itemType).compareTo(b.itemType);
      if (cmp == 0) cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    case 'tag':
      cmp = firstTagName(a, tagAssignments, fileTags)
          .compareTo(firstTagName(b, tagAssignments, fileTags));
      if (cmp == 0) cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    default:
      cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }
  return sortDir == 'desc' ? -cmp : cmp;
}

String groupLabel(
  FileItemDto entry, {
  required String groupBy,
  required Map<String, List<String>> tagAssignments,
  required List<FileTag> fileTags,
}) {
  if (groupBy == 'none') return '';
  if (groupBy == 'name') {
    final ch = entry.name.isNotEmpty ? entry.name[0].toUpperCase() : '#';
    return RegExp(r'[A-Z]').hasMatch(ch) ? ch : '#';
  }
  if (groupBy == 'type') {
    return entry.isDir ? 'Folders' : (entry.itemType.isNotEmpty ? entry.itemType : 'Files');
  }
  if (groupBy == 'tag') {
    final name = firstTagName(entry, tagAssignments, fileTags);
    return name.isEmpty ? 'Untagged' : name;
  }
  if (groupBy == 'size') {
    if (entry.isDir) return 'Folders';
    final sz = entry.size.toInt();
    if (sz < 1024) return 'Under 1 KB';
    if (sz < 1048576) return '1 KB – 1 MB';
    if (sz < 104857600) return '1 MB – 100 MB';
    return 'Over 100 MB';
  }
  final secs = (groupBy == 'created' ? entry.createdSecs : entry.modifiedSecs).toInt();
  if (secs == 0) return 'Unknown';
  final dt = DateTime.fromMillisecondsSinceEpoch(secs * 1000);
  return '${dt.year}-${dt.month.toString().padLeft(2, '0')}';
}

VisibleFiles computeVisibleFiles({
  required List<FileItemDto> source,
  required bool showHidden,
  required String localSearchMode,
  required List<FileItemDto> searchResults,
  required FmSearchFilters filters,
  required String sortBy,
  required String sortDir,
  required bool foldersFirst,
  required Map<String, List<String>> tagAssignments,
  required List<FileTag> fileTags,
  int renderedSearchCount = 300,
}) {
  final resultMode = localSearchMode == 'recursive' || localSearchMode == 'tag';
  final all = resultMode
      ? searchResults
      : (showHidden ? source : source.where((e) => !e.isHidden).toList());
  final filtered = all.where((e) => entryMatchesFilters(e, filters)).toList();

  int sortFn(FileItemDto a, FileItemDto b) => compareFiles(
        a,
        b,
        sortBy: sortBy,
        sortDir: sortDir,
        tagAssignments: tagAssignments,
        fileTags: fileTags,
      );

  final folders = filtered.where((e) => e.isDir).toList()..sort(sortFn);
  final files = filtered.where((e) => !e.isDir).toList()..sort(sortFn);

  if (resultMode) {
    final combined = [...folders, ...files];
    return VisibleFiles(
      folders: const [],
      files: combined.take(renderedSearchCount).toList(),
    );
  }
  if (foldersFirst) {
    return VisibleFiles(folders: folders, files: files);
  }
  final combined = [...filtered]..sort(sortFn);
  return VisibleFiles(folders: const [], files: combined);
}