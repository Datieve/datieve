// Filesystem operation handlers (mkdir, rename, copy, move, delete, etc.).
// All routes are under /api/fs and require an authenticated session.
// Every path is validated through fs_access before any disk operation.
use axum::{
    body::Body,
    extract::{Query, State},
    http::{header, StatusCode},
    response::{IntoResponse, Response},
    Extension, Json,
};
use percent_encoding::{utf8_percent_encode, NON_ALPHANUMERIC};
use serde::{Deserialize, Serialize};
use tokio::task::spawn_blocking;
use tokio_util::io::ReaderStream;

#[derive(Serialize)]
struct BatchFailure {
    path: String,
    error: String,
}

#[derive(Serialize)]
struct BatchResult {
    succeeded: Vec<String>,
    failed: Vec<BatchFailure>,
}

use crate::api::fs_access::{
    authorize_parent_for_create, authorize_path, bulk_rename_paths, compress_paths,
    copy_entry, delete_path, duplicate_entry, extract_archive, is_safe_filename, map_fs_error,
    move_entry, rotate_image_path,
};
use crate::api::middleware::SessionUser;
use crate::api::AppState;
use crate::error::AppError;

#[derive(Deserialize)]
pub struct MkdirRequest {
    pub path: String,
}

#[derive(Deserialize)]
pub struct CreateFileRequest {
    pub dir: String,
    pub name: String,
}

#[derive(Deserialize)]
pub struct CreateTextFileRequest {
    pub dir: String,
    pub name: String,
    pub content: String,
}

#[derive(Deserialize)]
pub struct RenameRequest {
    pub path: String,
    pub new_name: String,
}

#[derive(Deserialize)]
pub struct PathsRequest {
    pub paths: Vec<String>,
}

#[derive(Deserialize)]
pub struct TransferRequest {
    pub src_paths: Vec<String>,
    pub dest_dir: String,
    #[serde(default = "default_collision")]
    pub collision: String,
}

fn default_collision() -> String {
    "rename".into()
}

#[derive(Deserialize)]
pub struct SymlinkRequest {
    pub link_path: String,
    pub target: String,
}

#[derive(Deserialize)]
pub struct BulkRenameRequest {
    pub paths: Vec<String>,
    pub base_name: String,
}

#[derive(Deserialize)]
pub struct CompressRequest {
    pub paths: Vec<String>,
    pub dest_dir: String,
    pub format: String,
}

#[derive(Deserialize)]
pub struct ExtractRequest {
    pub path: String,
}

#[derive(Deserialize)]
pub struct RotateRequest {
    pub path: String,
    pub direction: String,
}

#[derive(Deserialize)]
pub struct ReadFileQuery {
    pub path: String,
}

#[derive(Deserialize)]
pub struct DownloadQuery {
    pub path: String,
}

#[derive(Deserialize)]
pub struct WriteFileRequest {
    pub path: String,
    pub content: String,
}

pub async fn mkdir(
    State(state): State<AppState>,
    Extension(session): Extension<SessionUser>,
    Json(payload): Json<MkdirRequest>,
) -> Result<impl IntoResponse, AppError> {
    tracing::info!(user = ?session.username, path = %payload.path, "mkdir");
    if !is_safe_filename(
        std::path::Path::new(&payload.path)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or(""),
    ) && !payload.path.ends_with('/') {
        // full path create  - validate final component
        let name = std::path::Path::new(&payload.path)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("");
        if !is_safe_filename(name) {
            return Err(AppError::BadRequest("Invalid directory name.".into()));
        }
    }

    let data_dir = state.config.read().await.data_dir.clone();
    let path = payload.path.clone();
    let parent_for_lock = std::path::Path::new(&path)
        .parent()
        .unwrap_or(std::path::Path::new("/"))
        .to_path_buf();
    let _folder_guard = crate::api::fs_access::acquire_folder_lock(&state.folder_locks, &parent_for_lock).await;
    let created = spawn_blocking(move || {
        let conn = state.db.get()?;
        let parent = std::path::Path::new(&path);
        let parent_dir = parent
            .parent()
            .ok_or_else(|| AppError::BadRequest("Invalid directory path.".into()))?;
        authorize_parent_for_create(&conn, &session, parent_dir.to_string_lossy().as_ref(), &data_dir)?;
        std::fs::create_dir(&path).map_err(|e| map_fs_error(e, "create", parent))?;
        Ok::<_, AppError>(path)
    })
    .await
    .map_err(|_| AppError::Internal("Task failed".into()))??;

    Ok(Json(serde_json::json!({ "path": created })))
}

