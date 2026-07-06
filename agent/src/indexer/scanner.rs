use crate::api::ScanStatus;
use crate::indexer::matcher::PathMatcher;
use crate::indexer::statx;
use crate::db::pool::DbPool;
use crate::error::AppError;
use jwalk::WalkDir;
use libc::{S_IFDIR, S_IFLNK, S_IFMT};
use std::ffi::CString;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;
use tokio::sync::watch;

use super::IndexEvent;

const SCAN_PROGRESS_INTERVAL: u64 = 5_000;

fn relative_path_str(absolute: &Path, root: &str) -> String {
    let relative = absolute
        .strip_prefix(root)
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|_| absolute.to_string_lossy().into_owned());
    if relative.starts_with('/') {
        relative
    } else {
        format!("/{relative}")
    }
}

/// Performs the initial deep traversal of a watched folder using single-threaded statx.
///
/// Serial traversal preserves HDD read locality. Parallel directory walks cause
/// competing threads to seek the disk head randomly.
pub fn spawn_scanner(
    tx: mpsc::Sender<IndexEvent>,
    status_tx: watch::Sender<ScanStatus>,
    watched_folder_id: i64,
    root_path: String,
    exclusion_patterns: Vec<String>,
    files_per_second: u32,
) -> tokio::task::JoinHandle<()> {
    tokio::task::spawn(async move {
        while !std::path::Path::new(&root_path).exists() {
            tracing::warn!("Watched folder {} is missing. Waiting...", root_path);
            let _ = status_tx.send(ScanStatus::FolderUnmounted);
            tokio::time::sleep(tokio::time::Duration::from_secs(30)).await;
        }

        let _ = status_tx.send(ScanStatus::Scanning);

        let _ = tokio::task::spawn_blocking(move || {
            tracing::info!("Starting serial HDD-friendly scan for {}", root_path);

            let matcher = PathMatcher::new(&exclusion_patterns);
            let mut scanned: u64 = 0;
            let root_prefix = root_path.trim_end_matches('/').to_string();
            let scan_started = std::time::Instant::now();
            let scan_generation = chrono::Utc::now()
                .timestamp_nanos_opt()
                .unwrap_or_else(|| chrono::Utc::now().timestamp_micros());
            // 0 means unlimited: skip throttle sleep entirely and saturate the disk.
            let unlimited = files_per_second == 0;
            let files_per_second = if unlimited { u64::MAX } else { files_per_second.clamp(1, 10_000) as u64 };

            if tx
                .blocking_send(IndexEvent::ScanStarted {
                    watched_folder_id,
                    generation: scan_generation,
                })
                .is_err()
            {
                return;
            }

            let walker = WalkDir::new(&root_path)
                .parallelism(jwalk::Parallelism::Serial)
                .process_read_dir({
                    let root_for_filter = root_prefix.clone();
                    let matcher_for_filter = matcher.clone();
                    move |_depth, _path, _read_dir_state, children| {
                        children.retain(|dir_entry_result| {
                            let Ok(e) = dir_entry_result else {
                                return true;
                            };
                            let name = e.file_name.to_string_lossy();
                            if super::is_internal_exclude_name(name.as_ref()) {
                                return false;
                            }
                            let abs = e.path();
                            let rel = relative_path_str(&abs, &root_for_filter);
                            !matcher_for_filter.is_excluded(name.as_ref())
                                && !matcher_for_filter.is_excluded(&rel)
                                && !matcher_for_filter.is_excluded(&abs.to_string_lossy())
                        });
                    }
                });

            for entry in walker {
                let entry = match entry {
                    Ok(e) => e,
                    Err(err) => {
                        tracing::warn!("Scan access error: {}", err);
                        continue;
                    }
                };

                let absolute_path = entry.path();
                let path_bytes = absolute_path.as_os_str().as_bytes();
                let path_cstr = match CString::new(path_bytes) {
                    Ok(c) => c,
                    Err(_) => {
                        tracing::debug!(
                            "Skipping path with interior null byte (unusual/malicious filename)"
                        );
                        continue;
                    }
                };

                let st = match statx::stat_file(path_cstr.as_ptr()) {
                    Ok(st) => st,
                    Err(err) => {
                        tracing::warn!("stat error for {:?}: {}", entry.path(), err);
                        continue;
                    }
                };

                let abs_path_str = absolute_path.to_string_lossy().into_owned();
                let rel_path_str = relative_path_str(&absolute_path, &root_prefix);
                let is_dir = (st.mode & S_IFMT) == S_IFDIR;

                if is_dir {
                    if rel_path_str != "/" {
                        let dir_created_at = st.btime.and_then(|(s, n)| {
                            chrono::DateTime::from_timestamp(s, n)
                        });
                        let event = IndexEvent::FolderFound {
                            watched_folder_id,
                            path: rel_path_str,
                            name: entry.file_name.to_string_lossy().to_string(),
                            device_id: Some(st.dev),
                            inode: Some(st.ino),
                            scan_generation: Some(scan_generation),
                            created_at: dir_created_at,
                        };
                        if tx.blocking_send(event).is_err() {
                            return;
                        }
                    }
                    continue;
                }

                let is_symlink = (st.mode & S_IFMT) == S_IFLNK;
                let name = entry.file_name.to_string_lossy().to_string();
                let extension = Path::new(&name)
                    .extension()
                    .and_then(|e| e.to_str())
                    .map(|s| s.to_string());

                let modified_at = chrono::DateTime::from_timestamp(st.mtime_sec, st.mtime_nsec)
                    .unwrap_or_else(chrono::Utc::now);

                let created_at = st
                    .btime
                    .and_then(|(s, n)| chrono::DateTime::from_timestamp(s, n))
                    .unwrap_or(modified_at);

                let event = IndexEvent::FileFound {
                    watched_folder_id,
                    path: rel_path_str,
                    absolute_path: abs_path_str,
                    name,
                    extension,
                    size_bytes: st.size,
                    created_at,
                    modified_at,
                    device_id: Some(st.dev),
                    inode: Some(st.ino),
                    is_symlink,
                    scan_generation: Some(scan_generation),
                };

                if tx.blocking_send(event).is_err() {
                    return;
                }

                scanned += 1;
                if !unlimited {
                    let target_elapsed =
                        std::time::Duration::from_secs_f64(scanned as f64 / files_per_second as f64);
                    if let Some(delay) = target_elapsed.checked_sub(scan_started.elapsed()) {
                        std::thread::sleep(delay.min(std::time::Duration::from_millis(250)));
                    }
                }

                if scanned % SCAN_PROGRESS_INTERVAL == 0 {
                    tracing::info!(folder_id = watched_folder_id, scanned, "scan progress");
                    let _ = tx.blocking_send(IndexEvent::ScanProgress {
                        watched_folder_id,
                        scanned,
                        total_estimate: None,
                    });
                }
            }

            tracing::info!(
                "Serial scan completed for {}. Total files: {}",
                root_path,
                scanned
            );
            let _ = tx.blocking_send(IndexEvent::ScanComplete {
                watched_folder_id,
                scanned,
            });
        })
        .await;
    })
}

