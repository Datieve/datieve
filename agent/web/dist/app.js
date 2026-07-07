"use strict";

/* ---------- crypto / session ---------- */

function hexToBytes(hex) {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < bytes.length; i++) bytes[i] = parseInt(hex.substr(i * 2, 2), 16);
  return bytes;
}

function bytesToHex(buf) {
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function importMacKey(hexKey) {
  return crypto.subtle.importKey("raw", hexToBytes(hexKey), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
}

function randomNonce() {
  if (crypto.randomUUID) return crypto.randomUUID();
  return bytesToHex(crypto.getRandomValues(new Uint8Array(16)));
}

const SESSION_KEY = "datieve_web_session";
let session = null; // { token, macKey (CryptoKey), macKeyHex, role, username }
let manageUnlocked = false;

function persistSession() {
  if (!session) { localStorage.removeItem(SESSION_KEY); return; }
  localStorage.setItem(
    SESSION_KEY,
    JSON.stringify({ token: session.token, macKeyHex: session.macKeyHex, role: session.role, username: session.username })
  );
}

async function restoreSession() {
  const raw = localStorage.getItem(SESSION_KEY);
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw);
    const macKey = await importMacKey(parsed.macKeyHex);
    return { ...parsed, macKey };
  } catch {
    return null;
  }
}

function clearSession() {
  session = null;
  manageUnlocked = false;
  storedAccountsCache = null;
  persistSession();
}

/* ---------- saved accounts (mirrors the desktop app's account switcher) ----------
   Access codes are AES-GCM encrypted before landing in localStorage so a casual
   disk/backup peek or XSS read of storage doesn't expose them in plaintext.
   Exactly one saved account auto-logs-in silently; two or more shows a picker. */

const ACCOUNTS_KEY = "datieve_web_accounts";
const VAULT_KEY_STORAGE = "datieve_web_vault_key";
let storedAccountsCache = null;
let vaultCryptoKeyPromise = null;

function invalidateAccountsCache() {
  storedAccountsCache = null;
}

async function getVaultCryptoKey() {
  if (!vaultCryptoKeyPromise) {
    vaultCryptoKeyPromise = (async () => {
      let raw = localStorage.getItem(VAULT_KEY_STORAGE);
      if (!raw) {
        raw = bytesToHex(crypto.getRandomValues(new Uint8Array(32)));
        localStorage.setItem(VAULT_KEY_STORAGE, raw);
      }
      return crypto.subtle.importKey("raw", hexToBytes(raw), { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
    })();
  }
  return vaultCryptoKeyPromise;
}

async function encryptSecret(text) {
  const key = await getVaultCryptoKey();
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, new TextEncoder().encode(text));
  return { iv: bytesToHex(iv), data: bytesToHex(new Uint8Array(ct)) };
}

async function decryptSecret(enc) {
  if (!enc?.iv || !enc?.data) return "";
  const key = await getVaultCryptoKey();
  const plain = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: hexToBytes(enc.iv) },
    key,
    hexToBytes(enc.data)
  );
  return new TextDecoder().decode(plain);
}

async function readStoredAccountRecords() {
  try {
    return JSON.parse(localStorage.getItem(ACCOUNTS_KEY) || "[]");
  } catch {
    return [];
  }
}

async function writeStoredAccountRecords(records) {
  localStorage.setItem(ACCOUNTS_KEY, JSON.stringify(records));
  invalidateAccountsCache();
}

async function loadStoredAccounts() {
  if (storedAccountsCache) return storedAccountsCache;
  const records = await readStoredAccountRecords();
  let migrated = false;
  const accounts = [];
  for (const rec of records) {
    if (rec.code) {
      const enc = await encryptSecret(rec.code);
      accounts.push({ username: rec.username, role: rec.role, code: rec.code });
      rec.codeEnc = enc;
      delete rec.code;
      migrated = true;
      continue;
    }
    const code = await decryptSecret(rec.codeEnc);
    if (!code) continue;
    accounts.push({ username: rec.username, role: rec.role, code });
  }
  if (migrated) {
    await writeStoredAccountRecords(records);
  }
  storedAccountsCache = accounts;
  return accounts;
}

async function saveStoredAccounts(list) {
  const records = [];
  for (const acc of list) {
    records.push({
      username: acc.username,
      role: acc.role,
      codeEnc: await encryptSecret(acc.code),
    });
  }
  await writeStoredAccountRecords(records);
  storedAccountsCache = list.map((a) => ({ ...a }));
}

async function upsertStoredAccount(username, role, code) {
  const list = (await loadStoredAccounts()).filter((a) => a.username !== username);
  list.push({ username, role, code });
  await saveStoredAccounts(list);
}

async function removeStoredAccount(username) {
  const list = (await loadStoredAccounts()).filter((a) => a.username !== username);
  await saveStoredAccounts(list);
}

/* ---------- theme ---------- */

const THEME_KEY = "datieve_web_theme"; // 'system' | 'light' | 'dark'

function loadTheme() {
  return localStorage.getItem(THEME_KEY) || "system";
}
function isEffectivelyDark(theme) {
  return theme === "dark" || (theme === "system" && window.matchMedia("(prefers-color-scheme: dark)").matches);
}
// Sets the CSS attribute only - safe to call immediately, before ICONS/DOM
// refs exist, so the correct palette applies before first paint.
function applyThemeAttribute(theme) {
  const root = document.documentElement;
  if (theme === "system") root.removeAttribute("data-theme");
  else root.setAttribute("data-theme", theme);
}
applyThemeAttribute(loadTheme());
// Updates the toggle buttons' icon - deferred until ICONS/DOM refs are ready.
function updateThemeIcon(theme) {
  const icon = isEffectivelyDark(theme) ? ICONS.moon : ICONS.sun;
  themeToggleBtn.innerHTML = icon;
  themeToggleBtnSetup.innerHTML = icon;
}
function applyTheme(theme) {
  applyThemeAttribute(theme);
  updateThemeIcon(theme);
}
function toggleTheme() {
  const next = isEffectivelyDark(loadTheme()) ? "light" : "dark";
  localStorage.setItem(THEME_KEY, next);
  applyTheme(next);
}

/* ---------- API ---------- */

async function signedFetch(pathAndQuery, options = {}) {
  const method = (options.method || "GET").toUpperCase();
  const nonce = randomNonce();
  const canonical = `${method}\n${pathAndQuery}\n${nonce}`;
  const mac = bytesToHex(await crypto.subtle.sign("HMAC", session.macKey, new TextEncoder().encode(canonical)));
  const headers = Object.assign({}, options.headers, {
    Authorization: `Bearer ${session.token}`,
    "x-datieve-nonce": nonce,
    "x-datieve-mac": mac,
  });
  if (options.body && !headers["Content-Type"]) headers["Content-Type"] = "application/json";
  const res = await fetch(pathAndQuery, { ...options, headers });
  if (res.status === 401) {
    clearSession();
    showLogin();
    throw new Error("Session expired. Please sign in again.");
  }
  return res;
}

async function errorFromResponse(res) {
  try {
    const body = await res.json();
    return new Error(body.message || `Request failed (${res.status})`);
  } catch {
    return new Error(`Request failed (${res.status})`);
  }
}

async function apiGet(pathAndQuery) {
  const res = await signedFetch(pathAndQuery);
  if (!res.ok) throw await errorFromResponse(res);
  return res.json();
}

async function apiPost(pathAndQuery, body) {
  const res = await signedFetch(pathAndQuery, { method: "POST", body: JSON.stringify(body || {}) });
  if (!res.ok) throw await errorFromResponse(res);
  const len = res.headers.get("content-length");
  if (len === "0") return null;
  return res.json().catch(() => null);
}

async function apiDelete(pathAndQuery) {
  const res = await signedFetch(pathAndQuery, { method: "DELETE" });
  if (!res.ok) throw await errorFromResponse(res);
}

async function apiPut(pathAndQuery, body) {
  const res = await signedFetch(pathAndQuery, { method: "PUT", body: JSON.stringify(body || {}) });
  if (!res.ok) throw await errorFromResponse(res);
  const len = res.headers.get("content-length");
  if (len === "0") return null;
  return res.json().catch(() => null);
}

function qs(params) {
  const usp = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) {
    if (v === undefined || v === null || v === "") continue;
    usp.set(k, String(v));
  }
  const s = usp.toString();
  return s ? `?${s}` : "";
}

/* ---------- utils ---------- */

