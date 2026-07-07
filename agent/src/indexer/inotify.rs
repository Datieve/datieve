// inotify-based live filesystem watcher.
//
// Watches all directories under each configured watched folder. On any create,
// delete, rename, or attribute change, emits an IndexEvent to the batch writer.
// IN_MOVED_FROM/IN_MOVED_TO pairs are correlated by cookie and translated into
// a rename rather than a delete+create. If no matching TO arrives within 250 ms,
// the FROM is treated as a deletion.
//
// On queue overflow (IN_Q_OVERFLOW), requests a full reconciliation scan.
use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::io;
use std::os::fd::RawFd;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// A buffered IN_MOVED_FROM event waiting for a matching IN_MOVED_TO (same cookie).
struct PendingMove {
    watched_folder_id: i64,
    rel_path: String,
    is_dir: bool,
    when: Instant,
}

use tokio::sync::{mpsc, watch};

use crate::api::ScanStatus;
use crate::db::pool::DbPool;
use crate::error::AppError;
use crate::indexer::matcher::PathMatcher;
use crate::indexer::statx;
use crate::indexer::IndexEvent;

const IN_ATTRIB: u32 = 0x0000_0004;
const IN_CLOSE_WRITE: u32 = 0x0000_0008;
const IN_MOVED_FROM: u32 = 0x0000_0040;
const IN_MOVED_TO: u32 = 0x0000_0080;
const IN_CREATE: u32 = 0x0000_0100;
const IN_DELETE: u32 = 0x0000_0200;
const IN_DELETE_SELF: u32 = 0x0000_0400;
const IN_MOVE_SELF: u32 = 0x0000_0800;
const IN_Q_OVERFLOW: u32 = 0x0000_4000;
const IN_IGNORED: u32 = 0x0000_8000;
const IN_ISDIR: u32 = 0x4000_0000;

const WATCH_MASK: u32 = IN_CREATE
    | IN_DELETE
    | IN_MOVED_FROM
    | IN_MOVED_TO
    | IN_ATTRIB
    | IN_CLOSE_WRITE
    | IN_DELETE_SELF
    | IN_MOVE_SELF;

const S_IFMT: u32 = 0o170000;
const S_IFDIR: u32 = 0o040000;
const S_IFLNK: u32 = 0o120000;
const MAX_USER_WATCHES: &str = "1048576\n";
const MAX_QUEUED_EVENTS: &str = "262144\n";

#[repr(C)]
#[derive(Clone, Copy)]
struct InotifyEvent {
    wd: i32,
    mask: u32,
    cookie: u32,
    len: u32,
}

#[derive(Clone)]
struct InotifyRoot {
    watched_folder_id: i64,
    root: PathBuf,
    matcher: PathMatcher,
    /// Absolute path of the agent's own data directory  - always excluded from indexing
    /// to prevent the self-indexing loop (DB writes -> inotify events -> DB writes...).
    agent_data_dir: Option<PathBuf>,
}

#[derive(Clone)]
struct WatchEntry {
    root_index: usize,
    path: PathBuf,
}

pub fn probe_path(path: &str) -> Result<(), String> {
    let fd = inotify_init_fd().map_err(|e| format!("inotify_init failed: {e}"))?;
    let result = add_watch(fd, Path::new(path));
    close_fd(fd);
    result
        .map(|_| ())
        .map_err(|e| format!("inotify add watch failed for {path}: {e}"))
}

