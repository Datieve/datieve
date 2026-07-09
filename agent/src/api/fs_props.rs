// Live filesystem metadata for the web UI — mirrors app-flutter/rust/src/core/mod.rs
// get_file_properties, calculate_file_hashes, get_volume_info_for_path, calculate_folder_summary.
use std::io::Read;
use std::path::Path;

use axum::{
    extract::{Query, State},
    Extension, Json,
};
use crc32fast::Hasher as Crc32Hasher;
use md5::Md5;
use serde::{Deserialize, Serialize};
use sha1::Sha1;
use sha2::Sha256;
use sha1::Digest as _;
use sha2::Digest as _;
use md5::Digest as _;
use tokio::task::spawn_blocking;

use crate::api::admin::normalize_path;
use crate::api::fs_access::{authorize_path, map_fs_error};
use crate::api::middleware::SessionUser;
use crate::api::AppState;
use crate::error::AppError;

#[derive(Deserialize)]
pub struct PathQuery {
    pub path: String,
    pub id: Option<i64>,
    #[serde(default)]
    pub kind: Option<String>,
}

#[derive(Serialize, Clone)]
pub struct FilePropertiesResponse {
    pub name: String,
    pub absolute_path: String,
    pub is_dir: bool,
    pub is_symlink: bool,
    pub symlink_target: Option<String>,
    pub size: u64,
    pub modified_secs: u64,
    pub created_secs: u64,
    pub accessed_secs: u64,
    pub permissions: String,
    pub mime_type: String,
    pub live: bool,
    pub owner: Option<String>,
    pub group: Option<String>,
    pub index_id: Option<i64>,
    pub index_kind: Option<String>,
    pub is_deleted: bool,
    pub deleted_at: Option<String>,
    pub indexed_at: Option<String>,
}

#[derive(Serialize)]
pub struct FileHashesResponse {
    pub md5: String,
    pub sha1: String,
    pub sha256: String,
    pub crc32: String,
}

#[derive(Serialize)]
pub struct VolumeInfoResponse {
    pub mount_path: String,
    pub device: String,
    pub fs_type: String,
    pub total_bytes: u64,
    pub used_bytes: u64,
    pub available_bytes: u64,
}

#[derive(Serialize)]
pub struct FolderSummaryResponse {
    pub total_size: u64,
    pub file_count: u64,
    pub folder_count: u64,
    pub truncated: bool,
}

#[derive(Clone)]
struct IndexMeta {
    id: i64,
    kind: String,
    is_deleted: bool,
    deleted_at: Option<String>,
    indexed_at: Option<String>,
    size_bytes: u64,
    created_at: Option<String>,
    modified_at: Option<String>,
}

