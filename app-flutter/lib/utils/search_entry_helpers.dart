import '../src/rust/bridge.dart';
import 'format_bytes.dart';

FileItemDto searchEntryToFileItem(SearchEntryDto e) {
  final detail = e.isDir
      ? (e.isSymlink ? 'Linked Folder' : 'Folder')
      : formatBytes(e.size.toDouble());
  return FileItemDto(
    name: e.name,
    path: e.absolutePath,
    detail: detail,
    isDir: e.isDir,
    isSymlink: e.isSymlink,
    size: e.size,
    modifiedSecs: e.modifiedSecs,
    createdSecs: e.createdSecs,
    accessedSecs: e.accessedSecs,
    isHidden: e.isHidden,
    fileExt: e.fileExt,
    itemType: e.itemType,
    parentPath: e.parentPath,
  );
}