pub fn spawn_inotify_watcher(
    db: DbPool,
    tx: mpsc::Sender<IndexEvent>,
    status_tx: watch::Sender<ScanStatus>,
    agent_data_dir: Option<PathBuf>,
) {
    tune_inotify_limits();
    let agent_data_dir_canon = agent_data_dir
        .as_deref()
        .and_then(|p| std::fs::canonicalize(p).ok().or_else(|| Some(p.to_path_buf())));
    tokio::task::spawn_blocking(move || loop {
        let roots = match load_inotify_roots(&db, agent_data_dir_canon.clone()) {
            Ok(roots) => roots,
            Err(e) => {
                tracing::warn!("Failed to load inotify watched roots: {e}");
                std::thread::sleep(Duration::from_secs(10));
                continue;
            }
        };

        if roots.is_empty() {
            std::thread::sleep(Duration::from_secs(10));
            continue;
        }

        let fd = match inotify_init_fd() {
            Ok(fd) => fd,
            Err(e) => {
                tracing::error!("inotify_init failed: {e}");
                let _ = status_tx.send(ScanStatus::WaitingForSnapshotSync);
                std::thread::sleep(Duration::from_secs(10));
                continue;
            }
        };

        let mut watches = HashMap::new();
        let mut failed_watches = 0usize;
        for (root_index, root) in roots.iter().enumerate() {
            failed_watches += add_watch_tree(fd, root_index, &root.root, &roots, &mut watches);
        }
        if failed_watches > 0 {
            tracing::warn!(
                "Failed to install {failed_watches} inotify watches; live tracking may be incomplete until the next full reconciliation"
            );
        }

        let root_signature = roots_signature(&roots);
        let mut next_reload_check = Instant::now() + Duration::from_secs(60);
        // Cookie-keyed map of buffered IN_MOVED_FROM events awaiting a matching IN_MOVED_TO.
        let mut pending_moves: HashMap<u32, PendingMove> = HashMap::new();
        loop {
            match drain_events(fd, &roots, &mut watches, &tx, &status_tx, &mut pending_moves) {
                Ok(()) => {
                    // Expire pending moves older than 250 ms  - no matching IN_MOVED_TO arrived,
                    // so the source was moved outside the watched tree: emit FileRemoved.
                    let now = Instant::now();
                    let stale: Vec<u32> = pending_moves
                        .iter()
                        .filter(|(_, m)| now.duration_since(m.when) > Duration::from_millis(250))
                        .map(|(k, _)| *k)
                        .collect();
                    for cookie in stale {
                        if let Some(m) = pending_moves.remove(&cookie) {
                            let ev = if m.is_dir {
                                IndexEvent::FolderRemoved {
                                    watched_folder_id: m.watched_folder_id,
                                    path: m.rel_path,
                                }
                            } else {
                                IndexEvent::FileRemoved {
                                    watched_folder_id: m.watched_folder_id,
                                    path: m.rel_path,
                                }
                            };
                            let _ = tx.blocking_send(ev);
                        }
                    }
                    // Brief yield after processing a batch so a busy event stream
                    // (e.g. large copy in progress) doesn't pin the CPU core.
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(100));
                }
                Err(e) => {
                    tracing::warn!("inotify read failed: {e}");
                    break;
                }
            }
            if Instant::now() >= next_reload_check {
                next_reload_check = Instant::now() + Duration::from_secs(60);
                match load_inotify_roots(&db, agent_data_dir_canon.clone()) {
                    Ok(updated_roots) if roots_signature(&updated_roots) != root_signature => {
                        tracing::info!("Watched folders changed; rebuilding inotify watches");
                        break;
                    }
                    Ok(_) => {}
                    Err(e) => tracing::warn!("Failed to reload inotify watched roots: {e}"),
                }
            }
        }

        close_fd(fd);
    });
}

fn roots_signature(roots: &[InotifyRoot]) -> Vec<(i64, PathBuf)> {
    roots
        .iter()
        .map(|root| (root.watched_folder_id, root.root.clone()))
        .collect()
}

fn tune_inotify_limits() {
    tracing::warn!(
        "Run these two commands on your NAS (as root) to allow Datieve to watch large directory trees:\n  \
         sudo sysctl -w fs.inotify.max_user_watches={}\n  \
         sudo sysctl -w fs.inotify.max_queued_events={}\n  \
         To make them permanent, add them to /etc/sysctl.conf.",
        MAX_USER_WATCHES.trim(),
        MAX_QUEUED_EVENTS.trim(),
    );
}

