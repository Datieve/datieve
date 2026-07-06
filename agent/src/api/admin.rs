// Admin API handlers. All routes here are mounted under /api/admin and require
// an admin session (enforced by the require_admin middleware layer).
//
// Covers: agent stats, user management, watched folders, exclusion patterns,
// settings, rescan triggers, ghost deletion, and management password verification.
use crate::api::middleware::SessionUser;
use crate::api::AppState;
use crate::error::AppError;
use axum::{
    extract::{Extension, State},
    http::StatusCode,
    response::IntoResponse,
    Json,
};
use rusqlite::OptionalExtension;
use serde::{Deserialize, Serialize};
use serde_json::json;
use tokio::task::spawn_blocking;

const MIN_CODE_LEN: usize = 10;
const ADMIN_FOLDER_BROWSE_LIMIT: usize = 2_000;

fn hash_admin_secret(code: &str) -> Result<String, AppError> {
    crate::auth::password::hash(&crate::auth::admin_code_preimage(code))
}

fn hash_user_secret(code: &str, uid: i64) -> Result<String, AppError> {
    crate::auth::password::hash(&crate::auth::user_code_preimage(code, uid))
}

fn hash_manage_secret(password: &str) -> Result<String, AppError> {
    crate::auth::password::hash(&crate::auth::manage_password_preimage(password))
}

#[derive(Serialize)]
pub struct StatsResponse {
    pub total_files: i64,
    pub total_folders: i64,
    pub watched_folders: Vec<WatchedFolderStats>,
    pub uptime_seconds: u64,
}

#[derive(Serialize)]
pub struct WatchedFolderStats {
    pub id: i64,
    pub path: String,
    pub status: String,
    pub scanned: i64,
    pub estimate: i64,
}

#[derive(Serialize)]
pub struct WatchedFolderInfo {
    pub id: i64,
    pub path: String,
    pub status: String,
    pub scanned: i64,
    pub estimate: i64,
    pub exclusion_patterns: Vec<String>,
    pub added_at: String,
}

#[derive(Serialize)]
pub struct CodeStatus {
    pub code_set: bool,
}

#[derive(Deserialize)]
pub struct SetAdminCodeRequest {
    pub code: String,
}

#[derive(Serialize)]
pub struct UserInfo {
    pub id: i64,
    pub username: String,
    pub created_at: String,
}

#[derive(Deserialize)]
pub struct CreateUserRequest {
    pub username: String,
    pub email: Option<String>,
    pub code: String,
}

#[derive(Serialize)]
pub struct UserFolderInfo {
    pub id: i64,
    pub watched_folder_id: i64,
    pub path: String,
    pub allow_deleted: bool,
    pub path_prefix: Option<String>,
}

#[derive(Deserialize)]
pub struct AssignUserFolderRequest {
    pub watched_folder_id: i64,
    pub allow_deleted: bool,
    pub path_prefix: Option<String>,
}

#[derive(Deserialize)]
pub struct ChangeUserCodeRequest {
    pub new_code: String,
}

use axum::response::sse::{Event, Sse};
use futures_util::stream::Stream;
use tokio_stream::wrappers::WatchStream;
use tokio_stream::StreamExt;

pub async fn sync_status_stream(
    State(state): State<AppState>,
    Extension(_session): Extension<SessionUser>,
) -> Sse<impl Stream<Item = Result<Event, std::convert::Infallible>>> {
    let status_stream = WatchStream::new(state.sync_status_rx.clone())
        .map(|status| {
            let msg = match status {
                crate::api::SnapshotSyncStatus::Healthy => "Healthy",
                crate::api::SnapshotSyncStatus::Unavailable => "Sync Unavailable",
                crate::api::SnapshotSyncStatus::Syncing => "Syncing",
            };
            Ok(Event::default().data(msg))
        });

    let changed_stream = WatchStream::new(state.file_change_rx.clone())
        .skip(1)
        .map(|_| Ok(Event::default().data("FileChanged")));

    let merged = status_stream.merge(changed_stream);
    Sse::new(merged).keep_alive(axum::response::sse::KeepAlive::default())
}

pub async fn stats(
    State(state): State<AppState>,
    Extension(_session): Extension<SessionUser>,
) -> Result<impl IntoResponse, AppError> {
    let res = spawn_blocking(move || {
        let conn = state.db.get()?;
        let scope = crate::engine::scope_tag();
        let total_files: i64 = conn.query_row(
            "SELECT COALESCE(SUM(file_count), 0) FROM folders WHERE parent_id IS NULL AND scope_tag = ?",
            [scope],
            |r| r.get(0),
        )?;
        let total_folders: i64 = conn.query_row(
            "SELECT COUNT(*) FROM folders WHERE is_deleted = 0 AND scope_tag = ?",
            [scope],
            |r| r.get(0),
        )?;

        let mut stmt = conn.prepare(
            "SELECT id, path, scan_status, files_scanned, total_files_estimate FROM watched_folders WHERE scope_tag = ?",
        )?;
        let folders = stmt.query_map([scope], |row| Ok(WatchedFolderStats {
            id: row.get(0)?, path: row.get(1)?, status: row.get(2)?, scanned: row.get(3)?, estimate: row.get(4)?,
        }))?.filter_map(Result::ok).collect();

        Ok::<_, AppError>(StatsResponse {
            total_files,
            total_folders,
            watched_folders: folders,
            uptime_seconds: state.start_time.elapsed().as_secs(),
        })
    }).await.map_err(|_| AppError::Internal("Task Panic".into()))??;

    Ok(Json(res))
}

