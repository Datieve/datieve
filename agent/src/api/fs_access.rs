// Path authorization and filesystem safety layer.
//
// Before any fs operation, the requested path must pass through here:
//   1. Must be inside a watched folder the session has access to.
//   2. Must not escape the watched root (no symlink traversal, no ../.. tricks).
//   3. Must not target a blocked system prefix (/proc, /sys, /dev, etc.).
//
// Returns AuthorizedPath on success, AppError::Forbidden on any violation.
use std::path::{Path, PathBuf};

use rusqlite::{Connection, OptionalExtension};

use crate::api::admin::BLOCKED_PREFIXES;
use crate::api::middleware::SessionUser;
use crate::error::AppError;

pub struct AuthorizedPath {
    pub canonical: PathBuf,
    pub watched_folder_id: i64,
    pub watched_folder_root: PathBuf,
}

pub fn map_fs_error(err: std::io::Error, action: &str, path: &Path) -> AppError {
    match err.kind() {
        std::io::ErrorKind::PermissionDenied => AppError::Forbidden(format!(
            "Permission denied: cannot {} '{}'. The NAS user running the agent does not have access.",
            action,
            path.display()
        )),
        std::io::ErrorKind::NotFound => AppError::NotFound,
        _ => {
            tracing::warn!("Filesystem {} failed for {}: {}", action, path.display(), err);
            AppError::BadRequest(format!(
                "Could not {} '{}': {}",
                action,
                path.display(),
                err
            ))
        }
    }
}

pub fn is_safe_filename(name: &str) -> bool {
    !name.is_empty()
        && name != "."
        && name != ".."
        && name.len() < 256
        && !name.contains('/')
        && !name.contains('\\')
        && !name.bytes().any(|b| b == 0)
}

fn canonicalize_for_access(path: &Path) -> Result<PathBuf, AppError> {
    let normalized = crate::api::admin::normalize_path(path.to_string_lossy().as_ref())?;
    std::fs::canonicalize(&normalized).map_err(|e| map_fs_error(e, "access", &normalized))
}

fn is_blocked_system_path(path: &Path) -> bool {
    path == Path::new("/")
        || BLOCKED_PREFIXES
            .iter()
            .any(|pfx| path.starts_with(Path::new(pfx)))
}

fn is_under_agent_data(path: &Path, data_dir: &Path) -> bool {
    let data = std::fs::canonicalize(data_dir).unwrap_or_else(|_| data_dir.to_path_buf());
    let target = std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    target == data || target.starts_with(data.join(""))
}

fn relative_within_root(root: &Path, path: &Path) -> String {
    path.strip_prefix(root)
        .map(|rel| rel.to_string_lossy().replace('\\', "/"))
        .unwrap_or_default()
}

pub(crate) fn user_can_access_relative(
    conn: &Connection,
    session: &SessionUser,
    watched_folder_id: i64,
    relative: &str,
) -> Result<bool, AppError> {
    if session.role == "admin" {
        return Ok(true);
    }
    let Some(user_id) = session.user_id else {
        return Ok(false);
    };
    let scope = crate::engine::scope_tag();
    let mut stmt = conn.prepare(
        "SELECT path_prefix FROM user_folders
         WHERE user_id = ? AND watched_folder_id = ? AND scope_tag = ?",
    )?;
    let rows = stmt.query_map(rusqlite::params![user_id, watched_folder_id, scope], |row| {
        row.get::<_, Option<String>>(0)
    })?;

    let mut saw_grant = false;
    for row in rows {
        let prefix = row?;
        saw_grant = true;
        match prefix {
            None => return Ok(true),
            Some(p) if p.trim().is_empty() => return Ok(true),
            Some(p) => {
                if relative == p.as_str()
                    || relative.starts_with(&format!("{}/", p.trim_end_matches('/')))
                {
                    return Ok(true);
                }
            }
        }
    }

    if !saw_grant {
        return Ok(false);
    }
    Ok(false)
}

