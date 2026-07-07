// Bookmarks API (GET/POST /api/bookmarks, DELETE /api/bookmarks/:id).
//
// A bookmark is a saved shortcut into the browse tree - either a folder or a
// file - so a user can jump straight there instead of navigating from the
// root every time. Owned by the single admin, or by a specific user.
use axum::{
    extract::{Path as AxumPath, State},
    http::StatusCode,
    response::IntoResponse,
    Extension, Json,
};
use rusqlite::OptionalExtension;
use serde::{Deserialize, Serialize};
use tokio::task::spawn_blocking;

use crate::api::middleware::SessionUser;
use crate::api::AppState;
use crate::error::AppError;

const MAX_BOOKMARKS_PER_OWNER: i64 = 200;

#[derive(Deserialize)]
pub struct CreateBookmarkRequest {
    pub kind: String, // "folder" or "file"
    pub target_id: i64,
    pub label: String,
}

#[derive(Serialize)]
pub struct BookmarkInfo {
    pub id: i64,
    pub kind: String,
    pub target_id: i64,
    pub label: String,
    pub path: Option<String>,
    /// Folder id to pass to `browse` to reveal this bookmark - equal to
    /// `target_id` for folder bookmarks, the parent folder for file bookmarks.
    pub open_folder_id: Option<i64>,
    pub is_missing: bool,
    pub created_at: String,
}

/// Builds the `role`/`user_id` owner clause shared by list/create/delete.
fn owner_params(session: &SessionUser, scope: &str) -> (String, i64, String) {
    if session.role == "admin" {
        ("admin".to_string(), 0, scope.to_string())
    } else {
        ("user".to_string(), session.user_id.unwrap_or(0), scope.to_string())
    }
}

/// Verifies the target belongs to a watched folder this session can access,
/// and (for non-admins) is at or below one of their entry points - mirrors
/// the reachability check in browse::browse.
/// `require_active`: when true, the target must exist and not be a ghost
/// (used when creating a bookmark). When false, ghost rows still resolve so
/// list_bookmarks can show a deleted target as "missing" rather than hiding
/// it outright - the folder/file row persists after a soft-delete.
fn authorize_target(
    conn: &rusqlite::Connection,
    session: &SessionUser,
    scope: &str,
    kind: &str,
    target_id: i64,
    require_active: bool,
) -> Result<(), AppError> {
    let folder_id: i64 = match kind {
        "folder" => {
            let deleted_filter = if require_active { "AND is_deleted = 0" } else { "" };
            let exists: Option<i64> = conn
                .query_row(
                    &format!("SELECT id FROM folders WHERE id = ? AND scope_tag = ? {deleted_filter}"),
                    rusqlite::params![target_id, scope],
                    |r| r.get(0),
                )
                .optional()?;
            exists.ok_or(AppError::NotFound)?
        }
        "file" => {
            let deleted_filter = if require_active { "AND f.is_deleted = 0" } else { "" };
            let exists: Option<i64> = conn
                .query_row(
                    &format!(
                        "SELECT fo.id FROM files f JOIN folders fo ON fo.id = f.folder_id
                         WHERE f.id = ? AND f.scope_tag = ? AND fo.scope_tag = ? {deleted_filter}"
                    ),
                    rusqlite::params![target_id, scope, scope],
                    |r| r.get(0),
                )
                .optional()?;
            exists.ok_or(AppError::NotFound)?
        }
        _ => return Err(AppError::BadRequest("kind must be 'folder' or 'file'.".into())),
    };

    let watched_folder_id: i64 = conn.query_row(
        "SELECT watched_folder_id FROM folders WHERE id = ? AND scope_tag = ?",
        rusqlite::params![folder_id, scope],
        |r| r.get(0),
    )?;

    if !session.allowed_folder_ids.contains(&watched_folder_id) {
        return Err(AppError::Forbidden("Unauthorized access".into()));
    }

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
            rusqlite::params![folder_id, scope, scope, entry_json],
            |r| r.get(0),
        ).unwrap_or(0);
        if reachable == 0 {
            return Err(AppError::Forbidden("Unauthorized access".into()));
        }
    }

    Ok(())
}