function escapeHtml(str) {
  return String(str).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

function formatBytes(n) {
  if (n === null || n === undefined) return "";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let v = n, i = 0;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  return `${v.toFixed(i === 0 ? 0 : 1)} ${units[i]}`;
}

function formatDate(s) {
  if (!s) return "";
  const d = new Date(s.includes("T") || s.includes("Z") ? s : s.replace(" ", "T") + "Z");
  if (isNaN(d.getTime())) return s;
  return d.toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" });
}

function debounce(fn, ms) {
  let t;
  return (...args) => { clearTimeout(t); t = setTimeout(() => fn(...args), ms); };
}

/* ---------- icons ----------
   Real Lucide icon paths (same icon family the desktop app uses via
   lucide_icons_flutter), not hand-drawn approximations - so the web UI
   actually matches the desktop app's visual language. */

function svgIcon(inner, size = "w-4 h-4") {
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="${size} shrink-0">${inner}</svg>`;
}

const ICONS = {
  folder: svgIcon('<path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/>'),
  file: svgIcon('<path d="M6 22a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h8a2.4 2.4 0 0 1 1.704.706l3.588 3.588A2.4 2.4 0 0 1 20 8v12a2 2 0 0 1-2 2z"/><path d="M14 2v5a1 1 0 0 0 1 1h5"/>'),
  download: svgIcon('<path d="M12 15V3"/><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><path d="m7 10 5 5 5-5"/>'),
  bookmark: svgIcon('<path d="M17 3a2 2 0 0 1 2 2v15a1 1 0 0 1-1.496.868l-4.512-2.578a2 2 0 0 0-1.984 0l-4.512 2.578A1 1 0 0 1 5 20V5a2 2 0 0 1 2-2z"/>'),
  bookmarkFilled: svgIcon('<path d="M17 3a2 2 0 0 1 2 2v15a1 1 0 0 1-1.496.868l-4.512-2.578a2 2 0 0 0-1.984 0l-4.512 2.578A1 1 0 0 1 5 20V5a2 2 0 0 1 2-2z" fill="currentColor"/>'),
  x: svgIcon('<path d="M18 6 6 18"/><path d="m6 6 12 12"/>', "w-3.5 h-3.5"),
  chevronRight: svgIcon('<path d="m9 18 6-6-6-6"/>', "w-3 h-3"),
  search: svgIcon('<path d="m21 21-4.34-4.34"/><circle cx="11" cy="11" r="8"/>', "w-4 h-4"),
  filters: svgIcon('<path d="M10 5H3"/><path d="M12 19H3"/><path d="M14 3v4"/><path d="M16 17v4"/><path d="M21 12h-9"/><path d="M21 19h-5"/><path d="M21 5h-7"/><path d="M8 10v4"/><path d="M8 12H3"/>', "w-4 h-4"),
  copy: svgIcon('<rect width="14" height="14" x="8" y="8" rx="2" ry="2"/><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/>'),
  link: svgIcon('<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>'),
  check: svgIcon('<path d="M20 6 9 17l-5-5"/>'),
  home: svgIcon('<path d="M15 21v-8a1 1 0 0 0-1-1h-4a1 1 0 0 0-1 1v8"/><path d="M3 10a2 2 0 0 1 .709-1.528l7-6a2 2 0 0 1 2.582 0l7 6A2 2 0 0 1 21 10v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>', "w-3 h-3"),
  sun: svgIcon('<circle cx="12" cy="12" r="4"/><path d="M12 2v2"/><path d="M12 20v2"/><path d="m4.93 4.93 1.41 1.41"/><path d="m17.66 17.66 1.41 1.41"/><path d="M2 12h2"/><path d="M20 12h2"/><path d="m6.34 17.66-1.41 1.41"/><path d="m19.07 4.93-1.41 1.41"/>'),
  moon: svgIcon('<path d="M20.985 12.486a9 9 0 1 1-9.473-9.472c.405-.022.617.46.402.803a6 6 0 0 0 8.268 8.268c.344-.215.825-.004.803.401"/>'),
  settings: svgIcon('<path d="M9.671 4.136a2.34 2.34 0 0 1 4.659 0 2.34 2.34 0 0 0 3.319 1.915 2.34 2.34 0 0 1 2.33 4.033 2.34 2.34 0 0 0 0 3.831 2.34 2.34 0 0 1-2.33 4.033 2.34 2.34 0 0 0-3.319 1.915 2.34 2.34 0 0 1-4.659 0 2.34 2.34 0 0 0-3.32-1.915 2.34 2.34 0 0 1-2.33-4.033 2.34 2.34 0 0 0 0-3.831A2.34 2.34 0 0 1 6.35 6.051a2.34 2.34 0 0 0 3.319-1.915"/>', "w-3.5 h-3.5"),
};

/* ---------- filters: relative date ranges + type categories -----------
   Mirrors the desktop app's filters panel (fm_filters_panel.dart) exactly -
   same field set, same "Created"/"Modified" relative-range options, same
   Type categories - rather than inventing a different filter UI for web. */

const DATE_RANGE_OPTIONS = [
  { value: "", label: "Any time" },
  { value: "1h", label: "Last hour" },
  { value: "today", label: "Today" },
  { value: "24h", label: "Last 24 hours" },
  { value: "3d", label: "Last 3 days" },
  { value: "7d", label: "Last 7 days" },
  { value: "14d", label: "Last 14 days" },
  { value: "30d", label: "Last 30 days" },
  { value: "45d", label: "Last 45 days" },
  { value: "60d", label: "Last 60 days" },
  { value: "60d+", label: "60+ days ago" },
];

function dateRangeToBounds(value) {
  const now = Date.now();
  const DAY = 86400000;
  switch (value) {
    case "1h": return { after: new Date(now - 3600000).toISOString() };
    case "today": { const s = new Date(); s.setHours(0, 0, 0, 0); return { after: s.toISOString() }; }
    case "24h": return { after: new Date(now - DAY).toISOString() };
    case "3d": return { after: new Date(now - 3 * DAY).toISOString() };
    case "7d": return { after: new Date(now - 7 * DAY).toISOString() };
    case "14d": return { after: new Date(now - 14 * DAY).toISOString() };
    case "30d": return { after: new Date(now - 30 * DAY).toISOString() };
    case "45d": return { after: new Date(now - 45 * DAY).toISOString() };
    case "60d": return { after: new Date(now - 60 * DAY).toISOString() };
    case "60d+": return { before: new Date(now - 60 * DAY).toISOString() };
    default: return {};
  }
}

const TYPE_EXTENSIONS = {
  images: new Set(["jpg", "jpeg", "png", "gif", "bmp", "webp", "svg", "heic", "tiff", "ico"]),
  documents: new Set(["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "md", "odt", "csv", "rtf"]),
  media: new Set(["mp4", "mkv", "avi", "mov", "webm", "mp3", "wav", "flac", "ogg", "m4a", "aac"]),
  archives: new Set(["zip", "rar", "7z", "tar", "gz", "bz2", "xz"]),
};

function extensionOf(name) {
  const i = name.lastIndexOf(".");
  return i > 0 ? name.slice(i + 1).toLowerCase() : "";
}

function matchesTypeFilter(name, type) {
  if (!type || type === "all") return true;
  const set = TYPE_EXTENSIONS[type];
  return set ? set.has(extensionOf(name)) : true;
}

// Browse mode has no server-side size/date filtering (only search does), so
// apply the same size/created/modified bounds client-side here - matching
// the desktop app, where the filters panel affects plain browsing too.
function matchesSizeDateFilters(file, f) {
  if (f.size_min !== undefined && file.size_bytes < f.size_min) return false;
  if (f.size_max !== undefined && file.size_bytes > f.size_max) return false;
  if (f.created_after && file.created_at < f.created_after) return false;
  if (f.created_before && file.created_at > f.created_before) return false;
  if (f.modified_after && file.modified_at < f.modified_after) return false;
  if (f.modified_before && file.modified_at > f.modified_before) return false;
  return true;
}

/* ---------- toast (transient feedback for clipboard copies, etc.) ---------- */

let toastTimer = null;
function showToast(message) {
  const toast = el("toast");
  toast.textContent = message;
  toast.classList.remove("hidden");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toast.classList.add("hidden"), 2200);
}

/* ---------- local path mapping ----------
   The agent only knows NAS-side paths (e.g. /data/pool/media/Movies). The
   browser has no way to know how *this* client has that share mounted -
   Z:\Movies, /mnt/movies, /mnt/home/user/media/Movies, anything. So instead
   of guessing, each watched-folder root can be mapped, once, to whatever
   local path this browser/computer uses - stored per-browser since that
   mapping is a fact about the client, not the NAS. */

const MOUNTS_KEY = "datieve_local_mounts"; // { [watchedRootAbsolutePath]: localPrefix }
let watchedRoots = []; // [{ absolutePath }] cached from the Home listing

function loadMounts() {
  try { return JSON.parse(localStorage.getItem(MOUNTS_KEY) || "{}"); } catch { return {}; }
}
function saveMounts(m) { localStorage.setItem(MOUNTS_KEY, JSON.stringify(m)); }

function toLocalPath(absolutePath) {
  const mounts = loadMounts();
  let best = null;
  for (const root of watchedRoots) {
    const prefix = mounts[root.absolutePath];
    if (!prefix) continue;
    if (absolutePath === root.absolutePath || absolutePath.startsWith(root.absolutePath + "/")) {
      if (!best || root.absolutePath.length > best.rootLen) best = { rootLen: root.absolutePath.length, root: root.absolutePath, prefix };
    }
  }
  if (!best) return null;
  const rel = absolutePath.slice(best.rootLen);
  const usesBackslash = best.prefix.includes("\\") && !best.prefix.includes("/");
  const relConverted = usesBackslash ? rel.replace(/\//g, "\\") : rel;
  return best.prefix.replace(/[\\/]+$/, "") + relConverted;
}

async function copyPathToClipboard(absolutePath) {
  const local = toLocalPath(absolutePath);
  const toCopy = local || absolutePath;
  try {
    await navigator.clipboard.writeText(toCopy);
  } catch {
    window.prompt("Copy this path:", toCopy);
    return;
  }
  showToast(local ? "Local path copied" : "NAS path copied (no local mapping set for this share - click the link icon at Home to set one)");
}

function mapLocalPathPrompt(absolutePath, name) {
  // Root folder paths come back from the API with a trailing slash; strip it
  // so this matches the same normalized form toLocalPath() looks up against.
  const key = absolutePath.replace(/[\\/]+$/, "");
  const mounts = loadMounts();
  const existing = mounts[key] || "";
  const value = window.prompt(
    `What's the local path to "${name}" on this computer?\n(e.g. Z:\\Movies or /mnt/movies - leave blank to clear)`,
    existing
  );
  if (value === null) return;
  if (value.trim() === "") delete mounts[key];
  else mounts[key] = value.trim();
  saveMounts(mounts);
  showToast(value.trim() ? "Local path saved" : "Local path mapping cleared");
  refreshCurrentView();
}