pub fn authorize_path(
    conn: &Connection,
    session: &SessionUser,
    raw_path: &str,
    data_dir: &Path,
) -> Result<AuthorizedPath, AppError> {
    let canonical = canonicalize_for_access(Path::new(raw_path))?;

    if is_blocked_system_path(&canonical) {
        return Err(AppError::Forbidden(
            "This path is blocked for file operations.".into(),
        ));
    }
    if is_under_agent_data(&canonical, data_dir) {
        return Err(AppError::Forbidden(
            "Cannot modify the agent's own data directory.".into(),
        ));
    }

    if session.allowed_folder_ids.is_empty() {
        return Err(AppError::Forbidden(
            "You do not have access to any indexed folders.".into(),
        ));
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

    let mut best: Option<(i64, PathBuf)> = None;
    for row in rows {
        let (id, root_str) = row?;
        let root = PathBuf::from(&root_str);
        let root_canon = std::fs::canonicalize(&root).unwrap_or(root);
        if canonical == root_canon || canonical.starts_with(root_canon.join("")) {
            best = Some((id, root_canon));
            break;
        }
    }

    let Some((watched_folder_id, root)) = best else {
        return Err(AppError::Forbidden(format!(
            "Path '{}' is outside your indexed NAS folders.",
            canonical.display()
        )));
    };

    let relative = relative_within_root(&root, &canonical);
    if !user_can_access_relative(conn, session, watched_folder_id, &relative)? {
        return Err(AppError::Forbidden(format!(
            "You do not have permission to access '{}'.",
            canonical.display()
        )));
    }

    Ok(AuthorizedPath {
        canonical,
        watched_folder_id,
        watched_folder_root: root,
    })
}

pub fn authorize_parent_for_create(
    conn: &Connection,
    session: &SessionUser,
    parent_dir: &str,
    data_dir: &Path,
) -> Result<PathBuf, AppError> {
    let parent = authorize_path(conn, session, parent_dir, data_dir)?;
    let meta = parent
        .canonical
        .symlink_metadata()
        .map_err(|e| map_fs_error(e, "access", &parent.canonical))?;
    if !meta.is_dir() {
        return Err(AppError::BadRequest(
            "Parent path is not a directory.".into(),
        ));
    }
    Ok(parent.canonical)
}

fn resolve_collision_dest(
    dest: &Path,
    collision: &str,
) -> Result<Option<PathBuf>, AppError> {
    if !dest.exists() {
        return Ok(Some(dest.to_path_buf()));
    }
    match collision {
        "skip" => Ok(None),
        "replace" => {
            let meta = dest
                .symlink_metadata()
                .map_err(|e| map_fs_error(e, "replace", dest))?;
            if meta.is_dir() {
                std::fs::remove_dir_all(dest).map_err(|e| map_fs_error(e, "replace", dest))?;
            } else {
                std::fs::remove_file(dest).map_err(|e| map_fs_error(e, "replace", dest))?;
            }
            Ok(Some(dest.to_path_buf()))
        }
        "fail" => Err(AppError::BadRequest(format!(
            "Destination already exists: {}",
            dest.display()
        ))),
        _ => Ok(Some(unique_path_for_collision(dest)?)),
    }
}

fn unique_path_for_collision(dest: &Path) -> Result<PathBuf, AppError> {
    let parent = dest
        .parent()
        .ok_or_else(|| AppError::BadRequest("No parent directory.".into()))?;
    let file_name = dest
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or_else(|| AppError::BadRequest("Invalid file name.".into()))?;
    let (stem, ext) = if dest.extension().is_some() && dest.is_file() {
        let stem = dest
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or(file_name);
        let ext = dest.extension().and_then(|e| e.to_str()).unwrap_or("");
        (stem.to_string(), ext.to_string())
    } else {
        (file_name.to_string(), String::new())
    };

    for index in 1..10_000 {
        let suffix = if index == 1 {
            " copy".to_string()
        } else {
            format!(" copy {}", index)
        };
        let candidate_name = if ext.is_empty() {
            format!("{}{}", stem, suffix)
        } else {
            format!("{}{}.{}", stem, suffix, ext)
        };
        let candidate = parent.join(candidate_name);
        if !candidate.exists() {
            return Ok(candidate);
        }
    }
    Err(AppError::BadRequest(
        "Could not find a free collision name.".into(),
    ))
}

static COPY_SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

fn temp_name() -> String {
    let seq = COPY_SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    format!(".datieve_tmp_{}_{}", std::process::id(), seq)
}

fn copy_dir_recursive(src: &Path, dest: &Path) -> Result<(), AppError> {
    use std::collections::VecDeque;
    let mut work: VecDeque<(std::path::PathBuf, std::path::PathBuf)> = VecDeque::new();
    work.push_back((src.to_path_buf(), dest.to_path_buf()));
    while let Some((src_dir, dest_dir)) = work.pop_front() {
        std::fs::create_dir_all(&dest_dir).map_err(|e| map_fs_error(e, "create", &dest_dir))?;
        for entry in std::fs::read_dir(&src_dir).map_err(|e| map_fs_error(e, "read", &src_dir))? {
            let entry = entry.map_err(|e| map_fs_error(e, "read", &src_dir))?;
            let child_dest = dest_dir.join(entry.file_name());
            // file_type() does not follow symlinks  - safe against directory symlink loops
            let file_type = entry.file_type().map_err(|e| map_fs_error(e, "read", &entry.path()))?;
            if file_type.is_symlink() {
                let target = std::fs::read_link(entry.path())
                    .map_err(|e| map_fs_error(e, "read", &entry.path()))?;
                #[cfg(unix)]
                std::os::unix::fs::symlink(&target, &child_dest)
                    .map_err(|e| map_fs_error(e, "copy", &child_dest))?;
            } else if file_type.is_dir() {
                work.push_back((entry.path(), child_dest));
            } else {
                copy_file_atomic(&entry.path(), &child_dest)?;
            }
        }
    }
    Ok(())
}

fn copy_file_atomic(src: &Path, dest: &Path) -> Result<(), AppError> {
    let parent = dest.parent().ok_or_else(|| {
        AppError::BadRequest(format!("No parent directory for {}", dest.display()))
    })?;
    let tmp = parent.join(temp_name());
    let result = std::fs::copy(src, &tmp).map_err(|e| map_fs_error(e, "copy", dest));
    match result {
        Ok(_) => {
            if let Err(e) = std::fs::rename(&tmp, dest) {
                let _ = std::fs::remove_file(&tmp);
                Err(map_fs_error(e, "finalize copy", dest))
            } else {
                Ok(())
            }
        }
        Err(e) => {
            let _ = std::fs::remove_file(&tmp);
            Err(e)
        }
    }
}

fn copy_entry_to(src: &Path, dest: &Path) -> Result<(), AppError> {
    let meta = src
        .symlink_metadata()
        .map_err(|e| map_fs_error(e, "read", src))?;
    if meta.file_type().is_symlink() {
        let target = std::fs::read_link(src).map_err(|e| map_fs_error(e, "read", src))?;
        #[cfg(unix)]
        std::os::unix::fs::symlink(&target, dest).map_err(|e| map_fs_error(e, "copy", dest))?;
        #[cfg(not(unix))]
        return Err(AppError::BadRequest(
            "Symlink copy is not supported on this platform.".into(),
        ));
        return Ok(());
    }
    if meta.is_dir() {
        // Copy into a temp dir alongside the dest, then atomically rename.
        let parent = dest.parent().ok_or_else(|| {
            AppError::BadRequest(format!("No parent for {}", dest.display()))
        })?;
        let tmp = parent.join(temp_name());
        let result = copy_dir_recursive(src, &tmp);
        match result {
            Ok(()) => {
                if let Err(e) = std::fs::rename(&tmp, dest) {
                    let _ = std::fs::remove_dir_all(&tmp);
                    return Err(map_fs_error(e, "finalize copy", dest));
                }
            }
            Err(e) => {
                let _ = std::fs::remove_dir_all(&tmp);
                return Err(e);
            }
        }
    } else {
        copy_file_atomic(src, dest)?;
    }
    Ok(())
}

pub fn copy_entry(
    src: &Path,
    dest_dir: &Path,
    collision: &str,
) -> Result<(), AppError> {
    if src.is_dir() && dest_dir.starts_with(src) {
        return Err(AppError::BadRequest(
            "Cannot copy a folder into itself.".into(),
        ));
    }
    let name = src
        .file_name()
        .ok_or_else(|| AppError::BadRequest("No file name.".into()))?;
    let dest = dest_dir.join(name);
    if let Some(dest) = resolve_collision_dest(&dest, collision)? {
        copy_entry_to(src, &dest)
    } else {
        Ok(())
    }
}

pub fn move_entry(
    src: &Path,
    dest_dir: &Path,
    collision: &str,
) -> Result<(), AppError> {
    if src.is_dir() && dest_dir.starts_with(src) {
        return Err(AppError::BadRequest(
            "Cannot move a folder into itself.".into(),
        ));
    }
    let name = src
        .file_name()
        .ok_or_else(|| AppError::BadRequest("No file name.".into()))?;
    let dest = dest_dir.join(name);
    let Some(dest) = resolve_collision_dest(&dest, collision)? else {
        return Ok(());
    };
    if std::fs::rename(src, &dest).is_err() {
        copy_entry_to(src, &dest)?;
        let meta = src
            .symlink_metadata()
            .map_err(|e| map_fs_error(e, "move", src))?;
        if meta.is_dir() {
            std::fs::remove_dir_all(src).map_err(|e| map_fs_error(e, "delete", src))?;
        } else {
            std::fs::remove_file(src).map_err(|e| map_fs_error(e, "delete", src))?;
        }
    }
    Ok(())
}

pub fn delete_path(path: &Path) -> Result<(), AppError> {
    let meta = path
        .symlink_metadata()
        .map_err(|e| map_fs_error(e, "delete", path))?;
    if meta.is_dir() && !meta.file_type().is_symlink() {
        std::fs::remove_dir_all(path).map_err(|e| map_fs_error(e, "delete", path))
    } else {
        std::fs::remove_file(path).map_err(|e| map_fs_error(e, "delete", path))
    }
}

pub fn duplicate_path_for(src: &Path) -> Result<PathBuf, AppError> {
    let parent = src
        .parent()
        .ok_or_else(|| AppError::BadRequest("No parent directory.".into()))?;
    let file_name = src
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or_else(|| AppError::BadRequest("Invalid file name.".into()))?;
    let meta = src
        .symlink_metadata()
        .map_err(|e| map_fs_error(e, "read", src))?;
    let (stem, ext) = if meta.is_file() && !meta.file_type().is_symlink() {
        let stem = src
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or(file_name);
        let ext = src.extension().and_then(|e| e.to_str()).unwrap_or("");
        (stem.to_string(), ext.to_string())
    } else {
        (file_name.to_string(), String::new())
    };
    for index in 1..10_000 {
        let suffix = if index == 1 {
            " copy".to_string()
        } else {
            format!(" copy {}", index)
        };
        let candidate_name = if ext.is_empty() {
            format!("{}{}", stem, suffix)
        } else {
            format!("{}{}.{}", stem, suffix, ext)
        };
        let candidate = parent.join(candidate_name);
        if !candidate.exists() {
            return Ok(candidate);
        }
    }
    Err(AppError::BadRequest(
        "Could not find a free duplicate name.".into(),
    ))
}

pub fn duplicate_entry(src: &Path) -> Result<PathBuf, AppError> {
    let dest = duplicate_path_for(src)?;
    copy_entry_to(src, &dest)?;
    Ok(dest)
}

pub fn bulk_rename_paths(paths: &[String], base_name: &str) -> Result<Vec<String>, AppError> {
    let base = base_name.trim();
    if !is_safe_filename(base) || base.contains('.') {
        return Err(AppError::BadRequest(
            "Enter a valid base name without an extension.".into(),
        ));
    }
    if paths.len() < 2 {
        return Err(AppError::BadRequest(
            "Select at least two items to bulk rename.".into(),
        ));
    }
    if paths.len() > 500 {
        return Err(AppError::BadRequest(
            "Bulk rename is limited to 500 items at a time.".into(),
        ));
    }

    let mut planned: Vec<(PathBuf, PathBuf)> = Vec::new();
    let mut reserved = std::collections::HashSet::<PathBuf>::new();

    for (index, path) in paths.iter().enumerate() {
        let canonical = canonicalize_for_access(Path::new(path))?;
        let parent = canonical
            .parent()
            .ok_or_else(|| AppError::BadRequest("No parent directory.".into()))?;
        let meta = canonical
            .symlink_metadata()
            .map_err(|e| map_fs_error(e, "read", &canonical))?;
        let ext = if meta.is_file() && !meta.file_type().is_symlink() {
            canonical.extension().and_then(|e| e.to_str()).unwrap_or("")
        } else {
            ""
        };
        let candidate_name = if ext.is_empty() {
            format!("{} {}", base, index + 1)
        } else {
            format!("{} {}.{}", base, index + 1, ext)
        };
        if !is_safe_filename(&candidate_name) {
            return Err(AppError::BadRequest("Generated file name is invalid.".into()));
        }
        let mut dest = parent.join(candidate_name);
        if dest.exists() || reserved.contains(&dest) {
            dest = unique_path_for_collision(&dest)?;
            while reserved.contains(&dest) {
                dest = unique_path_for_collision(&dest)?;
            }
        }
        reserved.insert(dest.clone());
        planned.push((canonical, dest));
    }

    let mut renamed = Vec::with_capacity(planned.len());
    for (source, dest) in planned {
        std::fs::rename(&source, &dest).map_err(|e| map_fs_error(e, "rename", &source))?;
        renamed.push(dest.to_string_lossy().into_owned());
    }
    Ok(renamed)
}

pub fn compress_paths(paths: &[PathBuf], dest_dir: &Path, format: &str) -> Result<(), AppError> {
    if paths.is_empty() {
        return Err(AppError::BadRequest("No paths provided.".into()));
    }
    let base_name = paths[0]
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "archive".to_string());
    let archive_name = format!("{}.{}", base_name, format.to_lowercase());
    let archive_path = dest_dir.join(&archive_name);
    let archive_str = archive_path
        .to_str()
        .ok_or_else(|| AppError::BadRequest("Invalid archive path.".into()))?;
    let path_args: Vec<String> = paths
        .iter()
        .map(|p| p.to_string_lossy().into_owned())
        .collect();

    let status = match format.to_lowercase().as_str() {
        "zip" => std::process::Command::new("zip")
            .arg("-r")
            .arg(archive_str)
            .args(&path_args)
            .current_dir(dest_dir)
            .status()
            .map_err(|_| {
                AppError::BadRequest("zip not found. Install the zip package on the NAS.".into())
            })?,
        "7z" => std::process::Command::new("7z")
            .arg("a")
            .arg(archive_str)
            .args(&path_args)
            .current_dir(dest_dir)
            .status()
            .map_err(|_| {
                AppError::BadRequest("7z not found. Install p7zip on the NAS.".into())
            })?,
        _ => return Err(AppError::BadRequest(format!("Unsupported format: {}", format))),
    };
    if !status.success() {
        return Err(AppError::BadRequest(format!(
            "Compression failed (exit {:?})",
            status.code()
        )));
    }
    Ok(())
}