pub async fn create_file(
    State(state): State<AppState>,
    Extension(session): Extension<SessionUser>,
    Json(payload): Json<CreateFileRequest>,
) -> Result<impl IntoResponse, AppError> {
    if !is_safe_filename(&payload.name) {
        return Err(AppError::BadRequest("Invalid file name.".into()));
    }
    let data_dir = state.config.read().await.data_dir.clone();
    let dir = payload.dir.clone();
    let name = payload.name.clone();
    let _folder_guard = crate::api::fs_access::acquire_folder_lock(
        &state.folder_locks, std::path::Path::new(&dir)).await;
    let created = spawn_blocking(move || {
        let conn = state.db.get()?;
        let parent = authorize_parent_for_create(&conn, &session, &dir, &data_dir)?;
        let dest = parent.join(&name);
        if dest.exists() {
            return Err(AppError::BadRequest("File already exists.".into()));
        }
        std::fs::File::create(&dest).map_err(|e| map_fs_error(e, "create", &dest))?;
        Ok::<_, AppError>(dest.to_string_lossy().into_owned())
    })
    .await
    .map_err(|_| AppError::Internal("Task failed".into()))??;

    Ok(Json(serde_json::json!({ "path": created })))
}

pub async fn create_text_file(
    State(state): State<AppState>,
    Extension(session): Extension<SessionUser>,
    Json(payload): Json<CreateTextFileRequest>,
) -> Result<impl IntoResponse, AppError> {
    if !is_safe_filename(&payload.name) {
        return Err(AppError::BadRequest("Invalid file name.".into()));
    }
    if payload.content.len() > 1024 * 1024 {
        return Err(AppError::BadRequest("Template content is too large.".into()));
    }
    let data_dir = state.config.read().await.data_dir.clone();
    let dir = payload.dir.clone();
    let name = payload.name.clone();
    let content = payload.content.clone();
    let _folder_guard = crate::api::fs_access::acquire_folder_lock(
        &state.folder_locks, std::path::Path::new(&dir)).await;
    let created = spawn_blocking(move || {
        let conn = state.db.get()?;
        let parent = authorize_parent_for_create(&conn, &session, &dir, &data_dir)?;
        let dest = parent.join(&name);
        if dest.exists() {
            return Err(AppError::BadRequest("File already exists.".into()));
        }
        std::fs::write(&dest, content.as_bytes()).map_err(|e| map_fs_error(e, "create", &dest))?;
        Ok::<_, AppError>(dest.to_string_lossy().into_owned())
    })
    .await
    .map_err(|_| AppError::Internal("Task failed".into()))??;

    Ok(Json(serde_json::json!({ "path": created })))
}