/* ---------- download ---------- */

async function downloadFile(path, suggestedName) {
  const url = `/api/fs/download${qs({ path })}`;
  const res = await signedFetch(url);
  if (!res.ok) throw await errorFromResponse(res);

  // Chromium: stream straight to disk via the File System Access API so we
  // never hold a large NAS file fully in memory. Everywhere else, fall back
  // to a blob download (bounded by available browser memory).
  if (window.showSaveFilePicker) {
    try {
      const handle = await window.showSaveFilePicker({ suggestedName });
      const writable = await handle.createWritable();
      await res.body.pipeTo(writable);
      return;
    } catch (e) {
      if (e && e.name === "AbortError") return;
      // fall through to blob fallback
    }
  }
  const blob = await res.blob();
  const objectUrl = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = objectUrl;
  a.download = suggestedName;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(objectUrl);
}

/* ---------- DOM refs ---------- */

const el = (id) => document.getElementById(id);
const loginScreen = el("login-screen");
const setupScreen = el("setup-screen");
const appShell = el("app-shell");
const loginForm = el("login-form");
const loginCode = el("login-code");
const loginError = el("login-error");
const loginTitle = el("login-title");
const accountList = el("account-list");
const loginBackToAccounts = el("login-back-to-accounts");
const loginUseDifferentCode = el("login-use-different-code");
const themeToggleBtn = el("theme-toggle-btn");
const themeToggleBtnSetup = el("theme-toggle-btn-setup");
themeToggleBtn.innerHTML = ICONS.sun;
themeToggleBtnSetup.innerHTML = ICONS.sun;
const breadcrumbs = el("breadcrumbs");
const homeBtn = el("home-btn");
const searchInput = el("search-input");
const searchToggleBtn = el("search-toggle-btn");
searchToggleBtn.innerHTML = ICONS.search;
const searchPopover = el("search-popover");
const filtersToggleBtn = el("filters-toggle-btn");
filtersToggleBtn.innerHTML = ICONS.filters;
const filtersPanel = el("filters-panel");
const filtersApply = el("filters-apply");
const filtersClear = el("filters-clear");
const filterCreatedRange = el("filter-created-range");
const filterModifiedRange = el("filter-modified-range");
filterCreatedRange.innerHTML = DATE_RANGE_OPTIONS.map((o) => `<option value="${o.value}">${o.label}</option>`).join("");
filterModifiedRange.innerHTML = filterCreatedRange.innerHTML;
const whoami = el("whoami");
const manageBtn = el("manage-btn");
const logoutBtn = el("logout-btn");
const manageOverlay = el("manage-overlay");
const manageCloseBtn = el("manage-close-btn");
const manageGate = el("manage-gate");
const manageBody = el("manage-body");
const manageGatePassword = el("manage-gate-password");
const manageGateError = el("manage-gate-error");
const manageGateSubmit = el("manage-gate-submit");
const manageTabs = el("manage-tabs");
const manageContent = el("manage-content");
const manageSavePassword = el("manage-save-password");
const manageSaveBtn = el("manage-save-btn");
manageCloseBtn.innerHTML = ICONS.x;
const statusLine = el("status-line");
const entriesBody = el("entries-body");
const loadMoreBtn = el("load-more-btn");
const bookmarksList = el("bookmarks-list");
const bookmarksEmpty = el("bookmarks-empty");
const bookmarkHereBtn = el("bookmark-here-btn");

/* ---------- navigation state ---------- */

let crumbs = [{ id: null, name: "Home" }];
let currentFolders = [];
let currentFiles = [];
let hasMoreFiles = false;
let fileOffset = 0;
const FILE_PAGE_SIZE = 500;
let searchMode = false;
let searchDebounceTimer = null;
let lastSearchResults = [];
// `${kind}:${target_id}` -> bookmark id, kept in sync by loadBookmarks()
let bookmarkedKeys = new Map();

function isBookmarked(kind, targetId) {
  return bookmarkedKeys.has(`${kind}:${targetId}`);
}

function currentFolderId() {
  return crumbs[crumbs.length - 1].id;
}

const SIZE_UNIT_MULTIPLIER = { KB: 1024, MB: 1024 * 1024, GB: 1024 * 1024 * 1024 };

function activeFilters() {
  const unit = SIZE_UNIT_MULTIPLIER[el("filter-size-unit").value] || SIZE_UNIT_MULTIPLIER.MB;
  const created = dateRangeToBounds(filterCreatedRange.value);
  const modified = dateRangeToBounds(filterModifiedRange.value);
  return {
    size_min: (() => { const v = parseFloat(el("filter-size-min").value); return isNaN(v) ? undefined : Math.round(v * unit); })(),
    size_max: (() => { const v = parseFloat(el("filter-size-max").value); return isNaN(v) ? undefined : Math.round(v * unit); })(),
    created_after: created.after,
    created_before: created.before,
    modified_after: modified.after,
    modified_before: modified.before,
    type: el("filter-type").value,
    include_deleted: el("filter-include-deleted").checked || undefined,
  };
}

/* ---------- rendering ---------- */

function renderBreadcrumbs() {
  // Desktop-style pill: bordered container, contents centered, current
  // segment gets a highlighted chip, ancestors are plain clickable text.
  breadcrumbs.innerHTML = crumbs
    .map((c, i) => {
      const isLast = i === crumbs.length - 1;
      const label = escapeHtml(c.name);
      const icon = i === 0 ? ICONS.home : "";
      const inner = `${icon}<span class="truncate max-w-[10rem]">${label}</span>`;
      if (isLast) {
        return `<span class="flex items-center gap-1 px-2 py-1 rounded-md bg-white/15 border border-white/10 font-semibold text-ink">${inner}</span>`;
      }
      return `<button data-crumb-index="${i}" class="flex items-center gap-1 px-2 py-1 rounded-md text-muted hover:text-brand transition-colors">${inner}</button>${ICONS.chevronRight}`;
    })
    .join("");
  const atRoot = crumbs.length <= 1;
  bookmarkHereBtn.disabled = atRoot;
  if (!atRoot) {
    const here = crumbs[crumbs.length - 1];
    const active = isBookmarked("folder", here.id);
    bookmarkHereBtn.innerHTML = `${active ? ICONS.bookmarkFilled : ICONS.bookmark}<span>${active ? "Bookmarked" : "Add"}</span>`;
  } else {
    bookmarkHereBtn.innerHTML = `${ICONS.bookmark}<span>Add</span>`;
  }
}