pub fn extract_archive(path: &Path, dest_dir: &Path) -> Result<(), AppError> {
    let path_str = path.to_string_lossy();
    let dest_str = dest_dir.to_string_lossy();
    if std::process::Command::new("7z")
        .args(["x", path_str.as_ref(), &format!("-o{}", dest_str.as_ref()), "-y"])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
    {
        return Ok(());
    }
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_lowercase();
    if ext == "zip"
        && std::process::Command::new("unzip")
            .args(["-o", path_str.as_ref(), "-d", dest_str.as_ref()])
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
    {
        return Ok(());
    }
    Err(AppError::BadRequest(
        "Could not extract. Install 7z or unzip on the NAS.".into(),
    ))
}

pub fn rotate_image_path(path: &Path, direction: &str) -> Result<(), AppError> {
    let p = path.to_string_lossy();
    let degrees = if direction == "left" { "270" } else { "90" };
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_lowercase();
    if ext == "jpg" || ext == "jpeg" {
        let tmp = format!("{}.tmp_rotate", p);
        if std::process::Command::new("jpegtran")
            .args(["-rotate", degrees, "-copy", "all", "-outfile", &tmp, p.as_ref()])
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
        {
            std::fs::rename(&tmp, path).map_err(|e| map_fs_error(e, "rotate", path))?;
            return Ok(());
        }
        let _ = std::fs::remove_file(&tmp);
    }
    let status = std::process::Command::new("convert")
        .args(["-rotate", degrees, p.as_ref(), p.as_ref()])
        .status()
        .map_err(|_| {
            AppError::BadRequest(
                "Rotation failed. Install jpegtran or ImageMagick on the NAS.".into(),
            )
        })?;
    if !status.success() {
        return Err(AppError::BadRequest(
            "Rotation failed. Install jpegtran or ImageMagick on the NAS.".into(),
        ));
    }
    Ok(())
}

