"use strict";
/* Datieve Web UI — NAS file manager mirroring Flutter datieve_state.dart */
const WEB_UI_BUILD = "2026-07-09-props-v2";

const SESSION_KEY = "datieve_web_session";
const ACCOUNTS_KEY = "datieve_web_accounts";
const VAULT_KEY_STORAGE = "datieve_web_vault_key";
const THEME_KEY = "datieve_web_theme";
const VIEW_KEY = "datieve_web_view";
const SORT_KEY = "datieve_web_sort";
const ZOOM_KEY = "datieve_web_zoom";
const MOUNT_MAPPINGS_KEY = "datieve_web_mount_mappings";
const FILE_PAGE = 500;

let session = null;
let sessionUser = null;
let manageUnlocked = false;
let skipAutoLoginOnce = false;
let storedAccountsCache = null;
let vaultCryptoKeyPromise = null;

let parentId = null;
let nasBackStack = [];
let nasForwardStack = [];
let nasCurrentName = "";
let searchActive = false;
let viewStyle = "list";
let sortBy = "name";
let sortDir = "asc";
let foldersFirst = true;
let gridZoom = 1.4;
let mountMappings = [];
let settingsPage = "appearance";
let mountNasDraft = "";
let mountLocalDraft = "";
let propertiesEntry = null;
let propertiesTab = "general";
let propertiesData = null;
let propertiesVolume = null;
let propertiesSummary = null;
let propertiesHashes = null;
let propertiesLoading = false;
let propertiesHashesLoading = false;
let propertiesHashesError = null;
let propertiesError = null;
let autoSelectFirst = false;
let dropDepth = 0;
let dropHoverPath = null;
let ctxSubMenuOpen = null;
let rawFolders = [];
let rawFiles = [];
let hasMoreFiles = false;
let fileOffset = 0;
let currentAbsPath = "";
let selectedPaths = new Set();
let anchorPath = null;
let clipboard = null;
let bookmarkedKeys = new Map();
let showFilters = false;
let loading = false;
let manageActiveTab = "stats";
let showShortcuts = false;
let adminData = { stats: null, folders: [], users: [], settings: null };
let adminForm = { friendlyName: "", adminUsername: "", adminCode: "", mgmtNewPassword: "", newFolderPath: "", newUserName: "", newUserCode: "", exclusionPatterns: [] };
let adminSaving = false;
let adminShowPwd = false;
let uiBound = false;

let sseAbort = null;
let sseReconnectTimer = null;
let lastAutoRefreshAt = 0;
const AUTO_REFRESH_MIN_MS = 400;

const $ = (id) => document.getElementById(id);

