// Browse API handler (GET /api/browse).
// Returns the folders and files under a given folder ID, with pagination.
// Also serves the SSE stream at /api/events that pushes "FileChanged" when
// the writer commits a batch, so the frontend can refresh without polling.
use axum::{
    extract::{Query, State},
    response::IntoResponse,
    Extension, Json,
};
use axum::response::sse::{Event, Sse};
use futures_util::stream::Stream;
use rusqlite::OptionalExtension;
use serde::{Deserialize, Serialize};
use tokio::task::spawn_blocking;
use tokio_stream::wrappers::WatchStream;
use tokio_stream::StreamExt as _;

use crate::api::middleware::SessionUser;
use crate::api::AppState;
use crate::error::AppError;

const BROWSE_RESPONSE_LIMIT: i64 = 2_000;

#[derive(Deserialize)]
pub struct BrowseQuery {
    pub parent_id: Option<i64>,
    /// Page size for files. If absent, uses the server default (2 000).
    pub file_limit: Option<i64>,
    /// Zero-based file offset for pagination. Defaults to 0.
    pub file_offset: Option<i64>,
    /// Include deleted (ghost) files in results.
    pub include_deleted: Option<bool>,
}

#[derive(Serialize)]
pub struct BrowseResponse {
    pub folders: Vec<FolderInfo>,
    pub files: Vec<FileInfo>,
    /// True when there are more files beyond the current page.
    pub has_more: bool,
    /// Absolute filesystem path of the folder being browsed, when known.
    pub current_absolute_path: Option<String>,
}

#[derive(Serialize)]
pub struct FolderInfo {
    pub id: i64,
    pub name: String,
    pub path: String,
    pub absolute_path: String,
    pub file_count: i64,
    pub total_size_bytes: i64,
    pub indexed_at: Option<String>,
    pub created_at: Option<String>,
    pub deleted_at: Option<String>,
    pub is_deleted: bool,
}

#[derive(Serialize)]
pub struct FileInfo {
    pub id: i64,
    pub name: String,
    pub path: String,
    pub absolute_path: String,
    pub size_bytes: u64,
    pub created_at: String,
    pub modified_at: String,
    pub deleted_at: Option<String>,
    pub is_deleted: bool,
    pub is_symlink: bool,
}