pub async fn get_admin_code_status(
    State(state): State<AppState>,
    Extension(_session): Extension<SessionUser>,
) -> Result<impl IntoResponse, AppError> {
    let code_set = spawn_blocking(move || {
        let conn = state.db.get()?;
        let scope = crate::engine::scope_tag();
        let count: i64 = conn.query_row(
            "SELECT COUNT(*) FROM admin_code WHERE scope_tag = ?",
            [scope],
            |r| r.get(0),
        )?;
        Ok::<_, AppError>(count > 0)
    })
    .await
    .map_err(|_| AppError::Internal("Task Panic".into()))??;
    Ok(Json(CodeStatus { code_set }))
}

pub async fn set_admin_code(
    State(state): State<AppState>,
    Extension(_session): Extension<SessionUser>,
    Json(payload): Json<SetAdminCodeRequest>,
) -> Result<impl IntoResponse, AppError> {

    if payload.code.len() < MIN_CODE_LEN {
        return Err(AppError::BadRequest(format!(
            "Code must be at least {} characters",
            MIN_CODE_LEN
        )));
    }
    if payload.code.len() > 128 {
        return Err(AppError::BadRequest("Code too long".into()));
    }

    let session_cache = state.session_cache.clone();
    let db = state.db.clone();
    spawn_blocking(move || {
        let conn = db.get()?;
        let scope = crate::engine::scope_tag();
        let hash = hash_admin_secret(&payload.code)?;
        conn.execute(
            "INSERT OR REPLACE INTO admin_code (id, code_hash, scope_tag) VALUES (1, ?, ?)",
            rusqlite::params![hash, scope],
        )?;
        let _ = conn.execute(
            "DELETE FROM sessions WHERE role = 'admin' AND scope_tag = ?",
            [scope],
        );
        Ok::<_, AppError>(())
    })
    .await
    .map_err(|_| AppError::Internal("Task Panic".into()))??;

    session_cache.write().await.clear();
    Ok(StatusCode::OK)
}

// User Management
pub async fn get_users(
    State(state): State<AppState>,
    Extension(_session): Extension<SessionUser>,
) -> Result<impl IntoResponse, AppError> {

    let users = spawn_blocking(move || {
        let conn = state.db.get()?;
        let scope = crate::engine::scope_tag();
        let mut stmt = conn.prepare(
            "SELECT id, username, created_at FROM users WHERE scope_tag = ? ORDER BY username ASC",
        )?;
        let rows = stmt
            .query_map([scope], |r| {
                Ok(UserInfo {
                    id: r.get(0)?,
                    username: r.get(1)?,
                    created_at: r.get(2)?,
                })
            })?
            .filter_map(Result::ok)
            .collect::<Vec<_>>();
        Ok::<_, AppError>(rows)
    })
    .await
    .map_err(|_| AppError::Internal("Task Panic".into()))??;
    Ok(Json(users))
}

pub async fn create_user(
    State(state): State<AppState>,
    Extension(session): Extension<SessionUser>,
    Json(payload): Json<CreateUserRequest>,
) -> Result<impl IntoResponse, AppError> {

    tracing::info!(by = ?session.username, new_user = %payload.username, "creating user");
    if payload.username.trim().is_empty() {
        return Err(AppError::BadRequest("Username required".into()));
    }
    if payload.code.len() < MIN_CODE_LEN {
        return Err(AppError::BadRequest(format!(
            "Code must be at least {} characters",
            MIN_CODE_LEN
        )));
    }
    if payload.code.len() > 128 {
        return Err(AppError::BadRequest("Code too long".into()));
    }

    let email = payload
        .email
        .unwrap_or_else(|| format!("{}@local.lan", payload.username.to_lowercase()));

    spawn_blocking(move || {
        let mut conn = state.db.get()?;
        let scope = crate::engine::scope_tag().to_string();
        let tx = conn.transaction().map_err(AppError::Database)?;
        let hash = hash_user_secret(&payload.code, 0)?;
        match tx.execute(
            "INSERT INTO users (username, email, code_hash, scope_tag) VALUES (?, ?, ?, ?)",
            rusqlite::params![&payload.username, &email, &hash, &scope],
        ) {
            Ok(_) => {
                let uid = tx.last_insert_rowid();
                let hash = hash_user_secret(&payload.code, uid)?;
                tx.execute(
                    "UPDATE users SET code_hash = ? WHERE id = ? AND scope_tag = ?",
                    rusqlite::params![hash, uid, scope],
                )?;
                let lookup = crate::auth::user_code_lookup_key(&payload.code)?;
                match tx.execute(
                    "INSERT INTO user_code_lookup (lookup, scope_tag, user_id) VALUES (?, ?, ?)",
                    rusqlite::params![lookup, scope, uid],
                ) {
                    Ok(_) => {
                        tx.commit().map_err(AppError::Database)?;
                        Ok::<_, AppError>(())
                    }
                    Err(rusqlite::Error::SqliteFailure(e, Some(_msg)))
                        if e.code == rusqlite::ErrorCode::ConstraintViolation =>
                    {
                        Err(AppError::BadRequest(
                            "Code already belongs to another user".into(),
                        ))
                    }
                    Err(e) => Err(AppError::Database(e)),
                }
            }
            Err(rusqlite::Error::SqliteFailure(e, Some(_msg)))
                if e.code == rusqlite::ErrorCode::ConstraintViolation =>
            {
                Err(AppError::BadRequest(
                    "Username or email already exists".into(),
                ))
            }
            Err(e) => Err(AppError::Database(e)),
        }
    })
    .await
    .map_err(|_| AppError::Internal("Task Panic".into()))??;
    Ok(StatusCode::CREATED)
}