fn load_inotify_roots(db: &DbPool, agent_data_dir: Option<PathBuf>) -> Result<Vec<InotifyRoot>, AppError> {
    let conn = db.get()?;
    let scope = crate::engine::scope_tag();
    let mut stmt = conn.prepare(
        "SELECT id, path, exclusion_patterns FROM watched_folders WHERE scope_tag = ? ORDER BY id",
    )?;
    let rows = stmt.query_map([scope], |row| {
        let id: i64 = row.get(0)?;
        let path: String = row.get(1)?;
        let patterns_json: String = row.get(2)?;
        Ok((id, path, patterns_json))
    })?;

    let mut roots = Vec::new();
    for row in rows {
        let (watched_folder_id, path, patterns_json) = row?;
        let canonical = std::fs::canonicalize(&path).unwrap_or_else(|_| PathBuf::from(&path));
        roots.push(InotifyRoot {
            watched_folder_id,
            root: canonical,
            matcher: PathMatcher::new(&super::parse_exclusions(&patterns_json)),
            agent_data_dir: agent_data_dir.clone(),
        });
    }
    Ok(roots)
}

fn inotify_init_fd() -> io::Result<RawFd> {
    let fd = unsafe { libc::inotify_init1(libc::IN_CLOEXEC | libc::IN_NONBLOCK) };
    if fd < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(fd)
    }
}

fn add_watch(fd: RawFd, path: &Path) -> io::Result<i32> {
    let path_cstr = CString::new(path.as_os_str().as_bytes())?;
    let wd = unsafe { libc::inotify_add_watch(fd, path_cstr.as_ptr(), WATCH_MASK) };
    if wd < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(wd)
    }
}

fn add_watch_tree(
    fd: RawFd,
    root_index: usize,
    start: &Path,
    roots: &[InotifyRoot],
    watches: &mut HashMap<i32, WatchEntry>,
) -> usize {
    let mut failed = 0usize;
    let mut stack = vec![start.to_path_buf()];
    while let Some(path) = stack.pop() {
        let root = &roots[root_index];
        if is_excluded(root, &path) {
            continue;
        }

        match add_watch(fd, &path) {
            Ok(wd) => {
                watches.insert(
                    wd,
                    WatchEntry {
                        root_index,
                        path: path.clone(),
                    },
                );
            }
            Err(e) => {
                failed += 1;
                tracing::debug!("Could not add inotify watch for {}: {e}", path.display());
                continue;
            }
        }

        let Ok(entries) = std::fs::read_dir(&path) else {
            continue;
        };
        for entry in entries.flatten() {
            let child = entry.path();
            let Ok(file_type) = entry.file_type() else {
                continue;
            };
            if file_type.is_dir() && !file_type.is_symlink() {
                stack.push(child);
            }
        }
    }
    failed
}

fn drain_events(
    fd: RawFd,
    roots: &[InotifyRoot],
    watches: &mut HashMap<i32, WatchEntry>,
    tx: &mpsc::Sender<IndexEvent>,
    status_tx: &watch::Sender<ScanStatus>,
    pending_moves: &mut HashMap<u32, PendingMove>,
) -> io::Result<()> {
    let mut buf = [0u8; 128 * 1024];
    let len = unsafe { libc::read(fd, buf.as_mut_ptr().cast(), buf.len()) };
    if len < 0 {
        return Err(io::Error::last_os_error());
    }
    let len = len as usize;
    let mut offset = 0usize;
    while offset + std::mem::size_of::<InotifyEvent>() <= len {
        let event =
            unsafe { std::ptr::read_unaligned(buf.as_ptr().add(offset).cast::<InotifyEvent>()) };
        let name_start = offset + std::mem::size_of::<InotifyEvent>();
        let name_end = name_start.saturating_add(event.len as usize);
        if name_end > len {
            break;
        }
        let name = if event.len > 0 {
            let raw = &buf[name_start..name_end];
            CStr::from_bytes_until_nul(raw)
                .ok()
                .and_then(|name| name.to_str().ok())
                .unwrap_or_default()
        } else {
            ""
        };

        process_event(fd, event, name, roots, watches, tx, status_tx, pending_moves);
        offset = name_end;
    }
    Ok(())
}