fn secs_from_system_time(t: std::time::SystemTime) -> u64 {
    t.duration_since(std::time::UNIX_EPOCH)
        .ok()
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn secs_from_iso(s: &str) -> u64 {
    chrono::DateTime::parse_from_rfc3339(s)
        .map(|dt| dt.timestamp().max(0) as u64)
        .unwrap_or(0)
}

fn lookup_index_meta(
    conn: &rusqlite::Connection,
    session: &SessionUser,
    path: &str,
    id: Option<i64>,
    kind: Option<&str>,
) -> Option<IndexMeta> {
    let scope = crate::engine::scope_tag();
    let allowed = serde_json::to_string(&session.allowed_folder_ids).ok()?;

    if let (Some(id), Some(kind)) = (id, kind) {
        if kind == "file" {
            if let Ok(row) = conn.query_row(
                "SELECT f.id, f.size_bytes, f.created_at, f.modified_at, f.is_deleted, f.deleted_at, f.indexed_at
                 FROM files f
                 JOIN folders fo ON fo.id = f.folder_id
                 JOIN watched_folders wf ON wf.id = fo.watched_folder_id
                 WHERE f.id = ? AND f.scope_tag = ? AND wf.id IN (SELECT value FROM json_each(?))
                 LIMIT 1",
                rusqlite::params![id, scope, allowed],
                |r| {
                    Ok(IndexMeta {
                        id: r.get(0)?,
                        kind: "file".into(),
                        is_deleted: r.get::<_, i64>(4)? == 1,
                        deleted_at: r.get(5)?,
                        indexed_at: r.get(6)?,
                        size_bytes: r.get(1)?,
                        created_at: r.get(2)?,
                        modified_at: r.get(3)?,
                    })
                },
            ) {
                return Some(row);
            }
        } else if kind == "folder" {
            if let Ok(row) = conn.query_row(
                "SELECT fo.id, fo.total_size_bytes, fo.indexed_at, fo.is_deleted, fo.deleted_at
                 FROM folders fo
                 JOIN watched_folders wf ON wf.id = fo.watched_folder_id
                 WHERE fo.id = ? AND fo.scope_tag = ? AND wf.id IN (SELECT value FROM json_each(?))
                 LIMIT 1",
                rusqlite::params![id, scope, allowed],
                |r| {
                    Ok(IndexMeta {
                        id: r.get(0)?,
                        kind: "folder".into(),
                        is_deleted: r.get::<_, i64>(3)? == 1,
                        deleted_at: r.get(4)?,
                        indexed_at: r.get(2)?,
                        size_bytes: r.get(1)?,
                        created_at: None,
                        modified_at: None,
                    })
                },
            ) {
                return Some(row);
            }
        }
    }

    if let Ok(row) = conn.query_row(
        "SELECT f.id, f.size_bytes, f.created_at, f.modified_at, f.is_deleted, f.deleted_at, f.indexed_at
         FROM files f
         JOIN folders fo ON fo.id = f.folder_id
         JOIN watched_folders wf ON wf.id = fo.watched_folder_id
         WHERE f.absolute_path = ? AND f.scope_tag = ? AND wf.id IN (SELECT value FROM json_each(?))
         LIMIT 1",
        rusqlite::params![path, scope, allowed],
        |r| {
            Ok(IndexMeta {
                id: r.get(0)?,
                kind: "file".into(),
                is_deleted: r.get::<_, i64>(4)? == 1,
                deleted_at: r.get(5)?,
                indexed_at: r.get(6)?,
                size_bytes: r.get(1)?,
                created_at: r.get(2)?,
                modified_at: r.get(3)?,
            })
        },
    ) {
        return Some(row);
    }

    None
}

fn authorize_read_path(
    conn: &rusqlite::Connection,
    session: &SessionUser,
    raw_path: &str,
    data_dir: &Path,
) -> Result<std::path::PathBuf, AppError> {
    if let Ok(auth) = authorize_path(conn, session, raw_path, data_dir) {
        return Ok(auth.canonical);
    }
    let normalized = normalize_path(raw_path)?;
    if crate::api::admin::BLOCKED_PREFIXES
        .iter()
        .any(|pfx| normalized.starts_with(Path::new(pfx)))
    {
        return Err(AppError::Forbidden("Blocked path.".into()));
    }
    let scope = crate::engine::scope_tag();
    let allowed_json = serde_json::to_string(&session.allowed_folder_ids)
        .map_err(|e| AppError::Internal(e.to_string()))?;
    let mut stmt = conn.prepare(
        "SELECT id, path FROM watched_folders
         WHERE scope_tag = ? AND id IN (SELECT value FROM json_each(?))
         ORDER BY length(path) DESC",
    )?;
    let rows = stmt.query_map(rusqlite::params![scope, allowed_json], |row| {
        Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
    })?;
    let norm_str = normalized.to_string_lossy();
    for row in rows {
        let (id, root_str) = row?;
        let root = Path::new(&root_str);
        let root_canon = std::fs::canonicalize(root).unwrap_or_else(|_| root.to_path_buf());
        let root_s = root_canon.to_string_lossy();
        if norm_str == root_s || norm_str.starts_with(&format!("{}/", root_s)) {
            let relative = norm_str
                .strip_prefix(root_s.as_ref())
                .unwrap_or("")
                .trim_start_matches('/');
            let rel = if relative.is_empty() {
                "/".to_string()
            } else {
                format!("/{}", relative)
            };
            if !crate::api::fs_access::user_can_access_relative(conn, session, id, &rel)? {
                return Err(AppError::Forbidden("Access denied.".into()));
            }
            return Ok(normalized);
        }
    }
    Err(AppError::Forbidden(format!(
        "Path '{}' is outside your indexed NAS folders.",
        normalized.display()
    )))
}

fn read_live_properties(path: &Path) -> Result<FilePropertiesResponse, AppError> {
    let lmeta = path
        .symlink_metadata()
        .map_err(|e| map_fs_error(e, "stat", path))?;
    let is_symlink = lmeta.file_type().is_symlink();
    let symlink_target = if is_symlink {
        std::fs::read_link(path)
            .ok()
            .map(|t| t.to_string_lossy().to_string())
    } else {
        None
    };
    let meta = path
        .metadata()
        .map_err(|e| map_fs_error(e, "stat", path))?;
    let is_dir = meta.is_dir();
    let size = meta.len();
    let modified_secs = meta.modified().map(secs_from_system_time).unwrap_or(0);
    let created_secs = meta.created().map(secs_from_system_time).unwrap_or(0);
    let accessed_secs = meta.accessed().map(secs_from_system_time).unwrap_or(0);

    #[cfg(unix)]
    let permissions = {
        use std::os::unix::fs::PermissionsExt;
        let mode = meta.permissions().mode() & 0o777;
        let bits = |v: u32, r: char, w: char, x: char| {
            format!(
                "{}{}{}",
                if v & 4 != 0 { r } else { '-' },
                if v & 2 != 0 { w } else { '-' },
                if v & 1 != 0 { x } else { '-' }
            )
        };
        format!(
            "{}{}{}",
            bits(mode >> 6, 'r', 'w', 'x'),
            bits((mode >> 3) & 7, 'r', 'w', 'x'),
            bits(mode & 7, 'r', 'w', 'x')
        )
    };
    #[cfg(not(unix))]
    let permissions = if meta.permissions().readonly() {
        "read-only".to_string()
    } else {
        "read-write".to_string()
    };

    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| path.to_string_lossy().to_string());
    let mime_type = mime_guess::from_path(path)
        .first_or_octet_stream()
        .to_string();

    let (owner, group) = read_owner_group(path);

    Ok(FilePropertiesResponse {
        name,
        absolute_path: path.to_string_lossy().to_string(),
        is_dir,
        is_symlink,
        symlink_target,
        size,
        modified_secs,
        created_secs,
        accessed_secs,
        permissions,
        mime_type,
        live: true,
        owner,
        group,
        index_id: None,
        index_kind: None,
        is_deleted: false,
        deleted_at: None,
        indexed_at: None,
    })
}