pub async fn delete_user(
    State(state): State<AppState>,
    Extension(session): Extension<SessionUser>,
    axum::extract::Path(id): axum::extract::Path<i64>,
) -> Result<impl IntoResponse, AppError> {

    tracing::info!(by = ?session.username, user_id = id, "deleting user");
    let session_cache = state.session_cache.clone();
    let db = state.db.clone();
    spawn_blocking(move || {
        let conn = db.get()?;
        let scope = crate::engine::scope_tag();
        conn.execute(
            "DELETE FROM sessions WHERE user_id = ? AND scope_tag = ?",
            rusqlite::params![id, scope],
        )?;
        conn.execute(
            "DELETE FROM users WHERE id = ? AND scope_tag = ?",
            rusqlite::params![id, scope],
        )?;
        Ok::<_, AppError>(())
    })
    .await
    .map_err(|_| AppError::Internal("Task Panic".into()))??;
    session_cache.write().await.clear();
    Ok(StatusCode::OK)
}

pub async fn get_user_folders(
    State(state): State<AppState>,
    Extension(_session): Extension<SessionUser>,
    axum::extract::Path(id): axum::extract::Path<i64>,
) -> Result<impl IntoResponse, AppError> {
    let folders = spawn_blocking(move || {
        let conn = state.db.get()?;
        let scope = crate::engine::scope_tag();
        let mut stmt = conn.prepare(
            "SELECT uf.id, wf.id, wf.path, uf.allow_deleted, uf.path_prefix FROM user_folders uf
             JOIN watched_folders wf ON uf.watched_folder_id = wf.id
             WHERE uf.user_id = ? AND uf.scope_tag = ? AND wf.scope_tag = ? ORDER BY wf.path, uf.path_prefix",
        )?;
        let rows = stmt
            .query_map(rusqlite::params![id, scope, scope], |r| {
                Ok(UserFolderInfo {
                    id: r.get(0)?,
                    watched_folder_id: r.get(1)?,
                    path: r.get(2)?,
                    allow_deleted: r.get::<_, i64>(3)? == 1,
                    path_prefix: r.get(4)?,
                })
            })?
            .filter_map(Result::ok)
            .collect::<Vec<_>>();
        Ok::<_, AppError>(rows)
    })
    .await
    .map_err(|_| AppError::Internal("Task Panic".into()))??;
    Ok(Json(folders))
}

pub async fn assign_user_folder(
    State(state): State<AppState>,
    Extension(_session): Extension<SessionUser>,
    axum::extract::Path(id): axum::extract::Path<i64>,
    Json(payload): Json<AssignUserFolderRequest>,
) -> Result<impl IntoResponse, AppError> {

    let session_cache = state.session_cache.clone();
    let db = state.db.clone();
    spawn_blocking(move || {
        let conn = db.get()?;
        let scope = crate::engine::scope_tag();
        let prefix = payload.path_prefix.as_deref().and_then(|p| {
            let p = p.trim();
            if p.is_empty() { None } else { Some(p.to_string()) }
        });
        conn.execute(
            "INSERT OR IGNORE INTO user_folders (user_id, watched_folder_id, scope_tag, allow_deleted, path_prefix) VALUES (?, ?, ?, ?, ?)",
            rusqlite::params![id, payload.watched_folder_id, scope, if payload.allow_deleted { 1 } else { 0 }, prefix]
        )?;
        Ok::<_, AppError>(())
    }).await.map_err(|_| AppError::Internal("Task Panic".into()))??;
    session_cache.write().await.clear();
    Ok(StatusCode::CREATED)
}

pub async fn remove_user_folder(
    State(state): State<AppState>,
    Extension(_session): Extension<SessionUser>,
    axum::extract::Path((id, folder_id)): axum::extract::Path<(i64, i64)>,
) -> Result<impl IntoResponse, AppError> {
    let session_cache = state.session_cache.clone();
    let db = state.db.clone();
    spawn_blocking(move || {
        let conn = db.get()?;
        let scope = crate::engine::scope_tag();
        conn.execute(
            "DELETE FROM user_folders WHERE user_id = ? AND watched_folder_id = ? AND scope_tag = ?",
            rusqlite::params![id, folder_id, scope],
        )?;
        Ok::<_, AppError>(())
    })
    .await
    .map_err(|_| AppError::Internal("Task Panic".into()))??;
    session_cache.write().await.clear();
    Ok(StatusCode::OK)
}

pub async fn remove_user_folder_entry(
    State(state): State<AppState>,
    Extension(_session): Extension<SessionUser>,
    axum::extract::Path((user_id, entry_id)): axum::extract::Path<(i64, i64)>,
) -> Result<impl IntoResponse, AppError> {
    let session_cache = state.session_cache.clone();
    let db = state.db.clone();
    spawn_blocking(move || {
        let conn = db.get()?;
        conn.execute(
            "DELETE FROM user_folders WHERE id = ? AND user_id = ?",
            rusqlite::params![entry_id, user_id],
        )?;
        Ok::<_, AppError>(())
    })
    .await
    .map_err(|_| AppError::Internal("Task Panic".into()))??;
    session_cache.write().await.clear();
    Ok(StatusCode::OK)
}