/// Poll for folders marked `pending` and run scanners without restart.
pub fn spawn_pending_scan_watcher(
    db: DbPool,
    tx: mpsc::Sender<IndexEvent>,
    status_tx: watch::Sender<ScanStatus>,
    scan_speed: u32,
    orchestrator: Arc<crate::indexer::scan_orchestrator::ScanOrchestrator>,
) {
    tokio::spawn(async move {
        loop {
            let pending = match load_pending_scans(&db) {
                Ok(rows) => rows,
                Err(e) => {
                    tracing::warn!("Failed to load pending scan jobs: {e}");
                    tokio::time::sleep(Duration::from_secs(5)).await;
                    continue;
                }
            };
            if !pending.is_empty() {
                tracing::info!("Pending scan watcher: {} folder(s) queued, starting now.", pending.len());
            }
            for (id, path, patterns) in pending {
                let Ok(true) = orchestrator.try_claim(&db, id) else {
                    continue;
                };
                tracing::info!("Starting scan for folder {id}: {path}");
                let orch = orchestrator.clone();
                let handle = spawn_scanner(
                    tx.clone(),
                    status_tx.clone(),
                    id,
                    path,
                    patterns,
                    scan_speed,
                );
                let _ = handle.await;
                orch.release(id);
            }
            // Sleep after checking, not before. This means the first check after
            // a FullRescanRequested event happens within 5 seconds, not after 30.
            tokio::time::sleep(Duration::from_secs(5)).await;
        }
    });
}

fn load_pending_scans(db: &DbPool) -> Result<Vec<(i64, String, Vec<String>)>, AppError> {
    let conn = db.get()?;
    let scope = crate::engine::scope_tag();
    let mut stmt = conn.prepare(
        "SELECT id, path, exclusion_patterns FROM watched_folders WHERE scan_status = 'pending' AND scope_tag = ?",
    )?;
    let rows = stmt.query_map([scope], |row| {
        let id: i64 = row.get(0)?;
        let path: String = row.get(1)?;
        let patterns_json: String = row.get(2)?;
        Ok((id, path, super::parse_exclusions(&patterns_json)))
    })?;
    rows.collect::<Result<Vec<_>, _>>()
        .map_err(AppError::Database)
}