pub async fn browse(
    State(state): State<AppState>,
    Extension(session): Extension<SessionUser>,
    Query(params): Query<BrowseQuery>,
) -> Result<impl IntoResponse, AppError> {
    let res = spawn_blocking(move || {
        let conn = state.db.get()?;
        let scope = crate::engine::scope_tag();
        let include_deleted = params.include_deleted.unwrap_or(false);

        if session.allowed_folder_ids.is_empty() {
            return Ok::<_, AppError>(BrowseResponse {
                folders: vec![],
                files: vec![],
                has_more: false,
                current_absolute_path: None,
            });
        }

        let mut folders = Vec::new();
        let mut files = Vec::new();
        let mut has_more = false;
        let mut current_absolute_path: Option<String> = None;
        let fl = params.file_limit.unwrap_or(BROWSE_RESPONSE_LIMIT).clamp(1, BROWSE_RESPONSE_LIMIT);
        let fo = params.file_offset.unwrap_or(0).max(0);

        if let Some(pid) = params.parent_id {
            // 1. Resolve the path of the current folder using a Recursive CTE
            let current_path: String = conn.query_row(
                "WITH RECURSIVE path_builder(id, name, parent_id, level) AS (
                    SELECT id, name, parent_id, 0 FROM folders WHERE id = ?
                    UNION ALL
                    SELECT f.id, f.name, f.parent_id, level + 1 FROM folders f
                    JOIN path_builder ON f.id = path_builder.parent_id
                )
                SELECT group_concat(name, '/') FROM (SELECT name FROM path_builder WHERE name != '' ORDER BY level DESC)",
                [pid], |r| r.get::<_, Option<String>>(0)
            ).optional()?.flatten().unwrap_or_default();

            let _display_path = if current_path.is_empty() { "/".to_string() } else { format!("/{}", current_path) };

            // 2. Verify this folder belongs to an allowed watched_folder
            let is_allowed: bool = conn.query_row(
                "SELECT 1 FROM folders WHERE id = ? AND is_deleted = 0 AND scope_tag = ? AND watched_folder_id IN (
                    SELECT value FROM json_each(?)
                )",
                rusqlite::params![pid, scope, serde_json::to_string(&session.allowed_folder_ids).unwrap()],
                |_| Ok(true)
            ).optional()?.unwrap_or(false);

            if !is_allowed { return Err(AppError::Forbidden("Unauthorized access".into())); }

            // Non-admin: verify this folder is at or below the user's entry point.
            // Prevents navigating above a path_prefix via a direct parent_id request.
            if session.role != "admin" {
                let entry_json = serde_json::to_string(&session.entry_folder_ids).unwrap_or_default();
                let reachable: i64 = conn.query_row(
                    "WITH RECURSIVE anc(id, parent_id) AS (
                        SELECT id, parent_id FROM folders WHERE id = ? AND scope_tag = ?
                        UNION ALL
                        SELECT f.id, f.parent_id FROM folders f
                        JOIN anc ON f.id = anc.parent_id WHERE f.scope_tag = ?
                    )
                    SELECT COUNT(1) FROM anc WHERE id IN (SELECT value FROM json_each(?))",
                    rusqlite::params![pid, scope, scope, entry_json],
                    |r| r.get(0),
                ).unwrap_or(0);
                if reachable == 0 {
                    return Err(AppError::Forbidden("Unauthorized access".into()));
                }
            }

            let watched_path: String = conn.query_row(
                "SELECT wf.path
                 FROM folders f
                 JOIN watched_folders wf ON wf.id = f.watched_folder_id
                 WHERE f.id = ? AND f.scope_tag = ? AND wf.scope_tag = ?",
                rusqlite::params![pid, scope, scope],
                |r| r.get(0)
            )?;
            let absolute_base = std::path::Path::new(&watched_path).join(&current_path);
            current_absolute_path = Some(absolute_base.to_string_lossy().into_owned());

            let hide_path = absolute_base.join(".datievehide");
            let mut hidden_names = std::collections::HashSet::new();
            if hide_path.exists() {
                if let Ok(content) = std::fs::read_to_string(&hide_path) {
                    for line in content.lines() {
                        let trimmed = line.trim();
                        if !trimmed.is_empty() {
                            hidden_names.insert(trimmed.to_string());
                        }
                    }
                }
            }

            // 3. Fetch Subfolders (include ghost folders when include_deleted is set)
            let folder_deleted_filter = if include_deleted { "" } else { "AND is_deleted = 0 " };
            let f_sql = format!(
                "SELECT id, name, file_count, total_size_bytes, indexed_at, created_at, is_deleted, deleted_at \
                 FROM folders WHERE parent_id = ? {}AND scope_tag = ? ORDER BY name ASC LIMIT ?",
                folder_deleted_filter
            );
            let mut f_stmt = conn.prepare(&f_sql)?;
            let f_rows = f_stmt.query_map(rusqlite::params![pid, scope, BROWSE_RESPONSE_LIMIT], |r| {
                let name: String = r.get(1)?;
                Ok(FolderInfo {
                    id: r.get(0)?,
                    name: name.clone(),
                    path: if current_path.is_empty() { format!("/{}", name) } else { format!("/{}/{}", current_path, name) },
                    absolute_path: absolute_base.join(&name).to_string_lossy().into_owned(),
                    file_count: r.get(2)?,
                    total_size_bytes: r.get(3)?,
                    indexed_at: r.get(4)?,
                    created_at: r.get(5)?,
                    is_deleted: r.get::<_, i64>(6)? == 1,
                    deleted_at: r.get(7)?,
                })
            })?;
            for f in f_rows {
                let f = f?;
                if !hidden_names.contains(&f.name) {
                    folders.push(f);
                }
            }

            // 4. Fetch Files (fetch fl+1 to detect whether more exist beyond this page)
            let deleted_filter = if include_deleted { "" } else { "AND is_deleted = 0 " };
            let fi_sql = format!(
                "SELECT id, name, size_bytes, created_at, modified_at, is_deleted, deleted_at, is_symlink \
                 FROM files WHERE folder_id = ? {}AND scope_tag = ? ORDER BY name ASC LIMIT ? OFFSET ?",
                deleted_filter
            );
            let mut fi_stmt = conn.prepare(&fi_sql)?;
            let fi_rows = fi_stmt.query_map(rusqlite::params![pid, scope, fl + 1, fo], |r| {
                let name: String = r.get(1)?;
                Ok(FileInfo {
                    id: r.get(0)?, name: name.clone(),
                    path: if current_path.is_empty() { format!("/{}", name) } else { format!("/{}/{}", current_path, name) },
                    absolute_path: absolute_base.join(&name).to_string_lossy().into_owned(),
                    size_bytes: r.get::<_, i64>(2)? as u64,
                    created_at: r.get(3)?,
                    modified_at: r.get(4)?,
                    is_deleted: r.get::<_, i64>(5)? == 1,
                    deleted_at: r.get(6)?,
                    is_symlink: r.get::<_, i64>(7)? == 1,
                })
            })?;
            for fi in fi_rows {
                let fi = fi?;
                if !hidden_names.contains(&fi.name) {
                    files.push(fi);
                }
            }
            if files.len() > fl as usize { has_more = true; files.pop(); }

        } else {
            // Root / Virtual Home
            // Use entry_folder_ids resolved in middleware (accounts for path_prefix).
            // Single entry point: auto-expand into its children.
            // Multiple: show each as a named entry-point folder.

            let entry_ids = &session.entry_folder_ids;
            if entry_ids.is_empty() {
                return Ok::<_, AppError>(BrowseResponse {
                    folders: vec![],
                    files: vec![],
                    has_more: false,
                    current_absolute_path: None,
                });
            }

            // Helper: compute the full relative path of a folder within its watched tree.
            let get_folder_path = |fid: i64| -> Result<(String, String), AppError> {
                let current_path: String = conn.query_row(
                    "WITH RECURSIVE path_builder(id, name, parent_id, level) AS (
                        SELECT id, name, parent_id, 0 FROM folders WHERE id = ?
                        UNION ALL
                        SELECT f.id, f.name, f.parent_id, level + 1 FROM folders f
                        JOIN path_builder ON f.id = path_builder.parent_id
                    )
                    SELECT group_concat(name, '/') FROM (SELECT name FROM path_builder WHERE name != '' ORDER BY level DESC)",
                    [fid], |r| r.get::<_, Option<String>>(0)
                ).optional()?.flatten().unwrap_or_default();

                let watched_path: String = conn.query_row(
                    "SELECT wf.path FROM folders f
                     JOIN watched_folders wf ON wf.id = f.watched_folder_id
                     WHERE f.id = ? AND f.scope_tag = ?",
                    rusqlite::params![fid, scope], |r| r.get(0)
                )?;
                Ok((current_path, watched_path))
            };

            {
                // Always show each watched folder as a named top-level entry.
                for &entry_id in entry_ids {
                    let (entry_path, watched_path) = get_folder_path(entry_id)?;
                    let abs_base = std::path::Path::new(&watched_path).join(&entry_path);
                    let display_name = std::path::Path::new(&watched_path)
                        .file_name()
                        .and_then(|n| n.to_str())
                        .unwrap_or(&watched_path)
                        .to_string();
                    let (fc, ts, ia): (i64, i64, Option<String>) = conn.query_row(
                        "SELECT file_count, total_size_bytes, indexed_at FROM folders WHERE id = ? AND scope_tag = ?",
                        rusqlite::params![entry_id, scope],
                        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))
                    ).unwrap_or((0, 0, None));
                    folders.push(FolderInfo {
                        id: entry_id,
                        name: display_name.clone(),
                        path: format!("/{}", display_name),
                        absolute_path: abs_base.to_string_lossy().into_owned(),
                        file_count: fc,
                        total_size_bytes: ts,
                        indexed_at: ia,
                        created_at: None,
                        deleted_at: None,
                        is_deleted: false,
                    });
                }
                folders.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
            }
        }

        folders.truncate(BROWSE_RESPONSE_LIMIT as usize);

        Ok::<_, AppError>(BrowseResponse {
            folders,
            files,
            has_more,
            current_absolute_path,
        })
    }).await.map_err(|_| AppError::Internal("Task Panic".into()))??;

    Ok(Json(res))
}

/// SSE stream that emits "changed" whenever the writer commits file-system changes to the DB.
/// Accessible to all authenticated users (admin and non-admin) so the frontend can drop
/// the polling interval and reload only when something actually changed.
pub async fn file_events_stream(
    State(state): State<AppState>,
    Extension(_session): Extension<SessionUser>,
) -> Sse<impl Stream<Item = Result<Event, std::convert::Infallible>>> {
    let rx = state.file_change_rx.clone();
    let stream = WatchStream::new(rx)
        .skip(1) // skip the initial value emitted on subscribe (not a real change)
        .map(|_| Ok(Event::default().data("changed")));
    Sse::new(stream).keep_alive(axum::response::sse::KeepAlive::default())
}