function bookmarkButtonHtml(kind, targetId, name) {
  const active = isBookmarked(kind, targetId);
  const icon = active ? ICONS.bookmarkFilled : ICONS.bookmark;
  const colorClass = active ? "text-brand" : "text-muted hover:text-brand";
  return `<button data-action="bookmark" data-kind="${kind}" data-target-id="${targetId}" data-label="${escapeHtml(name)}" class="${colorClass} transition-colors" title="${active ? "Remove bookmark" : "Add bookmark"}">${icon}</button>`;
}

function rowActionsHtml(kind, targetId, path, name, opts = {}) {
  const mapBtn = opts.showMap
    ? `<button data-action="map-path" data-path="${escapeHtml(path)}" data-name="${escapeHtml(name)}" class="text-muted hover:text-brand transition-colors" title="Map this share to a local path">${ICONS.link}</button>`
    : "";
  const copyBtn = `<button data-action="copy-path" data-path="${escapeHtml(path)}" class="text-muted hover:text-brand transition-colors" title="Copy path">${ICONS.copy}</button>`;
  const dl = kind === "file" ? `<button data-action="download" data-path="${escapeHtml(path)}" data-name="${escapeHtml(name)}" class="text-brand hover:text-brand-hover transition-colors" title="Download">${ICONS.download}</button>` : "";
  return `<span class="flex items-center gap-2.5 justify-end">${mapBtn}${copyBtn}${dl}${bookmarkButtonHtml(kind, targetId, name)}</span>`;
}

function renderEntries() {
  const atRoot = crumbs.length <= 1;
  const type = el("filter-type").value;
  const filters = activeFilters();
  const hideFolders = type === "files" || TYPE_EXTENSIONS[type] !== undefined;
  const visibleFolders = hideFolders ? [] : currentFolders;
  const visibleFiles = type === "folders"
    ? []
    : currentFiles.filter((f) => matchesTypeFilter(f.name, type) && matchesSizeDateFilters(f, filters));
  const rows = [];
  for (const f of visibleFolders) {
    rows.push(`
      <tr data-row-kind="folder" data-row-id="${f.id}" data-row-name="${escapeHtml(f.name)}" class="cursor-pointer border-b border-line hover:bg-panel-soft">
        <td class="py-1.5 pr-2">
          <span class="flex items-center gap-1.5">
            ${ICONS.folder}<span>${escapeHtml(f.name)}</span>${f.is_deleted ? '<span class="text-faint">(deleted)</span>' : ""}
          </span>
        </td>
        <td class="py-1.5 pr-2 text-muted">${f.file_count} item${f.file_count === 1 ? "" : "s"}</td>
        <td class="py-1.5 pr-2 text-muted">${formatDate(f.indexed_at)}</td>
        <td class="py-1.5">${rowActionsHtml("folder", f.id, f.absolute_path, f.name, { showMap: atRoot })}</td>
      </tr>`);
  }
  for (const f of visibleFiles) {
    rows.push(`
      <tr data-row-kind="file" data-row-path="${escapeHtml(f.absolute_path)}" data-row-name="${escapeHtml(f.name)}" class="cursor-pointer border-b border-line hover:bg-panel-soft">
        <td class="py-1.5 pr-2">
          <span class="flex items-center gap-1.5">
            ${ICONS.file}<span>${escapeHtml(f.name)}</span>${f.is_deleted ? '<span class="text-faint">(deleted)</span>' : ""}
          </span>
        </td>
        <td class="py-1.5 pr-2 text-muted">${formatBytes(f.size_bytes)}</td>
        <td class="py-1.5 pr-2 text-muted">${formatDate(f.modified_at)}</td>
        <td class="py-1.5">${rowActionsHtml("file", f.id, f.absolute_path, f.name)}</td>
      </tr>`);
  }
  entriesBody.innerHTML = rows.join("") || `<tr><td colspan="4" class="py-6 text-center text-faint">Empty folder.</td></tr>`;
  loadMoreBtn.classList.toggle("hidden", !hasMoreFiles);
  statusLine.textContent = `${visibleFolders.length} folder${visibleFolders.length === 1 ? "" : "s"}, ${visibleFiles.length} file${visibleFiles.length === 1 ? "" : "s"}${hasMoreFiles ? "+" : ""} — double-click a folder to open, a file to copy its path`;
}

function renderSearchResults(results) {
  lastSearchResults = results;
  entriesBody.innerHTML =
    results
      .map(
        (r) => `
      <tr data-row-kind="file" data-row-path="${escapeHtml(r.absolute_path)}" data-row-name="${escapeHtml(r.name)}" class="cursor-pointer border-b border-line hover:bg-panel-soft">
        <td class="py-1.5 pr-2">
          <span class="flex items-center gap-1.5">
            ${ICONS.file}<span>${escapeHtml(r.name)}</span>${r.is_deleted ? '<span class="text-faint">(deleted)</span>' : ""}
          </span>
          <button data-action="reveal-folder" data-folder-id="${r.folder_id}" class="text-faint text-[11px] truncate max-w-md block hover:text-brand hover:underline transition-colors text-left" title="Open containing folder">${escapeHtml(r.absolute_path)}</button>
        </td>
        <td class="py-1.5 pr-2 text-muted">${formatBytes(r.size_bytes)}</td>
        <td class="py-1.5 pr-2 text-muted">${formatDate(r.modified_at)}</td>
        <td class="py-1.5">${rowActionsHtml("file", r.id, r.absolute_path, r.name)}</td>
      </tr>`
      )
      .join("") || `<tr><td colspan="4" class="py-6 text-center text-faint">No results.</td></tr>`;
  loadMoreBtn.classList.add("hidden");
  statusLine.textContent = `${results.length} result${results.length === 1 ? "" : "s"} — double-click to copy its path`;
}

function renderBookmarks(items) {
  bookmarksList.innerHTML = items
    .map((b) => {
      const icon = b.kind === "folder" ? ICONS.folder : ICONS.file;
      const dim = b.is_missing ? "opacity-50" : "";
      return `
      <li class="group flex items-center gap-1.5 ${dim}">
        <button data-jump-bookmark="${b.id}" data-open-folder-id="${b.open_folder_id ?? ""}" data-label="${escapeHtml(b.label)}"
                class="flex-1 flex items-center gap-1.5 text-left truncate hover:text-brand transition-colors" title="${escapeHtml(b.path || "missing")}"
                ${b.is_missing ? "disabled" : ""}>
          ${icon}<span class="truncate">${escapeHtml(b.label)}</span>
        </button>
        <button data-remove-bookmark="${b.id}" class="hidden group-hover:inline text-faint hover:text-danger transition-colors" title="Remove">${ICONS.x}</button>
      </li>`;
    })
    .join("");
  bookmarksEmpty.classList.toggle("hidden", items.length > 0);
}

/* ---------- data loading ---------- */

async function loadBookmarks() {
  try {
    const items = await apiGet("/api/bookmarks");
    bookmarkedKeys = new Map(items.map((b) => [`${b.kind}:${b.target_id}`, b.id]));
    renderBookmarks(items);
  } catch (e) {
    console.error("Failed to load bookmarks", e);
  }
}

/* Re-renders whatever's currently on screen (browse or search) so bookmark
   stars / breadcrumb "Bookmarked" state reflect the latest server state,
   without re-fetching the folder/search listing itself. */
function refreshCurrentView() {
  renderBreadcrumbs();
  if (searchMode) renderSearchResults(lastSearchResults);
  else renderEntries();
}

async function loadFolder(id, name) {
  searchMode = false;
  searchInput.value = "";
  fileOffset = 0;
  if (id === null) {
    crumbs = [{ id: null, name: "Home" }];
  } else if (name !== undefined) {
    crumbs.push({ id, name });
  }
  await fetchAndRenderFolder();
}

