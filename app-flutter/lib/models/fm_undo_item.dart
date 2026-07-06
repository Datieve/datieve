class FmUndoItem {
  final String type; // 'rename', 'trash', 'move', 'copy'
  final String? newPath;
  final String? oldName;
  final List<String>? paths;
  final String? srcDir;
  final String? destDir;

  const FmUndoItem._({
    required this.type,
    this.newPath,
    this.oldName,
    this.paths,
    this.srcDir,
    this.destDir,
  });

  const FmUndoItem.rename({required String newPath, required String oldName})
      : this._(type: 'rename', newPath: newPath, oldName: oldName);

  const FmUndoItem.trash({required List<String> paths})
      : this._(type: 'trash', paths: paths);

  /// [paths] = file/dir names (not full paths), moved from [srcDir] to [destDir].
  const FmUndoItem.move({
    required List<String> names,
    required String srcDir,
    required String destDir,
  }) : this._(type: 'move', paths: names, srcDir: srcDir, destDir: destDir);

  /// [paths] = file/dir names copied into [destDir]. Undo = delete from destDir.
  const FmUndoItem.copy({required List<String> names, required String destDir})
      : this._(type: 'copy', paths: names, destDir: destDir);
}
