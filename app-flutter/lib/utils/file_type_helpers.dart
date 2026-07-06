bool isImage(String name) {
  final ext = name.split('.').lastOrNull?.toLowerCase() ?? '';
  return {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'svg', 'ico', 'tiff', 'tif'}
      .contains(ext);
}

bool isTextPreviewable(String name) {
  final ext = name.split('.').lastOrNull?.toLowerCase() ?? '';
  return {
    'txt', 'md', 'rst', 'log', 'json', 'yaml', 'yml', 'toml', 'xml', 'html',
    'htm', 'css', 'js', 'ts', 'jsx', 'tsx', 'py', 'rs', 'go', 'java', 'c',
    'cpp', 'h', 'hpp', 'sh', 'bash', 'zsh', 'sql', 'ini', 'cfg', 'conf',
    'env', 'csv', 'tsv', 'svg',
  }.contains(ext);
}

bool isVideo(String name) {
  final ext = name.split('.').lastOrNull?.toLowerCase() ?? '';
  return {'mp4', 'mkv', 'avi', 'mov', 'wmv', 'webm', 'm4v', 'ogv'}.contains(ext);
}

bool isArchive(String name) {
  final lower = name.toLowerCase();
  return lower.endsWith('.zip') ||
      lower.endsWith('.7z') ||
      lower.endsWith('.tar') ||
      lower.endsWith('.tar.gz') ||
      lower.endsWith('.tgz') ||
      lower.endsWith('.rar');
}