async function fetchAndRenderFolder() {
  const id = currentFolderId();
  statusLine.textContent = "Loading…";
  try {
    const res = await apiGet(
      `/api/browse${qs({ parent_id: id ?? undefined, file_offset: fileOffset, file_limit: FILE_PAGE_SIZE, include_deleted: el("filter-include-deleted").checked || undefined })}`
    );
    currentFolders = fileOffset === 0 ? res.folders : currentFolders;
    currentFiles = fileOffset === 0 ? res.files : currentFiles.concat(res.files);
    hasMoreFiles = res.has_more;
    if (id === null) {
      // Home's folder rows are exactly the watched-folder roots - cache them
      // so copy-path can substitute a user-configured local mount prefix.
      watchedRoots = res.folders.map((f) => ({ absolutePath: f.absolute_path.replace(/[\\/]+$/, "") }));
    }
    renderBreadcrumbs();
    renderEntries();
  } catch (e) {
    statusLine.textContent = e.message || "Failed to load folder.";
  }
}

function jumpToCrumb(index) {
  crumbs = crumbs.slice(0, index + 1);
  fileOffset = 0;
  searchMode = false;
  searchInput.value = "";
  fetchAndRenderFolder();
}

const runSearch = debounce(async () => {
  const q = searchInput.value.trim();
  if (q.length < 2) {
    if (searchMode) { searchMode = false; renderEntries(); }
    return;
  }
  searchMode = true;
  statusLine.textContent = "Searching…";
  const f = activeFilters();
  try {
    const results = await apiGet(
      `/api/search${qs({
        q,
        size_min: f.size_min,
        size_max: f.size_max,
        created_after: f.created_after,
        created_before: f.created_before,
        modified_after: f.modified_after,
        modified_before: f.modified_before,
        include_deleted: f.include_deleted,
      })}`
    );
    renderSearchResults(f.type === "folders" ? [] : results.filter((r) => matchesTypeFilter(r.name, f.type)));
  } catch (e) {
    statusLine.textContent = e.message || "Search failed.";
  }
}, 300);

/* ---------- bookmark actions ---------- */

// True toggle: if this target is already bookmarked, clicking again removes
// it instead of creating a duplicate.
async function toggleBookmark(kind, targetId, label) {
  const key = `${kind}:${targetId}`;
  const existingId = bookmarkedKeys.get(key);
  try {
    if (existingId) {
      await apiDelete(`/api/bookmarks/${existingId}`);
    } else {
      await apiPost("/api/bookmarks", { kind, target_id: targetId, label });
    }
    await loadBookmarks();
    refreshCurrentView();
  } catch (e) {
    alert(e.message || "Could not update bookmark.");
  }
}

async function removeBookmark(id) {
  try {
    await apiDelete(`/api/bookmarks/${id}`);
    await loadBookmarks();
    refreshCurrentView();
  } catch (e) {
    alert(e.message || "Could not remove bookmark.");
  }
}

/* ---------- row selection / open (double-click) ---------- */

// Desktop-app parity: single click selects a row, double click opens it.
// Detected on mousedown (not the native `dblclick` event) so the action
// fires the instant the second press lands, without waiting for its release.
const DOUBLE_CLICK_MS = 400;
let lastRowMouseDown = { key: null, time: 0 };

function rowKeyOf(tr) {
  return tr ? `${tr.dataset.rowKind}:${tr.dataset.rowId ?? tr.dataset.rowPath}` : null;
}

function selectRow(tr) {
  const prev = entriesBody.querySelector("tr.row-selected");
  if (prev && prev !== tr) prev.classList.remove("row-selected");
  tr.classList.add("row-selected");
}

function openRow(tr) {
  const kind = tr.dataset.rowKind;
  if (kind === "folder") {
    loadFolder(Number(tr.dataset.rowId), tr.dataset.rowName);
  } else if (kind === "file") {
    // Copying the path, not downloading: a file could be a 200 GB movie -
    // nobody wants that fetched into the browser just from a double-click.
    // Downloading stays an explicit, deliberate action via its own button.
    copyPathToClipboard(tr.dataset.rowPath);
  }
}

entriesBody.addEventListener("mousedown", (ev) => {
  if (ev.button !== 0) return; // left click only
  if (ev.target.closest("[data-action]")) return; // action buttons handle themselves via click
  const tr = ev.target.closest("tr[data-row-kind]");
  if (!tr) return;
  const key = rowKeyOf(tr);
  const now = Date.now();
  const isDoubleClick = key === lastRowMouseDown.key && now - lastRowMouseDown.time < DOUBLE_CLICK_MS;
  lastRowMouseDown = { key, time: isDoubleClick ? 0 : now };
  selectRow(tr);
  if (isDoubleClick) openRow(tr);
});

entriesBody.addEventListener("click", (ev) => {
  const dlBtn = ev.target.closest('[data-action="download"]');
  if (dlBtn) {
    downloadFile(dlBtn.dataset.path, dlBtn.dataset.name).catch((e) => alert(e.message || "Download failed."));
    return;
  }
  const bmBtn = ev.target.closest('[data-action="bookmark"]');
  if (bmBtn) {
    toggleBookmark(bmBtn.dataset.kind, Number(bmBtn.dataset.targetId), bmBtn.dataset.label);
    return;
  }
  const revealBtn = ev.target.closest('[data-action="reveal-folder"]');
  if (revealBtn) {
    loadFolder(Number(revealBtn.dataset.folderId));
    return;
  }
  const copyBtn = ev.target.closest('[data-action="copy-path"]');
  if (copyBtn) {
    copyPathToClipboard(copyBtn.dataset.path);
    return;
  }
  const mapBtn = ev.target.closest('[data-action="map-path"]');
  if (mapBtn) {
    mapLocalPathPrompt(mapBtn.dataset.path, mapBtn.dataset.name);
  }
});

breadcrumbs.addEventListener("click", (ev) => {
  const btn = ev.target.closest("[data-crumb-index]");
  if (btn) jumpToCrumb(Number(btn.dataset.crumbIndex));
});

bookmarksList.addEventListener("click", (ev) => {
  const jumpBtn = ev.target.closest("[data-jump-bookmark]");
  if (jumpBtn && !jumpBtn.disabled) {
    const folderId = jumpBtn.dataset.openFolderId;
    if (folderId) {
      crumbs = [{ id: null, name: "Home" }, { id: Number(folderId), name: jumpBtn.dataset.label }];
      fileOffset = 0;
      searchMode = false;
      searchInput.value = "";
      fetchAndRenderFolder();
    }
    return;
  }
  const removeBtn = ev.target.closest("[data-remove-bookmark]");
  if (removeBtn) removeBookmark(Number(removeBtn.dataset.removeBookmark));
});

bookmarkHereBtn.addEventListener("click", () => {
  const c = crumbs[crumbs.length - 1];
  if (c.id === null) return;
  toggleBookmark("folder", c.id, c.name);
});

homeBtn.addEventListener("click", () => loadFolder(null));
loadMoreBtn.addEventListener("click", () => { fileOffset += FILE_PAGE_SIZE; fetchAndRenderFolder(); });
searchInput.addEventListener("input", runSearch);

// Search collapses into a single icon by default, so the breadcrumb trail
// gets the header space instead of a permanently-docked search bar.
function openSearchPopover() {
  searchPopover.classList.remove("hidden");
  searchInput.focus();
}
function closeSearchPopover() {
  searchPopover.classList.add("hidden");
}
searchToggleBtn.addEventListener("click", (ev) => {
  ev.stopPropagation();
  if (searchPopover.classList.contains("hidden")) openSearchPopover();
  else closeSearchPopover();
});
document.addEventListener("click", (ev) => {
  if (searchPopover.classList.contains("hidden")) return;
  if (searchPopover.contains(ev.target) || ev.target === searchToggleBtn) return;
  closeSearchPopover();
});
document.addEventListener("keydown", (ev) => {
  if (ev.key === "Escape") closeSearchPopover();
});

// Filters: a persistent toggleable inline panel (mirrors the desktop app's
// FmFiltersPanel - a docked strip under the toolbar, not a popover), so it
// stays open across interactions rather than dismissing on outside click.
filtersToggleBtn.addEventListener("click", () => {
  filtersPanel.classList.toggle("hidden");
});
filtersApply.addEventListener("click", () => {
  if (searchMode) runSearch();
  else fetchAndRenderFolder();
});
filtersClear.addEventListener("click", () => {
  el("filter-size-min").value = "";
  el("filter-size-max").value = "";
  el("filter-size-unit").value = "MB";
  filterCreatedRange.value = "";
  filterModifiedRange.value = "";
  el("filter-type").value = "all";
  el("filter-include-deleted").checked = false;
  if (searchMode) runSearch();
  else fetchAndRenderFolder();
});