fn process_event(
    fd: RawFd,
    event: InotifyEvent,
    name: &str,
    roots: &[InotifyRoot],
    watches: &mut HashMap<i32, WatchEntry>,
    tx: &mpsc::Sender<IndexEvent>,
    status_tx: &watch::Sender<ScanStatus>,
    pending_moves: &mut HashMap<u32, PendingMove>,
) {
    if (event.mask & IN_Q_OVERFLOW) != 0 {
        tracing::error!("inotify queue overflow; scheduling full reconciliation");
        let _ = status_tx.send(ScanStatus::WaitingForSnapshotSync);
        let _ = tx.blocking_send(IndexEvent::FullRescanRequested {
            reason: "inotify queue overflow".to_string(),
        });
        return;
    }

    if (event.mask & IN_IGNORED) != 0 {
        watches.remove(&event.wd);
        return;
    }

    let Some(watch) = watches.get(&event.wd).cloned() else {
        return;
    };
    let root = &roots[watch.root_index];
    let abs_path = if name.is_empty() {
        watch.path
    } else {
        watch.path.join(name)
    };
    if is_excluded(root, &abs_path) {
        return;
    }
    let rel = relative_path(root, &abs_path);
    let is_dir = (event.mask & IN_ISDIR) != 0;

    if (event.mask & (IN_DELETE_SELF | IN_MOVE_SELF)) != 0 {
        // The parent directory's IN_DELETE / IN_MOVED_FROM already emits FolderRemoved.
        // Don't trigger a full rescan  - just let the parent events update the DB.
        return;
    }

    // Actual deletion  - emit FileRemoved/FolderRemoved immediately.
    if (event.mask & IN_DELETE) != 0 {
        let ev = if is_dir {
            IndexEvent::FolderRemoved { watched_folder_id: root.watched_folder_id, path: rel }
        } else {
            IndexEvent::FileRemoved { watched_folder_id: root.watched_folder_id, path: rel }
        };
        let _ = tx.blocking_send(ev);
        return;
    }

    // Source of a move  - buffer it by cookie. If a matching IN_MOVED_TO arrives
    // (same cookie, internal rename), we cancel the deletion. If no match arrives
    // within 250 ms, the expiry loop in the outer watcher emits FileRemoved.
    if (event.mask & IN_MOVED_FROM) != 0 && event.cookie != 0 {
        pending_moves.insert(event.cookie, PendingMove {
            watched_folder_id: root.watched_folder_id,
            rel_path: rel,
            is_dir,
            when: Instant::now(),
        });
        return;
    }

    // Destination of a move.
    if (event.mask & IN_MOVED_TO) != 0 {
        // If the source was inside the watched tree, emit removal at the old path so the
        // source folder's file_count (and all ancestors) are decremented immediately.
        if let Some(pending) = pending_moves.remove(&event.cookie) {
            let removal = if pending.is_dir {
                IndexEvent::FolderRemoved { watched_folder_id: pending.watched_folder_id, path: pending.rel_path }
            } else {
                IndexEvent::FileRemoved { watched_folder_id: pending.watched_folder_id, path: pending.rel_path }
            };
            let _ = tx.blocking_send(removal);
        }

        if is_dir {
            let failed = add_watch_tree(fd, watch.root_index, &abs_path, roots, watches);
            if failed > 0 {
                tracing::warn!(
                    "Failed to install {failed} inotify watches under moved directory {}; live tracking may be incomplete",
                    abs_path.display()
                );
            }
        }
        // Upsert the entry at its new path.
        if let Some(ev) = upsert_event(root, &abs_path, rel) {
            let _ = tx.blocking_send(ev);
        }
        return;
    }

    if is_dir && (event.mask & IN_CREATE) != 0 {
        let failed = add_watch_tree(fd, watch.root_index, &abs_path, roots, watches);
        if failed > 0 {
            tracing::warn!(
                "Failed to install {failed} inotify watches under {}; live tracking may be incomplete",
                abs_path.display()
            );
        }
    }

    if event.mask & (IN_CREATE | IN_ATTRIB | IN_CLOSE_WRITE) == 0 {
        return;
    }

    if let Some(ev) = upsert_event(root, &abs_path, rel) {
        let _ = tx.blocking_send(ev);
    }
}