function hexToBytes(hex) {
  const b = new Uint8Array(hex.length / 2);
  for (let i = 0; i < b.length; i++) b[i] = parseInt(hex.substr(i * 2, 2), 16);
  return b;
}
function bytesToHex(buf) {
  return Array.from(new Uint8Array(buf)).map((x) => x.toString(16).padStart(2, "0")).join("");
}
async function importMacKey(hex) {
  return crypto.subtle.importKey("raw", hexToBytes(hex), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
}
function randomNonce() {
  return crypto.randomUUID?.() || bytesToHex(crypto.getRandomValues(new Uint8Array(16)));
}

function persistSession() {
  if (!session) { localStorage.removeItem(SESSION_KEY); return; }
  localStorage.setItem(SESSION_KEY, JSON.stringify({
    token: session.token, macKeyHex: session.macKeyHex, role: session.role, username: session.username,
  }));
}
async function restoreSession() {
  const raw = localStorage.getItem(SESSION_KEY);
  if (!raw) return null;
  try {
    const p = JSON.parse(raw);
    return { ...p, macKey: await importMacKey(p.macKeyHex) };
  } catch { return null; }
}
function clearSession() {
  session = null; sessionUser = null; manageUnlocked = false;
  storedAccountsCache = null; persistSession(); stopSse();
}

async function getVaultKey() {
  if (!vaultCryptoKeyPromise) {
    vaultCryptoKeyPromise = (async () => {
      let raw = localStorage.getItem(VAULT_KEY_STORAGE);
      if (!raw) { raw = bytesToHex(crypto.getRandomValues(new Uint8Array(32))); localStorage.setItem(VAULT_KEY_STORAGE, raw); }
      return crypto.subtle.importKey("raw", hexToBytes(raw), { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
    })();
  }
  return vaultCryptoKeyPromise;
}
async function encSecret(t) {
  const k = await getVaultKey();
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, k, new TextEncoder().encode(t));
  return { iv: bytesToHex(iv), data: bytesToHex(new Uint8Array(ct)) };
}
async function decSecret(e) {
  if (!e?.iv || !e?.data) return "";
  const k = await getVaultKey();
  return new TextDecoder().decode(await crypto.subtle.decrypt({ name: "AES-GCM", iv: hexToBytes(e.iv) }, k, hexToBytes(e.data)));
}
async function loadStoredAccounts() {
  if (storedAccountsCache) return storedAccountsCache;
  const recs = JSON.parse(localStorage.getItem(ACCOUNTS_KEY) || "[]");
  const out = [];
  let migrated = false;
  for (const r of recs) {
    if (r.code) { out.push({ username: r.username, role: r.role, code: r.code }); r.codeEnc = await encSecret(r.code); delete r.code; migrated = true; continue; }
    const code = await decSecret(r.codeEnc);
    if (code) out.push({ username: r.username, role: r.role, code });
  }
  if (migrated) localStorage.setItem(ACCOUNTS_KEY, JSON.stringify(recs));
  storedAccountsCache = out; return out;
}
async function upsertAccount(u, role, code) {
  const list = (await loadStoredAccounts()).filter((a) => a.username !== u);
  list.push({ username: u, role, code });
  const recs = [];
  for (const a of list) recs.push({ username: a.username, role: a.role, codeEnc: await encSecret(a.code) });
  localStorage.setItem(ACCOUNTS_KEY, JSON.stringify(recs));
  storedAccountsCache = list;
}
async function removeAccount(u) {
  const list = (await loadStoredAccounts()).filter((a) => a.username !== u);
  const recs = [];
  for (const a of list) recs.push({ username: a.username, role: a.role, codeEnc: await encSecret(a.code) });
  localStorage.setItem(ACCOUNTS_KEY, JSON.stringify(recs));
  storedAccountsCache = list;
}

function loadTheme() { return localStorage.getItem(THEME_KEY) || "system"; }

function loadViewSettings() {
  viewStyle = localStorage.getItem(VIEW_KEY) || "list";
  const z = parseFloat(localStorage.getItem(ZOOM_KEY));
  gridZoom = Number.isFinite(z) ? Math.min(2.8, Math.max(0.56, z)) : 1.4;
  try {
    const s = JSON.parse(localStorage.getItem(SORT_KEY) || "{}");
    sortBy = s.sortBy || "name";
    sortDir = s.sortDir || "asc";
    foldersFirst = s.foldersFirst !== false;
  } catch { /* defaults */ }
  try {
    mountMappings = JSON.parse(localStorage.getItem(MOUNT_MAPPINGS_KEY) || "[]")
      .filter((m) => m?.nasPath && m?.localPath);
  } catch { mountMappings = []; }
  applyZoom();
}
function saveViewSettings() {
  localStorage.setItem(VIEW_KEY, viewStyle);
  localStorage.setItem(SORT_KEY, JSON.stringify({ sortBy, sortDir, foldersFirst }));
  localStorage.setItem(ZOOM_KEY, String(gridZoom));
}
function saveMountMappings() {
  localStorage.setItem(MOUNT_MAPPINGS_KEY, JSON.stringify(mountMappings));
}
function applyZoom() {
  const scale = gridZoom / 1.4;
  document.documentElement.style.setProperty("--fm-scale", String(scale));
  document.documentElement.style.setProperty("--grid-zoom", String(gridZoom));
  const z = $("status-zoom");
  if (z) z.textContent = `Zoom: ${Math.round(gridZoom / 1.4 * 100)}%`;
}
function zoomIn() { gridZoom = Math.min(2.8, +(gridZoom + 0.14).toFixed(2)); saveViewSettings(); applyZoom(); renderList(); }
function zoomOut() { gridZoom = Math.max(0.56, +(gridZoom - 0.14).toFixed(2)); saveViewSettings(); applyZoom(); renderList(); }
function resetZoom() { gridZoom = 1.4; saveViewSettings(); applyZoom(); renderList(); }
function mapNasToLocal(path) {
  let best = null;
  for (const m of mountMappings) {
    if (path.startsWith(m.nasPath) && (!best || m.nasPath.length > best.nasPath.length)) best = m;
  }
  if (!best) return path;
  return best.localPath + path.slice(best.nasPath.length);
}
function triggerAutoSelect() { autoSelectFirst = true; }
function canCreateHere() { return !!currentAbsPath; }
function isDark(t) { return t === "dark" || (t === "system" && matchMedia("(prefers-color-scheme: dark)").matches); }
function applyThemeAttr(t) {
  if (t === "system") document.documentElement.removeAttribute("data-theme");
  else document.documentElement.setAttribute("data-theme", t);
}
function toggleTheme() {
  const next = isDark(loadTheme()) ? "light" : "dark";
  localStorage.setItem(THEME_KEY, next); applyThemeAttr(next);
  [$("login-theme-btn"), $("setup-theme-btn")].forEach((b) => { if (b) b.innerHTML = isDark(next) ? I.moon : I.sun; });
}
applyThemeAttr(loadTheme());

async function signedFetch(path, opts = {}) {
  const method = (opts.method || "GET").toUpperCase();
  const nonce = randomNonce();
  const mac = bytesToHex(await crypto.subtle.sign("HMAC", session.macKey, new TextEncoder().encode(`${method}\n${path}\n${nonce}`)));
  const headers = { ...opts.headers, Authorization: `Bearer ${session.token}`, "x-datieve-nonce": nonce, "x-datieve-mac": mac };
  if (opts.body && !headers["Content-Type"]) headers["Content-Type"] = "application/json";
  const res = await fetch(path, { ...opts, headers });
  if (res.status === 401) { clearSession(); showPhase("login"); throw new Error("Session expired"); }
  if (res.status === 429) throw new Error("429 Too many requests — rate limit exceeded");
  return res;
}
async function apiGet(p) { const r = await signedFetch(p); if (!r.ok) throw await errFrom(r); return r.json(); }
async function apiPost(p, b) { const r = await signedFetch(p, { method: "POST", body: JSON.stringify(b || {}) }); if (!r.ok) throw await errFrom(r); return r.json().catch(() => null); }
async function apiDelete(p) { const r = await signedFetch(p, { method: "DELETE" }); if (!r.ok) throw await errFrom(r); }
async function signedMultipartFetch(path, formData) {
  const method = "POST";
  const nonce = randomNonce();
  const mac = bytesToHex(await crypto.subtle.sign("HMAC", session.macKey, new TextEncoder().encode(`${method}\n${path}\n${nonce}`)));
  const res = await fetch(path, {
    method,
    headers: { Authorization: `Bearer ${session.token}`, "x-datieve-nonce": nonce, "x-datieve-mac": mac },
    body: formData,
  });
  if (res.status === 401) { clearSession(); showPhase("login"); throw new Error("Session expired"); }
  if (res.status === 429) throw new Error("429 Too many requests — rate limit exceeded");
  if (!res.ok) throw await errFrom(res);
  return res.json().catch(() => null);
}
async function errFrom(r) { try { const j = await r.json(); return new Error(j.message || r.statusText); } catch { return new Error(r.statusText); } }
function qs(o) {
  const u = new URLSearchParams();
  for (const [k, v] of Object.entries(o)) if (v !== undefined && v !== null && v !== "") u.set(k, String(v));
  const s = u.toString(); return s ? `?${s}` : "";
}

function esc(s) { return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }
function fmtBytes(n) {
  if (n == null) return "";
  const u = ["B", "KB", "MB", "GB", "TB"]; let v = n, i = 0;
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
  return `${v.toFixed(i ? 1 : 0)} ${u[i]}`;
}
function fmtDate(iso) {
  if (!iso) return "";
  try { return new Date(iso).toLocaleString(undefined, { dateStyle: "short", timeStyle: "short" }); } catch { return iso; }
}
function toast(msg) { const t = $("toast"); t.textContent = msg; t.classList.remove("hidden"); setTimeout(() => t.classList.add("hidden"), 2800); }

const svg = (inner, sz = "w-4 h-4") => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" class="${sz} shrink-0">${inner}</svg>`;
const I = {
  back: svg('<path d="m15 18-6-6 6-6"/>'),
  fwd: svg('<path d="m9 18 6-6-6-6"/>'),
  up: svg('<path d="m18 15-6-6-6 6"/>'),
  refresh: svg('<path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"/><path d="M8 16H3v5"/>'),
  filter: svg('<path d="M10 5H3"/><path d="M12 19H3"/><path d="M14 3v4"/><path d="M16 17v4"/><path d="M21 12h-9"/><path d="M21 19h-5"/><path d="M21 5h-7"/><path d="M8 10v4"/><path d="M8 12H3"/>'),
  settings: svg('<path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z"/><circle cx="12" cy="12" r="3"/>'),
  folder: svg('<path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/>'),
  file: svg('<path d="M6 22a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h8a2.4 2.4 0 0 1 1.704.706l3.588 3.588A2.4 2.4 0 0 1 20 8v12a2 2 0 0 1-2 2z"/><path d="M14 2v5a1 1 0 0 0 1 1h5"/>'),
  sun: svg('<circle cx="12" cy="12" r="4"/><path d="M12 2v2"/><path d="M12 20v2"/><path d="m4.93 4.93 1.41 1.41"/><path d="m17.66 17.66 1.41 1.41"/><path d="M2 12h2"/><path d="M20 12h2"/><path d="m6.34 17.66-1.41 1.41"/><path d="m19.07 4.93-1.41 1.41"/>'),
  moon: svg('<path d="M20.985 12.486a9 9 0 1 1-9.473-9.472c.405-.022.617.46.402.803a6 6 0 0 0 8.268 8.268c.344-.215.825-.004.803.401"/>'),
  x: svg('<path d="M18 6 6 18"/><path d="m6 6 12 12"/>', "w-3.5 h-3.5"),
  home: svg('<path d="M15 21v-8a1 1 0 0 0-1-1h-4a1 1 0 0 0-1 1v8"/><path d="M3 10a2 2 0 0 1 .709-1.528l7-6a2 2 0 0 1 2.582 0l7 6A2 2 0 0 1 21 10v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>', "w-3 h-3"),
  chev: svg('<path d="m9 18 6-6-6-6"/>', "w-3 h-3"),
  bm: svg('<path d="M17 3a2 2 0 0 1 2 2v15a1 1 0 0 1-1.496.868l-4.512-2.578a2 2 0 0 0-1.984 0l-4.512 2.578A1 1 0 0 1 5 20V5a2 2 0 0 1 2-2z"/>'),
  bmf: svg('<path d="M17 3a2 2 0 0 1 2 2v15a1 1 0 0 1-1.496.868l-4.512-2.578a2 2 0 0 0-1.984 0l-4.512 2.578A1 1 0 0 1 5 20V5a2 2 0 0 1 2-2z" fill="currentColor"/>'),
  list: svg('<path d="M3 5h.01"/><path d="M3 12h.01"/><path d="M3 19h.01"/><path d="M8 5h13"/><path d="M8 12h13"/><path d="M8 19h13"/>'),
  grid: svg('<rect width="7" height="7" x="3" y="3" rx="1"/><rect width="7" height="7" x="14" y="3" rx="1"/><rect width="7" height="7" x="14" y="14" rx="1"/><rect width="7" height="7" x="3" y="14" rx="1"/>'),
  keyboard: svg('<rect width="20" height="16" x="2" y="4" rx="2"/><path d="M6 8h.001"/><path d="M10 8h.001"/><path d="M14 8h.001"/><path d="M18 8h.001"/><path d="M8 12h.001"/><path d="M12 12h.001"/><path d="M16 12h.001"/>'),
  eye: svg('<path d="M2.062 12.348a1 1 0 0 1 0-.696 10.75 10.75 0 0 1 19.876 0 1 1 0 0 1 0 .696 10.75 10.75 0 0 1-19.876 0"/><circle cx="12" cy="12" r="3"/>'),
  eyeOff: svg('<path d="M10.733 5.076a10.744 10.744 0 0 1 11.205 6.575 1 1 0 0 1 0 .696 10.747 10.747 0 0 1-1.444 2.49"/><path d="M14.084 14.158a3 3 0 0 1-4.242-4.242"/><path d="M17.479 17.499a10.75 10.75 0 0 1-15.417-5.151 1 1 0 0 1 0-.696 10.75 10.75 0 0 1 4.446-5.143"/><path d="m2 2 20 20"/>'),
  logOut: svg('<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><polyline points="16 17 21 12 16 7"/><line x1="21" x2="9" y1="12" y2="12"/>'),
  fingerprint: svg('<path d="M12 10a2 2 0 0 0-2 2c0 1.02-.1 2.51-.26 4"/><path d="M14 13.12c0 2.38 0 6.38-1 8.88"/><path d="M17.29 21.02c.12-.6.43-2.3.5-3.02"/><path d="M2 12a10 10 0 0 1 18-6"/><path d="M2 16h.01"/><path d="M21.8 16c.2-2 .131-5.354 0-6"/><path d="M5 19.5C5.5 18 6 15 6 12a6 6 0 0 1 .34-2"/><path d="M8.65 22c.21-.66.45-1.32.57-2"/><path d="M9 6.8a6 6 0 0 1 9 5.2v2"/>'),
};

const KEYBOARD_SHORTCUTS = [
  { h: "Files & Navigation" },
  { d: "Move selection up / down", k: "↑ / ↓" },
  { d: "Open selected item", k: "Enter" },
  { d: "Navigate back", k: "Alt+Left" },
  { d: "Navigate forward", k: "Alt+Right" },
  { d: "Go up one level", k: "Alt+Up / Backspace" },
  { d: "Refresh current folder", k: "F5" },
  { d: "Focus search bar", k: "/" },
  { d: "Focus search bar (alternate)", k: "Ctrl+F" },
  { h: "File Operations" },
  { d: "Select all", k: "Ctrl+A" },
  { d: "Copy selected", k: "Ctrl+C" },
  { d: "Cut selected", k: "Ctrl+X" },
  { d: "Paste", k: "Ctrl+V" },
  { d: "Rename selected", k: "F2" },
  { d: "Move to Trash", k: "Del" },
  { d: "Delete permanently", k: "Shift+Del" },
  { d: "New folder", k: "Ctrl+Shift+N" },
  { d: "New file", k: "Ctrl+N" },
  { h: "App" },
  { d: "Properties", k: "Space" },
  { d: "Zoom in / out / reset", k: "Ctrl++ / Ctrl+- / Ctrl+0" },
  { d: "Keyboard shortcuts", k: "Ctrl+/" },
  { d: "Settings", k: "Ctrl+S" },
  { d: "Clear selection / close", k: "Escape" },
];

const DATE_OPTS = [
  ["", "Any time"], ["last_1h", "Last hour"], ["today", "Today"], ["last_24h", "Last 24 hours"],
  ["last_3d", "Last 3 days"], ["last_7d", "Last 7 days"], ["last_14d", "Last 14 days"],
  ["last_30d", "Last 30 days"], ["last_45d", "Last 45 days"], ["last_60d", "Last 60 days"], ["older_60d", "60+ days ago"],
];
const UNIT_B = { KB: 1024, MB: 1048576, GB: 1073741824 };
const TYPE_EXT = {
  images: new Set(["jpg", "jpeg", "png", "gif", "bmp", "webp", "svg", "heic", "tiff", "ico"]),
  documents: new Set(["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "md", "odt", "csv", "rtf"]),
  media: new Set(["mp4", "mkv", "avi", "mov", "webm", "mp3", "wav", "flac", "ogg", "m4a", "aac"]),
  archives: new Set(["zip", "rar", "7z", "tar", "gz", "bz2", "xz"]),
};

function rangeToIso(range) {
  const now = Date.now(), DAY = 86400000;
  const h = { last_1h: 1, last_24h: 24, last_3d: 72, last_7d: 168, last_14d: 336, last_30d: 720, last_45d: 1080, last_60d: 1440 };
  if (range === "today") { const s = new Date(); s.setHours(0, 0, 0, 0); return { after: s.toISOString() }; }
  if (h[range]) return { after: new Date(now - h[range] * 3600000).toISOString() };
  if (range === "older_60d") return { before: new Date(now - 60 * DAY).toISOString() };
  return {};
}

function getFilters() {
  const unit = UNIT_B[$("f-size-unit").value] || UNIT_B.MB;
  const c = rangeToIso($("f-created").value);
  const m = rangeToIso($("f-modified").value);
  const smin = parseFloat($("f-size-min").value);
  const smax = parseFloat($("f-size-max").value);
  return {
    type: $("f-type").value,
    include_deleted: $("f-include-deleted").checked,
    size_min: isNaN(smin) ? undefined : Math.round(smin * unit),
    size_max: isNaN(smax) ? undefined : Math.round(smax * unit),
    created_after: c.after, created_before: c.before,
    modified_after: m.after, modified_before: m.before,
  };
}

function extOf(n) { const i = n.lastIndexOf("."); return i > 0 ? n.slice(i + 1).toLowerCase() : ""; }
function matchType(name, isDir, type) {
  if (!type || type === "all") return true;
  if (type === "folders") return isDir;
  if (type === "files") return !isDir;
  const s = TYPE_EXT[type]; return s ? s.has(extOf(name)) : true;
}
function matchClientFilters(entry, isDir) {
  const f = getFilters();
  if (!matchType(entry.name, isDir, f.type)) return false;
  if (!isDir && f.size_min != null && entry.size_bytes < f.size_min) return false;
  if (!isDir && f.size_max != null && entry.size_bytes > f.size_max) return false;
  const ca = entry.created_at ? new Date(entry.created_at).getTime() : 0;
  const ma = entry.modified_at ? new Date(entry.modified_at).getTime() : (entry.indexed_at ? new Date(entry.indexed_at).getTime() : 0);
  if (f.created_after && (!ca || ca < new Date(f.created_after).getTime())) return false;
  if (f.created_before && ca && ca > new Date(f.created_before).getTime()) return false;
  if (f.modified_after && (!ma || ma < new Date(f.modified_after).getTime())) return false;
  if (f.modified_before && ma && ma > new Date(f.modified_before).getTime()) return false;
  return true;
}

function visibleEntries() {
  const folders = rawFolders.filter((f) => matchClientFilters(f, true)).map((f) => ({ ...f, kind: "folder" }));
  const files = rawFiles.filter((f) => matchClientFilters(f, false)).map((f) => ({ ...f, kind: "file" }));
  const merged = foldersFirst ? [...folders, ...files] : [...files, ...folders];
  const dir = sortDir === "desc" ? -1 : 1;
  const cmp = (a, b) => {
    let av, bv;
    switch (sortBy) {
      case "modified": av = a.modified_at || a.indexed_at || ""; bv = b.modified_at || b.indexed_at || ""; break;
      case "created": av = a.created_at || ""; bv = b.created_at || ""; break;
      case "size": av = a.size_bytes ?? 0; bv = b.size_bytes ?? 0; return ((av > bv) - (av < bv)) * dir;
      case "type": av = extOf(a.name); bv = extOf(b.name); break;
      default: av = a.name.toLowerCase(); bv = b.name.toLowerCase();
    }
    if (av < bv) return -1 * dir;
    if (av > bv) return 1 * dir;
    return a.name.localeCompare(b.name) * dir;
  };
  if (!foldersFirst) return merged.sort(cmp);
  const sf = folders.sort(cmp);
  const sfi = files.sort(cmp);
  return [...sf, ...sfi];
}

function tryAutoSelectFirst() {
  if (!autoSelectFirst || loading) return;
  const entries = visibleEntries();
  if (!entries.length) { autoSelectFirst = false; return; }
  autoSelectFirst = false;
  selectedPaths = new Set([entries[0].absolute_path]);
  anchorPath = entries[0].absolute_path;
}

function showPhase(name) {
  $("phase-login").classList.toggle("hidden", name !== "login");
  $("phase-setup").classList.toggle("hidden", name !== "setup");
  $("phase-app").classList.toggle("hidden", name !== "app");
}
/* ---------- SSE (mirrors datieve_state.dart _startSse) ---------- */

function stopSse() {
  if (sseAbort) { sseAbort.abort(); sseAbort = null; }
  if (sseReconnectTimer) { clearTimeout(sseReconnectTimer); sseReconnectTimer = null; }
}

function scheduleSseReconnect() {
  if (sseReconnectTimer || !session) return;
  sseReconnectTimer = setTimeout(() => { sseReconnectTimer = null; startSse(); }, 5000);
}

function onIndexChanged() {
  if (searchActive) return;
  refreshFileManager({ force: true, bookmarks: false });
}

async function startSse() {
  stopSse();
  if (!session) return;
  const ctrl = new AbortController();
  sseAbort = ctrl;
  try {
    const path = "/api/events";
    const nonce = randomNonce();
    const mac = bytesToHex(await crypto.subtle.sign("HMAC", session.macKey, new TextEncoder().encode(`GET\n${path}\n${nonce}`)));
    const res = await fetch(path, {
      headers: { Authorization: `Bearer ${session.token}`, "x-datieve-nonce": nonce, "x-datieve-mac": mac },
      signal: ctrl.signal,
    });
    if (!res.ok || !res.body) { scheduleSseReconnect(); return; }
    const reader = res.body.getReader();
    const dec = new TextDecoder();
    let buf = "";
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      const lines = buf.split("\n");
      buf = lines.pop() || "";
      for (const line of lines) {
        if (!line.startsWith("data:")) continue;
        const payload = line.slice(5).trim();
        if (payload === "changed" || payload === "FileChanged") {
          if (!searchActive) onIndexChanged();
        }
      }
    }
    scheduleSseReconnect();
  } catch (e) {
    if (e.name !== "AbortError") scheduleSseReconnect();
  }
}

/* ---------- navigation ---------- */

function crumbs() {
  const c = [{ id: null, name: "Home" }];
  for (const e of nasBackStack) c.push(e);
  if (parentId != null && nasCurrentName) c.push({ id: parentId, name: nasCurrentName });
  return c;
}

function nasNavigateHome() {
  searchActive = false; $("search-input").value = "";
  nasBackStack = []; nasForwardStack = []; parentId = null; nasCurrentName = "";
  triggerAutoSelect();
  fileOffset = 0; refreshFileManager();
}

function nasNavigateBack() {
  if (!nasBackStack.length) return;
  searchActive = false; $("search-input").value = "";
  const prev = nasBackStack.pop();
  nasForwardStack.push({ id: parentId, name: nasCurrentName || "Home" });
  parentId = prev.id; nasCurrentName = prev.name;
  triggerAutoSelect();
  fileOffset = 0; refreshFileManager();
}

function nasNavigateForward() {
  if (!nasForwardStack.length) return;
  searchActive = false; $("search-input").value = "";
  const next = nasForwardStack.pop();
  nasBackStack.push({ id: parentId, name: nasCurrentName || "Home" });
  parentId = next.id; nasCurrentName = next.name;
  triggerAutoSelect();
  fileOffset = 0; refreshFileManager();
}

function nasNavigateUp() {
  if (nasBackStack.length) {
    const prev = nasBackStack.pop();
    nasForwardStack = [];
    parentId = prev.id; nasCurrentName = prev.name;
  } else nasNavigateHome();
  triggerAutoSelect();
  fileOffset = 0; refreshFileManager();
}

function openFolder(id, name) {
  searchActive = false; $("search-input").value = "";
  if (parentId != null) nasBackStack.push({ id: parentId, name: nasCurrentName || "Folder" });
  nasForwardStack = [];
  parentId = id; nasCurrentName = name;
  triggerAutoSelect();
  fileOffset = 0; refreshFileManager();
}

/* ---------- data loading ---------- */

async function refreshFileManager(opts = {}) {
  if (!session) return;
  const { bookmarks = true, force = false } = opts;
  if (!force) {
    const now = Date.now();
    if (now - lastAutoRefreshAt < AUTO_REFRESH_MIN_MS && !loading) return;
  }
  lastAutoRefreshAt = Date.now();
  loading = true; renderList();
  try {
    if (bookmarks) await loadBookmarks();
    if (searchActive) await loadSearch();
    else await loadBrowse(false);
  } catch (e) {
    if (e.message?.includes("429") || e.message?.toLowerCase().includes("rate")) {
      toast("Rate limited — pausing auto-refresh. Press F5 to retry.");
    } else {
      toast(e.message || "Load failed");
    }
  } finally {
    loading = false; renderAll();
  }
}

async function loadBrowse(append) {
  const f = getFilters();
  const res = await apiGet(`/api/browse${qs({
    parent_id: parentId ?? undefined,
    file_offset: fileOffset,
    file_limit: FILE_PAGE,
    include_deleted: f.include_deleted && sessionUser?.allow_deleted ? true : undefined,
  })}`);
  if (!append) {
    rawFolders = res.folders || [];
    rawFiles = res.files || [];
  } else rawFiles = rawFiles.concat(res.files || []);
  hasMoreFiles = res.has_more;
  currentAbsPath = res.current_absolute_path || "";
}

async function loadSearch() {
  const q = $("search-input").value.trim();
  if (q.length < 2) { searchActive = false; fileOffset = 0; return loadBrowse(false); }
  const f = getFilters();
  const res = await apiGet(`/api/search${qs({
    q, size_min: f.size_min, size_max: f.size_max,
    created_after: f.created_after, created_before: f.created_before,
    modified_after: f.modified_after, modified_before: f.modified_before,
    include_deleted: f.include_deleted && sessionUser?.allow_deleted ? true : undefined,
  })}`);
  rawFolders = [];
  rawFiles = Array.isArray(res) ? res : [];
  hasMoreFiles = false;
}

async function loadBookmarks() {
  try {
    const items = await apiGet("/api/bookmarks");
    bookmarkedKeys = new Map(items.map((b) => [`${b.kind}:${b.target_id}`, b.id]));
    $("bookmarks-list").innerHTML = items.map((b) => `
      <li><button data-bm="${b.id}" data-fid="${b.open_folder_id ?? ""}" data-label="${esc(b.label)}"
          class="w-full text-left truncate text-xs py-1 px-1 rounded hover:text-brand ${b.is_missing ? "opacity-50" : ""}"
          ${b.is_missing ? "disabled" : ""}>${esc(b.label)}</button></li>`).join("") || "";
    $("bookmarks-empty").classList.toggle("hidden", items.length > 0);
  } catch { /* ignore */ }
}

async function toggleBookmark(kind, id, label) {
  const key = `${kind}:${id}`;
  const existing = bookmarkedKeys.get(key);
  try {
    if (existing) await apiDelete(`/api/bookmarks/${existing}`);
    else await apiPost("/api/bookmarks", { kind, target_id: id, label });
    await loadBookmarks(); renderList();
  } catch (e) { toast(e.message); }
}

/* ---------- FS operations ---------- */

async function nasFs(endpoint, body) {
  return apiPost(`/api/fs/${endpoint}`, body);
}

function selectedAbsPaths() {
  return [...selectedPaths];
}

async function copySelected() {
  const paths = selectedAbsPaths();
  if (!paths.length) return;
  clipboard = { op: "copy", paths }; updateStatus();
}

async function cutSelected() {
  const paths = selectedAbsPaths();
  if (!paths.length) return;
  clipboard = { op: "cut", paths }; updateStatus();
}

async function pasteClipboard(collision) {
  if (!clipboard || !currentAbsPath) { toast("Navigate into a folder to paste"); return; }
  const endpoint = clipboard.op === "copy" ? "copy" : "move";
  const body = { src_paths: clipboard.paths, dest_dir: currentAbsPath };
  if (collision) body.collision = collision;
  try {
    const res = await nasFs(endpoint, body);
    const failed = res?.failed || [];
    if (clipboard.op === "cut" && !failed.length) clipboard = null;
    toast(failed.length ? `${failed.length} failed` : "Pasted");
    updateStatus();
    await refreshFileManager({ force: true, bookmarks: false });
  } catch (e) { toast(e.message); }
}

async function trashSelected() {
  const paths = selectedAbsPaths();
  if (!paths.length) return;
  try {
    const res = await nasFs("trash", { paths });
    toast((res?.failed?.length) ? "Some items failed" : "Moved to trash");
    selectedPaths.clear();
    await refreshFileManager({ force: true, bookmarks: false });
  } catch (e) { toast(e.message); }
}

async function deleteSelected() {
  const paths = selectedAbsPaths();
  if (!paths.length) return;
  if (!confirm(`Permanently delete ${paths.length} item(s)?`)) return;
  try {
    const res = await nasFs("delete", { paths });
    toast((res?.failed?.length) ? "Some items failed" : "Deleted");
    selectedPaths.clear();
    await refreshFileManager({ force: true, bookmarks: false });
  } catch (e) { toast(e.message); }
}

async function renameSelected() {
  const paths = selectedAbsPaths();
  if (paths.length !== 1) return;
  const p = paths[0];
  const name = p.split("/").pop();
  const neu = prompt("New name:", name);
  if (!neu || neu === name) return;
  try {
    await nasFs("rename", { path: p, new_name: neu });
    toast("Renamed");
    await refreshFileManager({ force: true, bookmarks: false });
  } catch (e) { toast(e.message); }
}

async function downloadPath(path, name) {
  const nonce = randomNonce();
  const q = qs({ path });
  const mac = bytesToHex(await crypto.subtle.sign("HMAC", session.macKey, new TextEncoder().encode(`GET\n/api/fs/download${q}\n${nonce}`)));
  const res = await fetch(`/api/fs/download${q}`, {
    headers: { Authorization: `Bearer ${session.token}`, "x-datieve-nonce": nonce, "x-datieve-mac": mac },
  });
  if (!res.ok) throw new Error("Download failed");
  const blob = await res.blob();
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = name || path.split("/").pop();
  a.click();
  URL.revokeObjectURL(a.href);
}

async function copyPath(path, opts = {}) {
  const raw = path || selectedAbsPaths()[0];
  if (!raw) return;
  const mapped = mapNasToLocal(raw);
  const text = opts.quoted ? `"${mapped}"` : mapped;
  try {
    await navigator.clipboard.writeText(text);
    toast(mapped !== raw ? "Local path copied" : "Path copied");
  } catch { toast(text); }
}

async function nasCreateNewFolder(name) {
  if (!canCreateHere()) { toast("Navigate into a folder first"); return; }
  const folderName = name || "New Folder";
  try {
    await nasFs("mkdir", { path: `${currentAbsPath}/${folderName}` });
    toast(`Created "${folderName}"`);
    await refreshFileManager({ force: true, bookmarks: false });
  } catch (e) { toast(e.message); }
}

async function nasCreateNewFile(name) {
  if (!canCreateHere()) { toast("Navigate into a folder first"); return; }
  const fileName = name || "New File";
  try {
    await nasFs("create-file", { dir: currentAbsPath, name: fileName });
    toast(`Created "${fileName}"`);
    await refreshFileManager({ force: true, bookmarks: false });
  } catch (e) { toast(e.message); }
}

function invertSelection() {
  const all = new Set(visibleEntries().map((e) => e.absolute_path));
  const next = new Set();
  for (const p of all) if (!selectedPaths.has(p)) next.add(p);
  selectedPaths = next;
  renderList();
}

async function walkFileEntry(entry, prefix, out) {
  if (entry.isFile) {
    const f = await new Promise((res, rej) => entry.file((file) => res(file), rej));
    if (f) out.push({ file: f, relPath: prefix ? `${prefix}/${f.name}` : f.name });
    return;
  }
  if (!entry.isDirectory) return;
  const reader = entry.createReader();
  const readBatch = () => new Promise((res, rej) => reader.readEntries((ents) => res(ents), rej));
  let batch;
  do {
    batch = await readBatch();
    for (const child of batch) {
      const childPrefix = prefix ? `${prefix}/${child.name}` : child.name;
      await walkFileEntry(child, childPrefix, out);
    }
  } while (batch.length);
}

async function collectDropFiles(dataTransfer) {
  const out = [];
  const items = [...(dataTransfer.items || [])];
  if (items.length && items[0].webkitGetAsEntry) {
    for (const item of items) {
      if (item.kind !== "file") continue;
      const entry = item.webkitGetAsEntry();
      if (entry) await walkFileEntry(entry, "", out);
    }
  }
  if (!out.length) {
    for (const f of dataTransfer.files || []) out.push({ file: f, relPath: f.name });
  }
  return out;
}

async function uploadDroppedFiles(dataTransfer, destDir) {
  if (!destDir) { toast("Navigate into a folder to upload"); return; }
  const collected = await collectDropFiles(dataTransfer);
  if (!collected.length) return;
  const fd = new FormData();
  fd.append("dest_dir", destDir);
  for (const { file, relPath } of collected) {
    fd.append("files", file, file.name);
    fd.append("relative_paths", relPath);
  }
  try {
    const res = await signedMultipartFetch("/api/fs/upload", fd);
    const failed = res?.failed?.length || 0;
    toast(failed ? `Uploaded with ${failed} failure(s)` : `Uploaded ${collected.length} item(s)`);
    await refreshFileManager({ force: true, bookmarks: false });
  } catch (e) { toast(e.message); }
}

function setDropOverlay(show) {
  $("drop-overlay")?.classList.toggle("hidden", !show);
}

function setDropHover(path) {
  if (dropHoverPath === path) return;
  if (dropHoverPath) document.querySelector(`[data-path="${CSS.escape(dropHoverPath)}"]`)?.classList.remove("drag-over");
  dropHoverPath = path;
  if (path) document.querySelector(`[data-path="${CSS.escape(path)}"]`)?.classList.add("drag-over");
}

/* ---------- rendering ---------- */

function renderToolbar() {
  $("btn-back").disabled = !nasBackStack.length;
  $("btn-forward").disabled = !nasForwardStack.length;
  $("btn-back").innerHTML = I.back;
  $("btn-forward").innerHTML = I.fwd;
  $("btn-up").innerHTML = I.up;
  $("btn-refresh").innerHTML = I.refresh;
  $("btn-view").innerHTML = viewStyle === "grid" ? I.list : I.grid;
  $("btn-view").title = viewStyle === "grid" ? "Switch to list view" : "Switch to grid view";
  $("btn-filters").innerHTML = I.filter;
  $("btn-settings").innerHTML = I.settings;
  const c = crumbs();
  $("breadcrumbs").innerHTML = c.map((cr, i) => {
    const last = i === c.length - 1;
    const inner = `${i === 0 ? I.home : ""}<span>${esc(cr.name)}</span>`;
    return last
      ? `<span class="fm-crumb fm-crumb-active">${inner}</span>`
      : `<button data-crumb="${i}" class="fm-crumb">${inner}</button>${I.chev}`;
  }).join("");
  $("filters-panel").classList.toggle("hidden", !showFilters);
  $("f-apply-search").classList.toggle("hidden", !searchActive);
}

function entryAttrs(e) {
  return `data-path="${esc(e.absolute_path)}" data-name="${esc(e.name)}" data-kind="${e.kind}" data-id="${e.id}"`;
}

function bookmarkBtn(e, bm) {
  return `<button class="fm-row-bm ${bm ? "text-brand" : "text-faint"}" data-bm-toggle="${e.kind}:${e.id}" data-label="${esc(e.name)}" title="Bookmark">${bm ? I.bmf : I.bm}</button>`;
}

function entryDetail(e) {
  if (e.is_deleted) {
    const when = e.deleted_at ? fmtDate(e.deleted_at) : "unknown time";
    return `Deleted · ${when}`;
  }
  if (e.kind === "folder") return `${e.file_count ?? 0} items`;
  return `${fmtBytes(e.size_bytes)} · ${fmtDate(e.modified_at)}`;
}

function listIconSize() {
  return Math.min(48, Math.max(20, 34 * (gridZoom / 1.4)));
}

function gridIconSize() {
  return Math.min(128, Math.max(24, 56 * gridZoom));
}

function renderListRow(e) {
  const sel = selectedPaths.has(e.absolute_path);
  const del = e.is_deleted;
  const iconPx = listIconSize();
  const icon = fmIconImg(e.name, e.kind === "folder", e.absolute_path, iconPx, del);
  const detail = entryDetail(e);
  const bm = bookmarkedKeys.has(`${e.kind}:${e.id}`);
  const dropCls = e.kind === "folder" && !del ? " fm-drop-target" : "";
  return `<div class="fm-row ${sel ? "fm-row-selected" : ""} ${del ? "fm-row-deleted" : ""}${dropCls}" ${entryAttrs(e)}>
    <span class="fm-row-icon">${icon}</span>
    <div class="fm-row-text">
      <div class="fm-row-name">${esc(e.name)}${del ? ' <span class="fm-deleted-tag">Deleted</span>' : ""}</div>
      <div class="fm-row-detail">${esc(detail)}</div>
    </div>
    ${bookmarkBtn(e, bm)}
  </div>`;
}

function renderGridTile(e) {
  const sel = selectedPaths.has(e.absolute_path);
  const del = e.is_deleted;
  const iconPx = gridIconSize();
  const icon = fmIconImg(e.name, e.kind === "folder", e.absolute_path, iconPx, del);
  const bm = bookmarkedKeys.has(`${e.kind}:${e.id}`);
  const dropCls = e.kind === "folder" && !del ? " fm-drop-target" : "";
  return `<div class="fm-grid-tile ${sel ? "fm-grid-tile-selected" : ""} ${del ? "fm-row-deleted" : ""}${dropCls}" ${entryAttrs(e)}>
    <span class="fm-grid-icon">${icon}</span>
    <span class="fm-grid-name">${esc(e.name)}${del ? ' <span class="fm-deleted-tag">Deleted</span>' : ""}</span>
    ${bookmarkBtn(e, bm)}
  </div>`;
}

function renderList() {
  $("loading-msg").classList.toggle("hidden", !loading);
  $("empty-msg").classList.toggle("hidden", loading || visibleEntries().length > 0);
  $("load-more-btn").classList.toggle("hidden", searchActive || !hasMoreFiles);
  const list = $("file-list");
  if (loading) { list.innerHTML = ""; return; }
  tryAutoSelectFirst();
  const entries = visibleEntries();
  if (viewStyle === "grid") {
    list.className = "fm-grid";
    list.innerHTML = entries.map(renderGridTile).join("");
  } else {
    list.className = "divide-y divide-line";
    list.innerHTML = entries.map(renderListRow).join("");
  }
  updateStatus();
}

function updateStatus() {
  const n = visibleEntries().length;
  $("status-count").textContent = `${n} item${n === 1 ? "" : "s"}`;
  const sel = selectedPaths.size;
  $("status-selection").classList.toggle("hidden", !sel);
  $("status-selection").textContent = sel ? `| ${sel} selected` : "";
  $("status-clipboard").classList.toggle("hidden", !clipboard);
  $("status-clipboard").textContent = clipboard ? `| ${clipboard.op === "cut" ? "Cut" : "Copied"} ${clipboard.paths.length}` : "";
}

function renderAll() {
  renderToolbar(); renderList(); applyZoom();
  $("user-label").textContent = session?.username || session?.role || "";
  $("f-deleted-wrap").classList.toggle("hidden", !sessionUser?.allow_deleted);
}
/* ---------- context menu ---------- */

function hideCtx() {
  $("ctx-menu").classList.add("hidden");
  $("ctx-submenu").classList.add("hidden");
  ctxSubMenuOpen = null;
}

function paintCtxMenu(x, y, items) {
  const m = $("ctx-menu");
  m.innerHTML = items.map((item, i) => {
    if (item.sep) return `<div class="my-1 border-t border-line"></div>`;
    if (item.sub) return `<button data-sub="${i}" class="ctx-has-sub" ${item.disabled ? "disabled" : ""}>${esc(item.label)}</button>`;
    return `<button data-ctx="${i}" ${item.disabled ? "disabled" : ""}>${esc(item.label)}${item.shortcut ? `<span class="float-right text-faint ml-4">${esc(item.shortcut)}</span>` : ""}</button>`;
  }).join("");
  m.classList.remove("hidden");
  m.style.left = `${Math.min(x, innerWidth - 220)}px`;
  m.style.top = `${Math.min(y, innerHeight - 320)}px`;
  m.querySelectorAll("[data-ctx]").forEach((btn) => {
    const i = Number(btn.dataset.ctx);
    const item = items[i];
    if (!item?.run) return;
    btn.addEventListener("click", () => { hideCtx(); item.run(); });
  });
  m.querySelectorAll("[data-sub]").forEach((btn) => {
    const i = Number(btn.dataset.sub);
    const item = items[i];
    btn.addEventListener("mouseenter", () => showCtxSubMenu(btn, item.sub));
    btn.addEventListener("click", (ev) => { ev.stopPropagation(); showCtxSubMenu(btn, item.sub); });
  });
}

function showCtxSubMenu(anchor, subItems) {
  const sm = $("ctx-submenu");
  sm.innerHTML = subItems.map((item, i) => {
    if (item.sep) return `<div class="my-1 border-t border-line"></div>`;
    return `<button data-subctx="${i}" ${item.disabled ? "disabled" : ""}>${esc(item.label)}${item.shortcut ? `<span class="float-right text-faint ml-4">${esc(item.shortcut)}</span>` : ""}${item.selected ? " ✓" : ""}</button>`;
  }).join("");
  const r = anchor.getBoundingClientRect();
  sm.classList.remove("hidden");
  sm.style.left = `${Math.min(r.right + 2, innerWidth - 180)}px`;
  sm.style.top = `${Math.min(r.top, innerHeight - 240)}px`;
  sm.querySelectorAll("[data-subctx]").forEach((btn) => {
    const i = Number(btn.dataset.subctx);
    const item = subItems[i];
    if (!item?.run) return;
    btn.addEventListener("click", () => { hideCtx(); item.run(); });
  });
  ctxSubMenuOpen = sm;
}

function showCtx(x, y, entry) {
  const items = [];
  if (entry?.kind === "folder") items.push({ label: "Open", run: () => openFolder(entry.id, entry.name) });
  items.push({ label: "Copy path", run: () => copyPath(entry.absolute_path) });
  if (entry?.kind === "file") items.push({ label: "Download", run: () => downloadPath(entry.absolute_path, entry.name).catch((e) => toast(e.message)) });
  items.push({ label: "Copy", run: () => { selectedPaths = new Set([entry.absolute_path]); copySelected(); } });
  items.push({ label: "Cut", run: () => { selectedPaths = new Set([entry.absolute_path]); cutSelected(); } });
  if (clipboard) items.push({ label: "Paste", shortcut: "Ctrl+V", run: () => pasteClipboard() });
  items.push({ sep: true });
  items.push({ label: "Trash", run: () => { selectedPaths = new Set([entry.absolute_path]); trashSelected(); } });
  items.push({ label: "Delete permanently", run: () => { selectedPaths = new Set([entry.absolute_path]); deleteSelected(); } });
  items.push({ label: "Rename", shortcut: "F2", run: () => { selectedPaths = new Set([entry.absolute_path]); renameSelected(); } });
  items.push({ label: "Toggle bookmark", run: () => toggleBookmark(entry.kind, entry.id, entry.name) });
  items.push({ sep: true });
  items.push({ label: "Properties", run: () => openProperties(entry) });
  paintCtxMenu(x, y, items);
}

function sortMenuItems() {
  const labels = { name: "Name", modified: "Date Modified", created: "Date Created", size: "Size", type: "Type" };
  return [
    ...Object.entries(labels).map(([k, label]) => ({
      label, selected: sortBy === k, run: () => { sortBy = k; saveViewSettings(); renderList(); },
    })),
    { sep: true },
    { label: "Ascending", selected: sortDir === "asc", run: () => { sortDir = "asc"; saveViewSettings(); renderList(); } },
    { label: "Descending", selected: sortDir === "desc", run: () => { sortDir = "desc"; saveViewSettings(); renderList(); } },
  ];
}

function showEmptyCtx(x, y) {
  const items = [
    {
      label: "Layout", sub: [
        { label: "List view", selected: viewStyle === "list", run: () => { viewStyle = "list"; saveViewSettings(); renderList(); } },
        { label: "Compact view", selected: viewStyle === "grid", run: () => { viewStyle = "grid"; saveViewSettings(); renderList(); } },
      ],
    },
    { label: "Sort by", sub: sortMenuItems() },
    { label: "Refresh", shortcut: "F5", run: () => refreshFileManager({ force: true, bookmarks: true }) },
    { sep: true },
  ];
  if (canCreateHere()) {
    items.push({
      label: "New", sub: [
        { label: "Folder", shortcut: "Ctrl+Shift+N", run: () => nasCreateNewFolder() },
        { label: "File", shortcut: "Ctrl+N", run: () => nasCreateNewFile() },
      ],
    });
  }
  items.push({ label: "Paste", shortcut: "Ctrl+V", disabled: !clipboard, run: () => pasteClipboard() });
  items.push({ sep: true });
  items.push({ label: "Select all", shortcut: "Ctrl+A", run: () => { selectedPaths = new Set(visibleEntries().map((e) => e.absolute_path)); renderList(); } });
  items.push({ label: "Invert selection", run: invertSelection });
  if (selectedPaths.size) items.push({ label: "Clear selection", run: () => { selectedPaths.clear(); anchorPath = null; renderList(); } });
  paintCtxMenu(x, y, items);
}

function openAdmin() {
  $("admin-overlay").classList.remove("hidden");
  if (manageUnlocked) {
    $("admin-gate").classList.add("hidden");
    $("admin-body").classList.remove("hidden");
    renderAdminTab(manageActiveTab);
  } else {
    $("admin-gate").classList.remove("hidden");
    $("admin-body").classList.add("hidden");
    $("admin-gate-pwd").value = "";
    $("admin-gate-err").classList.add("hidden");
    $("admin-gate-pwd").focus();
  }
}

function closeAdmin() {
  manageUnlocked = false;
  $("admin-gate-pwd").value = "";
  $("admin-save-pwd").value = "";
  $("admin-gate").classList.remove("hidden");
  $("admin-body").classList.add("hidden");
  $("admin-overlay").classList.add("hidden");
}

function openShortcuts() {
  showShortcuts = true;
  $("shortcuts-overlay").classList.remove("hidden");
  renderShortcutsList();
  $("shortcuts-search").value = "";
  $("shortcuts-search").focus();
}

function closeShortcuts() {
  showShortcuts = false;
  $("shortcuts-overlay").classList.add("hidden");
}

const SETTINGS_PAGES = [
  { id: "appearance", label: "Appearance" },
  { id: "view", label: "File View" },
  { id: "mounts", label: "Mount Mappings" },
  { id: "shortcuts", label: "Shortcuts" },
];

function openSettings() {
  $("settings-overlay").classList.remove("hidden");
  renderSettingsPage(settingsPage);
}

function closeSettings() {
  $("settings-overlay").classList.add("hidden");
}

function renderSettingsPage(page) {
  settingsPage = page;
  const pages = [...SETTINGS_PAGES];
  if (session?.role === "admin") pages.push({ id: "admin", label: "Administration" });
  $("settings-tabs").innerHTML = pages.map((p) =>
    `<button data-spage="${p.id}" class="fm-settings-tab ${p.id === page ? "fm-settings-tab-active" : ""}">${esc(p.label)}</button>`
  ).join("");
  $("settings-tabs").querySelectorAll("[data-spage]").forEach((b) => b.onclick = () => renderSettingsPage(b.dataset.spage));
  const c = $("settings-content");
  if (page === "appearance") {
    const theme = loadTheme();
    c.innerHTML = `
      <div class="p-6 space-y-4 max-w-lg">
        <h3 class="text-[10px] font-black tracking-wider text-muted uppercase">Theme</h3>
        <div class="flex gap-2">
          ${["system", "light", "dark"].map((t) => `<button data-theme-pick="${t}" class="rounded-md border px-3 py-1.5 text-xs ${theme === t ? "border-ink bg-panel-muted font-semibold" : "border-line hover:border-line-strong"}">${t}</button>`).join("")}
        </div>
        <h3 class="text-[10px] font-black tracking-wider text-muted uppercase pt-2">Zoom</h3>
        <p class="text-xs text-muted">Matches desktop status bar: ${Math.round(gridZoom / 1.4 * 100)}% (Ctrl+− / Ctrl++ / Ctrl+0)</p>
        <div class="flex items-center gap-2">
          <button id="set-zoom-out" class="rounded border border-line px-3 py-1 text-xs hover:border-brand">−</button>
          <span class="text-sm font-semibold min-w-[4rem] text-center">${Math.round(gridZoom / 1.4 * 100)}%</span>
          <button id="set-zoom-in" class="rounded border border-line px-3 py-1 text-xs hover:border-brand">+</button>
          <button id="set-zoom-reset" class="rounded border border-line px-3 py-1 text-xs hover:border-brand ml-2">Reset</button>
        </div>
      </div>`;
    c.querySelectorAll("[data-theme-pick]").forEach((b) => b.onclick = () => {
      localStorage.setItem(THEME_KEY, b.dataset.themePick);
      applyThemeAttr(b.dataset.themePick);
      [$("login-theme-btn"), $("setup-theme-btn")].forEach((btn) => { if (btn) btn.innerHTML = isDark(b.dataset.themePick) ? I.moon : I.sun; });
      renderSettingsPage("appearance");
    });
    $("set-zoom-in").onclick = () => { zoomIn(); renderSettingsPage("appearance"); };
    $("set-zoom-out").onclick = () => { zoomOut(); renderSettingsPage("appearance"); };
    $("set-zoom-reset").onclick = () => { resetZoom(); renderSettingsPage("appearance"); };
  } else if (page === "view") {
    c.innerHTML = `
      <div class="p-6 space-y-4 max-w-lg">
        <h3 class="text-[10px] font-black tracking-wider text-muted uppercase">Layout</h3>
        <div class="flex gap-2">
          <button data-vstyle="list" class="rounded-md border px-3 py-1.5 text-xs ${viewStyle === "list" ? "border-ink bg-panel-muted font-semibold" : "border-line"}">List view</button>
          <button data-vstyle="grid" class="rounded-md border px-3 py-1.5 text-xs ${viewStyle === "grid" ? "border-ink bg-panel-muted font-semibold" : "border-line"}">Compact view</button>
        </div>
        <h3 class="text-[10px] font-black tracking-wider text-muted uppercase pt-2">Sort</h3>
        <p class="text-xs text-muted">Sort by ${sortBy}, ${sortDir === "asc" ? "ascending" : "descending"}, folders ${foldersFirst ? "first" : "mixed"}</p>
        <p class="text-xs text-faint">Use the empty-area context menu for sort options.</p>
      </div>`;
    c.querySelectorAll("[data-vstyle]").forEach((b) => b.onclick = () => {
      viewStyle = b.dataset.vstyle;
      saveViewSettings();
      renderAll();
      renderSettingsPage("view");
    });
  } else if (page === "mounts") {
    c.innerHTML = `
      <div class="p-6 max-w-2xl">
        <h3 class="text-[10px] font-black tracking-wider text-muted uppercase">NAS Mount Mappings</h3>
        <p class="text-xs text-muted mt-2 mb-4 leading-relaxed">Map watched folder paths on your NAS (e.g. /data/pool/media) to local mount points on this computer so copy-path uses the correct local path.</p>
        <div class="flex gap-2 mb-4">
          <input id="mount-nas-draft" value="${esc(mountNasDraft)}" placeholder="NAS path prefix (e.g. /data/pool/media)" class="flex-1 rounded-md border border-line bg-bg px-3 py-2 text-xs outline-none focus:border-brand" />
          <input id="mount-local-draft" value="${esc(mountLocalDraft)}" placeholder="Local path (e.g. /mnt/media)" class="flex-1 rounded-md border border-line bg-bg px-3 py-2 text-xs outline-none focus:border-brand" />
          <button id="mount-add" class="rounded-md bg-ink text-on-brand px-3 py-2 text-xs font-semibold shrink-0">Add</button>
        </div>
        <div id="mount-list">${mountMappings.length ? mountMappings.map((m, i) => `
          <div class="py-3 border-b border-line flex gap-3 items-start">
            <div class="flex-1 min-w-0">
              <p class="text-xs text-muted">NAS: <span class="text-ink font-mono">${esc(m.nasPath)}</span></p>
              <p class="text-xs text-muted mt-1">Local: <span class="text-ink font-mono">${esc(m.localPath)}</span></p>
            </div>
            <button data-rm-mount="${i}" class="text-danger text-xs hover:underline shrink-0">Delete</button>
          </div>`).join("") : '<p class="text-xs text-faint py-4">No mount mappings defined.</p>'}</div>
      </div>`;
    $("mount-nas-draft").oninput = (ev) => { mountNasDraft = ev.target.value; };
    $("mount-local-draft").oninput = (ev) => { mountLocalDraft = ev.target.value; };
    $("mount-add").onclick = () => {
      const nas = mountNasDraft.trim();
      const local = mountLocalDraft.trim();
      if (!nas || !local) { toast("Enter both NAS and local paths"); return; }
      mountMappings = [...mountMappings, { nasPath: nas, localPath: local }];
      mountNasDraft = "";
      mountLocalDraft = "";
      saveMountMappings();
      renderSettingsPage("mounts");
    };
    c.querySelectorAll("[data-rm-mount]").forEach((b) => b.onclick = () => {
      mountMappings = mountMappings.filter((_, i) => i !== Number(b.dataset.rmMount));
      saveMountMappings();
      renderSettingsPage("mounts");
    });
  } else if (page === "shortcuts") {
    c.innerHTML = `<div class="p-6"><p class="text-xs text-muted mb-3">Keyboard shortcuts reference (Ctrl+/)</p><button id="set-open-shortcuts" class="rounded-md bg-ink text-on-brand px-4 py-2 text-xs font-semibold">Open shortcuts</button></div>`;
    $("set-open-shortcuts").onclick = () => { closeSettings(); openShortcuts(); };
  } else if (page === "admin") {
    c.innerHTML = `<div class="p-6"><p class="text-xs text-muted mb-3">Agent management console (requires management password each time you open it).</p><button id="set-open-admin" class="rounded-md bg-ink text-on-brand px-4 py-2 text-xs font-semibold">Open Management Console</button></div>`;
    $("set-open-admin").onclick = () => { closeSettings(); openAdmin(); };
  }
}

function fmtCount(n) {
  return Number(n).toLocaleString("en-US");
}

function fmtPropDate(secs) {
  if (!secs) return "—";
  try {
    const dt = new Date(secs * 1000);
    const months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
    const weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
    const hour = dt.getHours() === 0 ? 12 : (dt.getHours() > 12 ? dt.getHours() - 12 : dt.getHours());
    const ampm = dt.getHours() >= 12 ? "PM" : "AM";
    const min = String(dt.getMinutes()).padStart(2, "0");
    return `${weekdays[(dt.getDay() + 6) % 7]}, ${months[dt.getMonth()]} ${dt.getDate()}, ${dt.getFullYear()}, ${String(hour).padStart(2, "0")}:${min} ${ampm}`;
  } catch { return "—"; }
}

function humanFileType(mime, name) {
  const ext = name.includes(".") ? name.split(".").pop().toLowerCase() : "";
  const extLabel = ext ? ` (.${ext})` : "";
  if (!mime) return ext ? `${ext.toUpperCase()} File` : "File";
  const parts = mime.split("/");
  if (parts.length < 2) return ext ? `${ext.toUpperCase()} File` : "File";
  const sub = parts[1].toLowerCase();
  const map = {
    jpeg: "JPEG Image", jpg: "JPEG Image", png: "PNG Image", gif: "GIF Image", webp: "WebP Image",
    "svg+xml": "SVG Image", mp4: "MPEG-4 Video", "x-matroska": "Matroska Video", webm: "WebM Video",
    pdf: "PDF Document", zip: "ZIP Archive", json: "JSON File", plain: "Plain Text",
    javascript: "JavaScript File", "x-python": "Python Script", "x-sh": "Shell Script",
  };
  let label = map[sub];
  if (!label) {
    if (parts[0] === "image") label = "Image";
    else if (parts[0] === "video") label = "Video";
    else if (parts[0] === "audio") label = "Audio";
    else if (parts[0] === "text") label = "Text File";
    else label = ext ? `${ext.toUpperCase()} File` : "File";
  }
  return `${label}${extLabel}`;
}

function propRow(label, value, opts = {}) {
  if (!value || value === "—") return "";
  const copyBtn = opts.copyable ? `<button type="button" class="prop-copy shrink-0 text-faint hover:text-brand p-0.5" data-copy="${esc(value)}" title="Copy">${svg('<rect width="8" height="10" x="8" y="8" rx="1"/><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h2"/>', "w-3.5 h-3.5")}</button>` : "";
  return `<div class="fm-prop-row"><span class="fm-prop-label">${esc(label)}</span><span class="fm-prop-value ${opts.mono ? "font-mono text-[11px]" : ""}">${esc(value)}</span>${copyBtn}</div>`;
}

function permChip(label, on) {
  return `<span class="fm-perm-chip ${on ? "fm-perm-chip-on" : "fm-perm-chip-off"}">${label}</span>`;
}

function permGroupHtml(title, bits) {
  return `<div class="fm-perm-group"><p class="fm-perm-group-title">${esc(title)}</p><div class="fm-perm-chips">${permChip("R", bits[0] === "r")}${permChip("W", bits[1] === "w")}${permChip("X", bits[2] === "x")}</div></div>`;
}

function permGridHtml(permissions) {
  if (!permissions || permissions.length < 9) {
    return permissions ? `<p class="font-mono text-xs text-muted">${esc(permissions)}</p>` : '<p class="text-xs text-muted py-2">Permissions unavailable.</p>';
  }
  return `<div class="fm-perm-groups">${permGroupHtml("Owner", permissions.slice(0, 3))}${permGroupHtml("Group", permissions.slice(3, 6))}${permGroupHtml("Others", permissions.slice(6, 9))}</div><p class="font-mono text-[11px] text-faint mt-2">Octal: ${esc(permissions)}</p>`;
}

function volumeRingSvg(pct) {
  const r = 28;
  const c = 2 * Math.PI * r;
  const off = c * (1 - Math.min(1, Math.max(0, pct)));
  const color = pct > 0.9 ? "var(--color-danger)" : "var(--color-ink)";
  return `<svg viewBox="0 0 64 64"><circle cx="32" cy="32" r="${r}" fill="none" stroke="var(--color-line)" stroke-width="5"/><circle cx="32" cy="32" r="${r}" fill="none" stroke="${color}" stroke-width="5" stroke-dasharray="${c}" stroke-dashoffset="${off}" transform="rotate(-90 32 32)" stroke-linecap="round"/></svg>`;
}

function volumeLegendRow(dotColor, label, value) {
  return `<div class="fm-volume-legend-row"><span class="fm-volume-dot" style="background:${dotColor}"></span><span class="w-[72px] font-semibold text-muted">${esc(label)}</span><span class="text-ink">${esc(value)}</span></div>`;
}

function volumeCardHtml(vol) {
  if (!vol) return '<p class="text-xs text-muted">Partition details unavailable.</p>';
  const pct = vol.total_bytes > 0 ? vol.used_bytes / vol.total_bytes : 0;
  const pctLabel = `${Math.round(pct * 100)}%`;
  return `<div class="fm-volume-card">
    <div class="fm-volume-ring">${volumeRingSvg(pct)}<span class="fm-volume-ring-label">${pctLabel}</span></div>
    <div class="fm-volume-legend">
      ${volumeLegendRow("var(--color-ink)", "Used space", fmtBytes(vol.used_bytes))}
      ${volumeLegendRow("var(--color-line)", "Free space", fmtBytes(vol.available_bytes))}
      ${volumeLegendRow("var(--color-muted)", "Capacity", fmtBytes(vol.total_bytes))}
      <p class="text-[11px] text-faint mt-2">${esc(vol.device)} · ${esc(vol.fs_type)}</p>
      <p class="text-[11px] font-mono text-muted">${esc(vol.mount_path)}</p>
    </div>
  </div>`;
}

function hashRowHtml(label, value) {
  return `<div class="fm-hash-row"><span class="w-20 shrink-0 text-xs font-bold text-muted">${esc(label)}</span><code class="fm-hash-val">${esc(value)}</code><button type="button" class="prop-copy text-faint hover:text-brand" data-copy="${esc(value)}">${svg('<rect width="8" height="10" x="8" y="8" rx="1"/><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h2"/>', "w-3.5 h-3.5")}</button></div>`;
}

function propsQuery(entry) {
  return qs({ path: entry.absolute_path, id: entry.id, kind: entry.kind });
}

async function loadPropertiesData(entry) {
  propertiesLoading = true;
  propertiesError = null;
  propertiesData = null;
  propertiesVolume = null;
  propertiesSummary = null;
  propertiesHashes = null;
  propertiesHashesError = null;
  renderProperties();
  const q = propsQuery(entry);
  try {
    const [props, vol, summary] = await Promise.all([
      apiGet(`/api/fs/properties${q}`),
      apiGet(`/api/fs/volume${qs({ path: entry.absolute_path })}`).catch(() => null),
      entry.kind === "folder" && !entry.is_deleted
        ? apiGet(`/api/fs/folder-summary${qs({ path: entry.absolute_path })}`).catch(() => null)
        : Promise.resolve(null),
    ]);
    propertiesData = props;
    propertiesVolume = vol;
    propertiesSummary = summary;
  } catch (e) {
    propertiesError = e.message || "Could not load properties.";
  } finally {
    propertiesLoading = false;
    renderProperties();
  }
}

function canCalculateHashes() {
  const p = propertiesData;
  return p && p.live && !p.is_dir && !p.is_deleted;
}

async function calculatePropertyHashes() {
  const entry = propertiesEntry;
  const p = propertiesData;
  if (!entry || !p || !canCalculateHashes()) return;
  propertiesHashesLoading = true;
  propertiesHashesError = null;
  renderProperties();
  try {
    propertiesHashes = await apiGet(`/api/fs/hashes${qs({ path: p.absolute_path || entry.absolute_path })}`);
  } catch (e) {
    propertiesHashesError = e.message || "Hash calculation failed.";
  } finally {
    propertiesHashesLoading = false;
    renderProperties();
  }
}

function switchPropertiesTab(tab) {
  propertiesTab = tab;
  if (tab === "storage" && canCalculateHashes() && !propertiesHashes && !propertiesHashesLoading && !propertiesHashesError) {
    calculatePropertyHashes();
  }
  renderProperties();
}

function openProperties(entry) {
  propertiesEntry = entry || visibleEntries().find((e) => selectedPaths.has(e.absolute_path)) || null;
  if (!propertiesEntry) return;
  propertiesTab = "general";
  $("properties-overlay").classList.remove("hidden");
  loadPropertiesData(propertiesEntry);
}

function closeProperties() {
  propertiesEntry = null;
  propertiesData = null;
  propertiesVolume = null;
  propertiesSummary = null;
  propertiesHashes = null;
  propertiesError = null;
  $("properties-overlay").classList.add("hidden");
}

function renderProperties() {
  const e = propertiesEntry;
  if (!e) return;
  const p = propertiesData;
  const iconPx = 48;
  const icon = fmIconImg(e.name, e.kind === "folder", e.absolute_path, iconPx, e.is_deleted || p?.is_deleted);
  const mapped = mapNasToLocal(p?.absolute_path || e.absolute_path);
  const tabs = [
    ["general", "General"],
    ["advanced", "Advanced & Permissions"],
    ["storage", "Storage & Integrity"],
  ];

  if (propertiesLoading) {
    $("properties-box").innerHTML = `<div class="flex items-center justify-center" style="min-height:240px"><p class="text-sm text-brand animate-pulse">Loading…</p></div>`;
    return;
  }

  if (propertiesError && !p) {
    $("properties-box").innerHTML = `
      <div class="p-6 text-center">
        <p class="text-sm text-danger mb-4">${esc(propertiesError)}</p>
        <button id="properties-close-btn" class="fm-props-btn-cancel">Close</button>
      </div>`;
    $("properties-close-btn").onclick = closeProperties;
    return;
  }

  let body = "";
  if (propertiesTab === "general" && p) {
    const typeLabel = p.is_dir ? "Folder" : humanFileType(p.mime_type, p.name);
    const sizeBytes = p.is_dir ? (propertiesSummary?.total_size ?? p.size) : p.size;
    const sizeStr = p.is_dir
      ? (propertiesSummary ? `${fmtBytes(sizeBytes)} (${fmtCount(sizeBytes)} bytes)` : (propertiesSummary === null ? "Calculating…" : "—"))
      : `${fmtBytes(sizeBytes)} (${fmtCount(sizeBytes)} bytes)`;
    const contains = p.is_dir
      ? (propertiesSummary ? `${fmtCount(propertiesSummary.file_count)} files, ${fmtCount(propertiesSummary.folder_count)} folders${propertiesSummary.truncated ? " (truncated)" : ""}` : "Scanning subfolders…")
      : "";
    const readOnly = p.permissions && !p.permissions.includes("w");
    const hidden = p.name.startsWith(".");
    body = [
      propRow("Type of File", typeLabel),
      propRow("Location", p.absolute_path, { copyable: true, mono: true }),
      mapped !== p.absolute_path ? propRow("Local path", mapped, { copyable: true, mono: true }) : "",
      propRow("Size", sizeStr),
      contains ? propRow("Contains", contains) : "",
      '<div class="my-2 border-t border-line"></div>',
      propRow("Created", fmtPropDate(p.created_secs)),
      propRow("Modified", fmtPropDate(p.modified_secs)),
      propRow("Accessed", fmtPropDate(p.accessed_secs)),
      p.is_deleted ? propRow("Deleted", p.deleted_at ? fmtDate(p.deleted_at) : "Yes") : "",
      p.indexed_at ? propRow("Indexed", fmtDate(p.indexed_at)) : "",
      !p.live ? propRow("Data source", "Index (file not on disk)") : "",
      '<div class="my-2 border-t border-line"></div>',
      `<div class="fm-prop-row"><span class="fm-prop-label">Attributes</span><span class="flex gap-4 text-xs"><label class="flex items-center gap-1"><input type="checkbox" disabled ${readOnly ? "checked" : ""}/> Read-only</label><label class="flex items-center gap-1"><input type="checkbox" disabled ${hidden ? "checked" : ""}/> Hidden</label></span></div>`,
    ].join("");
  } else if (propertiesTab === "advanced" && p) {
    body = [
      p.owner ? propRow("Owner", p.owner) : "",
      p.group ? propRow("Group", p.group) : "",
      p.permissions ? permGridHtml(p.permissions) : "",
      p.symlink_target ? propRow("Symlink Target", p.symlink_target, { copyable: true, mono: true }) : "",
      p.index_id != null ? propRow("Index ID", String(p.index_id)) : "",
      p.index_kind ? propRow("Index kind", p.index_kind) : "",
      propRow("Live on disk", p.live ? "Yes" : "No (ghost/index only)"),
    ].join("");
  } else if (propertiesTab === "storage") {
    const hashBlock = propertiesHashesLoading
      ? '<div class="flex items-center gap-3 py-3"><span class="inline-block w-4 h-4 rounded-full border-2 border-brand border-t-transparent animate-spin"></span><span class="text-xs text-muted">Computing hashes…</span></div>'
      : propertiesHashes
        ? [hashRowHtml("MD5", propertiesHashes.md5), hashRowHtml("SHA-1", propertiesHashes.sha1), hashRowHtml("SHA-256", propertiesHashes.sha256), hashRowHtml("CRC32", propertiesHashes.crc32)].join("")
        : (propertiesHashesError ? `<p class="text-xs text-danger mb-2">${esc(propertiesHashesError)}</p>` : "")
          + (canCalculateHashes()
            ? `<button id="prop-calc-hashes" type="button" class="fm-props-hash-btn">${I.fingerprint}<span>Calculate Checksums</span></button>`
            : `<p class="text-xs text-muted">${p?.is_dir ? "Checksums apply to files only." : p?.is_deleted || !p?.live ? "Checksums require a live file on disk." : "Select a file to calculate checksums."}</p>`);
    body = [
      '<p class="fm-props-section-title">DISK / PARTITION INFO</p>',
      volumeCardHtml(propertiesVolume),
      '<div class="my-4 border-t border-line"></div>',
      '<p class="fm-props-section-title">FILE CHECKSUMS (INTEGRITY)</p>',
      hashBlock,
    ].join("");
  }

  $("properties-box").innerHTML = `
    <div class="fm-props-header shrink-0 flex items-center gap-4 border-b border-line">
      <span class="shrink-0">${icon}</span>
      <input id="prop-name" class="fm-props-name" value="${esc(p?.name || e.name)}" readonly />
      ${(p?.is_deleted || e.is_deleted) ? '<span class="fm-deleted-tag shrink-0">Deleted</span>' : ""}
    </div>
    <div class="fm-props-tabs shrink-0 flex overflow-x-auto">${tabs.map(([id, label]) =>
      `<button type="button" data-ptab="${id}" class="fm-prop-tab ${propertiesTab === id ? "fm-prop-tab-active" : ""}">${label}</button>`
    ).join("")}</div>
    <div class="fm-props-body flex-1 overflow-y-auto min-h-0">${body || '<p class="text-muted">No data for this tab.</p>'}</div>
    <div class="fm-props-footer shrink-0">
      <button type="button" id="properties-close-btn" class="fm-props-btn-cancel">Cancel</button>
      <button type="button" id="properties-ok-btn" class="fm-props-btn-ok">OK</button>
    </div>`;

  $("properties-close-btn").onclick = closeProperties;
  $("properties-ok-btn").onclick = closeProperties;
  $("properties-box").querySelectorAll("[data-ptab]").forEach((b) => b.onclick = () => switchPropertiesTab(b.dataset.ptab));
  $("prop-calc-hashes")?.addEventListener("click", calculatePropertyHashes);
  $("properties-box").querySelectorAll(".prop-copy").forEach((btn) => {
    btn.onclick = async () => {
      const t = btn.dataset.copy;
      try { await navigator.clipboard.writeText(t); toast("Copied"); } catch { toast(t); }
    };
  });
}

function renderShortcutsList() {
  const q = ($("shortcuts-search")?.value || "").trim().toLowerCase();
  const filtered = !q ? KEYBOARD_SHORTCUTS : KEYBOARD_SHORTCUTS.filter((s) => {
    if (s.h) return false;
    return s.d.toLowerCase().includes(q) || (s.k || "").toLowerCase().includes(q);
  });
  const list = $("shortcuts-list");
  if (!filtered.length) {
    list.innerHTML = `<p class="text-xs text-faint text-center py-8">No shortcuts match "${esc(q)}"</p>`;
    return;
  }
  list.innerHTML = filtered.map((s) => {
    if (s.h) return `<p class="text-[9px] font-black tracking-wider text-muted uppercase mt-3 mb-1.5 first:mt-0">${esc(s.h)}</p>`;
    return `<div class="flex items-center gap-2 py-1"><span class="flex-1 text-xs text-muted">${esc(s.d)}</span><kbd class="shrink-0 rounded border border-line bg-panel-soft px-2 py-0.5 text-[10px] font-mono font-bold text-ink">${esc(s.k)}</kbd></div>`;
  }).join("");
}

/* ---------- events ---------- */

function bindUi() {
  if (uiBound) return;
  uiBound = true;
  [$("login-theme-btn"), $("setup-theme-btn")].forEach((b) => { if (b) { b.innerHTML = isDark(loadTheme()) ? I.moon : I.sun; b.onclick = toggleTheme; } });
  $("btn-back").onclick = nasNavigateBack;
  $("btn-forward").onclick = nasNavigateForward;
  $("btn-up").onclick = nasNavigateUp;
  $("btn-refresh").onclick = () => refreshFileManager({ force: true, bookmarks: true });
  $("btn-view").onclick = () => { viewStyle = viewStyle === "grid" ? "list" : "grid"; saveViewSettings(); renderAll(); };
  $("btn-filters").onclick = () => { showFilters = !showFilters; renderToolbar(); };
  $("btn-logout").innerHTML = I.logOut;
  $("btn-logout").onclick = () => { skipAutoLoginOnce = true; clearSession(); showPhase("login"); showLogin(); };
  $("admin-close").innerHTML = I.x;
  $("admin-close-gate").innerHTML = I.x;
  $("admin-close").onclick = closeAdmin;
  $("admin-close-gate").onclick = closeAdmin;
  $("shortcuts-close").innerHTML = I.x;
  $("shortcuts-icon").innerHTML = I.keyboard;
  $("shortcuts-close").onclick = closeShortcuts;
  $("shortcuts-overlay").onclick = (ev) => { if (ev.target === $("shortcuts-overlay")) closeShortcuts(); };
  $("shortcuts-box")?.addEventListener("click", (ev) => ev.stopPropagation());
  $("shortcuts-search")?.addEventListener("input", renderShortcutsList);
  $("admin-pwd-toggle").innerHTML = I.eye;
  $("admin-pwd-toggle").onclick = () => {
    adminShowPwd = !adminShowPwd;
    $("admin-save-pwd").type = adminShowPwd ? "text" : "password";
    $("admin-pwd-toggle").innerHTML = adminShowPwd ? I.eyeOff : I.eye;
  };

  $("breadcrumbs").onclick = (ev) => {
    const b = ev.target.closest("[data-crumb]");
    if (!b) return;
    const idx = Number(b.dataset.crumb);
    if (idx === 0) return nasNavigateHome();
    const target = crumbs()[idx];
    nasBackStack = nasBackStack.slice(0, idx - 1);
    parentId = target.id; nasCurrentName = target.name;
    triggerAutoSelect();
    fileOffset = 0; refreshFileManager();
  };

  $("bookmarks-list").onclick = (ev) => {
    const b = ev.target.closest("[data-bm]");
    if (!b || b.disabled) return;
    const fid = b.dataset.fid;
    if (fid) openFolder(Number(fid), b.dataset.label);
  };

  $("search-input").addEventListener("keydown", (ev) => {
    if (ev.key === "Enter") { searchActive = true; fileOffset = 0; refreshFileManager(); }
    if (ev.key === "Escape") { searchActive = false; ev.target.value = ""; fileOffset = 0; refreshFileManager(); }
  });

  $("f-apply-search").onclick = () => { searchActive = true; fileOffset = 0; refreshFileManager(); };
  $("f-clear").onclick = () => {
    ["f-size-min", "f-size-max"].forEach((id) => { $(id).value = ""; });
    $("f-size-unit").value = "MB"; $("f-created").value = ""; $("f-modified").value = "";
    $("f-type").value = "all"; $("f-include-deleted").checked = false;
    refreshFileManager();
  };
  ["f-size-min", "f-size-max", "f-size-unit", "f-created", "f-modified", "f-type"].forEach((id) => {
    $(id).addEventListener("change", () => { if (!searchActive) renderList(); });
  });
  $("f-include-deleted").addEventListener("change", () => refreshFileManager());

  $("load-more-btn").onclick = async () => {
    fileOffset += FILE_PAGE;
    await loadBrowse(true);
    renderList();
  };

  let lastTap = { path: null, t: 0 };
  const DBL_MS = 280;

  function activateEntry(entry) {
    if (entry?.kind === "folder" && !entry.is_deleted) openFolder(entry.id, entry.name);
    else if (entry?.kind === "file" && !entry.is_deleted) downloadPath(entry.absolute_path, entry.name).catch((e) => toast(e.message));
  }

  function selectRow(path, ev) {
    if (ev.shiftKey && anchorPath) {
      const entries = visibleEntries();
      const ai = entries.findIndex((e) => e.absolute_path === anchorPath);
      const bi = entries.findIndex((e) => e.absolute_path === path);
      if (ai >= 0 && bi >= 0) {
        const [lo, hi] = ai < bi ? [ai, bi] : [bi, ai];
        for (let i = lo; i <= hi; i++) selectedPaths.add(entries[i].absolute_path);
      }
    } else if (ev.ctrlKey || ev.metaKey) {
      if (selectedPaths.has(path)) selectedPaths.delete(path); else selectedPaths.add(path);
      anchorPath = path;
    } else {
      selectedPaths = new Set([path]);
      anchorPath = path;
    }
    renderList();
  }

  $("file-list").addEventListener("mousedown", (ev) => {
    if (ev.button !== 0) return;
    if (ev.target.closest("[data-bm-toggle]")) return;
    const row = ev.target.closest("[data-path]");
    if (!row) return;
    ev.preventDefault();
    const path = row.dataset.path;
    const now = Date.now();
    const isDouble = lastTap.path === path && now - lastTap.t < DBL_MS;
    lastTap = { path, t: now };
    if (isDouble) {
      const entry = visibleEntries().find((e) => e.absolute_path === path);
      activateEntry(entry);
      return;
    }
    selectRow(path, ev);
  });

  $("file-list").addEventListener("dblclick", (ev) => ev.preventDefault());

  $("file-list").addEventListener("click", (ev) => {
    const b = ev.target.closest("[data-bm-toggle]");
    if (!b) return;
    const [kind, id] = b.dataset.bmToggle.split(":");
    toggleBookmark(kind, Number(id), b.dataset.label);
  });

  $("file-list").addEventListener("contextmenu", (ev) => {
    ev.preventDefault();
    const row = ev.target.closest("[data-path]");
    if (!row) { showEmptyCtx(ev.clientX, ev.clientY); return; }
    if (!selectedPaths.has(row.dataset.path)) { selectedPaths = new Set([row.dataset.path]); renderList(); }
    const entry = visibleEntries().find((e) => e.absolute_path === row.dataset.path);
    showCtx(ev.clientX, ev.clientY, entry);
  });

  $("file-panel").addEventListener("contextmenu", (ev) => {
    if (ev.target.closest("[data-path]")) return;
    ev.preventDefault();
    showEmptyCtx(ev.clientX, ev.clientY);
  });

  $("file-panel").addEventListener("mousedown", (ev) => {
    if (ev.target.closest("[data-path]") || ev.target.closest("[data-bm-toggle]")) return;
    if (ev.button === 0) { selectedPaths.clear(); anchorPath = null; renderList(); }
  });

  const panel = $("file-panel");
  panel.addEventListener("dragenter", (ev) => {
    ev.preventDefault();
    dropDepth++;
    setDropOverlay(true);
  });
  panel.addEventListener("dragleave", () => {
    dropDepth = Math.max(0, dropDepth - 1);
    if (dropDepth === 0) { setDropOverlay(false); setDropHover(null); }
  });
  panel.addEventListener("dragover", (ev) => {
    ev.preventDefault();
    ev.dataTransfer.dropEffect = "copy";
    const folder = ev.target.closest(".fm-drop-target");
    setDropHover(folder?.dataset.path || null);
  });
  panel.addEventListener("drop", async (ev) => {
    ev.preventDefault();
    dropDepth = 0;
    setDropOverlay(false);
    const folder = ev.target.closest(".fm-drop-target");
    const dest = folder?.dataset.path || currentAbsPath;
    setDropHover(null);
    await uploadDroppedFiles(ev.dataTransfer, dest);
  });

  document.addEventListener("click", (ev) => {
    if (!$("ctx-menu").contains(ev.target) && !$("ctx-submenu").contains(ev.target)) hideCtx();
  });

  $("btn-settings").onclick = openSettings;
  $("settings-close").innerHTML = I.x;
  $("settings-close").onclick = closeSettings;
  $("properties-overlay").onclick = (ev) => { if (ev.target === $("properties-overlay")) closeProperties(); };
  $("properties-box")?.addEventListener("click", (ev) => ev.stopPropagation());
  $("status-bar")?.addEventListener("wheel", (ev) => {
    if (!ev.ctrlKey && !ev.metaKey) return;
    ev.preventDefault();
    if (ev.deltaY < 0) zoomIn(); else zoomOut();
  }, { passive: false });
  $("modal-overlay").onclick = (ev) => { if (ev.target === $("modal-overlay")) $("modal-overlay").classList.add("hidden"); };

  $("admin-gate-btn").onclick = unlockAdmin;
  $("admin-gate-pwd").addEventListener("keydown", (ev) => { if (ev.key === "Enter") unlockAdmin(); });
  $("admin-save-btn").onclick = saveAdminSettings;

  document.addEventListener("keydown", onKeyDown);
  $("file-panel").addEventListener("click", () => $("file-panel").focus());
}

function onKeyDown(ev) {
  const ctrl = ev.ctrlKey || ev.metaKey;
  if (ctrl && ev.key === "/") { ev.preventDefault(); showShortcuts ? closeShortcuts() : openShortcuts(); return; }
  if (isInputFocused()) {
    if (ev.key === "Escape") document.activeElement?.blur?.();
    return;
  }
  if (ev.key === "F5") { ev.preventDefault(); refreshFileManager(); return; }
  if (ev.altKey && ev.key === "ArrowLeft") { ev.preventDefault(); nasNavigateBack(); return; }
  if (ev.altKey && ev.key === "ArrowRight") { ev.preventDefault(); nasNavigateForward(); return; }
  if (ev.altKey && ev.key === "ArrowUp") { ev.preventDefault(); nasNavigateUp(); return; }
  if (ev.key === "Backspace" && !ctrl) { ev.preventDefault(); nasNavigateUp(); return; }
  if (ev.key === "/" || (ctrl && ev.key === "f")) { ev.preventDefault(); $("search-input").focus(); return; }
  if (ctrl && ev.key === "c") { ev.preventDefault(); copySelected(); return; }
  if (ctrl && ev.key === "x") { ev.preventDefault(); cutSelected(); return; }
  if (ctrl && ev.key === "v") { ev.preventDefault(); pasteClipboard(); return; }
  if (ev.key === "Delete" && ev.shiftKey) { ev.preventDefault(); deleteSelected(); return; }
  if (ev.key === "Delete") { ev.preventDefault(); trashSelected(); return; }
  if (ev.key === "F2") { ev.preventDefault(); renameSelected(); return; }
  if (ctrl && ev.key === "a") { ev.preventDefault(); selectedPaths = new Set(visibleEntries().map((e) => e.absolute_path)); renderList(); return; }
  if (ctrl && ev.shiftKey && ev.key === "N") { ev.preventDefault(); nasCreateNewFolder(); return; }
  if (ctrl && ev.key === "n" && !ev.shiftKey) { ev.preventDefault(); nasCreateNewFile(); return; }
  if (ctrl && ev.key === "s") { ev.preventDefault(); openSettings(); return; }
  if (ev.key === " " && !ctrl) {
    ev.preventDefault();
    const entry = visibleEntries().find((e) => selectedPaths.has(e.absolute_path));
    if (entry) openProperties(entry);
    return;
  }
  if (ctrl && (ev.key === "=" || ev.key === "+")) { ev.preventDefault(); zoomIn(); return; }
  if (ctrl && ev.key === "-") { ev.preventDefault(); zoomOut(); return; }
  if (ctrl && ev.key === "0") { ev.preventDefault(); resetZoom(); return; }
  if (ev.key === "Escape") {
    hideCtx();
    $("modal-overlay").classList.add("hidden");
    if (propertiesEntry) { closeProperties(); return; }
    if (!$("settings-overlay").classList.contains("hidden")) { closeSettings(); return; }
    if (showShortcuts) { closeShortcuts(); return; }
    if (!$("admin-overlay").classList.contains("hidden")) { closeAdmin(); return; }
    if (searchActive) { searchActive = false; $("search-input").value = ""; refreshFileManager(); }
    return;
  }
  const entries = visibleEntries();
  if (!entries.length) return;
  const cur = [...selectedPaths][0];
  let idx = entries.findIndex((e) => e.absolute_path === cur);
  if (ev.key === "ArrowDown") { ev.preventDefault(); idx = Math.min(entries.length - 1, idx + 1); selectedPaths = new Set([entries[idx].absolute_path]); renderList(); }
  if (ev.key === "ArrowUp") { ev.preventDefault(); idx = Math.max(0, idx - 1); selectedPaths = new Set([entries[Math.max(0, idx)].absolute_path]); renderList(); }
  if (ev.key === "Enter") {
    ev.preventDefault();
    const e = entries[Math.max(0, idx)];
    if (e?.kind === "folder" && !e.is_deleted) openFolder(e.id, e.name);
    else if (e?.kind === "file" && !e.is_deleted) downloadPath(e.absolute_path, e.name).catch((err) => toast(err.message));
  }
}

function isInputFocused() {
  const a = document.activeElement;
  return a && (a.tagName === "INPUT" || a.tagName === "TEXTAREA" || a.tagName === "SELECT" || a.isContentEditable);
}

/* ---------- admin (mirrors fm_admin_dashboard.dart) ---------- */

const ADMIN_TABS = [
  { id: "stats", label: "Overview" },
  { id: "agent", label: "Agent Name" },
  { id: "admin", label: "Admin Account" },
  { id: "folders", label: "Watched Folders" },
  { id: "exclusions", label: "Exclusions" },
  { id: "users", label: "Users" },
  { id: "management", label: "Management" },
  { id: "maintenance", label: "Maintenance" },
];

function setAdminMsg(err, ok) {
  const e = $("admin-error"), s = $("admin-success");
  if (err) { e.textContent = err; e.classList.remove("hidden"); } else e.classList.add("hidden");
  if (ok) { s.textContent = ok; s.classList.remove("hidden"); } else s.classList.add("hidden");
}

async function unlockAdmin() {
  $("admin-gate-err").classList.add("hidden");
  try {
    await apiPost("/api/admin/management/verify", { password: $("admin-gate-pwd").value });
    manageUnlocked = true;
    $("admin-gate").classList.add("hidden");
    $("admin-body").classList.remove("hidden");
    await loadAdminData();
    renderAdminTab("stats");
  } catch (e) {
    $("admin-gate-err").textContent = e.message || "Wrong management code.";
    $("admin-gate-err").classList.remove("hidden");
  }
}

async function loadAdminData() {
  setAdminMsg("", "");
  const [stats, folders, users, settings] = await Promise.all([
    apiGet("/api/admin/stats"),
    apiGet("/api/admin/folders"),
    apiGet("/api/admin/users"),
    apiGet("/api/admin/settings"),
  ]);
  adminData = { stats, folders: folders || [], users: users || [], settings };
  adminForm.friendlyName = settings?.friendly_name || "";
  adminForm.adminUsername = settings?.admin_username || "";
  adminForm.exclusionPatterns = [...(settings?.exclusion_patterns || [])];
}

function readAdminFormFromDom() {
  adminForm.friendlyName = $("adm-friendly")?.value ?? adminForm.friendlyName;
  adminForm.adminUsername = $("adm-admin-user")?.value ?? adminForm.adminUsername;
  adminForm.adminCode = $("adm-admin-code")?.value ?? adminForm.adminCode;
  adminForm.mgmtNewPassword = $("adm-mgmt-new")?.value ?? adminForm.mgmtNewPassword;
  adminForm.newFolderPath = $("adm-new-folder")?.value ?? adminForm.newFolderPath;
  adminForm.newUserName = $("adm-new-user")?.value ?? adminForm.newUserName;
  adminForm.newUserCode = $("adm-new-user-code")?.value ?? adminForm.newUserCode;
  document.querySelectorAll("[data-excl]").forEach((inp) => {
    const i = Number(inp.dataset.excl);
    if (!Number.isNaN(i)) adminForm.exclusionPatterns[i] = inp.value;
  });
}

async function saveAdminSettings() {
  readAdminFormFromDom();
  const pwd = $("admin-save-pwd").value;
  if (!pwd) return toast("Enter management password");
  adminSaving = true;
  $("admin-save-btn").disabled = true;
  setAdminMsg("", "");
  try {
    const body = {
      management_password: pwd,
      friendly_name: adminForm.friendlyName.trim(),
      admin_username: adminForm.adminUsername.trim(),
      exclusion_patterns: adminForm.exclusionPatterns.map((p) => p.trim()).filter(Boolean),
    };
    if (adminForm.adminCode) body.admin_code = adminForm.adminCode;
    if (adminForm.mgmtNewPassword) body.management_password_new = adminForm.mgmtNewPassword;
    await apiPost("/api/admin/settings", body);
    adminForm.adminCode = "";
    adminForm.mgmtNewPassword = "";
    setAdminMsg("", "Settings saved.");
    await loadAdminData();
    renderAdminTab(manageActiveTab);
  } catch (e) {
    setAdminMsg(e.message, "");
  } finally {
    adminSaving = false;
    $("admin-save-btn").disabled = false;
  }
}

function adminField(label, inner) {
  return `<label class="block"><span class="text-[10px] font-black tracking-wider text-muted uppercase">${esc(label)}</span><div class="mt-2">${inner}</div></label>`;
}

function adminInput(id, value, opts = {}) {
  const type = opts.type || "text";
  const ph = opts.placeholder ? ` placeholder="${esc(opts.placeholder)}"` : "";
  return `<input id="${id}" type="${type}" value="${esc(value || "")}"${ph} class="w-full rounded-md border border-line bg-bg px-3 py-2 text-sm outline-none focus:border-brand" />`;
}

function renderAdminTab(tab) {
  manageActiveTab = tab;
  readAdminFormFromDom();
  const tabMeta = ADMIN_TABS.find((t) => t.id === tab) || ADMIN_TABS[0];
  $("admin-tab-title").textContent = tabMeta.label;
  $("admin-tabs").innerHTML = ADMIN_TABS.map((t) =>
    `<button data-tab="${t.id}" class="w-full text-left px-4 py-2.5 border-b border-line flex items-center gap-2 ${t.id === tab ? "bg-panel border-r-2 border-r-ink font-semibold text-ink" : "text-muted hover:text-ink"}">${esc(t.label)}</button>`
  ).join("");
  $("admin-tabs").querySelectorAll("[data-tab]").forEach((b) => b.onclick = () => renderAdminTab(b.dataset.tab));

  const c = $("admin-content");
  const s = adminData.stats;
  if (tab === "stats") {
    const files = s?.total_files ?? 0;
    const dirs = s?.total_folders ?? 0;
    const watched = s?.watched_folders || [];
    c.innerHTML = `
      <div class="grid grid-cols-2 border-b border-line">
        <div class="p-6"><p class="text-[9px] font-black tracking-widest text-muted mb-1">FILES INDEXED</p><p class="text-3xl font-bold">${files}</p></div>
        <div class="p-6 border-l border-line"><p class="text-[9px] font-black tracking-widest text-muted mb-1">DIRECTORIES</p><p class="text-3xl font-bold">${dirs}</p></div>
      </div>
      ${watched.map((wf) => `<div class="px-6 py-3 border-b border-line"><p class="font-semibold text-sm">${esc(wf.path)}</p><p class="text-faint text-[11px] mt-0.5">${esc(wf.status)} · ${wf.scanned ?? 0} / ${wf.estimate ?? 0} scanned</p></div>`).join("") || '<p class="p-6 text-faint">No watched folders</p>'}`;
  } else if (tab === "agent") {
    c.innerHTML = `<div class="p-6">${adminField("Agent name", adminInput("adm-friendly", adminForm.friendlyName, { placeholder: "e.g. Home Server" }))}</div>`;
  } else if (tab === "admin") {
    c.innerHTML = `<div class="p-6 space-y-4">
      ${adminField("Admin display name", adminInput("adm-admin-user", adminForm.adminUsername))}
      ${adminField("New admin code", adminInput("adm-admin-code", "", { type: "password", placeholder: "Blank = keep current" }))}
    </div>`;
  } else if (tab === "folders") {
    c.innerHTML = `
      <div class="p-3 flex gap-2 border-b border-line">
        <input id="adm-new-folder" value="${esc(adminForm.newFolderPath)}" placeholder="/mnt/tank/archive" class="flex-1 rounded-md border border-line bg-bg px-3 py-2 text-sm outline-none focus:border-brand" />
        <button id="adm-add-folder" class="rounded-md bg-ink text-on-brand px-3 py-2 text-xs font-semibold shrink-0">Add Folder</button>
      </div>
      <div id="adm-folder-list">${(adminData.folders || []).map((f) => `
        <div class="px-4 py-3 border-b border-line flex items-start gap-3">
          <div class="flex-1 min-w-0"><p class="font-semibold truncate">${esc(f.path)}</p><p class="text-faint text-[11px]">${esc(f.status)} · ${f.scanned ?? 0} / ${f.estimate ?? 0}</p></div>
          <button data-del-folder="${f.id}" class="text-danger text-xs hover:underline shrink-0">Delete</button>
        </div>`).join("") || '<p class="p-6 text-faint">No watched folders</p>'}</div>`;
    $("adm-add-folder").onclick = addAdminFolder;
    c.querySelectorAll("[data-del-folder]").forEach((b) => b.onclick = () => deleteAdminFolder(Number(b.dataset.delFolder)));
  } else if (tab === "exclusions") {
    const patterns = adminForm.exclusionPatterns.length ? adminForm.exclusionPatterns : [""];
    c.innerHTML = `<div class="p-4 space-y-2">
      ${patterns.map((p, i) => `<div class="flex gap-2"><input data-excl="${i}" value="${esc(p)}" placeholder="e.g. .* or *.tmp" class="flex-1 rounded-md border border-line bg-bg px-3 py-2 text-sm outline-none focus:border-brand" /><button data-rm-excl="${i}" class="text-faint hover:text-danger px-1">${I.x}</button></div>`).join("")}
      <button id="adm-add-excl" class="text-xs text-brand">+ Add pattern</button>
    </div>`;
    $("adm-add-excl").onclick = () => { readAdminFormFromDom(); adminForm.exclusionPatterns.push(""); renderAdminTab("exclusions"); };
    c.querySelectorAll("[data-rm-excl]").forEach((b) => b.onclick = () => {
      readAdminFormFromDom();
      adminForm.exclusionPatterns.splice(Number(b.dataset.rmExcl), 1);
      renderAdminTab("exclusions");
    });
  } else if (tab === "users") {
    c.innerHTML = `
      <div class="p-3 flex gap-2 border-b border-line">
        <input id="adm-new-user" value="${esc(adminForm.newUserName)}" placeholder="Username" class="flex-1 rounded-md border border-line bg-bg px-3 py-2 text-sm outline-none focus:border-brand" />
        <input id="adm-new-user-code" type="password" value="${esc(adminForm.newUserCode)}" placeholder="User code" class="flex-1 rounded-md border border-line bg-bg px-3 py-2 text-sm outline-none focus:border-brand" />
        <button id="adm-add-user" class="rounded-md bg-ink text-on-brand px-3 py-2 text-xs font-semibold shrink-0">Add User</button>
      </div>
      <div>${(adminData.users || []).map((u) => `
        <div class="px-4 py-3 border-b border-line flex items-center gap-3">
          <div class="flex-1"><p class="font-semibold">${esc(u.username)}</p><p class="text-faint text-[11px]">Joined ${esc((u.created_at || "").split(" ")[0] || "")}</p></div>
          <button data-del-user="${u.id}" class="text-danger text-xs hover:underline">Delete</button>
        </div>`).join("") || '<p class="p-6 text-faint">No users</p>'}</div>`;
    $("adm-add-user").onclick = addAdminUser;
    c.querySelectorAll("[data-del-user]").forEach((b) => b.onclick = () => deleteAdminUser(Number(b.dataset.delUser)));
  } else if (tab === "management") {
    c.innerHTML = `<div class="p-6 space-y-3">
      ${adminField("New management password", adminInput("adm-mgmt-new", "", { type: "password", placeholder: "Blank = keep current password" }))}
      <p class="text-[11px] text-faint">Enter the current management password in the header bar and click Save to apply.</p>
    </div>`;
  } else if (tab === "maintenance") {
    c.innerHTML = `
      <div class="p-4 space-y-3">
        <div class="flex items-center justify-between gap-4 py-2 border-b border-line">
          <div><p class="font-semibold">Rescan now</p><p class="text-faint text-[11px]">Trigger a full filesystem rescan</p></div>
          <button id="adm-rescan" class="rounded border border-line px-3 py-1.5 text-xs hover:border-brand">Rescan</button>
        </div>
        <div class="flex items-center justify-between gap-4 py-2">
          <div><p class="font-semibold">Restart agent</p><p class="text-faint text-[11px]">The app will reconnect automatically</p></div>
          <button id="adm-restart" class="rounded border border-danger-line text-danger px-3 py-1.5 text-xs hover:bg-danger-bg">Restart</button>
        </div>
      </div>`;
    $("adm-rescan").onclick = async () => { try { await apiPost("/api/admin/rescan", {}); toast("Rescan queued"); } catch (e) { setAdminMsg(e.message, ""); } };
    $("adm-restart").onclick = async () => {
      if (!confirm("Restart agent?")) return;
      try { await apiPost("/api/admin/restart", {}); toast("Restarting"); } catch (e) { setAdminMsg(e.message, ""); }
    };
  }
}

async function addAdminFolder() {
  readAdminFormFromDom();
  const path = adminForm.newFolderPath.trim();
  if (!path.startsWith("/")) { setAdminMsg("Enter an absolute NAS path.", ""); return; }
  try {
    await apiPost("/api/admin/folders", path);
    adminForm.newFolderPath = "";
    await loadAdminData();
    renderAdminTab("folders");
    setAdminMsg("", "");
  } catch (e) { setAdminMsg(e.message, ""); }
}

async function deleteAdminFolder(id) {
  if (!confirm("Remove this watched folder?")) return;
  try {
    await apiDelete(`/api/admin/folders/${id}`);
    await loadAdminData();
    renderAdminTab("folders");
  } catch (e) { setAdminMsg(e.message, ""); }
}

async function addAdminUser() {
  readAdminFormFromDom();
  try {
    await apiPost("/api/admin/users", { username: adminForm.newUserName.trim(), code: adminForm.newUserCode });
    adminForm.newUserName = "";
    adminForm.newUserCode = "";
    await loadAdminData();
    renderAdminTab("users");
  } catch (e) { setAdminMsg(e.message, ""); }
}

async function deleteAdminUser(id) {
  if (!confirm("Delete this user?")) return;
  try {
    await apiDelete(`/api/admin/users/${id}`);
    await loadAdminData();
    renderAdminTab("users");
  } catch (e) { setAdminMsg(e.message, ""); }
}

/* ---------- auth / setup ---------- */

let setupPaths = [""];
let setupPatterns = [];

function renderSetupFolders() {
  $("setup-folders").innerHTML = setupPaths.map((p, i) => `
    <div class="flex gap-2"><input data-fi="${i}" value="${esc(p)}" placeholder="/mnt/share" class="flex-1 rounded-lg border border-line bg-bg px-3 py-1.5 text-xs font-mono"/>
    <button data-fr="${i}" class="text-faint hover:text-danger">${I.x}</button></div>`).join("");
}
function renderSetupPatterns() {
  $("setup-patterns").innerHTML = setupPatterns.map((p, i) => `
    <div class="flex gap-2"><input data-pi="${i}" value="${esc(p)}" class="flex-1 rounded-lg border border-line bg-bg px-3 py-1.5 text-xs font-mono"/>
    <button data-pr="${i}" class="text-faint hover:text-danger">${I.x}</button></div>`).join("");
}

async function showLogin() {
  showPhase("login");
  const accounts = await loadStoredAccounts();
  const auto = accounts.length === 1 && !skipAutoLoginOnce;
  skipAutoLoginOnce = false;
  if (auto) {
    try { await loginWithCode(accounts[0].code); return; } catch { /* fall through */ }
  }
  if (accounts.length > 1) {
    $("account-list").innerHTML = accounts.map((a) =>
      `<button data-acc="${esc(a.username)}" class="w-full text-left rounded-lg border border-line px-3 py-2 text-xs hover:border-brand">${esc(a.username)} <span class="text-faint">${esc(a.role)}</span></button>`
    ).join("");
    $("account-list").classList.remove("hidden");
    $("login-form").classList.add("hidden");
    $("login-different-code").classList.remove("hidden");
    $("account-list").onclick = async (ev) => {
      const b = ev.target.closest("[data-acc]");
      if (!b) return;
      const acc = accounts.find((x) => x.username === b.dataset.acc);
      if (acc) try { await loginWithCode(acc.code); } catch (e) { $("login-error").textContent = e.message; $("login-error").classList.remove("hidden"); }
    };
    $("login-different-code").onclick = () => { $("account-list").classList.add("hidden"); $("login-form").classList.remove("hidden"); $("login-different-code").classList.add("hidden"); };
    return;
  }
  $("account-list").classList.add("hidden");
  $("login-form").classList.remove("hidden");
}

async function loginWithCode(code) {
  const res = await fetch("/api/auth/verify-code", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ code }) });
  if (!res.ok) throw await errFrom(res);
  const data = await res.json();
  session = { token: data.token, macKeyHex: data.mac_key, macKey: await importMacKey(data.mac_key), role: data.role, username: data.username };
  persistSession();
  if (data.username) await upsertAccount(data.username, data.role, code);
  await enterApp();
}