/// Resolves the current display path and revealing folder id for a bookmark
/// target. Returns `None` when the target no longer exists or has since been
/// deleted.
fn resolve_target(
    conn: &rusqlite::Connection,
    scope: &str,
    kind: &str,
    target_id: i64,
) -> Result<Option<(String, i64)>, AppError> {
    let folder_path = |folder_id: i64| -> Result<Option<String>, AppError> {
        let row: Option<(String, i64, String)> = conn
            .query_row(
                "WITH RECURSIVE path_builder(id, name, parent_id, level) AS (
                    SELECT id, name, parent_id, 0 FROM folders WHERE id = ? AND scope_tag = ?
                    UNION ALL
                    SELECT f.id, f.name, f.parent_id, level + 1 FROM folders f
                    JOIN path_builder ON f.id = path_builder.parent_id WHERE f.scope_tag = ?
                )
                SELECT
                    (SELECT group_concat(name, '/') FROM (SELECT name FROM path_builder WHERE name != '' ORDER BY level DESC)),
                    (SELECT watched_folder_id FROM folders WHERE id = ?),
                    (SELECT wf.path FROM folders f2 JOIN watched_folders wf ON wf.id = f2.watched_folder_id WHERE f2.id = ?)",
                rusqlite::params![folder_id, scope, scope, folder_id, folder_id],
                |r| Ok((r.get::<_, Option<String>>(0)?.unwrap_or_default(), r.get(1)?, r.get(2)?)),
            )
            .optional()?;
        let Some((rel, _wfid, watched_path)) = row else { return Ok(None) };
        let abs = if rel.is_empty() { watched_path } else { format!("{}/{}", watched_path, rel) };
        Ok(Some(abs))
    };

    match kind {
        "folder" => {
            let exists: bool = conn
                .query_row(
                    "SELECT 1 FROM folders WHERE id = ? AND scope_tag = ? AND is_deleted = 0",
                    rusqlite::params![target_id, scope],
                    |_| Ok(true),
                )
                .optional()?
                .unwrap_or(false);
            if !exists {
                return Ok(None);
            }
            Ok(folder_path(target_id)?.map(|p| (p, target_id)))
        }
        "file" => {
            let row: Option<(i64, String)> = conn
                .query_row(
                    "SELECT folder_id, name FROM files WHERE id = ? AND scope_tag = ? AND is_deleted = 0",
                    rusqlite::params![target_id, scope],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .optional()?;
            let Some((folder_id, name)) = row else { return Ok(None) };
            let Some(dir) = folder_path(folder_id)? else { return Ok(None) };
            Ok(Some((format!("{}/{}", dir, name), folder_id)))
        }
        _ => Ok(None),
    }
}