pub async fn change_user_code(
    State(state): State<AppState>,
    Extension(session): Extension<SessionUser>,
    axum::extract::Path(user_id): axum::extract::Path<i64>,
    Json(payload): Json<ChangeUserCodeRequest>,
) -> Result<impl IntoResponse, AppError> {
    tracing::info!(by = ?session.username, user_id, "changing user code");
    if payload.new_code.len() < MIN_CODE_LEN {
        return Err(AppError::BadRequest(format!("Code must be at least {} characters", MIN_CODE_LEN)));
    }
    let session_cache = state.session_cache.clone();
    let db = state.db.clone();
    spawn_blocking(move || {
        let conn = db.get()?;
        let hash = hash_user_secret(&payload.new_code, user_id)?;
        let new_lookup = crate::auth::user_code_lookup_key(&payload.new_code)?;
        conn.execute(
            "UPDATE users SET code_hash = ? WHERE id = ?",
            rusqlite::params![hash, user_id],
        )?;
        conn.execute(
            "DELETE FROM user_code_lookup WHERE user_id = ?",
            rusqlite::params![user_id],
        )?;
        let scope = crate::engine::scope_tag();
        conn.execute(
            "INSERT OR REPLACE INTO user_code_lookup (lookup, scope_tag, user_id) VALUES (?, ?, ?)",
            rusqlite::params![new_lookup, scope, user_id],
        )?;
        conn.execute(
            "DELETE FROM sessions WHERE user_id = ? AND scope_tag = ?",
            rusqlite::params![user_id, scope],
        )?;
        Ok::<_, AppError>(())
    })
    .await
    .map_err(|_| AppError::Internal("Task Panic".into()))??;
    session_cache.write().await.clear();
    Ok(StatusCode::OK)
}

// Watched Folders
pub async fn get_watched_folders(
    State(state): State<AppState>,
    Extension(_session): Extension<SessionUser>,
) -> Result<impl IntoResponse, AppError> {

    let folders = spawn_blocking(move || {
        let conn = state.db.get()?;
        let scope = crate::engine::scope_tag();
        let mut stmt = conn.prepare(
            "SELECT id, path, scan_status, files_scanned, total_files_estimate, exclusion_patterns, added_at
             FROM watched_folders WHERE scope_tag = ? ORDER BY path ASC"
        )?;
        let rows = stmt.query_map([scope], |row| {
            let exclusions_json: String = row.get(5)?;
            let exclusion_patterns = serde_json::from_str::<Vec<String>>(&exclusions_json).unwrap_or_default();
            Ok(WatchedFolderInfo {
                id: row.get(0)?,
                path: row.get(1)?,
                status: row.get(2)?,
                scanned: row.get(3)?,
                estimate: row.get(4)?,
                exclusion_patterns,
                added_at: row.get(6)?,
            })
        })?.filter_map(Result::ok).collect::<Vec<_>>();
        Ok::<_, AppError>(rows)
    }).await.map_err(|_| AppError::Internal("Task Panic".into()))??;
    Ok(Json(folders))
}

pub async fn add_watched_folder(
    State(state): State<AppState>,
    Extension(session): Extension<SessionUser>,
    Json(path): Json<String>,
) -> Result<impl IntoResponse, AppError> {

    tracing::info!(by = ?session.username, %path, "adding watched folder");
    // Path Verification
    let safe_path = sanitize_path(&path, &state)?;
    match std::fs::metadata(&safe_path) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Err(AppError::BadRequest("Path does not exist.".into()));
        }
        Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => {
            return Err(AppError::BadRequest(
                "Permission denied  - the agent cannot read this path. Grant read access to the agent user or run the agent as root.".into()
            ));
        }
        Err(e) => {
            return Err(AppError::BadRequest(format!("Cannot access path: {}", e)));
        }
        Ok(m) if !m.is_dir() => {
            return Err(AppError::BadRequest("Path exists but is not a directory.".into()));
        }
        Ok(_) => {}
    }
    if let Err(e) = std::fs::read_dir(&safe_path) {
        if e.kind() == std::io::ErrorKind::PermissionDenied {
            return Err(AppError::BadRequest(
                "Permission denied  - the agent can see this directory but cannot list its contents. Grant read access to the agent user.".into()
            ));
        }
        return Err(AppError::BadRequest(format!("Cannot list directory: {}", e)));
    }
    let path_clean = safe_path.to_string_lossy().into_owned();

    let global_exclusion_patterns = state.config.read().await.exclusion_patterns.clone();
    let db = state.db.clone();
    let session_cache = state.session_cache.clone();
    let res = spawn_blocking(move || {
        let mut conn = db.get()?;
        let tx = conn.transaction().map_err(AppError::Database)?;

        let scope = crate::engine::scope_tag();

        let global_exclusions = serde_json::to_string(&global_exclusion_patterns).unwrap_or_default();
        match tx.execute(
            "INSERT INTO watched_folders (path, exclusion_patterns, scope_tag) VALUES (?, ?, ?)",
            rusqlite::params![&path_clean, global_exclusions, scope],
        ) {
            Ok(_) => {}
            Err(rusqlite::Error::SqliteFailure(e, _))
                if e.code == rusqlite::ErrorCode::ConstraintViolation =>
            {
                return Err(AppError::BadRequest(
                    "This folder is already being watched".into(),
                ));
            }
            Err(e) => return Err(AppError::Database(e)),
        }
        let id = tx.last_insert_rowid();

        // Initialize the 'Root' folder record immediately for navigation/stats
        tx.execute(
            "INSERT INTO folders (name, scope_tag, parent_id, watched_folder_id, indexed_at) VALUES ('', ?, NULL, ?, datetime('now'))",
            rusqlite::params![scope, id],
        )?;

        tx.commit().map_err(AppError::Database)?;
        Ok::<_, AppError>((id, path_clean))
    })
    .await
    .map_err(|_| AppError::Internal("Task Panic".into()))??;

    session_cache.write().await.clear();
    let (id, path) = res;



    if !state.scan_orchestrator.try_claim(&state.db, id)? {
        return Ok(StatusCode::CREATED);
    }

    let speed = state.config.read().await.trickle_sync_files_per_second;
    let exclusions = vec![
        ".zfs".into(),
        ".datieve".into(),
        ".snapshot".into(),
        "@recently-snapshot".into(),
        "@Recycle".into(),
        "#recycle".into(),
        ".Trash-*".into(),
    ];
    let orch = state.scan_orchestrator.clone();
    let tx = state.indexer_tx.clone();
    let status_tx = state.status_tx.clone();
    tokio::spawn(async move {
        let handle =
            crate::indexer::scanner::spawn_scanner(tx, status_tx, id, path, exclusions, speed);
        let _ = handle.await;
        orch.release(id);
    });
    Ok(StatusCode::CREATED)
}