async function enterApp() {
  sessionUser = await apiGet("/api/auth/me");
  showPhase("app");
  nasNavigateHome();
  startSse();
  bindUi();
  renderAll();
}

$("login-form")?.addEventListener("submit", async (ev) => {
  ev.preventDefault();
  $("login-error").classList.add("hidden");
  try { await loginWithCode($("login-code").value.trim()); $("login-code").value = ""; }
  catch (e) { $("login-error").textContent = e.message; $("login-error").classList.remove("hidden"); }
});

function initSetup(discovery) {
  showPhase("setup");
  $("setup-hostname").textContent = discovery.hostname || "";
  renderSetupFolders();
  $("setup-add-folder").onclick = () => { setupPaths.push(""); renderSetupFolders(); };
  $("setup-folders").addEventListener("input", (ev) => { const i = ev.target.dataset?.fi; if (i != null) setupPaths[Number(i)] = ev.target.value; });
  $("setup-folders").addEventListener("click", (ev) => { const i = ev.target.closest("[data-fr]")?.dataset?.fr; if (i != null) { setupPaths.splice(Number(i), 1); renderSetupFolders(); } });
  $("setup-add-pattern").onclick = () => { setupPatterns.push(""); renderSetupPatterns(); };
  $("setup-patterns").addEventListener("input", (ev) => { const i = ev.target.dataset?.pi; if (i != null) setupPatterns[Number(i)] = ev.target.value; });
  $("setup-patterns").addEventListener("click", (ev) => { const i = ev.target.closest("[data-pr]")?.dataset?.pr; if (i != null) { setupPatterns.splice(Number(i), 1); renderSetupPatterns(); } });
  $("setup-submit").onclick = async () => {
    $("setup-error").classList.add("hidden");
    const paths = setupPaths.map((p) => p.trim()).filter(Boolean);
    if (!paths.length || !$("setup-admin-code").value.trim() || !$("setup-manage-pwd").value) {
      $("setup-error").textContent = "Paths, admin code, and management password required.";
      $("setup-error").classList.remove("hidden"); return;
    }
    const patterns = [...setupPatterns.filter(Boolean)];
    if ($("setup-exclude-hidden").checked) patterns.push(".*");
    try {
      const res = await fetch("/api/auth/setup/finalize", {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          friendly_name: "", watched_paths: paths, exclusion_patterns: patterns,
          app_admin_code: $("setup-admin-code").value,
          admin_username: $("setup-admin-user").value.trim() || "admin",
          users: [], snapshot_sync_interval_secs: 5, ghost_file_prune_days: 30,
          manage_username: "admin", manage_password: $("setup-manage-pwd").value,
        }),
      });
      if (!res.ok) throw await errFrom(res);
      toast("Setup complete"); showLogin();
    } catch (e) { $("setup-error").textContent = e.message; $("setup-error").classList.remove("hidden"); }
  };
}

function initFilterDropdowns() {
  const html = DATE_OPTS.map(([v, l]) => `<option value="${v}">${l}</option>`).join("");
  $("f-created").innerHTML = html;
  $("f-modified").innerHTML = html;
}

async function boot() {
  console.info(`Datieve Web UI ${WEB_UI_BUILD}`);
  loadViewSettings();
  initFilterDropdowns();
  let info = null;
  try { info = await fetch("/api/auth/discovery").then((r) => r.json()); $("login-title").textContent = info.hostname || "Datieve"; } catch { /* */ }
  if (info && !info.is_setup) { initSetup(info); return; }
  const restored = await restoreSession();
  if (restored) {
    session = restored;
    try { await enterApp(); return; } catch { clearSession(); }
  }
  showLogin();
}

boot();