pub async fn rename_path(
    State(state): State<AppState>,
    Extension(session): Extension<SessionUser>,
    Json(payload): Json<RenameRequest>,
) -> Result<impl IntoResponse, AppError> {
    tracing::info!(user = ?session.username, path = %payload.path, new_name = %payload.new_name, "rename");
    if !is_safe_filename(&payload.new_name) {
        return Err(AppError::BadRequest("Invalid file name.".into()));
    }
    let data_dir = state.config.read().await.data_dir.clone();
    let old_path = payload.path.clone();
    let new_name = payload.new_name.clone();
    let parent_for_lock = std::path::Path::new(&old_path)
        .parent()
        .unwrap_or(std::path::Path::new("/"))
        .to_path_buf();
    let _folder_guard = crate::api::fs_access::acquire_folder_lock(&state.folder_locks, &parent_for_lock).await;
    let new_path = spawn_blocking(move || {
        let conn = state.db.get()?;
        let authorized = authorize_path(&conn, &session, &old_path, &data_dir)?;
        let parent = authorized
            .canonical
            .parent()
            .ok_or_else(|| AppError::BadRequest("No parent directory.".into()))?;
        authorize_parent_for_create(&conn, &session, parent.to_string_lossy().as_ref(), &data_dir)?;
        let dest = parent.join(&new_name);
        if dest.exists() {
            return Err(AppError::BadRequest("Destination already exists.".into()));
        }
        std::fs::rename(&authorized.canonical, &dest)
            .map_err(|e| map_fs_error(e, "rename", &authorized.canonical))?;
        Ok::<_, AppError>(dest.to_string_lossy().into_owned())
    })
    .await
    .map_err(|_| AppError::Internal("Task failed".into()))??;

    Ok(Json(serde_json::json!({ "path": new_path })))
}

pub async fn copy_paths(
    State(state): State<AppState>,
    Extension(session): Extension<SessionUser>,
    Json(payload): Json<TransferRequest>,
) -> Result<impl IntoResponse, AppError> {
    tracing::info!(user = ?session.username, count = payload.src_paths.len(), dest = %payload.dest_dir, "copy");
    if payload.src_paths.is_empty() {
        return Err(AppError::BadRequest("No paths provided.".into()));
    }
    let data_dir = state.config.read().await.data_dir.clone();
    let dest_dir = payload.dest_dir.clone();
    let src_paths = payload.src_paths.clone();
    let collision = payload.collision.clone();
    let _folder_guard = crate::api::fs_access::acquire_folder_lock(
        &state.folder_locks, std::path::Path::new(&dest_dir)).await;
    let result = spawn_blocking(move || {
        let conn = state.db.get()?;
        let dest = authorize_parent_for_create(&conn, &session, &dest_dir, &data_dir)?;
        let mut succeeded = Vec::new();
        let mut failed = Vec::new();
        for src in &src_paths {
            match authorize_path(&conn, &session, src, &data_dir)
                .and_then(|auth| copy_entry(&auth.canonical, &dest, &collision).map(|_| auth.canonical.to_string_lossy().into_owned()))
            {
                Ok(path) => succeeded.push(path),
                Err(e) => failed.push(BatchFailure { path: src.clone(), error: e.to_string() }),
            }
        }
        Ok::<_, AppError>(BatchResult { succeeded, failed })
    })
    .await
    .map_err(|_| AppError::Internal("Task failed".into()))??;

    Ok(Json(result))
}

pub async fn move_paths(
    State(state): State<AppState>,
    Extension(session): Extension<SessionUser>,
    Json(payload): Json<TransferRequest>,
) -> Result<impl IntoResponse, AppError> {
    tracing::info!(user = ?session.username, count = payload.src_paths.len(), dest = %payload.dest_dir, "move");
    if payload.src_paths.is_empty() {
        return Err(AppError::BadRequest("No paths provided.".into()));
    }
    let data_dir = state.config.read().await.data_dir.clone();
    let dest_dir = payload.dest_dir.clone();
    let src_paths = payload.src_paths.clone();
    let collision = payload.collision.clone();
    let _folder_guard = crate::api::fs_access::acquire_folder_lock(
        &state.folder_locks, std::path::Path::new(&dest_dir)).await;
    let result = spawn_blocking(move || {
        let conn = state.db.get()?;
        let dest = authorize_parent_for_create(&conn, &session, &dest_dir, &data_dir)?;
        let mut succeeded = Vec::new();
        let mut failed = Vec::new();
        for src in &src_paths {
            let item_result = (|| -> Result<String, AppError> {
                let authorized = authorize_path(&conn, &session, src, &data_dir)?;
                if authorized.canonical == dest || dest.starts_with(&authorized.canonical) {
                    return Err(AppError::BadRequest("Cannot move a folder into itself.".into()));
                }
                move_entry(&authorized.canonical, &dest, &collision)?;
                Ok(authorized.canonical.to_string_lossy().into_owned())
            })();
            match item_result {
                Ok(path) => succeeded.push(path),
                Err(e) => failed.push(BatchFailure { path: src.clone(), error: e.to_string() }),
            }
        }
        Ok::<_, AppError>(BatchResult { succeeded, failed })
    })
    .await
    .map_err(|_| AppError::Internal("Task failed".into()))??;

    Ok(Json(result))
}