whoami.addEventListener("click", () => {
  clearSession();
  showLogin();
});

logoutBtn.addEventListener("click", () => {
  clearSession();
  showLogin();
});

let loginInFlight = false;

function setLoginBusy(busy) {
  const submitBtn = loginForm.querySelector('button[type="submit"]');
  if (submitBtn) submitBtn.disabled = busy;
  accountList.querySelectorAll("[data-account-username]").forEach((btn) => {
    btn.disabled = busy;
    btn.classList.toggle("opacity-50", busy);
  });
}

async function loginWithCode(code) {
  if (loginInFlight) return;
  loginInFlight = true;
  setLoginBusy(true);
  try {
    const res = await fetch("/api/auth/verify-code", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code }),
    });
    if (!res.ok) throw await errorFromResponse(res);
    const data = await res.json();
    session = { token: data.token, macKeyHex: data.mac_key, macKey: await importMacKey(data.mac_key), role: data.role, username: data.username };
    persistSession();
    if (data.username) await upsertStoredAccount(data.username, data.role, code);
    await showApp();
  } finally {
    loginInFlight = false;
    setLoginBusy(false);
  }
}

loginForm.addEventListener("submit", async (ev) => {
  ev.preventDefault();
  loginError.classList.add("hidden");
  const code = loginCode.value.trim();
  if (!code) return;
  try {
    await loginWithCode(code);
    loginCode.value = "";
  } catch (e) {
    loginError.textContent = e.message || "Login failed.";
    loginError.classList.remove("hidden");
  }
});

/* ---------- account picker (desktop-style: tap a saved account, remove one,
   or fall back to a plain code field) ---------- */

async function showAccountForm() {
  accountList.classList.add("hidden");
  loginUseDifferentCode.classList.add("hidden");
  loginForm.classList.remove("hidden");
  const accounts = await loadStoredAccounts();
  loginBackToAccounts.classList.toggle("hidden", accounts.length === 0);
  loginCode.focus();
}

async function renderAccountList() {
  const accounts = await loadStoredAccounts();
  if (accounts.length <= 1) {
    await showAccountForm();
    return;
  }
  accountList.innerHTML = accounts
    .map(
      (a) => `
    <div class="flex items-center gap-2 group">
      <button data-account-username="${escapeHtml(a.username)}" class="flex-1 flex items-center justify-between text-left rounded-lg border border-line px-3 py-2 text-xs hover:border-brand transition-colors">
        <span>${escapeHtml(a.username)}</span>
        <span class="text-faint uppercase text-[10px]">${escapeHtml(a.role)}</span>
      </button>
      <button data-remove-account="${escapeHtml(a.username)}" class="hidden group-hover:inline text-faint hover:text-danger transition-colors" title="Remove saved account">${ICONS.x}</button>
    </div>`
    )
    .join("");
  accountList.classList.remove("hidden");
  loginUseDifferentCode.classList.remove("hidden");
  loginForm.classList.add("hidden");
  loginBackToAccounts.classList.add("hidden");
}

accountList.addEventListener("click", async (ev) => {
  const removeBtn = ev.target.closest("[data-remove-account]");
  if (removeBtn) {
    await removeStoredAccount(removeBtn.dataset.removeAccount);
    await renderAccountList();
    return;
  }
  const tileBtn = ev.target.closest("[data-account-username]");
  if (tileBtn) {
    const acc = (await loadStoredAccounts()).find((a) => a.username === tileBtn.dataset.accountUsername);
    if (!acc || loginInFlight) return;
    loginError.classList.add("hidden");
    try {
      await loginWithCode(acc.code);
    } catch (e) {
      loginError.textContent = e.message || "That saved code no longer works. Try a different one.";
      loginError.classList.remove("hidden");
    }
  }
});

loginUseDifferentCode.addEventListener("click", () => { showAccountForm(); });
loginBackToAccounts.addEventListener("click", () => {
  loginError.classList.add("hidden");
  renderAccountList();
});

themeToggleBtn.addEventListener("click", toggleTheme);
themeToggleBtnSetup.addEventListener("click", toggleTheme);

/* ---------- first-time setup wizard ----------
   Lets the web UI configure an unset-up agent directly, without the desktop
   app. Skips naming the NAS entirely (the agent auto-defaults friendly_name
   to its hostname) - that step was redundant, per user's feedback: there's
   only ever one agent behind a given address, so there's nothing to
   disambiguate by name. */

const setupHostname = el("setup-hostname");
const setupAdminUsername = el("setup-admin-username");
const setupAdminCode = el("setup-admin-code");
const setupFoldersList = el("setup-folders-list");
const setupAddFolder = el("setup-add-folder");
const setupExcludeHidden = el("setup-exclude-hidden");
const setupPatternsList = el("setup-patterns-list");
const setupAddPattern = el("setup-add-pattern");
const setupUsersList = el("setup-users-list");
const setupAddUser = el("setup-add-user");
const setupManagePassword = el("setup-manage-password");
const setupError = el("setup-error");
const setupSubmit = el("setup-submit");

let setupWatchedPaths = [""];
let setupPatterns = [];
let setupUsers = []; // { username, code, allowedPaths: [""] }

function renderSetupFolders() {
  setupFoldersList.innerHTML = setupWatchedPaths
    .map(
      (p, i) => `
    <div class="flex items-center gap-2">
      <input data-folder-index="${i}" type="text" placeholder="/mnt/storage/media" value="${escapeHtml(p)}"
             class="flex-1 rounded-lg border border-line bg-bg px-3 py-1.5 text-xs outline-none focus:border-brand font-mono" />
      <button data-remove-folder="${i}" class="text-faint hover:text-danger transition-colors" title="Remove">${ICONS.x}</button>
    </div>`
    )
    .join("");
}
function renderSetupPatterns() {
  setupPatternsList.innerHTML = setupPatterns
    .map(
      (p, i) => `
    <div class="flex items-center gap-2">
      <input data-pattern-index="${i}" type="text" placeholder="*.tmp" value="${escapeHtml(p)}"
             class="flex-1 rounded-lg border border-line bg-bg px-3 py-1.5 text-xs outline-none focus:border-brand font-mono" />
      <button data-remove-pattern="${i}" class="text-faint hover:text-danger transition-colors" title="Remove">${ICONS.x}</button>
    </div>`
    )
    .join("");
}
function renderSetupUsers() {
  setupUsersList.innerHTML = setupUsers
    .map((u, ui) => {
      const pathRows = u.allowedPaths
        .map(
          (p, pi) => `
        <div class="flex items-center gap-2">
          <input data-user-path="${ui}:${pi}" type="text" placeholder="Allowed path (defaults to full access if empty)" value="${escapeHtml(p)}"
                 class="flex-1 rounded-lg border border-line bg-bg px-2 py-1 text-[11px] outline-none focus:border-brand font-mono" />
          <button data-remove-user-path="${ui}:${pi}" class="text-faint hover:text-danger transition-colors" title="Remove">${ICONS.x}</button>
        </div>`
        )
        .join("");
      return `
      <div class="rounded-lg border border-line p-3">
        <div class="flex items-center gap-2 mb-2">
          <input data-user-username="${ui}" type="text" placeholder="Username" value="${escapeHtml(u.username)}"
                 class="flex-1 rounded-lg border border-line bg-bg px-2 py-1.5 text-xs outline-none focus:border-brand" />
          <input data-user-code="${ui}" type="password" autocomplete="off" placeholder="Access code" value="${escapeHtml(u.code)}"
                 class="flex-1 rounded-lg border border-line bg-bg px-2 py-1.5 text-xs outline-none focus:border-brand" />
          <button data-remove-user="${ui}" class="text-faint hover:text-danger transition-colors" title="Remove user">${ICONS.x}</button>
        </div>
        <div class="space-y-1.5 mb-1.5">${pathRows}</div>
        <button data-add-user-path="${ui}" class="text-[11px] text-brand hover:text-brand-hover transition-colors">+ Allowed path</button>
      </div>`;
    })
    .join("");
}

setupAddFolder.addEventListener("click", () => { setupWatchedPaths.push(""); renderSetupFolders(); });
setupFoldersList.addEventListener("input", (ev) => {
  const input = ev.target.closest("[data-folder-index]");
  if (input) setupWatchedPaths[Number(input.dataset.folderIndex)] = input.value;
});
setupFoldersList.addEventListener("click", (ev) => {
  const btn = ev.target.closest("[data-remove-folder]");
  if (btn) { setupWatchedPaths.splice(Number(btn.dataset.removeFolder), 1); renderSetupFolders(); }
});