fn properties_from_index(path: &str, index: &IndexMeta) -> FilePropertiesResponse {
    let name = Path::new(path)
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| path.to_string());
    let is_dir = index.kind == "folder";
    FilePropertiesResponse {
        name,
        absolute_path: path.to_string(),
        is_dir,
        is_symlink: false,
        symlink_target: None,
        size: index.size_bytes,
        modified_secs: index
            .modified_at
            .as_deref()
            .map(secs_from_iso)
            .unwrap_or(0),
        created_secs: index
            .created_at
            .as_deref()
            .map(secs_from_iso)
            .unwrap_or(0),
        accessed_secs: 0,
        permissions: String::new(),
        mime_type: if is_dir {
            String::new()
        } else {
            mime_guess::from_path(path)
                .first_or_octet_stream()
                .to_string()
        },
        live: false,
        owner: None,
        group: None,
        index_id: Some(index.id),
        index_kind: Some(index.kind.clone()),
        is_deleted: index.is_deleted,
        deleted_at: index.deleted_at.clone(),
        indexed_at: index.indexed_at.clone(),
    }
}

fn merge_index(props: &mut FilePropertiesResponse, index: &IndexMeta) {
    props.index_id = Some(index.id);
    props.index_kind = Some(index.kind.clone());
    props.is_deleted = index.is_deleted;
    props.deleted_at = index.deleted_at.clone();
    props.indexed_at = index.indexed_at.clone();
}

#[cfg(unix)]
fn read_owner_group(path: &Path) -> (Option<String>, Option<String>) {
    let output = std::process::Command::new("stat")
        .args(["-c", "%U (%u)|%G (%g)"])
        .arg(path)
        .output();
    let Ok(output) = output else {
        return (None, None);
    };
    if !output.status.success() {
        return (None, None);
    }
    let text = String::from_utf8_lossy(&output.stdout);
    let parts: Vec<&str> = text.trim().split('|').collect();
    if parts.len() == 2 {
        (Some(parts[0].to_string()), Some(parts[1].to_string()))
    } else {
        (None, None)
    }
}