pub async fn delete_paths(
    State(state): State<AppState>,
    Extension(session): Extension<SessionUser>,
    Json(payload): Json<PathsRequest>,
) -> Result<impl IntoResponse, AppError> {
    if payload.paths.is_empty() {
        return Err(AppError::BadRequest("No paths provided.".into()));
    }
    tracing::info!(user = ?session.username, count = payload.paths.len(), "delete");
    let data_dir = state.config.read().await.data_dir.clone();
    let paths = payload.paths.clone();
    // Lock on data_dir as a coarse guard covering all watched folder paths.
    let _folder_guard = crate::api::fs_access::acquire_folder_lock(&state.folder_locks, &data_dir).await;
    let result = spawn_blocking(move || {
        let conn = state.db.get()?;
        let mut succeeded = Vec::new();
        let mut failed = Vec::new();
        for path in paths {
            match authorize_path(&conn, &session, &path, &data_dir)
                .and_then(|auth| delete_path(&auth.canonical).map(|_| auth.canonical.to_string_lossy().into_owned()))
            {
                Ok(p) => succeeded.push(p),
                Err(e) => failed.push(BatchFailure { path, error: e.to_string() }),
            }
        }
        Ok::<_, AppError>(BatchResult { succeeded, failed })
    })
    .await
    .map_err(|_| AppError::Internal("Task failed".into()))??;

    Ok(Json(result))
}

pub async fn create_symlink(
    State(state): State<AppState>,
    Extension(session): Extension<SessionUser>,
    Json(payload): Json<SymlinkRequest>,
) -> Result<impl IntoResponse, AppError> {
    let name = std::path::Path::new(&payload.link_path)
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or_else(|| AppError::BadRequest("Invalid link name.".into()))?
        .to_string();
    if !is_safe_filename(&name) {
        return Err(AppError::BadRequest("Invalid link name.".into()));
    }
    let data_dir = state.config.read().await.data_dir.clone();
    let link_path = payload.link_path.clone();
    let target = payload.target.clone();
    let symlink_parent = std::path::Path::new(&link_path)
        .parent()
        .unwrap_or(std::path::Path::new("/"))
        .to_path_buf();
    let _folder_guard = crate::api::fs_access::acquire_folder_lock(&state.folder_locks, &symlink_parent).await;
    spawn_blocking(move || {
        let conn = state.db.get()?;
        let parent = std::path::Path::new(&link_path)
            .parent()
            .ok_or_else(|| AppError::BadRequest("No parent directory.".into()))?;
        let parent_dir = authorize_parent_for_create(
            &conn,
            &session,
            parent.to_string_lossy().as_ref(),
            &data_dir,
        )?;
        let full_link = parent_dir.join(&name);
        if full_link.exists() {
            return Err(AppError::BadRequest("Link path already exists.".into()));
        }
        #[cfg(unix)]
        std::os::unix::fs::symlink(&target, &full_link)
            .map_err(|e| map_fs_error(e, "create symlink", &full_link))?;
        #[cfg(not(unix))]
        return Err(AppError::BadRequest(
            "Symlinks are not supported on this platform.".into(),
        ));
        Ok::<_, AppError>(())
    })
    .await
    .map_err(|_| AppError::Internal("Task failed".into()))??;

    Ok(StatusCode::OK)
}