pub async fn delete_watched_folder(
    State(state): State<AppState>,
    Extension(session): Extension<SessionUser>,
    axum::extract::Path(id): axum::extract::Path<i64>,
) -> Result<impl IntoResponse, AppError> {

    tracing::info!(by = ?session.username, folder_id = id, "removing watched folder");
    let session_cache = state.session_cache.clone();
    let db = state.db.clone();
    spawn_blocking(move || {
        let conn = db.get()?;
        let scope = crate::engine::scope_tag();
        conn.execute(
            "DELETE FROM watched_folders WHERE id = ? AND scope_tag = ?",
            rusqlite::params![id, scope],
        )?;
        Ok::<_, AppError>(())
    })
    .await
    .map_err(|_| AppError::Internal("Task Panic".into()))??;
    session_cache.write().await.clear();
    Ok(StatusCode::OK)
}

pub async fn update_watched_folder_exclusions(
    State(state): State<AppState>,
    Extension(_session): Extension<SessionUser>,
    axum::extract::Path(_id): axum::extract::Path<i64>,
    Json(exclusions): Json<Vec<String>>,
) -> Result<impl IntoResponse, AppError> {

    // Exclusions are global  - save to config and sync all watched folder rows.
    let mut new_cfg = state.config.read().await.clone();
    new_cfg.exclusion_patterns = exclusions;
    new_cfg.save(&state.config_path)?;
    let exclusion_json = serde_json::to_string(&new_cfg.exclusion_patterns).unwrap_or_default();
    let scope = crate::engine::scope_tag();
    let db = state.db.clone();
    spawn_blocking(move || {
        if let Ok(conn) = db.get() {
            let _ = conn.execute(
                "UPDATE watched_folders SET exclusion_patterns = ? WHERE scope_tag = ?",
                rusqlite::params![exclusion_json, scope],
            );
        }
    }).await.ok();
    *state.config.write().await = new_cfg;
    Ok(StatusCode::OK)
}

// Settings
pub async fn get_settings(
    State(state): State<AppState>,
    Extension(_session): Extension<SessionUser>,
) -> Result<impl IntoResponse, AppError> {

    let cfg = state.config.read().await;
    Ok(Json(json!({
        "friendly_name": cfg.friendly_name,
        "admin_username": cfg.admin_username,
        "platform": crate::config::Platform::detect(),
        "snapshot_sync_interval_secs": cfg.snapshot_sync_interval_secs,
        "deleted_file_prune_days": cfg.deleted_file_prune_days,
        "login_rate_limit_per_minute": cfg.login_rate_limit_per_minute,
        "general_rate_limit_per_minute": cfg.general_rate_limit_per_minute,
        "management_username": cfg.management_username,
        "exclusion_patterns": cfg.exclusion_patterns,
        "port": cfg.port,
        "bind_address": cfg.bind_address,
    })))
}