/// Path relative to the watched root, e.g. `/docs/file.txt` - matches the
/// format scanner.rs's `relative_path_str` produces for the initial scan.
///
/// This used to just return the absolute path unchanged, which the writer
/// then split on `/` to build the folder hierarchy - recreating the OS's
/// entire real directory structure as a nested, duplicated tree *inside*
/// the actual watched folder (and since the watched root's own leaf name
/// is one of those path components, it would reappear as a phantom child
/// of itself).
fn relative_path(root: &InotifyRoot, abs: &Path) -> String {
    let relative = abs
        .strip_prefix(&root.root)
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|_| abs.to_string_lossy().into_owned());
    if relative.starts_with('/') {
        relative
    } else {
        format!("/{relative}")
    }
}

fn is_excluded(root: &InotifyRoot, abs: &Path) -> bool {
    // Always exclude the agent's own data directory  - DB writes would cause a self-indexing loop.
    if let Some(data_dir) = &root.agent_data_dir {
        if abs.starts_with(data_dir) || abs == data_dir.as_path() {
            return true;
        }
    }
    let name = abs
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or_default();
    let path = abs.to_string_lossy();
    let rel = abs
        .strip_prefix(&root.root)
        .map(|path| format!("/{}", path.to_string_lossy().trim_start_matches('/')))
        .unwrap_or_else(|_| path.to_string());
    super::is_internal_exclude_name(name)
        || root.matcher.is_excluded(name)
        || root.matcher.is_excluded(&rel)
        || root.matcher.is_excluded(&path)
}

fn upsert_event(root: &InotifyRoot, abs: &Path, rel: String) -> Option<IndexEvent> {
    let cstr = CString::new(abs.as_os_str().as_bytes()).ok()?;
    let st = statx::stat_file(cstr.as_ptr()).ok()?;
    let is_dir = (st.mode & S_IFMT) == S_IFDIR;
    let name = abs.file_name()?.to_string_lossy().to_string();

    if is_dir {
        let dir_created_at = st.btime.and_then(|(s, n)| chrono::DateTime::from_timestamp(s, n));
        return Some(IndexEvent::FolderFound {
            watched_folder_id: root.watched_folder_id,
            path: rel,
            name,
            device_id: Some(st.dev),
            inode: Some(st.ino),
            scan_generation: None,
            created_at: dir_created_at,
        });
    }

    let modified_at = chrono::DateTime::from_timestamp(st.mtime_sec, st.mtime_nsec)
        .unwrap_or_else(chrono::Utc::now);
    let created_at = st
        .btime
        .and_then(|(s, n)| chrono::DateTime::from_timestamp(s, n))
        .unwrap_or(modified_at);
    let extension = abs
        .extension()
        .and_then(|ext| ext.to_str())
        .map(str::to_string);
    Some(IndexEvent::FileFound {
        watched_folder_id: root.watched_folder_id,
        path: rel,
        absolute_path: abs.to_string_lossy().into_owned(),
        name,
        extension,
        size_bytes: st.size,
        created_at,
        modified_at,
        device_id: Some(st.dev),
        inode: Some(st.ino),
        is_symlink: (st.mode & S_IFMT) == S_IFLNK,
        scan_generation: None,
    })
}

fn close_fd(fd: RawFd) {
    if fd >= 0 {
        unsafe {
            libc::close(fd);
        }
    }
}