pub async fn duplicate_paths(
    State(state): State<AppState>,
    Extension(session): Extension<SessionUser>,
    Json(payload): Json<PathsRequest>,
) -> Result<impl IntoResponse, AppError> {
    if payload.paths.is_empty() {
        return Err(AppError::BadRequest("No paths provided.".into()));
    }
    let data_dir = state.config.read().await.data_dir.clone();
    let paths = payload.paths.clone();
    let duplicated = spawn_blocking(move || {
        let conn = state.db.get()?;
        let mut out = Vec::with_capacity(paths.len());
        for path in paths {
            let authorized = authorize_path(&conn, &session, &path, &data_dir)?;
            let dest = duplicate_entry(&authorized.canonical)?;
            out.push(dest.to_string_lossy().into_owned());
        }
        Ok::<_, AppError>(out)
    })
    .await
    .map_err(|_| AppError::Internal("Task failed".into()))??;

    Ok(Json(serde_json::json!({ "paths": duplicated })))
}

pub async fn bulk_rename(
    State(state): State<AppState>,
    Extension(session): Extension<SessionUser>,
    Json(payload): Json<BulkRenameRequest>,
) -> Result<impl IntoResponse, AppError> {
    let data_dir = state.config.read().await.data_dir.clone();
    let paths = payload.paths.clone();
    let base_name = payload.base_name.clone();
    let renamed = spawn_blocking(move || {
        let conn = state.db.get()?;
        for path in &paths {
            authorize_path(&conn, &session, path, &data_dir)?;
        }
        bulk_rename_paths(&paths, &base_name)
    })
    .await
    .map_err(|_| AppError::Internal("Task failed".into()))??;

    Ok(Json(serde_json::json!({ "paths": renamed })))
}

pub async fn compress_paths_handler(
    State(state): State<AppState>,
    Extension(session): Extension<SessionUser>,
    Json(payload): Json<CompressRequest>,
) -> Result<impl IntoResponse, AppError> {
    if payload.paths.is_empty() {
        return Err(AppError::BadRequest("No paths provided.".into()));
    }
    let data_dir = state.config.read().await.data_dir.clone();
    let dest_dir = payload.dest_dir.clone();
    let paths = payload.paths.clone();
    let format = payload.format.clone();
    spawn_blocking(move || {
        let conn = state.db.get()?;
        let dest = authorize_parent_for_create(&conn, &session, &dest_dir, &data_dir)?;
        let mut authorized_paths = Vec::with_capacity(paths.len());
        for path in paths {
            let authorized = authorize_path(&conn, &session, &path, &data_dir)?;
            authorized_paths.push(authorized.canonical);
        }
        compress_paths(&authorized_paths, &dest, &format)
    })
    .await
    .map_err(|_| AppError::Internal("Task failed".into()))??;

    Ok(StatusCode::OK)
}

pub async fn extract_here(
    State(state): State<AppState>,
    Extension(session): Extension<SessionUser>,
    Json(payload): Json<ExtractRequest>,
) -> Result<impl IntoResponse, AppError> {
    let data_dir = state.config.read().await.data_dir.clone();
    let path = payload.path.clone();
    spawn_blocking(move || {
        let conn = state.db.get()?;
        let authorized = authorize_path(&conn, &session, &path, &data_dir)?;
        let parent = authorized
            .canonical
            .parent()
            .ok_or_else(|| AppError::BadRequest("No parent directory.".into()))?;
        extract_archive(&authorized.canonical, parent)
    })
    .await
    .map_err(|_| AppError::Internal("Task failed".into()))??;

    Ok(StatusCode::OK)
}

pub async fn extract_to_subfolder(
    State(state): State<AppState>,
    Extension(session): Extension<SessionUser>,
    Json(payload): Json<ExtractRequest>,
) -> Result<impl IntoResponse, AppError> {
    let data_dir = state.config.read().await.data_dir.clone();
    let path = payload.path.clone();
    spawn_blocking(move || {
        let conn = state.db.get()?;
        let authorized = authorize_path(&conn, &session, &path, &data_dir)?;
        let stem = authorized
            .canonical
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("extracted");
        let parent = authorized
            .canonical
            .parent()
            .ok_or_else(|| AppError::BadRequest("No parent directory.".into()))?;
        let dest = parent.join(stem);
        std::fs::create_dir_all(&dest).map_err(|e| map_fs_error(e, "create", &dest))?;
        extract_archive(&authorized.canonical, &dest)
    })
    .await
    .map_err(|_| AppError::Internal("Task failed".into()))??;

    Ok(StatusCode::OK)
}