setupAddPattern.addEventListener("click", () => { setupPatterns.push(""); renderSetupPatterns(); });
setupPatternsList.addEventListener("input", (ev) => {
  const input = ev.target.closest("[data-pattern-index]");
  if (input) setupPatterns[Number(input.dataset.patternIndex)] = input.value;
});
setupPatternsList.addEventListener("click", (ev) => {
  const btn = ev.target.closest("[data-remove-pattern]");
  if (btn) { setupPatterns.splice(Number(btn.dataset.removePattern), 1); renderSetupPatterns(); }
});

setupAddUser.addEventListener("click", () => { setupUsers.push({ username: "", code: "", allowedPaths: [""] }); renderSetupUsers(); });
setupUsersList.addEventListener("input", (ev) => {
  const uInput = ev.target.closest("[data-user-username]");
  if (uInput) { setupUsers[Number(uInput.dataset.userUsername)].username = uInput.value; return; }
  const cInput = ev.target.closest("[data-user-code]");
  if (cInput) { setupUsers[Number(cInput.dataset.userCode)].code = cInput.value; return; }
  const pInput = ev.target.closest("[data-user-path]");
  if (pInput) {
    const [ui, pi] = pInput.dataset.userPath.split(":").map(Number);
    setupUsers[ui].allowedPaths[pi] = pInput.value;
  }
});
setupUsersList.addEventListener("click", (ev) => {
  const removeUserBtn = ev.target.closest("[data-remove-user]");
  if (removeUserBtn) { setupUsers.splice(Number(removeUserBtn.dataset.removeUser), 1); renderSetupUsers(); return; }
  const addPathBtn = ev.target.closest("[data-add-user-path]");
  if (addPathBtn) { setupUsers[Number(addPathBtn.dataset.addUserPath)].allowedPaths.push(""); renderSetupUsers(); return; }
  const removePathBtn = ev.target.closest("[data-remove-user-path]");
  if (removePathBtn) {
    const [ui, pi] = removePathBtn.dataset.removeUserPath.split(":").map(Number);
    setupUsers[ui].allowedPaths.splice(pi, 1);
    renderSetupUsers();
  }
});

function showSetupScreen(info) {
  loginScreen.classList.add("hidden");
  appShell.classList.add("hidden");
  setupScreen.classList.remove("hidden");
  setupHostname.textContent = info.hostname ? `"${info.hostname}"` : "";
  setupWatchedPaths = [""];
  setupPatterns = [];
  setupUsers = [];
  renderSetupFolders();
  renderSetupPatterns();
  renderSetupUsers();
}

setupSubmit.addEventListener("click", async () => {
  setupError.classList.add("hidden");
  const adminUsername = setupAdminUsername.value.trim() || "admin";
  const adminCode = setupAdminCode.value;
  const managePassword = setupManagePassword.value;
  const watchedPaths = setupWatchedPaths.map((p) => p.trim()).filter(Boolean);

  if (!adminCode) { return showSetupError("Admin access code is required."); }
  if (!managePassword) { return showSetupError("Management password is required."); }
  if (watchedPaths.length === 0) { return showSetupError("At least one watched folder path is required."); }

  const exclusionPatterns = setupPatterns.map((p) => p.trim()).filter(Boolean);
  if (setupExcludeHidden.checked) exclusionPatterns.push(".*");

  const users = setupUsers
    .filter((u) => u.username.trim() && u.code.trim())
    .map((u) => {
      const explicitPaths = u.allowedPaths.map((p) => p.trim()).filter(Boolean);
      // The agent grants nothing for an empty allowed_paths list (not "full
      // access" as the placeholder implies to a first-time user) - so an
      // empty list here means "didn't restrict it", which should default to
      // every watched path rather than silently locking the user out.
      return {
        username: u.username.trim(),
        code: u.code.trim(),
        allowed_paths: explicitPaths.length > 0 ? explicitPaths : watchedPaths,
      };
    });

  setupSubmit.disabled = true;
  setupSubmit.textContent = "Deploying…";
  try {
    const res = await fetch("/api/auth/setup/finalize", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        friendly_name: "",
        watched_paths: watchedPaths,
        exclusion_patterns: exclusionPatterns,
        app_admin_code: adminCode,
        admin_username: adminUsername,
        users,
        snapshot_sync_interval_secs: 5,
        ghost_file_prune_days: null,
        manage_username: "manage",
        manage_password: managePassword,
      }),
    });
    if (!res.ok) throw await errorFromResponse(res);
    showToast("Setup complete");
    setupScreen.classList.add("hidden");
    try {
      await loginWithCode(adminCode);
    } catch {
      showLogin();
    }
  } catch (e) {
    showSetupError(e.message || "Setup failed.");
  } finally {
    setupSubmit.disabled = false;
    setupSubmit.textContent = "Deploy";
  }
});

function showSetupError(message) {
  setupError.textContent = message;
  setupError.classList.remove("hidden");
}

/* ---------- management console (admin-only, mirrors desktop FmAdminDashboard) ---------- */

let manageActiveTab = "overview";
let manageSettingsCache = null;
let manageDraft = {};

const MANAGE_TABS = [
  { id: "overview", label: "Overview" },
  { id: "settings", label: "Settings" },
  { id: "folders", label: "Folders" },
  { id: "users", label: "Users" },
  { id: "maintenance", label: "Maintenance" },
];

function openManageConsole() {
  manageOverlay.classList.remove("hidden");
  manageGate.classList.toggle("hidden", manageUnlocked);
  manageBody.classList.toggle("hidden", !manageUnlocked);
  manageGatePassword.value = "";
  manageGateError.classList.add("hidden");
  if (manageUnlocked) renderManageTab(manageActiveTab);
}

function closeManageConsole() {
  manageOverlay.classList.add("hidden");
}

async function unlockManageConsole() {
  manageGateError.classList.add("hidden");
  const password = manageGatePassword.value;
  if (!password) return;
  try {
    await apiPost("/api/admin/management/verify", { password });
    manageUnlocked = true;
    manageSavePassword.value = password;
    manageGate.classList.add("hidden");
    manageBody.classList.remove("hidden");
    await renderManageTab(manageActiveTab);
  } catch (e) {
    manageGateError.textContent = e.message || "Wrong management password.";
    manageGateError.classList.remove("hidden");
  }
}

function renderManageTabs() {
  manageTabs.innerHTML = MANAGE_TABS.map(
    (t) => `<button data-manage-tab="${t.id}" type="button"
      class="rounded-md px-2.5 py-1 whitespace-nowrap transition-colors ${t.id === manageActiveTab ? "bg-panel-muted text-ink font-medium" : "text-muted hover:text-ink"}">${t.label}</button>`
  ).join("");
}

async function renderManageTab(tab) {
  manageActiveTab = tab;
  renderManageTabs();
  manageContent.innerHTML = `<p class="text-muted">Loading…</p>`;
  try {
    if (tab === "overview") await renderManageOverview();
    else if (tab === "settings") await renderManageSettings();
    else if (tab === "folders") await renderManageFolders();
    else if (tab === "users") await renderManageUsers();
    else if (tab === "maintenance") renderManageMaintenance();
  } catch (e) {
    manageContent.innerHTML = `<p class="text-danger">${escapeHtml(e.message || "Failed to load.")}</p>`;
  }
}

async function renderManageOverview() {
  const stats = await apiGet("/api/admin/stats");
  const uptimeH = Math.floor((stats.uptime_seconds || 0) / 3600);
  const uptimeM = Math.floor(((stats.uptime_seconds || 0) % 3600) / 60);
  manageContent.innerHTML = `
    <div class="grid grid-cols-2 gap-3 mb-4">
      <div class="rounded-lg border border-line p-3"><div class="text-faint text-[10px] uppercase mb-1">Files</div><div class="text-lg font-semibold">${stats.total_files ?? 0}</div></div>
      <div class="rounded-lg border border-line p-3"><div class="text-faint text-[10px] uppercase mb-1">Folders</div><div class="text-lg font-semibold">${stats.total_folders ?? 0}</div></div>
    </div>
    <p class="text-muted mb-3">Uptime: ${uptimeH}h ${uptimeM}m</p>
    <h3 class="text-[10px] font-semibold uppercase tracking-wide text-muted mb-2">Watched folders</h3>
    <ul class="space-y-1">${(stats.watched_folders || []).map((f) =>
      `<li class="flex justify-between gap-2 rounded border border-line px-2 py-1.5 font-mono text-[11px]"><span class="truncate">${escapeHtml(f.path)}</span><span class="text-faint shrink-0">${escapeHtml(f.status)} · ${f.scanned ?? 0}</span></li>`
    ).join("") || '<li class="text-faint">None</li>'}</ul>`;
}