#[cfg(not(unix))]
fn read_owner_group(_path: &Path) -> (Option<String>, Option<String>) {
    (None, None)
}

fn calculate_hashes(path: &Path) -> Result<FileHashesResponse, AppError> {
    let meta = path
        .metadata()
        .map_err(|e| map_fs_error(e, "read", path))?;
    if meta.is_dir() {
        return Err(AppError::BadRequest(
            "Hashes are only available for files.".into(),
        ));
    }
    let mut file = std::fs::File::open(path).map_err(|e| map_fs_error(e, "read", path))?;
    let mut reader = std::io::BufReader::new(&mut file);
    let mut md5 = Md5::new();
    let mut sha1 = Sha1::new();
    let mut sha256 = Sha256::new();
    let mut crc32 = Crc32Hasher::new();
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let read = reader
            .read(&mut buffer)
            .map_err(|e| map_fs_error(e, "read", path))?;
        if read == 0 {
            break;
        }
        let chunk = &buffer[..read];
        md5.update(chunk);
        sha1.update(chunk);
        sha256.update(chunk);
        crc32.update(chunk);
    }
    Ok(FileHashesResponse {
        md5: hex::encode(md5.finalize()),
        sha1: hex::encode(sha1.finalize()),
        sha256: hex::encode(sha256.finalize()),
        crc32: format!("{:08x}", crc32.finalize()),
    })
}

#[cfg(target_os = "linux")]
fn decode_mount_field(value: &str) -> String {
    value
        .replace("\\040", " ")
        .replace("\\011", "\t")
        .replace("\\012", "\n")
        .replace("\\134", "\\")
}

#[cfg(target_os = "linux")]
fn mount_space_bytes(path: &str) -> (u64, u64, u64) {
    let output = std::process::Command::new("df")
        .args(["-P", "-B1", path])
        .output();
    let Ok(output) = output else {
        return (0, 0, 0);
    };
    if !output.status.success() {
        return (0, 0, 0);
    }
    let text = String::from_utf8_lossy(&output.stdout);
    let Some(line) = text.lines().nth(1) else {
        return (0, 0, 0);
    };
    let cols: Vec<&str> = line.split_whitespace().collect();
    if cols.len() < 5 {
        return (0, 0, 0);
    }
    let total = cols[1].parse::<u64>().unwrap_or(0);
    let used = cols[2].parse::<u64>().unwrap_or(0);
    let available = cols[3].parse::<u64>().unwrap_or(0);
    (total, used, available)
}

fn volume_info_for_path(path: &Path) -> Result<VolumeInfoResponse, AppError> {
    let canonical = std::fs::canonicalize(path).map_err(|e| map_fs_error(e, "resolve", path))?;
    let target = canonical.to_string_lossy().to_string();

    #[cfg(target_os = "linux")]
    {
        let content =
            std::fs::read_to_string("/proc/mounts").map_err(|e| AppError::Internal(e.to_string()))?;
        let mut best: Option<(String, String, String)> = None;
        for line in content.lines() {
            let parts: Vec<&str> = line.splitn(4, ' ').collect();
            if parts.len() < 3 {
                continue;
            }
            let device = decode_mount_field(parts[0]);
            let mount_point = decode_mount_field(parts[1]);
            let fs_type = parts[2].to_string();
            if target.starts_with(&mount_point)
                && mount_point.len() >= best.as_ref().map(|b| b.1.len()).unwrap_or(0)
            {
                best = Some((device, mount_point, fs_type));
            }
        }
        let Some((device, mount_path, fs_type)) = best else {
            return Err(AppError::NotFound);
        };
        let (total_bytes, used_bytes, available_bytes) = mount_space_bytes(&mount_path);
        return Ok(VolumeInfoResponse {
            mount_path,
            device,
            fs_type,
            total_bytes,
            used_bytes,
            available_bytes,
        });
    }

    #[cfg(not(target_os = "linux"))]
    {
        let _ = target;
        Err(AppError::NotFound)
    }
}