pub async fn list_bookmarks(
    State(state): State<AppState>,
    Extension(session): Extension<SessionUser>,
) -> Result<impl IntoResponse, AppError> {
    let scope = crate::engine::scope_tag().to_string();
    let items = spawn_blocking(move || {
        let conn = state.db.get()?;
        let (role, user_id, scope) = owner_params(&session, &scope);
        let mut stmt = conn.prepare(
            "SELECT id, kind, target_id, label, created_at FROM bookmarks
             WHERE role = ? AND scope_tag = ? AND (? = 'admin' OR user_id = ?)
             ORDER BY created_at DESC",
        )?;
        let rows = stmt.query_map(
            rusqlite::params![role, scope, role, user_id],
            |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, i64>(2)?,
                    r.get::<_, String>(3)?,
                    r.get::<_, String>(4)?,
                ))
            },
        )?;

        let mut out = Vec::new();
        for row in rows {
            let (id, kind, target_id, label, created_at) = row?;
            // Only surface bookmarks the session can currently reach - permissions
            // may have changed since the bookmark was created. Ghost (soft-deleted)
            // targets are still reachable here (require_active = false) so they can
            // be shown as "missing" rather than silently disappearing.
            if authorize_target(&conn, &session, &scope, &kind, target_id, false).is_err() {
                continue;
            }
            let resolved = resolve_target(&conn, &scope, &kind, target_id)?;
            let is_missing = resolved.is_none();
            let (path, open_folder_id) = match resolved {
                Some((p, fid)) => (Some(p), Some(fid)),
                None => (None, None),
            };
            out.push(BookmarkInfo { id, kind, target_id, label, path, open_folder_id, is_missing, created_at });
        }
        Ok::<_, AppError>(out)
    })
    .await
    .map_err(|_| AppError::Internal("Task failed".into()))??;

    Ok(Json(items))
}

pub async fn create_bookmark(
    State(state): State<AppState>,
    Extension(session): Extension<SessionUser>,
    Json(payload): Json<CreateBookmarkRequest>,
) -> Result<impl IntoResponse, AppError> {
    let label = payload.label.trim().to_string();
    if label.is_empty() || label.len() > 200 {
        return Err(AppError::BadRequest("Label must be 1-200 characters.".into()));
    }
    if payload.kind != "folder" && payload.kind != "file" {
        return Err(AppError::BadRequest("kind must be 'folder' or 'file'.".into()));
    }

    let scope = crate::engine::scope_tag().to_string();
    let kind = payload.kind.clone();
    let target_id = payload.target_id;
    let id = spawn_blocking(move || {
        let conn = state.db.get()?;
        authorize_target(&conn, &session, &scope, &kind, target_id, true)?;

        let (role, user_id, scope) = owner_params(&session, &scope);
        let count: i64 = conn.query_row(
            "SELECT COUNT(1) FROM bookmarks WHERE role = ? AND scope_tag = ? AND (? = 'admin' OR user_id = ?)",
            rusqlite::params![role, scope, role, user_id],
            |r| r.get(0),
        )?;
        if count >= MAX_BOOKMARKS_PER_OWNER {
            return Err(AppError::BadRequest(format!(
                "Bookmark limit reached ({MAX_BOOKMARKS_PER_OWNER}). Remove one before adding another."
            )));
        }

        let user_id_param: Option<i64> = if role == "admin" { None } else { Some(user_id) };
        conn.execute(
            "INSERT INTO bookmarks (role, user_id, scope_tag, kind, target_id, label) VALUES (?, ?, ?, ?, ?, ?)",
            rusqlite::params![role, user_id_param, scope, kind, target_id, label],
        )?;
        Ok::<_, AppError>(conn.last_insert_rowid())
    })
    .await
    .map_err(|_| AppError::Internal("Task failed".into()))??;

    Ok(Json(serde_json::json!({ "id": id })))
}

pub async fn delete_bookmark(
    State(state): State<AppState>,
    Extension(session): Extension<SessionUser>,
    AxumPath(id): AxumPath<i64>,
) -> Result<impl IntoResponse, AppError> {
    spawn_blocking(move || {
        let conn = state.db.get()?;
        let scope = crate::engine::scope_tag().to_string();
        let (role, user_id, scope) = owner_params(&session, &scope);
        let deleted = conn.execute(
            "DELETE FROM bookmarks WHERE id = ? AND role = ? AND scope_tag = ? AND (? = 'admin' OR user_id = ?)",
            rusqlite::params![id, role, scope, role, user_id],
        )?;
        if deleted == 0 {
            return Err(AppError::NotFound);
        }
        Ok::<_, AppError>(())
    })
    .await
    .map_err(|_| AppError::Internal("Task failed".into()))??;

    Ok(StatusCode::OK)
}