pub async fn update_settings(
    State(state): State<AppState>,
    Extension(_session): Extension<SessionUser>,
    Json(payload): Json<serde_json::Value>,
) -> Result<impl IntoResponse, AppError> {


    // Verify management password before applying any changes.
    // The agent uses its own stored username  - the caller only needs to supply the password.
    let manage_password = payload.get("management_password")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    if manage_password.is_empty() {
        return Err(AppError::Unauthorized);
    }
    let scope = crate::engine::setup_scope();
    let db = state.db.clone();
    let manage_password_verify = manage_password.clone();
    let scope_verify = scope.clone();
    let creds_ok = tokio::task::spawn_blocking(move || {
        let conn = db.get()?;
        let hash: Option<String> = conn.query_row(
            "SELECT code_hash FROM admin_manage_code WHERE id = 1 AND scope_tag = ?",
            [&scope_verify],
            |row| row.get(0),
        ).optional()?;
        Ok::<bool, crate::error::AppError>(match hash {
            Some(h) => crate::auth::password::verify(
                &crate::auth::manage_password_preimage(&manage_password_verify),
                &h,
            )
            .unwrap_or(false),
            None => false,
        })
    }).await.map_err(|_| AppError::Internal("Task failed".into()))??;
    if !creds_ok {
        return Err(AppError::Forbidden("Wrong management credentials.".into()));
    }

    let mut new_cfg = state.config.read().await.clone();
    let old_exclusion_patterns = new_cfg.exclusion_patterns.clone();
    let db2 = state.db.clone();
    let scope2 = scope.clone();

    // Collect values before the blocking task.
    let new_friendly_name = payload.get("friendly_name").and_then(|v| v.as_str()).map(|s| s.to_string());
    let new_admin_username = payload.get("admin_username").and_then(|v| v.as_str()).map(|s| s.to_string());
    let new_admin_code = payload.get("admin_code").and_then(|v| v.as_str()).map(|s| s.to_string());
    let new_management_username = payload.get("management_username_new").and_then(|v| v.as_str()).map(|s| s.to_string());
    let new_management_password = payload.get("management_password_new").and_then(|v| v.as_str()).map(|s| s.to_string());
    let new_snapshot_sync = payload.get("snapshot_sync_interval_secs").and_then(|v| v.as_u64());
    let new_prune_days = payload.get("deleted_file_prune_days").map(|v| v.as_u64());
    let new_exclusion_patterns = payload.get("exclusion_patterns")
        .and_then(|v| serde_json::from_value::<Vec<String>>(v.clone()).ok());
    let new_port = payload.get("port").and_then(|v| v.as_u64()).map(|v| v as u16);
    let new_bind_address = payload.get("bind_address").and_then(|v| v.as_str()).map(|s| s.to_string());

    if let Some(val) = new_friendly_name { if !val.trim().is_empty() { new_cfg.friendly_name = val; } }
    if let Some(val) = new_admin_username { if !val.trim().is_empty() { new_cfg.admin_username = val; } }
    if let Some(val) = new_management_username { if !val.trim().is_empty() { new_cfg.management_username = val; } }
    if let Some(val) = new_snapshot_sync { new_cfg.snapshot_sync_interval_secs = val.clamp(2, 10); }
    if let Some(val) = new_prune_days { new_cfg.deleted_file_prune_days = val.map(|v| v.min(u32::MAX as u64) as u32); }
    if let Some(patterns) = new_exclusion_patterns { new_cfg.exclusion_patterns = patterns; }
    if let Some(p) = new_port { if p >= 1024 { new_cfg.port = p; } }
    if let Some(addr) = new_bind_address { if !addr.trim().is_empty() { new_cfg.bind_address = addr; } }
    // Detect whether any pattern was removed (need rescan to pick up newly un-excluded items).
    let patterns_removed = old_exclusion_patterns.iter().any(|p| !new_cfg.exclusion_patterns.contains(p));

    // DB mutations (admin code + management password) happen in a blocking task.
    let admin_code_to_set = new_admin_code;
    let mgmt_pwd_to_set = new_management_password;
    if admin_code_to_set.is_some() || mgmt_pwd_to_set.is_some() {
        tokio::task::spawn_blocking(move || {
            let conn = db2.get()?;
            if let Some(code) = admin_code_to_set {
                if !code.is_empty() {
                    let hash = hash_admin_secret(&code)?;
                    conn.execute(
                        "UPDATE admin_code SET code_hash = ? WHERE scope_tag = ?",
                        rusqlite::params![hash, scope2],
                    )?;
                }
            }
            if let Some(pwd) = mgmt_pwd_to_set {
                if !pwd.is_empty() {
                    let hash = hash_manage_secret(&pwd)?;
                    conn.execute(
                        "UPDATE admin_manage_code SET code_hash = ? WHERE id = 1 AND scope_tag = ?",
                        rusqlite::params![hash, scope2],
                    )?;
                }
            }
            Ok::<_, AppError>(())
        }).await.map_err(|_| AppError::Internal("Task failed".into()))??;
    }

    new_cfg.save(&state.config_path)?;
    // Sync global exclusion patterns to every watched folder row so scanners/inotify pick them up on restart.
    let exclusion_json = serde_json::to_string(&new_cfg.exclusion_patterns).unwrap_or_default();
    let scope_for_sync = crate::engine::scope_tag();
    let db_for_sync = state.db.clone();
    let _ = spawn_blocking(move || {
        if let Ok(conn) = db_for_sync.get() {
            let _ = conn.execute(
                "UPDATE watched_folders SET exclusion_patterns = ? WHERE scope_tag = ?",
                rusqlite::params![exclusion_json, scope_for_sync],
            );
        }
    }).await;

    // Hard-delete any DB entries that match the current exclusion patterns.
    // This makes exclusions take effect immediately without a rescan.
    let db_excl = state.db.clone();
    let scope_excl = crate::engine::scope_tag();
    let patterns_for_delete = new_cfg.exclusion_patterns.clone();
    let _ = spawn_blocking(move || {
        let matcher = crate::indexer::matcher::PathMatcher::new(&patterns_for_delete);
        let conn = db_excl.get()?;

        let file_ids: Vec<i64> = {
            let mut stmt = conn.prepare(
                "SELECT id, name FROM files WHERE is_deleted = 0 AND scope_tag = ?"
            )?;
            let ids: Vec<i64> = stmt.query_map([&scope_excl], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))?
                .flatten()
                .filter(|(_, name)| matcher.is_excluded(name))
                .map(|(id, _)| id)
                .collect();
            ids
        };

        let folder_ids: Vec<i64> = {
            let mut stmt = conn.prepare(
                "SELECT id, name FROM folders WHERE is_deleted = 0 AND scope_tag = ?"
            )?;
            let ids: Vec<i64> = stmt.query_map([&scope_excl], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))?
                .flatten()
                .filter(|(_, name)| matcher.is_excluded(name))
                .map(|(id, _)| id)
                .collect();
            ids
        };

        for id in &file_ids {
            conn.execute("DELETE FROM files WHERE id = ? AND scope_tag = ?", rusqlite::params![id, scope_excl]).ok();
            conn.execute("DELETE FROM files_fts WHERE rowid = ?", [id]).ok();
        }

        for id in &folder_ids {
            // Delete all files inside the folder tree
            conn.execute(
                "DELETE FROM files_fts WHERE rowid IN (
                    WITH RECURSIVE tree(id) AS (
                        SELECT id FROM folders WHERE id = ? AND scope_tag = ?
                        UNION ALL SELECT f.id FROM folders f JOIN tree t ON f.parent_id = t.id
                    ) SELECT fi.id FROM files fi JOIN tree t ON fi.folder_id = t.id
                )",
                rusqlite::params![id, scope_excl],
            ).ok();
            conn.execute(
                "WITH RECURSIVE tree(id) AS (
                    SELECT id FROM folders WHERE id = ? AND scope_tag = ?
                    UNION ALL SELECT f.id FROM folders f JOIN tree t ON f.parent_id = t.id
                ) DELETE FROM files WHERE folder_id IN (SELECT id FROM tree)",
                rusqlite::params![id, scope_excl],
            ).ok();
            conn.execute(
                "WITH RECURSIVE tree(id) AS (
                    SELECT id FROM folders WHERE id = ? AND scope_tag = ?
                    UNION ALL SELECT f.id FROM folders f JOIN tree t ON f.parent_id = t.id
                ) DELETE FROM folders WHERE id IN (SELECT id FROM tree)",
                rusqlite::params![id, scope_excl],
            ).ok();
        }

        if !file_ids.is_empty() || !folder_ids.is_empty() {
            tracing::info!(
                "Exclusion update: hard-deleted {} files and {} folder trees from index",
                file_ids.len(), folder_ids.len()
            );
        }
        Ok::<_, AppError>(())
    }).await.ok();

    let _ = patterns_removed; // caller can trigger rescan manually if needed

    *state.config.write().await = new_cfg;
    Ok(StatusCode::OK)
}

