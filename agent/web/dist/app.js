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
  persistSession();
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
const appShell = el("app-shell");
const loginForm = el("login-form");
const loginCode = el("login-code");
const loginError = el("login-error");
const loginTitle = el("login-title");
const loginSetupWarning = el("login-setup-warning");
const breadcrumbs = el("breadcrumbs");
const homeBtn = el("home-btn");
const searchInput = el("search-input");
const filtersToggle = el("filters-toggle");
const filtersPanel = el("filters-panel");
const filtersApply = el("filters-apply");
const filtersClear = el("filters-clear");
const whoami = el("whoami");
const logoutBtn = el("logout-btn");
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

function currentFolderId() {
  return crumbs[crumbs.length - 1].id;
}

function activeFilters() {
  return {
    size_min: (() => { const v = parseFloat(el("filter-size-min").value); return isNaN(v) ? undefined : Math.round(v * 1024 * 1024); })(),
    size_max: (() => { const v = parseFloat(el("filter-size-max").value); return isNaN(v) ? undefined : Math.round(v * 1024 * 1024); })(),
    modified_after: el("filter-modified-after").value || undefined,
    // Append end-of-day so picking the same date for "before" still includes that whole day.
    modified_before: el("filter-modified-before").value ? `${el("filter-modified-before").value}T23:59:59` : undefined,
    include_deleted: el("filter-include-deleted").checked || undefined,
  };
}

/* ---------- rendering ---------- */

function renderBreadcrumbs() {
  breadcrumbs.innerHTML = crumbs
    .map((c, i) => {
      const isLast = i === crumbs.length - 1;
      const label = escapeHtml(c.name);
      if (isLast) return `<span class="text-ink font-medium">${label}</span>`;
      return `<button data-crumb-index="${i}" class="hover:text-brand transition-colors">${label}</button><span class="text-faint">/</span>`;
    })
    .join(" ");
  bookmarkHereBtn.disabled = crumbs.length <= 1;
}

function rowActionsHtml(kind, targetId, path, name) {
  const dl = kind === "file" ? `<button data-action="download" data-path="${escapeHtml(path)}" data-name="${escapeHtml(name)}" class="text-brand hover:text-brand-hover transition-colors" title="Download">&#8595;</button>` : "";
  const bm = `<button data-action="bookmark" data-kind="${kind}" data-target-id="${targetId}" data-label="${escapeHtml(name)}" class="text-muted hover:text-warn transition-colors" title="Bookmark">&#9734;</button>`;
  return `<span class="flex items-center gap-2 justify-end">${dl}${bm}</span>`;
}

function renderEntries() {
  const rows = [];
  for (const f of currentFolders) {
    rows.push(`
      <tr class="border-b border-line hover:bg-panel-soft">
        <td class="py-1.5 pr-2">
          <button data-open-folder="${f.id}" data-name="${escapeHtml(f.name)}" class="flex items-center gap-1.5 hover:text-brand transition-colors text-left">
            <span>&#128193;</span><span>${escapeHtml(f.name)}</span>${f.is_deleted ? '<span class="text-faint">(deleted)</span>' : ""}
          </button>
        </td>
        <td class="py-1.5 pr-2 text-muted">${f.file_count} item${f.file_count === 1 ? "" : "s"}</td>
        <td class="py-1.5 pr-2 text-muted">${formatDate(f.indexed_at)}</td>
        <td class="py-1.5">${rowActionsHtml("folder", f.id, f.absolute_path, f.name)}</td>
      </tr>`);
  }
  for (const f of currentFiles) {
    rows.push(`
      <tr class="border-b border-line hover:bg-panel-soft">
        <td class="py-1.5 pr-2">
          <span class="flex items-center gap-1.5">
            <span>&#128196;</span><span>${escapeHtml(f.name)}</span>${f.is_deleted ? '<span class="text-faint">(deleted)</span>' : ""}
          </span>
        </td>
        <td class="py-1.5 pr-2 text-muted">${formatBytes(f.size_bytes)}</td>
        <td class="py-1.5 pr-2 text-muted">${formatDate(f.modified_at)}</td>
        <td class="py-1.5">${rowActionsHtml("file", f.id, f.absolute_path, f.name)}</td>
      </tr>`);
  }
  entriesBody.innerHTML = rows.join("") || `<tr><td colspan="4" class="py-6 text-center text-faint">Empty folder.</td></tr>`;
  loadMoreBtn.classList.toggle("hidden", !hasMoreFiles);
  statusLine.textContent = `${currentFolders.length} folder${currentFolders.length === 1 ? "" : "s"}, ${currentFiles.length} file${currentFiles.length === 1 ? "" : "s"}${hasMoreFiles ? "+" : ""}`;
}

function renderSearchResults(results) {
  entriesBody.innerHTML =
    results
      .map(
        (r) => `
      <tr class="border-b border-line hover:bg-panel-soft">
        <td class="py-1.5 pr-2">
          <button data-open-folder="${r.folder_id}" data-name="${escapeHtml(r.name)}" class="flex items-center gap-1.5 hover:text-brand transition-colors text-left">
            <span>&#128196;</span><span>${escapeHtml(r.name)}</span>${r.is_deleted ? '<span class="text-faint">(deleted)</span>' : ""}
          </button>
          <div class="text-faint text-[11px] truncate max-w-md">${escapeHtml(r.absolute_path)}</div>
        </td>
        <td class="py-1.5 pr-2 text-muted">${formatBytes(r.size_bytes)}</td>
        <td class="py-1.5 pr-2 text-muted">${formatDate(r.modified_at)}</td>
        <td class="py-1.5">${rowActionsHtml("file", r.id, r.absolute_path, r.name)}</td>
      </tr>`
      )
      .join("") || `<tr><td colspan="4" class="py-6 text-center text-faint">No results.</td></tr>`;
  loadMoreBtn.classList.add("hidden");
  statusLine.textContent = `${results.length} result${results.length === 1 ? "" : "s"}`;
}