pub async fn rotate_image(
    State(state): State<AppState>,
    Extension(session): Extension<SessionUser>,
    Json(payload): Json<RotateRequest>,
) -> Result<impl IntoResponse, AppError> {
    let data_dir = state.config.read().await.data_dir.clone();
    let path = payload.path.clone();
    let direction = payload.direction.clone();
    spawn_blocking(move || {
        let conn = state.db.get()?;
        let authorized = authorize_path(&conn, &session, &path, &data_dir)?;
        rotate_image_path(&authorized.canonical, &direction)
    })
    .await
    .map_err(|_| AppError::Internal("Task failed".into()))??;

    Ok(StatusCode::OK)
}

pub async fn read_file(
    State(state): State<AppState>,
    Extension(session): Extension<SessionUser>,
    Query(payload): Query<ReadFileQuery>,
) -> Result<impl IntoResponse, AppError> {
    let data_dir = state.config.read().await.data_dir.clone();
    let path = payload.path.clone();
    let content = spawn_blocking(move || {
        let conn = state.db.get()?;
        let authorized = authorize_path(&conn, &session, &path, &data_dir)?;
        let meta = authorized.canonical
            .symlink_metadata()
            .map_err(|e| map_fs_error(e, "read", &authorized.canonical))?;
        if meta.is_dir() {
            return Err(AppError::BadRequest("Path is a directory.".into()));
        }
        const MAX: u64 = 2 * 1024 * 1024;
        if meta.len() > MAX {
            return Err(AppError::BadRequest(format!(
                "File is too large to read ({} bytes). Max 2 MB.",
                meta.len()
            )));
        }
        let bytes = std::fs::read(&authorized.canonical)
            .map_err(|e| map_fs_error(e, "read", &authorized.canonical))?;
        String::from_utf8(bytes)
            .map_err(|_| AppError::BadRequest("File is not valid UTF-8 text.".into()))
    })
    .await
    .map_err(|_| AppError::Internal("Task failed".into()))??;

    Ok(Json(serde_json::json!({ "content": content })))
}

pub async fn write_file(
    State(state): State<AppState>,
    Extension(session): Extension<SessionUser>,
    Json(payload): Json<WriteFileRequest>,
) -> Result<impl IntoResponse, AppError> {
    if payload.content.len() > 10 * 1024 * 1024 {
        return Err(AppError::BadRequest("Content too large. Max 10 MB.".into()));
    }
    let data_dir = state.config.read().await.data_dir.clone();
    let path = payload.path.clone();
    let content = payload.content.clone();
    spawn_blocking(move || {
        let conn = state.db.get()?;
        let authorized = authorize_path(&conn, &session, &path, &data_dir)?;
        std::fs::write(&authorized.canonical, content.as_bytes())
            .map_err(|e| map_fs_error(e, "write", &authorized.canonical))
    })
    .await
    .map_err(|_| AppError::Internal("Task failed".into()))??;

    Ok(StatusCode::OK)
}