fn folder_summary(path: &Path) -> Result<FolderSummaryResponse, AppError> {
    const MAX_VISITED: u64 = 50_000;
    let root = std::fs::canonicalize(path).map_err(|e| map_fs_error(e, "access", path))?;
    if !root.is_dir() {
        return Err(AppError::BadRequest(
            "Folder summary is only available for folders.".into(),
        ));
    }
    let mut total_size = 0u64;
    let mut file_count = 0u64;
    let mut folder_count = 0u64;
    let mut visited = 0u64;
    let mut truncated = false;
    let mut stack = vec![root];
    while let Some(dir) = stack.pop() {
        if visited >= MAX_VISITED {
            truncated = true;
            break;
        }
        let read_dir = match std::fs::read_dir(&dir) {
            Ok(iter) => iter,
            Err(_) => continue,
        };
        for entry in read_dir.flatten() {
            if visited >= MAX_VISITED {
                truncated = true;
                break;
            }
            visited += 1;
            let path = entry.path();
            let meta = match entry.metadata() {
                Ok(meta) => meta,
                Err(_) => continue,
            };
            if meta.is_dir() {
                folder_count = folder_count.saturating_add(1);
                if !entry
                    .file_type()
                    .map(|ft| ft.is_symlink())
                    .unwrap_or(false)
                {
                    stack.push(path);
                }
            } else if meta.is_file() {
                file_count = file_count.saturating_add(1);
                total_size = total_size.saturating_add(meta.len());
            }
        }
    }
    Ok(FolderSummaryResponse {
        total_size,
        file_count,
        folder_count,
        truncated,
    })
}

pub async fn get_properties(
    State(state): State<AppState>,
    Extension(session): Extension<SessionUser>,
    Query(q): Query<PathQuery>,
) -> Result<Json<FilePropertiesResponse>, AppError> {
    let path = q.path;
    let id = q.id;
    let kind = q.kind;
    let data_dir = state.config.read().await.data_dir.clone();
    let result = spawn_blocking(move || {
        let conn = state.db.get()?;
        let index = lookup_index_meta(&conn, &session, &path, id, kind.as_deref());
        let canonical = authorize_read_path(&conn, &session, &path, &data_dir)?;
        match read_live_properties(&canonical) {
            Ok(mut props) => {
                if let Some(ref idx) = index {
                    merge_index(&mut props, idx);
                }
                Ok(props)
            }
            Err(_) => index
                .map(|idx| properties_from_index(&path, &idx))
                .ok_or(AppError::NotFound),
        }
    })
    .await
    .map_err(|_| AppError::Internal("Task failed".into()))??;
    Ok(Json(result))
}

pub async fn get_hashes(
    State(state): State<AppState>,
    Extension(session): Extension<SessionUser>,
    Query(q): Query<PathQuery>,
) -> Result<Json<FileHashesResponse>, AppError> {
    let path = q.path.clone();
    let data_dir = state.config.read().await.data_dir.clone();
    let result = spawn_blocking(move || {
        let conn = state.db.get()?;
        let canonical = authorize_read_path(&conn, &session, &path, &data_dir)?;
        calculate_hashes(&canonical)
    })
    .await
    .map_err(|_| AppError::Internal("Task failed".into()))??;
    Ok(Json(result))
}

pub async fn get_volume(
    State(state): State<AppState>,
    Extension(session): Extension<SessionUser>,
    Query(q): Query<PathQuery>,
) -> Result<Json<VolumeInfoResponse>, AppError> {
    let path = q.path.clone();
    let data_dir = state.config.read().await.data_dir.clone();
    let result = spawn_blocking(move || {
        let conn = state.db.get()?;
        let canonical = authorize_read_path(&conn, &session, &path, &data_dir)?;
        volume_info_for_path(&canonical)
    })
    .await
    .map_err(|_| AppError::Internal("Task failed".into()))??;
    Ok(Json(result))
}

pub async fn get_folder_summary(
    State(state): State<AppState>,
    Extension(session): Extension<SessionUser>,
    Query(q): Query<PathQuery>,
) -> Result<Json<FolderSummaryResponse>, AppError> {
    let path = q.path.clone();
    let data_dir = state.config.read().await.data_dir.clone();
    let result = spawn_blocking(move || {
        let conn = state.db.get()?;
        let canonical = authorize_read_path(&conn, &session, &path, &data_dir)?;
        folder_summary(&canonical)
    })
    .await
    .map_err(|_| AppError::Internal("Task failed".into()))??;
    Ok(Json(result))
}