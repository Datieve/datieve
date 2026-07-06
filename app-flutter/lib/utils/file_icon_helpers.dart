// Material Icon Theme file icons — ported from the original Datieve App.tsx system.
// Folders use Papirus SVGs; files use extension/name-mapped material icons.

const extToIcon = <String, String>{
  'py': 'python', 'pyw': 'python', 'pyi': 'python',
  'rs': 'rust',
  'js': 'javascript', 'mjs': 'javascript', 'cjs': 'javascript',
  'ts': 'typescript', 'mts': 'typescript',
  'jsx': 'jsx', 'tsx': 'tsx',
  'html': 'html', 'htm': 'html',
  'css': 'css', 'scss': 'scss', 'sass': 'sass', 'less': 'less', 'styl': 'stylus',
  'json': 'json', 'jsonc': 'json', 'json5': 'json',
  'yaml': 'yaml', 'yml': 'yaml',
  'xml': 'xml', 'xsd': 'xml', 'xsl': 'xml',
  'graphql': 'graphql', 'gql': 'graphql',
  'toml': 'toml', 'proto': 'proto', 'nix': 'nix',
  'md': 'markdown', 'mdx': 'markdown', 'markdown': 'markdown', 'rst': 'markdown',
  'pdf': 'pdf',
  'doc': 'word', 'docx': 'word', 'odt': 'word', 'rtf': 'word',
  'xls': 'excel', 'xlsx': 'excel', 'ods': 'excel', 'csv': 'csv',
  'ppt': 'powerpoint', 'pptx': 'powerpoint', 'odp': 'powerpoint',
  'txt': 'txt',
  'log': 'log',
  'mp4': 'video', 'mkv': 'video', 'avi': 'video', 'mov': 'video',
  'wmv': 'video', 'flv': 'video', 'webm': 'video', 'm4v': 'video', 'mpeg': 'video',
  'mp3': 'audio', 'flac': 'audio', 'wav': 'audio', 'ogg': 'audio',
  'm4a': 'audio', 'aac': 'audio', 'opus': 'audio', 'wma': 'audio', 'aiff': 'audio',
  'jpg': 'image', 'jpeg': 'image', 'png': 'image', 'gif': 'image',
  'webp': 'image', 'ico': 'image', 'bmp': 'image', 'tiff': 'image', 'avif': 'image',
  'svg': 'svg', 'heic': 'image',
  'zip': 'zip', 'tar': 'zip', 'gz': 'zip', 'bz2': 'zip', 'xz': 'zip',
  '7z': 'archive', 'rar': 'archive', 'zst': 'zip', 'lz4': 'zip',
  'deb': 'zip', 'rpm': 'zip', 'appimage': 'zip',
  'c': 'c', 'h': 'c',
  'cpp': 'cpp', 'cc': 'cpp', 'cxx': 'cpp', 'hpp': 'cpp',
  'cs': 'csharp', 'java': 'java', 'class': 'java', 'jar': 'java',
  'go': 'go', 'php': 'php', 'rb': 'ruby', 'rake': 'ruby',
  'swift': 'swift', 'kt': 'kotlin', 'kts': 'kotlin',
  'scala': 'scala', 'lua': 'lua', 'pl': 'perl', 'pm': 'perl',
  'r': 'r', 'hs': 'haskell', 'ex': 'elixir', 'exs': 'elixir',
  'dart': 'dart', 'vue': 'vue', 'svelte': 'svelte',
  'sh': 'shell', 'bash': 'bash', 'zsh': 'bash', 'fish': 'bash',
  'ps1': 'powershell', 'psm1': 'powershell', 'bat': 'powershell', 'cmd': 'powershell',
  'sql': 'database', 'sqlite': 'database', 'db': 'database',
  'dockerfile': 'docker', 'tf': 'terraform', 'tfvars': 'terraform',
  'env': 'env', 'lock': 'lock',
  'pem': 'key', 'crt': 'certificate', 'cer': 'certificate', 'key': 'key', 'p12': 'certificate',
  'ipynb': 'notebook', 'wasm': 'wasm',
  'ttf': 'font', 'otf': 'font', 'woff': 'font', 'woff2': 'font', 'eot': 'font',
};

const nameToIcon = <String, String>{
  'dockerfile': 'docker',
  'docker-compose.yml': 'docker',
  'docker-compose.yaml': 'docker',
  'makefile': 'makefile',
  'cmakelists.txt': 'cmake',
  'readme': 'readme',
  'readme.md': 'readme',
  'readme.txt': 'readme',
  'license': 'license',
  'license.md': 'license',
  'license.txt': 'license',
  '.gitignore': 'git',
  '.gitattributes': 'git',
  '.env': 'env',
  '.env.local': 'env',
  '.prettierrc': 'prettier',
  '.eslintrc': 'eslintrc',
  'package.json': 'nodejs',
  'package-lock.json': 'lock',
  'yarn.lock': 'lock',
  'pnpm-lock.yaml': 'lock',
  'cargo.toml': 'rust',
  'cargo.lock': 'lock',
  'go.mod': 'go',
  'go.sum': 'go',
  'requirements.txt': 'python',
  'pyproject.toml': 'python',
  'vite.config.ts': 'vite',
  'vite.config.js': 'vite',
  'tsconfig.json': 'typescript',
  'changelog': 'changelog',
  'changelog.md': 'changelog',
  'todo': 'todo',
  'todo.md': 'todo',
};

String resolveFileMaterialIcon(String name) {
  final lower = name.toLowerCase();
  if (nameToIcon.containsKey(lower)) {
    return nameToIcon[lower]!;
  }
  final dot = name.lastIndexOf('.');
  if (dot > 0) {
    final ext = name.substring(dot + 1).toLowerCase();
    if (extToIcon.containsKey(ext)) {
      return extToIcon[ext]!;
    }
  }
  return 'file';
}

String fileIconAssetPath(String name, {required bool isDir, String? folderIconId}) {
  if (isDir) {
    final id = folderIconId ?? 'papirus-folder';
    return 'assets/icons/$id.svg';
  }
  final icon = resolveFileMaterialIcon(name);
  return 'assets/icons/$icon.svg';
}