/// Blocked system pseudo-filesystems  - unsafe to index or modify.
pub(crate) const BLOCKED_PREFIXES: &[&str] = &["/proc", "/sys", "/dev", "/run"];

pub(crate) fn normalize_path(path: &str) -> Result<std::path::PathBuf, AppError> {
    let p = std::path::PathBuf::from(path);
    if !p.is_absolute() {
        return Err(AppError::BadRequest("Absolute path required".into()));
    }

    let mut normalized = std::path::PathBuf::new();
    for component in p.components() {
        match component {
            std::path::Component::ParentDir => { normalized.pop(); }
            std::path::Component::CurDir => {}
            std::path::Component::RootDir => { normalized.push("/"); }
            std::path::Component::Normal(c) => { normalized.push(c); }
            _ => {}
        }
    }

    Ok(std::fs::canonicalize(&normalized).unwrap_or(normalized))
}

pub(crate) fn sanitize_path(path: &str, _state: &AppState) -> Result<std::path::PathBuf, AppError> {
    let final_path = normalize_path(path)?;

    // Block the root itself and kernel pseudo-filesystems.
    if final_path == std::path::Path::new("/") {
        return Err(AppError::BadRequest("Cannot watch the root filesystem directly. Choose a specific subdirectory.".into()));
    }
    let is_blocked = BLOCKED_PREFIXES
        .iter()
        .any(|pfx| final_path.starts_with(std::path::Path::new(pfx)));
    if is_blocked {
        return Err(AppError::BadRequest(
            "Cannot watch system pseudo-filesystems (/proc, /sys, /dev, /run).".into(),
        ));
    }
    Ok(final_path)
}

fn existing_storage_roots() -> Vec<String> {
    // Return top-level directories that actually exist (excluding system pseudo-fs).
    let Ok(entries) = std::fs::read_dir("/") else { return vec![]; };
    entries
        .flatten()
        .filter(|e| e.file_type().map(|t| t.is_dir()).unwrap_or(false))
        .map(|e| e.path().to_string_lossy().into_owned())
        .filter(|p| !BLOCKED_PREFIXES.iter().any(|blocked| p.starts_with(blocked)))
        .collect()
}

pub async fn browse_nas_folders(
    State(state): State<AppState>,
    Extension(_session): Extension<SessionUser>,
    Json(path): Json<Option<String>>,
) -> Result<impl IntoResponse, AppError> {
    let raw_path = path.unwrap_or_else(|| "/".into());
    if raw_path.trim().is_empty() || raw_path == "/" {
        return Ok(Json(existing_storage_roots()));
    }

    let path = sanitize_path(&raw_path, &state)?;
    let entries = spawn_blocking(move || {
        let list = std::fs::read_dir(&path)
            .map_err(|e| {
                if e.kind() == std::io::ErrorKind::PermissionDenied {
                    AppError::Forbidden(format!("Permission denied reading {:?}", path))
                } else {
                    AppError::Internal(e.to_string())
                }
            })?
            .filter_map(|e| e.ok())
            .filter(|e| e.file_type().map(|t| t.is_dir()).unwrap_or(false))
            .take(ADMIN_FOLDER_BROWSE_LIMIT)
            .map(|e| e.path().to_string_lossy().into_owned())
            .collect::<Vec<String>>();
        Ok::<_, AppError>(list)
    })
    .await
    .map_err(|_| AppError::Internal("Task Panic".into()))??;
    Ok(Json(entries))
}

pub async fn delete_ghost(
    State(state): State<AppState>,
    Extension(_session): Extension<SessionUser>,
    axum::extract::Path(file_id): axum::extract::Path<i64>,
) -> Result<impl IntoResponse, AppError> {
    let scope = crate::engine::scope_tag();
    let conn = state.db.get()?;
    let deleted = conn.execute(
        "DELETE FROM files WHERE id = ? AND is_deleted = 1 AND scope_tag = ?",
        rusqlite::params![file_id, scope],
    )?;
    if deleted == 0 {
        return Err(AppError::NotFound);
    }
    conn.execute(
        "DELETE FROM files_fts WHERE rowid = ?",
        rusqlite::params![file_id],
    ).ok();
    Ok(Json(json!({ "ok": true })))
}