pub fn is_indexed_live_path(conn: &Connection, absolute_path: &str) -> Result<bool, AppError> {
    let scope = crate::engine::scope_tag();
    let exists: Option<i64> = conn
        .query_row(
            "SELECT 1 FROM files f
             JOIN folders fo ON fo.id = f.folder_id
             JOIN watched_folders wf ON wf.id = fo.watched_folder_id
             WHERE f.is_deleted = 0 AND f.scope_tag = ? AND fo.scope_tag = ? AND wf.scope_tag = ?
               AND (? = wf.path OR ? LIKE wf.path || '/%')
             LIMIT 1",
            rusqlite::params![
                scope,
                scope,
                scope,
                absolute_path,
                absolute_path
            ],
            |row| row.get(0),
        )
        .optional()?;
    if exists.is_some() {
        return Ok(true);
    }
    let exists_folder: Option<i64> = conn
        .query_row(
            "SELECT 1 FROM folders fo
             JOIN watched_folders wf ON wf.id = fo.watched_folder_id
             WHERE fo.is_deleted = 0 AND fo.scope_tag = ? AND wf.scope_tag = ?
               AND (? = wf.path OR ? LIKE wf.path || '/%')
             LIMIT 1",
            rusqlite::params![scope, scope, absolute_path, absolute_path],
            |row| row.get(0),
        )
        .optional()?;
    Ok(exists_folder.is_some())
}

pub type FolderLocks = std::sync::Arc<
    std::sync::RwLock<std::collections::HashMap<PathBuf, std::sync::Arc<tokio::sync::Mutex<()>>>>,
>;

pub async fn acquire_folder_lock(
    locks: &FolderLocks,
    folder: &Path,
) -> tokio::sync::OwnedMutexGuard<()> {
    // Clone the Arc out before any .await so no std::sync guard is held across yield points.
    let maybe_existing = locks.read().unwrap().get(folder).map(|l| l.clone());
    if let Some(lock) = maybe_existing {
        return lock.lock_owned().await;
    }
    let lock = {
        let mut map = locks.write().unwrap();
        map.entry(folder.to_path_buf())
            .or_insert_with(|| std::sync::Arc::new(tokio::sync::Mutex::new(())))
            .clone()
    };
    lock.lock_owned().await
}