async function renderManageSettings() {
  manageSettingsCache = await apiGet("/api/admin/settings");
  manageDraft = {
    friendly_name: manageSettingsCache.friendly_name || "",
    port: manageSettingsCache.port || 34514,
    bind_address: manageSettingsCache.bind_address || "",
    exclusion_patterns: (manageSettingsCache.exclusion_patterns || []).join("\n"),
  };
  manageContent.innerHTML = `
    <div class="space-y-3">
      <label class="flex flex-col gap-1"><span class="text-muted">Agent name</span>
        <input id="manage-friendly-name" type="text" value="${escapeHtml(manageDraft.friendly_name)}"
               class="rounded-lg border border-line bg-bg px-3 py-1.5 outline-none focus:border-brand" /></label>
      <div class="grid grid-cols-2 gap-3">
        <label class="flex flex-col gap-1"><span class="text-muted">Port</span>
          <input id="manage-port" type="number" min="1024" value="${manageDraft.port}"
                 class="rounded-lg border border-line bg-bg px-3 py-1.5 outline-none focus:border-brand font-mono" /></label>
        <label class="flex flex-col gap-1"><span class="text-muted">Bind address</span>
          <input id="manage-bind" type="text" value="${escapeHtml(manageDraft.bind_address)}"
                 class="rounded-lg border border-line bg-bg px-3 py-1.5 outline-none focus:border-brand font-mono" /></label>
      </div>
      <label class="flex flex-col gap-1"><span class="text-muted">Global exclusion patterns (one per line)</span>
        <textarea id="manage-exclusions" rows="4"
                  class="rounded-lg border border-line bg-bg px-3 py-1.5 outline-none focus:border-brand font-mono text-[11px]">${escapeHtml(manageDraft.exclusion_patterns)}</textarea></label>
      <p class="text-faint text-[11px]">Saving settings requires the management password below. Port changes take effect after agent restart.</p>
    </div>`;
}

async function renderManageFolders() {
  const folders = await apiGet("/api/admin/folders");
  manageContent.innerHTML = `
    <ul class="space-y-1.5">${(folders || []).map((f) =>
      `<li class="rounded border border-line px-2 py-1.5 font-mono text-[11px] flex justify-between gap-2">
        <span class="truncate">${escapeHtml(f.path)}</span>
        <span class="text-faint shrink-0">${escapeHtml(f.status)}</span>
      </li>`
    ).join("") || '<li class="text-faint">No watched folders.</li>'}</ul>`;
}

async function renderManageUsers() {
  const users = await apiGet("/api/admin/users");
  manageContent.innerHTML = `
    <ul class="space-y-1.5">${(users || []).map((u) =>
      `<li class="flex items-center justify-between rounded border border-line px-2 py-1.5">
        <span>${escapeHtml(u.username)}</span>
        <button data-delete-user="${u.id}" type="button" class="text-faint hover:text-danger transition-colors" title="Delete user">${ICONS.x}</button>
      </li>`
    ).join("") || '<li class="text-faint">No users besides admin.</li>'}</ul>`;
  manageContent.querySelectorAll("[data-delete-user]").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const pwd = manageSavePassword.value;
      if (!pwd) { showToast("Enter management password to save changes."); return; }
      try {
        await apiDelete(`/api/admin/users/${btn.dataset.deleteUser}`);
        showToast("User removed");
        await renderManageUsers();
      } catch (e) {
        showToast(e.message || "Delete failed");
      }
    });
  });
}

function renderManageMaintenance() {
  manageContent.innerHTML = `
    <div class="space-y-2">
      <button id="manage-rescan-btn" type="button"
              class="w-full rounded-lg border border-line px-3 py-2 text-left hover:border-brand transition-colors">Trigger full rescan</button>
      <button id="manage-restart-btn" type="button"
              class="w-full rounded-lg border border-line px-3 py-2 text-left hover:border-brand transition-colors">Restart agent</button>
      <p class="text-faint text-[11px] mt-2">Restart disconnects all clients briefly.</p>
    </div>`;
  el("manage-rescan-btn").addEventListener("click", async () => {
    try {
      await apiPost("/api/admin/rescan");
      showToast("Rescan started");
    } catch (e) {
      showToast(e.message || "Rescan failed");
    }
  });
  el("manage-restart-btn").addEventListener("click", async () => {
    if (!confirm("Restart the agent now?")) return;
    try {
      await apiPost("/api/admin/restart");
      showToast("Agent restarting…");
      closeManageConsole();
    } catch (e) {
      showToast(e.message || "Restart failed");
    }
  });
}

async function saveManageSettings() {
  const pwd = manageSavePassword.value;
  if (!pwd) { showToast("Enter management password to save."); return; }
  const payload = { management_password: pwd };
  if (manageActiveTab === "settings") {
    const patterns = (el("manage-exclusions")?.value || "")
      .split("\n").map((p) => p.trim()).filter(Boolean);
    Object.assign(payload, {
      friendly_name: el("manage-friendly-name")?.value?.trim() || "",
      port: Number(el("manage-port")?.value) || undefined,
      bind_address: el("manage-bind")?.value?.trim() || "",
      exclusion_patterns: patterns,
    });
  } else {
    showToast("Nothing to save on this tab.");
    return;
  }
  try {
    await apiPost("/api/admin/settings", payload);
    showToast("Settings saved");
    await renderManageTab(manageActiveTab);
  } catch (e) {
    showToast(e.message || "Save failed");
  }
}

manageBtn.addEventListener("click", openManageConsole);
manageCloseBtn.addEventListener("click", closeManageConsole);
manageOverlay.addEventListener("click", (ev) => { if (ev.target === manageOverlay) closeManageConsole(); });
manageGateSubmit.addEventListener("click", unlockManageConsole);
manageGatePassword.addEventListener("keydown", (ev) => { if (ev.key === "Enter") unlockManageConsole(); });
manageTabs.addEventListener("click", (ev) => {
  const tabBtn = ev.target.closest("[data-manage-tab]");
  if (tabBtn) renderManageTab(tabBtn.dataset.manageTab);
});
manageSaveBtn.addEventListener("click", saveManageSettings);

/* ---------- boot ---------- */

async function showLogin() {
  appShell.classList.add("hidden");
  setupScreen.classList.add("hidden");
  loginScreen.classList.remove("hidden");
  loginError.classList.add("hidden");

  const accounts = await loadStoredAccounts();
  if (accounts.length === 1) {
    accountList.classList.add("hidden");
    loginUseDifferentCode.classList.add("hidden");
    loginForm.classList.add("hidden");
    loginBackToAccounts.classList.add("hidden");
    loginWithCode(accounts[0].code).catch(async () => {
      await showAccountForm();
      loginError.textContent = "Saved code no longer works. Enter a new one or remove the account.";
      loginError.classList.remove("hidden");
    });
    return;
  }
  await renderAccountList();
}

async function showApp() {
  loginScreen.classList.add("hidden");
  setupScreen.classList.add("hidden");
  appShell.classList.remove("hidden");
  whoami.textContent = session.username ? `${session.username} (${session.role})` : session.role;
  manageBtn.classList.toggle("hidden", session.role !== "admin");
  crumbs = [{ id: null, name: "Home" }];
  // Sequential, not parallel: renderEntries() reads bookmarkedKeys to draw
  // filled/outline stars, so it needs bookmarks loaded first.
  await loadBookmarks();
  await fetchAndRenderFolder();
}

async function boot() {
  let info = null;
  try {
    info = await fetch("/api/auth/discovery").then((r) => r.json());
    loginTitle.textContent = info.hostname || "Datieve";
  } catch {
    /* discovery is best-effort; if it fails, assume already set up and let login fail loudly instead */
  }

  if (info && !info.is_setup) {
    showSetupScreen(info);
    return;
  }

  const restored = await restoreSession();
  if (restored) {
    session = restored;
    try {
      await apiGet("/api/auth/me");
      await showApp();
      return;
    } catch {
      clearSession();
    }
  }
  showLogin();
}

updateThemeIcon(loadTheme());
boot();