pub async fn delete_ghost_folder(
    State(state): State<AppState>,
    Extension(_session): Extension<SessionUser>,
    axum::extract::Path(folder_id): axum::extract::Path<i64>,
) -> Result<impl IntoResponse, AppError> {
    let scope = crate::engine::scope_tag();
    spawn_blocking(move || {
        let conn = state.db.get()?;
        let is_ghost: Option<i64> = conn.query_row(
            "SELECT id FROM folders WHERE id = ? AND is_deleted = 1 AND scope_tag = ?",
            rusqlite::params![folder_id, scope],
            |r| r.get(0),
        ).optional()?;
        if is_ghost.is_none() {
            return Err(AppError::NotFound);
        }
        conn.execute(
            "DELETE FROM files_fts WHERE rowid IN (
                WITH RECURSIVE tree(id) AS (
                    SELECT id FROM folders WHERE id = ? AND scope_tag = ?
                    UNION ALL SELECT f.id FROM folders f JOIN tree t ON f.parent_id = t.id
                ) SELECT fi.id FROM files fi JOIN tree t ON fi.folder_id = t.id
            )",
            rusqlite::params![folder_id, scope],
        )?;
        conn.execute(
            "WITH RECURSIVE tree(id) AS (
                SELECT id FROM folders WHERE id = ? AND scope_tag = ?
                UNION ALL SELECT f.id FROM folders f JOIN tree t ON f.parent_id = t.id
            ) DELETE FROM files WHERE folder_id IN (SELECT id FROM tree)",
            rusqlite::params![folder_id, scope],
        )?;
        conn.execute(
            "WITH RECURSIVE tree(id) AS (
                SELECT id FROM folders WHERE id = ? AND scope_tag = ?
                UNION ALL SELECT f.id FROM folders f JOIN tree t ON f.parent_id = t.id
            ) DELETE FROM folders WHERE id IN (SELECT id FROM tree)",
            rusqlite::params![folder_id, scope],
        )?;
        Ok::<_, AppError>(())
    }).await.map_err(|_| AppError::Internal("Task panic".into()))??;
    Ok(Json(json!({ "ok": true })))
}

pub async fn prune_system(
    State(state): State<AppState>,
    Extension(_session): Extension<SessionUser>,
    Json(payload): Json<serde_json::Value>,
) -> Result<impl IntoResponse, AppError> {

    let res = spawn_blocking(move || {
        let conn = state.db.get()?;
        let mut deleted_files = 0;
        if let Some(days) = payload.get("deleted_files_older_than_days").and_then(|v| v.as_i64()) {
            if days < 0 { return Err(AppError::BadRequest("deleted_files_older_than_days cannot be negative".into())); }
            let limit = format!("-{} days", days);
            let scope = crate::engine::scope_tag();
            conn.execute("DELETE FROM files_fts WHERE rowid IN (SELECT id FROM files WHERE is_deleted = 1 AND deleted_at IS NOT NULL AND deleted_at < datetime('now', ?) AND scope_tag = ?)", rusqlite::params![limit, scope])?;
            deleted_files = conn.execute("DELETE FROM files WHERE is_deleted = 1 AND deleted_at < datetime('now', ?) AND scope_tag = ?", rusqlite::params![limit, scope])?;
        }
        Ok::<_, AppError>(json!({ "deleted_files_count": deleted_files }))
    }).await.map_err(|_| AppError::Internal("Task Panic".into()))??;
    Ok(Json(res))
}

pub async fn verify_management_code(
    State(state): State<AppState>,
    Extension(_session): Extension<SessionUser>,
    Json(payload): Json<serde_json::Value>,
) -> Result<impl IntoResponse, AppError> {
    let password = payload.get("password").and_then(|v| v.as_str()).unwrap_or("").to_string();
    if password.is_empty() {
        return Err(AppError::Unauthorized);
    }
    let scope = crate::engine::setup_scope();
    let ok = tokio::task::spawn_blocking(move || {
        let conn = state.db.get()?;
        let hash: Option<String> = conn.query_row(
            "SELECT code_hash FROM admin_manage_code WHERE id = 1 AND scope_tag = ?",
            [&scope],
            |row| row.get(0),
        ).optional()?;
        Ok::<bool, AppError>(match hash {
            Some(h) => crate::auth::password::verify(
                &crate::auth::manage_password_preimage(&password),
                &h,
            ).unwrap_or(false),
            None => false,
        })
    }).await.map_err(|_| AppError::Internal("Task failed".into()))??;

    if !ok {
        return Err(AppError::Forbidden("Wrong management code.".into()));
    }
    Ok(Json(json!({ "ok": true })))
}

pub async fn rescan_now(
    State(state): State<AppState>,
    Extension(session): Extension<SessionUser>,
) -> impl IntoResponse {
    tracing::info!(username = ?session.username, "full rescan triggered by admin");
    let _ = state.indexer_tx.send(crate::indexer::IndexEvent::FullRescanRequested {
        reason: "manual rescan requested by admin".to_string(),
    }).await;
    Json(json!({ "ok": true }))
}

pub async fn restart_agent(
    Extension(session): Extension<SessionUser>,
) -> impl IntoResponse {
    tracing::warn!(username = ?session.username, "agent restart triggered by admin");
    let args: Vec<String> = std::env::args().skip(1).collect();
    tokio::spawn(async move {
        // Give the response time to reach the client before we exit.
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
        if let Ok(exe) = std::env::current_exe() {
            // Detach stdio so the child doesn't die when the parent closes its file descriptors.
            let _ = std::process::Command::new(&exe)
                .args(&args)
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .spawn();
        }
        std::process::exit(0);
    });
    Json(json!({ "ok": true }))
}