function renderBookmarks(items) {
  bookmarksList.innerHTML = items
    .map((b) => {
      const icon = b.kind === "folder" ? "&#128193;" : "&#128196;";
      const dim = b.is_missing ? "opacity-50" : "";
      return `
      <li class="group flex items-center gap-1 ${dim}">
        <button data-jump-bookmark="${b.id}" data-open-folder-id="${b.open_folder_id ?? ""}" data-label="${escapeHtml(b.label)}"
                class="flex-1 text-left truncate hover:text-brand transition-colors" title="${escapeHtml(b.path || "missing")}"
                ${b.is_missing ? "disabled" : ""}>
          <span>${icon}</span> ${escapeHtml(b.label)}
        </button>
        <button data-remove-bookmark="${b.id}" class="hidden group-hover:inline text-faint hover:text-danger transition-colors" title="Remove">&times;</button>
      </li>`;
    })
    .join("");
  bookmarksEmpty.classList.toggle("hidden", items.length > 0);
}

/* ---------- data loading ---------- */

async function loadBookmarks() {
  try {
    const items = await apiGet("/api/bookmarks");
    renderBookmarks(items);
  } catch (e) {
    console.error("Failed to load bookmarks", e);
  }
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
        modified_after: f.modified_after,
        modified_before: f.modified_before,
        include_deleted: f.include_deleted,
      })}`
    );
    renderSearchResults(results);
  } catch (e) {
    statusLine.textContent = e.message || "Search failed.";
  }
}, 300);

/* ---------- bookmark actions ---------- */

async function addBookmark(kind, targetId, label) {
  try {
    await apiPost("/api/bookmarks", { kind, target_id: targetId, label });
    await loadBookmarks();
  } catch (e) {
    alert(e.message || "Could not add bookmark.");
  }
}

async function removeBookmark(id) {
  try {
    await apiDelete(`/api/bookmarks/${id}`);
    await loadBookmarks();
  } catch (e) {
    alert(e.message || "Could not remove bookmark.");
  }
}

/* ---------- event wiring ---------- */

entriesBody.addEventListener("click", (ev) => {
  const openBtn = ev.target.closest("[data-open-folder]");
  if (openBtn) {
    loadFolder(Number(openBtn.dataset.openFolder), openBtn.dataset.name);
    return;
  }
  const dlBtn = ev.target.closest('[data-action="download"]');
  if (dlBtn) {
    downloadFile(dlBtn.dataset.path, dlBtn.dataset.name).catch((e) => alert(e.message || "Download failed."));
    return;
  }
  const bmBtn = ev.target.closest('[data-action="bookmark"]');
  if (bmBtn) {
    addBookmark(bmBtn.dataset.kind, Number(bmBtn.dataset.targetId), bmBtn.dataset.label);
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
  addBookmark("folder", c.id, c.name);
});

homeBtn.addEventListener("click", () => loadFolder(null));
loadMoreBtn.addEventListener("click", () => { fileOffset += FILE_PAGE_SIZE; fetchAndRenderFolder(); });
searchInput.addEventListener("input", runSearch);

filtersToggle.addEventListener("click", () => filtersPanel.classList.toggle("hidden"));
filtersApply.addEventListener("click", () => {
  if (searchMode) runSearch();
  else fetchAndRenderFolder();
});
filtersClear.addEventListener("click", () => {
  el("filter-size-min").value = "";
  el("filter-size-max").value = "";
  el("filter-modified-after").value = "";
  el("filter-modified-before").value = "";
  el("filter-include-deleted").checked = false;
  if (searchMode) runSearch();
  else fetchAndRenderFolder();
});

logoutBtn.addEventListener("click", () => {
  clearSession();
  showLogin();
});

loginForm.addEventListener("submit", async (ev) => {
  ev.preventDefault();
  loginError.classList.add("hidden");
  const code = loginCode.value.trim();
  if (!code) return;
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
    loginCode.value = "";
    await showApp();
  } catch (e) {
    loginError.textContent = e.message || "Login failed.";
    loginError.classList.remove("hidden");
  }
});

/* ---------- boot ---------- */

function showLogin() {
  appShell.classList.add("hidden");
  loginScreen.classList.remove("hidden");
}

async function showApp() {
  loginScreen.classList.add("hidden");
  appShell.classList.remove("hidden");
  whoami.textContent = session.username ? `${session.username} (${session.role})` : session.role;
  crumbs = [{ id: null, name: "Home" }];
  await Promise.all([fetchAndRenderFolder(), loadBookmarks()]);
}

async function boot() {
  try {
    const info = await fetch("/api/auth/discovery").then((r) => r.json());
    loginTitle.textContent = info.hostname || "Datieve";
    if (!info.is_setup) loginSetupWarning.classList.remove("hidden");
  } catch {
    /* discovery is best-effort cosmetic info; ignore failures */
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

boot();