pub async fn trash_paths(
    State(state): State<AppState>,
    Extension(session): Extension<SessionUser>,
    Json(payload): Json<PathsRequest>,
) -> Result<impl IntoResponse, AppError> {
    if payload.paths.is_empty() {
        return Err(AppError::BadRequest("No paths provided.".into()));
    }
    tracing::info!(user = ?session.username, count = payload.paths.len(), "trash");
    let data_dir = state.config.read().await.data_dir.clone();
    let paths = payload.paths.clone();
    let _folder_guard = crate::api::fs_access::acquire_folder_lock(&state.folder_locks, &data_dir).await;
    let result = spawn_blocking(move || {
        let conn = state.db.get()?;
        let mut succeeded = Vec::new();
        let mut failed = Vec::new();
        for path in paths {
            let item_result = (|| -> Result<String, AppError> {
                let authorized = authorize_path(&conn, &session, &path, &data_dir)?;
                // Trash lives inside the watched folder root so each NAS share has its own
                // .datieve_trash. Falls back to data_dir trash if root is somehow empty.
                let trash_root = if authorized.watched_folder_root.as_os_str().is_empty() {
                    data_dir.clone()
                } else {
                    authorized.watched_folder_root.clone()
                };
                let trash_dir = trash_root.join(".datieve_trash");
                std::fs::create_dir_all(&trash_dir)
                    .map_err(|e| map_fs_error(e, "create trash directory", &trash_dir))?;
                let name = authorized
                    .canonical
                    .file_name()
                    .ok_or_else(|| AppError::BadRequest("Invalid path.".into()))?
                    .to_string_lossy()
                    .into_owned();
                let dest = trash_dir.join(&name);
                let collision_name = if dest.exists() {
                    let ts = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_secs();
                    format!("{}.{}", name, ts)
                } else {
                    name
                };
                let final_dest = trash_dir.join(&collision_name);
                std::fs::rename(&authorized.canonical, &final_dest)
                    .or_else(|_| {
                        // Cross-device move: copy then delete
                        copy_entry(&authorized.canonical, &trash_dir, "rename")?;
                        delete_path(&authorized.canonical)
                    })
                    .map_err(|_| AppError::BadRequest(format!(
                        "Could not move '{}' to trash.",
                        authorized.canonical.display()
                    )))?;
                Ok(authorized.canonical.to_string_lossy().into_owned())
            })();
            match item_result {
                Ok(p) => succeeded.push(p),
                Err(e) => failed.push(BatchFailure { path, error: e.to_string() }),
            }
        }
        Ok::<_, AppError>(BatchResult { succeeded, failed })
    })
    .await
    .map_err(|_| AppError::Internal("Task failed".into()))??;

    Ok(Json(result))
}

/// Streams a single file's bytes to the caller (used by the web UI's "Download" action,
/// where there's no local filesystem to hand a path back to like the desktop app has).
/// Reads in chunks via `ReaderStream` rather than buffering the whole file in memory,
/// so this stays cheap for large files.
pub async fn download_file(
    State(state): State<AppState>,
    Extension(session): Extension<SessionUser>,
    Query(payload): Query<DownloadQuery>,
) -> Result<impl IntoResponse, AppError> {
    let data_dir = state.config.read().await.data_dir.clone();
    let path = payload.path.clone();
    let (file, canonical, len) = spawn_blocking(move || {
        let conn = state.db.get()?;
        let authorized = authorize_path(&conn, &session, &path, &data_dir)?;
        let meta = authorized
            .canonical
            .symlink_metadata()
            .map_err(|e| map_fs_error(e, "read", &authorized.canonical))?;
        if meta.is_dir() {
            return Err(AppError::BadRequest("Path is a directory.".into()));
        }
        let file = std::fs::File::open(&authorized.canonical)
            .map_err(|e| map_fs_error(e, "read", &authorized.canonical))?;
        Ok::<_, AppError>((file, authorized.canonical, meta.len()))
    })
    .await
    .map_err(|_| AppError::Internal("Task failed".into()))??;

    let stream = ReaderStream::new(tokio::fs::File::from_std(file));
    let body = Body::from_stream(stream);

    let file_name = canonical
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("download")
        .to_string();
    let ascii_fallback: String = file_name
        .chars()
        .map(|c| if c.is_ascii() { c } else { '_' })
        .collect();
    let encoded = utf8_percent_encode(&file_name, NON_ALPHANUMERIC).to_string();
    let disposition = format!(
        "attachment; filename=\"{}\"; filename*=UTF-8''{}",
        ascii_fallback.replace('"', "'"),
        encoded
    );
    let mime = mime_guess::from_path(&canonical).first_or_octet_stream();

    Response::builder()
        .header(header::CONTENT_TYPE, mime.as_ref())
        .header(header::CONTENT_DISPOSITION, disposition)
        .header(header::CONTENT_LENGTH, len)
        .body(body)
        .map_err(|e| AppError::Internal(e.to_string()))
}