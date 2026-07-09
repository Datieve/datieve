"use strict";
/* Ported from app-flutter/lib/utils/file_icon_helpers.dart + custom_folder_icons_store.dart */

const EXT_TO_ICON = {
  py: "python", pyw: "python", pyi: "python",
  rs: "rust",
  js: "javascript", mjs: "javascript", cjs: "javascript",
  ts: "typescript", mts: "typescript",
  jsx: "jsx", tsx: "tsx",
  html: "html", htm: "html",
  css: "css", scss: "scss", sass: "sass", less: "less", styl: "stylus",
  json: "json", jsonc: "json", json5: "json",
  yaml: "yaml", yml: "yaml",
  xml: "xml", xsd: "xml", xsl: "xml",
  graphql: "graphql", gql: "graphql",
  toml: "toml", proto: "proto", nix: "nix",
  md: "markdown", mdx: "markdown", markdown: "markdown", rst: "markdown",
  pdf: "pdf",
  doc: "word", docx: "word", odt: "word", rtf: "word",
  xls: "excel", xlsx: "excel", ods: "excel", csv: "csv",
  ppt: "powerpoint", pptx: "powerpoint", odp: "powerpoint",
  txt: "txt",
  log: "log",
  mp4: "video", mkv: "video", avi: "video", mov: "video",
  wmv: "video", flv: "video", webm: "video", m4v: "video", mpeg: "video",
  mp3: "audio", flac: "audio", wav: "audio", ogg: "audio",
  m4a: "audio", aac: "audio", opus: "audio", wma: "audio", aiff: "audio",
  jpg: "image", jpeg: "image", png: "image", gif: "image",
  webp: "image", ico: "image", bmp: "image", tiff: "image", avif: "image",
  svg: "svg", heic: "image",
  zip: "zip", tar: "zip", gz: "zip", bz2: "zip", xz: "zip",
  "7z": "archive", rar: "archive", zst: "zip", lz4: "zip",
  deb: "zip", rpm: "zip", appimage: "zip",
  c: "c", h: "c",
  cpp: "cpp", cc: "cpp", cxx: "cpp", hpp: "cpp",
  cs: "csharp", java: "java", class: "java", jar: "java",
  go: "go", php: "php", rb: "ruby", rake: "ruby",
  swift: "swift", kt: "kotlin", kts: "kotlin",
  scala: "scala", lua: "lua", pl: "perl", pm: "perl",
  r: "r", hs: "haskell", ex: "elixir", exs: "elixir",
  dart: "dart", vue: "vue", svelte: "svelte",
  sh: "shell", bash: "bash", zsh: "bash", fish: "bash",
  ps1: "powershell", psm1: "powershell", bat: "powershell", cmd: "powershell",
  sql: "database", sqlite: "database", db: "database",
  dockerfile: "docker", tf: "terraform", tfvars: "terraform",
  env: "env", lock: "lock",
  pem: "key", crt: "certificate", cer: "certificate", key: "key", p12: "certificate",
  ipynb: "notebook", wasm: "wasm",
  ttf: "font", otf: "font", woff: "font", woff2: "font", eot: "font",
};

const NAME_TO_ICON = {
  dockerfile: "docker",
  "docker-compose.yml": "docker",
  "docker-compose.yaml": "docker",
  makefile: "makefile",
  "cmakelists.txt": "cmake",
  readme: "readme",
  "readme.md": "readme",
  "readme.txt": "readme",
  license: "license",
  "license.md": "license",
  "license.txt": "license",
  ".gitignore": "git",
  ".gitattributes": "git",
  ".env": "env",
  ".env.local": "env",
  ".prettierrc": "prettier",
  ".eslintrc": "eslintrc",
  "package.json": "nodejs",
  "package-lock.json": "lock",
  "yarn.lock": "lock",
  "pnpm-lock.yaml": "lock",
  "cargo.toml": "rust",
  "cargo.lock": "lock",
  "go.mod": "go",
  "go.sum": "go",
  "requirements.txt": "python",
  "pyproject.toml": "python",
  "vite.config.ts": "vite",
  "vite.config.js": "vite",
  "tsconfig.json": "typescript",
  changelog: "changelog",
  "changelog.md": "changelog",
  todo: "todo",
  "todo.md": "todo",
};

const FOLDER_NAME_HEURISTICS = {
  pictures: "papirus-folder-pictures",
  photos: "papirus-folder-pictures",
  images: "papirus-folder-pictures",
  music: "papirus-folder-music",
  audio: "papirus-folder-music",
  videos: "papirus-folder-videos",
  movies: "papirus-folder-videos",
  downloads: "papirus-folder-download",
  download: "papirus-folder-download",
  documents: "papirus-folder-documents",
  docs: "papirus-folder-documents",
  desktop: "papirus-folder-desktop",
  public: "papirus-folder-public",
  cloud: "papirus-folder-cloud",
  games: "papirus-folder-games",
  code: "papirus-folder-code",
  src: "papirus-folder-code",
  templates: "papirus-folder-templates",
};

function normalizeFolderIconId(id) {
  let iconId = id || "papirus-folder";
  if (iconId.startsWith("mac-")) iconId = iconId.replace("mac-", "papirus-");
  if (!iconId.startsWith("papirus-")) iconId = "papirus-folder";
  return iconId;
}

function resolveFileMaterialIcon(name) {
  const lower = name.toLowerCase();
  if (NAME_TO_ICON[lower]) return NAME_TO_ICON[lower];
  const dot = name.lastIndexOf(".");
  if (dot > 0) {
    const ext = name.slice(dot + 1).toLowerCase();
    if (EXT_TO_ICON[ext]) return EXT_TO_ICON[ext];
  }
  return "file";
}

function resolveFolderIconId(path, name, customIcons) {
  if (customIcons && customIcons[path]) {
    return normalizeFolderIconId(customIcons[path]);
  }
  const lower = name.toLowerCase();
  for (const [key, id] of Object.entries(FOLDER_NAME_HEURISTICS)) {
    if (lower === key || lower.includes(key)) return id;
  }
  return "papirus-folder";
}

function fileIconAssetPath(name, isDir, folderPath, customFolderIcons) {
  if (isDir) {
    const id = resolveFolderIconId(folderPath || "", name, customFolderIcons);
    return `/icons/${id}.svg`;
  }
  return `/icons/${resolveFileMaterialIcon(name)}.svg`;
}

function fmIconImg(name, isDir, folderPath, sizePx, isDeleted, customFolderIcons) {
  const primary = fileIconAssetPath(name, isDir, folderPath, customFolderIcons);
  const fallback = isDir ? "/icons/papirus-folder.svg" : "/icons/file.svg";
  const del = isDeleted ? " fm-icon-deleted" : "";
  return `<img src="${primary}" alt="" class="fm-file-icon${del}" width="${sizePx}" height="${sizePx}" loading="lazy" onerror="if(this.dataset.fb!=='1'){this.dataset.fb='1';this.src='${fallback}';}else{this.classList.add('fm-icon-broken');}" />`;
}