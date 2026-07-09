use std::collections::{HashMap, HashSet};
use std::num::NonZeroUsize;
use std::sync::Arc;
use tokio::sync::mpsc;
use tokio::time::{timeout, Duration};

use lru::LruCache;
use rusqlite::{params, Connection, OptionalExtension, Transaction};

use super::IndexEvent;
use crate::api::ScanStatus;
use crate::error::AppError;
use tokio::sync::watch;

/// Sanitize path components that would corrupt the folder tree (literal "." / ".." / control chars
/// that guests can create). We percent-encode only for hierarchy resolution/storage so the tree
/// remains stable and UNIQUE/parent lookups work. Original names are still stored where possible
/// and used for display/search on the file records themselves.
#[inline]
fn sanitize_for_hierarchy(name: &str) -> String {
    if name == "." || name == ".." || name.is_empty() || name.bytes().any(|b| b < 0x20 || b == 0x7f)
    {
        percent_encoding::percent_encode(name.as_bytes(), percent_encoding::NON_ALPHANUMERIC)
            .to_string()
    } else {
        name.to_string()
    }
}

pub struct WriterState {
    rx: mpsc::Receiver<IndexEvent>,
    conn: Connection,
    /// Fast lookups: (watched_folder_id, full_path) -> folders.id
    folder_cache: LruCache<(i64, String), i64>,
    /// Fast lookups: folder_id -> parent_id
    parent_cache: LruCache<i64, Option<i64>>,
    status_tx: watch::Sender<ScanStatus>,
    file_change_tx: Arc<watch::Sender<u64>>,
}

#[derive(Default)]
struct FolderDelta {
    count_delta: i64,
    size_delta: i64,
}

impl WriterState {
    pub fn new(
        rx: mpsc::Receiver<IndexEvent>,
        conn: Connection,
        status_tx: watch::Sender<ScanStatus>,
        file_change_tx: Arc<watch::Sender<u64>>,
    ) -> Self {
        Self {
            rx,
            conn,
            // Cap caches to avoid runaway memory usage under guest-generated path churn.
            folder_cache: LruCache::new(NonZeroUsize::new(200_000).unwrap()),
            parent_cache: LruCache::new(NonZeroUsize::new(200_000).unwrap()),
            status_tx,
            file_change_tx,
        }
    }

    pub async fn run(mut self, batch_size: usize, flush_interval_ms: u64) {
        let flush_dur = Duration::from_millis(flush_interval_ms);
        let mut buffer: Vec<IndexEvent> = Vec::with_capacity(batch_size);
        let mut flush_count: u64 = 0;
        loop {
            // Wall-clock deadline: flush after at most flush_dur regardless of event rate.
            // Using an idle timeout would never fire when inotify floods the channel.
            let batch_deadline = tokio::time::Instant::now() + flush_dur;
            while buffer.len() < batch_size {
                let remaining = batch_deadline.saturating_duration_since(tokio::time::Instant::now());
                if remaining.is_zero() {
                    break;
                }
                match timeout(remaining, self.rx.recv()).await {
                    Ok(Some(event)) => {
                        let urgent = matches!(
                            &event,
                            IndexEvent::FolderRemoved { .. }
                                | IndexEvent::FullRescanRequested { .. }
                                | IndexEvent::ScanComplete { .. }
                        );
                        buffer.push(event);
                        if urgent {
                            break; // flush immediately  - don't wait for the batch to fill
                        }
                    }
                    Ok(None) => {
                        if !buffer.is_empty() {
                            let _ = self.flush_batch(&mut buffer);
                        }
                        return;
                    }
                    Err(_) => break, // deadline reached
                }
            }
            if !buffer.is_empty() {
                let mut retry_delay = Duration::from_millis(500);
                loop {
                    match self.flush_batch(&mut buffer) {
                        Ok(_) => {
                            flush_count += 1;
                            let _ = self.file_change_tx.send(flush_count);
                            break;
                        }
                        Err(e) => {
                            if !is_retryable_flush_error(&e) {
                                tracing::error!("Non-retryable batch flush failed: {e}. Dropping the current batch to keep the writer alive.");
                                buffer.clear();
                                break;
                            }
                            tracing::error!("Batch flush failed: {e}. Retrying...");
                            tokio::time::sleep(retry_delay).await;
                            retry_delay = std::cmp::min(retry_delay * 2, Duration::from_secs(30));
                        }
                    }
                }
            }
        }
    }

    fn flush_batch(&mut self, buffer: &mut Vec<IndexEvent>) -> Result<(), AppError> {
        if buffer.is_empty() {
            return Ok(());
        }

        let events = std::mem::take(buffer);

        let tx = self.conn.transaction().map_err(AppError::Database)?;
        let mut deltas = HashMap::<i64, FolderDelta>::new();
        let mut chain_cache: HashMap<i64, Vec<i64>> = HashMap::new();
        let scope = crate::engine::scope_tag();
        let active_watched_folders = {
            let mut stmt = tx.prepare("SELECT id FROM watched_folders WHERE scope_tag = ?1")?;
            let rows = stmt.query_map([scope], |row| row.get::<_, i64>(0))?;
            rows.collect::<Result<HashSet<_>, _>>()?
        };

        let mut select_active_file = tx.prepare(
            "SELECT id, folder_id, size_bytes, created_at, modified_at FROM files \
             WHERE name = ?1 AND folder_id = ?2 AND is_deleted = 0 AND scope_tag = ?3",
        )?;
        let mut update_file = tx.prepare(
            "UPDATE files SET name = ?1, extension = ?2, folder_id = ?3, size_bytes = ?4, \
             created_at = ?5, modified_at = ?6, device_id = ?7, inode = ?8, is_symlink = ?9, \
             is_deleted = 0, deleted_at = NULL, last_seen_at = datetime('now'), \
             scan_generation = CASE WHEN ?10 IS NULL THEN scan_generation ELSE ?10 END, \
             absolute_path = CASE WHEN ?13 = '' THEN absolute_path ELSE ?13 END \
             WHERE id = ?11 AND scope_tag = ?12",
        )?;
        let mut insert_file = tx.prepare(
            "INSERT INTO files (name, scope_tag, extension, folder_id, size_bytes, created_at, modified_at, \
             device_id, inode, is_symlink, scan_generation, absolute_path) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
        )?;
        let mut delete_fts = tx.prepare("DELETE FROM files_fts WHERE rowid = ?1")?;
        let mut insert_fts = tx.prepare("INSERT INTO files_fts(rowid, name) VALUES (?1, ?2)")?;
        let mut apply_folder_delta = tx.prepare(
            "UPDATE folders SET \
             file_count = MAX(0, file_count + ?1), \
             total_size_bytes = MAX(0, total_size_bytes + ?2), \
             counts_dirty = 1, \
             is_deleted = CASE WHEN ?1 < 0 AND MAX(0, file_count + ?1) = 0 AND parent_id IS NOT NULL THEN 1 ELSE is_deleted END, \
             deleted_at = CASE WHEN ?1 < 0 AND MAX(0, file_count + ?1) = 0 AND parent_id IS NOT NULL THEN datetime('now') ELSE deleted_at END, \
             inode = CASE WHEN ?1 < 0 AND MAX(0, file_count + ?1) = 0 AND parent_id IS NOT NULL THEN NULL ELSE inode END \
             WHERE id = ?3 AND scope_tag = ?4",
        )?;

        for event in events {
            if let Some(watched_folder_id) = event.watched_folder_id() {
                if !active_watched_folders.contains(&watched_folder_id) {
                    continue;
                }
            }

            match event {
                IndexEvent::ScanStarted {
                    watched_folder_id,
                    generation,
                } => {
                    let root_id = get_or_insert_root(&tx, scope, watched_folder_id)?;
                    tx.execute(
                        "UPDATE folders
                         SET scan_generation = ?1,
                             is_deleted = 0,
                             deleted_at = NULL
                         WHERE id = ?2 AND scope_tag = ?3",
                        params![generation, root_id, scope],
                    )?;
                    tx.execute(
                        "UPDATE watched_folders
                         SET scan_status = 'scanning',
                             scan_generation = ?1,
                             files_scanned = 0,
                             rescan_after_scan = 0
                         WHERE id = ?2 AND scope_tag = ?3",
                        params![generation, watched_folder_id, scope],
                    )?;
                }

                IndexEvent::FileFound {
                    watched_folder_id,
                    path,
                    absolute_path,
                    name,
                    extension,
                    size_bytes,
                    created_at,
                    modified_at,
                    device_id,
                    inode,
                    is_symlink,
                    scan_generation,
                } => {
                    let effective_scan_generation = scan_generation.unwrap_or_else(|| {
                        Self::watched_folder_scan_generation(&tx, scope, watched_folder_id)
                            .unwrap_or(0)
                    });
                    let parent_path = std::path::Path::new(&path)
                        .parent()
                        .and_then(|p| p.to_str())
                        .unwrap_or("");
                    let folder_id = Self::resolve_folder_id(
                        &mut self.folder_cache,
                        &mut self.parent_cache,
                        &tx,
                        scope,
                        watched_folder_id,
                        parent_path,
                        Some(effective_scan_generation),
                    )?;

                    let current_info: Option<(i64, i64, i64, String, String)> = select_active_file
                        .query_row(params![name, folder_id, scope], |r| {
                            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
                        })
                        .optional()?;

                    let ctime_str = created_at.to_rfc3339();
                    let mtime_str = modified_at.to_rfc3339();
                    if let Some((id, old_folder_id, old_size, _old_ctime, old_mtime)) = current_info
                    {
                        if old_mtime == mtime_str
                            && old_folder_id == folder_id
                            && old_size == size_bytes as i64
                        {
                            tx.execute(
                                "UPDATE files
                                 SET scan_generation = ?1,
                                     last_seen_at = datetime('now'),
                                     is_deleted = 0,
                                     deleted_at = NULL
                                 WHERE id = ?2 AND scope_tag = ?3",
                                params![effective_scan_generation, id, scope],
                            )?;
                            continue;
                        }

                        update_file.execute(params![
                            name,
                            extension,
                            folder_id,
                            size_bytes as i64,
                            ctime_str,
                            mtime_str,
                            device_id,
                            inode,
                            is_symlink as i64,
                            effective_scan_generation,
                            id,
                            scope,
                            absolute_path
                        ])?;

                        if old_folder_id != folder_id {
                            Self::add_delta(
                                &mut self.parent_cache,
                                &mut chain_cache,
                                &mut deltas,
                                &tx,
                                old_folder_id,
                                -1,
                                -old_size,
                            )?;
                            Self::add_delta(
                                &mut self.parent_cache,
                                &mut chain_cache,
                                &mut deltas,
                                &tx,
                                folder_id,
                                1,
                                size_bytes as i64,
                            )?;
                        } else {
                            Self::add_delta(
                                &mut self.parent_cache,
                                &mut chain_cache,
                                &mut deltas,
                                &tx,
                                folder_id,
                                0,
                                (size_bytes as i64) - old_size,
                            )?;
                        }

                        delete_fts.execute([id])?;
                        insert_fts.execute(params![id, name])?;
                    } else {
                        insert_file.execute(params![
                            name,
                            scope,
                            extension,
                            folder_id,
                            size_bytes as i64,
                            ctime_str,
                            mtime_str,
                            device_id,
                            inode,
                            is_symlink as i64,
                            effective_scan_generation,
                            absolute_path
                        ])?;
                        let id = tx.last_insert_rowid();
                        insert_fts.execute(params![id, name])?;
                        Self::add_delta(
                            &mut self.parent_cache,
                            &mut chain_cache,
                            &mut deltas,
                            &tx,
                            folder_id,
                            1,
                            size_bytes as i64,
                        )?;
                    }
                }

                IndexEvent::FolderFound {
                    watched_folder_id,
                    path,
                    name,
                    device_id,
                    inode,
                    scan_generation,
                    created_at,
                } => {
                    let effective_scan_generation = scan_generation.unwrap_or_else(|| {
                        Self::watched_folder_scan_generation(&tx, scope, watched_folder_id)
                            .unwrap_or(0)
                    });
                    let parent_path = std::path::Path::new(&path)
                        .parent()
                        .and_then(|p| p.to_str())
                        .unwrap_or("");
                    let parent_id = Self::resolve_folder_id(
                        &mut self.folder_cache,
                        &mut self.parent_cache,
                        &tx,
                        scope,
                        watched_folder_id,
                        parent_path,
                        Some(effective_scan_generation),
                    )?;

                    let safe_name = sanitize_for_hierarchy(&name);

                    let folder_by_name: Option<i64> = tx.query_row(
	                        "SELECT id FROM folders WHERE name = ?1 AND parent_id = ?2 AND watched_folder_id = ?3 AND scope_tag = ?4 LIMIT 1",
	                        params![&safe_name, parent_id, watched_folder_id, scope],
	                        |r| r.get(0),
	                    ).optional()?;

                    let folder_by_inode: Option<i64> = if let Some(ino) = inode {
                        tx.query_row(
	                            "SELECT id FROM folders WHERE device_id = ?1 AND inode = ?2 AND watched_folder_id = ?3 AND is_deleted = 0 AND scope_tag = ?4 LIMIT 1",
	                            params![device_id, ino, watched_folder_id, scope], |r| r.get(0)
	                        ).optional()?
                    } else {
                        None
                    };

                    let created_at_str = created_at.map(|t| t.format("%Y-%m-%dT%H:%M:%S%.fZ").to_string());

                    if let Some(id) = folder_by_name.or(folder_by_inode) {
                        tx.execute(
	                            "UPDATE folders SET name = ?, parent_id = ?, watched_folder_id = ?, device_id = ?, inode = ?, is_deleted = 0, deleted_at = NULL, scan_generation = CASE WHEN ? IS NULL THEN scan_generation ELSE ? END, created_at = COALESCE(created_at, ?) WHERE id = ?",
	                            params![&safe_name, parent_id, watched_folder_id, device_id, inode, effective_scan_generation, effective_scan_generation, created_at_str, id]
	                        )?;
                        if let Some(old_id) = folder_by_inode {
                            if old_id != id {
                                tx.execute(
	                                    "UPDATE folders SET is_deleted = 1, deleted_at = datetime('now'), inode = NULL WHERE id = ?",
	                                    [old_id],
	                                )?;
                            }
                        }
                        self.parent_cache.put(id, Some(parent_id));
                        self.folder_cache.clear();
                    } else {
                        tx.execute(
	                            "INSERT INTO folders (name, scope_tag, parent_id, watched_folder_id, device_id, inode, scan_generation, indexed_at, created_at) \
	                             VALUES (?, ?, ?, ?, ?, ?, ?, datetime('now'), ?)",
	                            params![&safe_name, scope, parent_id, watched_folder_id, device_id, inode, effective_scan_generation, created_at_str],
	                        )?;
                        let id = tx.last_insert_rowid();
                        self.parent_cache.put(id, Some(parent_id));
                    }
                }

                IndexEvent::FileRemoved {
                    watched_folder_id,
                    path,
                } => {
                    let std_path = std::path::Path::new(&path);
                    let name = std_path
                        .file_name()
                        .and_then(|s| s.to_str())
                        .unwrap_or_default();
                    let parent_path = std_path.parent().and_then(|s| s.to_str()).unwrap_or("");
                    let folder_id = Self::resolve_folder_id(
                        &mut self.folder_cache,
                        &mut self.parent_cache,
                        &tx,
                        scope,
                        watched_folder_id,
                        parent_path,
                        None,
                    )?;

                    let row: Option<(i64, i64)> = tx.query_row(
                        "SELECT id, size_bytes FROM files WHERE name = ?1 AND folder_id = ?2 AND is_deleted = 0 AND scope_tag = ?3",
                        params![name, folder_id, scope], |r| Ok((r.get(0)?, r.get(1)?)),
                    ).optional()?;

                    if let Some((id, old_size)) = row {
                        tx.execute("UPDATE files SET is_deleted = 1, deleted_at = datetime('now'), inode = NULL WHERE id = ?", [id])?;
                        delete_fts.execute([id])?;
                        Self::add_delta(
                            &mut self.parent_cache,
                            &mut chain_cache,
                            &mut deltas,
                            &tx,
                            folder_id,
                            -1,
                            -old_size,
                        )?;
                    }
                }

                IndexEvent::FolderRemoved {
                    watched_folder_id,
                    path,
                } => {
                    let std_path = std::path::Path::new(&path);
                    let name = sanitize_for_hierarchy(
                        std_path
                            .file_name()
                            .and_then(|s| s.to_str())
                            .unwrap_or_default(),
                    );
                    let parent_path = std_path.parent().and_then(|s| s.to_str()).unwrap_or("");
                    let parent_id = Self::resolve_folder_id(
                        &mut self.folder_cache,
                        &mut self.parent_cache,
                        &tx,
                        scope,
                        watched_folder_id,
                        parent_path,
                        None,
                    )?;

                    let folder_id: Option<i64> = tx.query_row(
	                        "SELECT id FROM folders WHERE name = ? AND parent_id = ? AND watched_folder_id = ? AND is_deleted = 0 AND scope_tag = ?4",
	                        params![name, parent_id, watched_folder_id, scope], |r| r.get(0)
	                    ).optional()?;

                    if let Some(id) = folder_id {
                        tx.execute("UPDATE folders SET is_deleted = 1, deleted_at = datetime('now'), inode = NULL WHERE id = ? AND scope_tag = ?", rusqlite::params![id, scope])?;
                        tx.execute(
                            "WITH RECURSIVE tree(id) AS (
                                SELECT ?1 UNION ALL SELECT f.id FROM folders f JOIN tree ON f.parent_id = tree.id AND f.scope_tag = ?2
                             ) DELETE FROM files_fts WHERE rowid IN (
                                 SELECT id FROM files WHERE folder_id IN (SELECT id FROM tree) AND scope_tag = ?2
                             )",
                            rusqlite::params![id, scope]
                        )?;
                        tx.execute(
                            "WITH RECURSIVE tree(id) AS (
                                SELECT ?1 UNION ALL SELECT f.id FROM folders f JOIN tree ON f.parent_id = tree.id AND f.scope_tag = ?2
                             ) UPDATE files SET is_deleted = 1, deleted_at = datetime('now'), inode = NULL
                               WHERE folder_id IN (SELECT id FROM tree) AND scope_tag = ?2",
                            rusqlite::params![id, scope]
                        )?;
                        tx.execute(
                            "WITH RECURSIVE tree(id) AS (
                                SELECT ?1 UNION ALL SELECT f.id FROM folders f JOIN tree ON f.parent_id = tree.id AND f.scope_tag = ?2
                             ) UPDATE folders SET is_deleted = 1, deleted_at = datetime('now'), inode = NULL
                               WHERE id IN (SELECT id FROM tree) AND id != ?1 AND scope_tag = ?2",
                            rusqlite::params![id, scope]
                        )?;

                        let (files_lost, size_lost): (i64, i64) = tx.query_row(
                            "SELECT COALESCE(file_count, 0), COALESCE(total_size_bytes, 0) FROM folders WHERE id = ?",
                            [id], |r| Ok((r.get(0)?, r.get(1)?))
                        )?;
                        Self::add_delta(
                            &mut self.parent_cache,
                            &mut chain_cache,
                            &mut deltas,
                            &tx,
                            parent_id,
                            -files_lost,
                            -size_lost,
                        )?;
                    }
                }

                IndexEvent::ScanProgress {
                    watched_folder_id,
                    scanned,
                    total_estimate,
                } => {
                    if let Some(est) = total_estimate {
                        tx.execute("UPDATE watched_folders SET scan_status = 'scanning', files_scanned = ?, total_files_estimate = ? WHERE id = ? AND scope_tag = ?", params![scanned as i64, est as i64, watched_folder_id, scope])?;
                    } else {
                        tx.execute("UPDATE watched_folders SET scan_status = 'scanning', files_scanned = ? WHERE id = ? AND scope_tag = ?", params![scanned as i64, watched_folder_id, scope])?;
                    }
                }

                IndexEvent::ScanComplete {
                    watched_folder_id,
                    scanned,
                } => {
                    let (generation, rescan_after_scan): (i64, i64) = tx.query_row(
                        "SELECT scan_generation, rescan_after_scan FROM watched_folders WHERE id = ?1 AND scope_tag = ?2",
                        params![watched_folder_id, scope],
                        |row| Ok((row.get(0)?, row.get(1)?)),
                    )?;
                    tx.execute(
                        "UPDATE files
                         SET is_deleted = 1,
                             deleted_at = datetime('now'),
                             inode = NULL
                         WHERE is_deleted = 0
                           AND scan_generation < ?1
                           AND scope_tag = ?2
                           AND folder_id IN (
                               SELECT id FROM folders
                               WHERE watched_folder_id = ?3 AND scope_tag = ?2
                           )",
                        params![generation, scope, watched_folder_id],
                    )?;
                    tx.execute(
                        "UPDATE folders
                         SET is_deleted = 1,
                             deleted_at = datetime('now'),
                             inode = NULL
                         WHERE is_deleted = 0
                           AND parent_id IS NOT NULL
                           AND scan_generation < ?1
                           AND watched_folder_id = ?2
                           AND scope_tag = ?3",
                        params![generation, watched_folder_id, scope],
                    )?;
                    tx.execute(
                        "UPDATE folders
                         SET counts_dirty = 1
                         WHERE watched_folder_id = ?1 AND scope_tag = ?2",
                        params![watched_folder_id, scope],
                    )?;
                    tx.execute(
                        "UPDATE watched_folders
                         SET scan_status = CASE WHEN ?1 != 0 THEN 'pending' ELSE 'ready' END,
                             files_scanned = ?,
                             total_files_estimate = CASE WHEN total_files_estimate = 0 THEN ? ELSE total_files_estimate END,
                             rescan_after_scan = 0
                         WHERE id = ? AND scope_tag = ?",
                        params![
                            rescan_after_scan,
                            scanned as i64,
                            scanned as i64,
                            watched_folder_id,
                            scope
                        ],
                    )?;
                    if rescan_after_scan == 0 {
                        let _ = self.status_tx.send(ScanStatus::Ready);
                    }
                }

                IndexEvent::FullRescanRequested { reason } => {
                    tx.execute(
                        "UPDATE watched_folders
                         SET scan_status = CASE WHEN scan_status = 'scanning' THEN scan_status ELSE 'pending' END,
                             rescan_after_scan = CASE WHEN scan_status = 'scanning' THEN 1 ELSE rescan_after_scan END,
                             files_scanned = CASE WHEN scan_status = 'scanning' THEN files_scanned ELSE 0 END,
                             total_files_estimate = CASE WHEN scan_status = 'scanning' THEN total_files_estimate ELSE 0 END,
                             reconcile_requested_at = datetime('now')
                         WHERE scope_tag = ?1",
                        [scope],
                    )?;
                    tracing::warn!("Queued full reconciliation from writer: {reason}");
                }
            }
        }

        for (folder_id, delta) in deltas {
            apply_folder_delta.execute(params![
                delta.count_delta,
                delta.size_delta,
                folder_id,
                scope
            ])?;
        }

        drop(select_active_file);
        drop(update_file);
        drop(insert_file);
        drop(delete_fts);
        drop(insert_fts);
        drop(apply_folder_delta);

        tx.commit().map_err(AppError::Database)?;
        Ok(())
    }

    fn ancestor_chain(
        folder_id: i64,
        parent_cache: &mut LruCache<i64, Option<i64>>,
        chain_cache: &mut HashMap<i64, Vec<i64>>,
        tx: &Transaction<'_>,
    ) -> Result<Vec<i64>, AppError> {
        if let Some(chain) = chain_cache.get(&folder_id) {
            return Ok(chain.clone());
        }

        let mut chain = Vec::new();
        let mut current_id = Some(folder_id);
        while let Some(id) = current_id {
            chain.push(id);
            if let Some(&parent_id) = parent_cache.get(&id) {
                current_id = parent_id;
            } else {
                let parent_id: Option<i64> = tx
                    .query_row("SELECT parent_id FROM folders WHERE id = ?", [id], |r| {
                        r.get::<_, Option<i64>>(0)
                    })
                    .optional()?
                    .flatten();
                parent_cache.put(id, parent_id);
                current_id = parent_id;
            }
        }

        chain_cache.insert(folder_id, chain.clone());
        Ok(chain)
    }

    fn add_delta(
        parent_cache: &mut LruCache<i64, Option<i64>>,
        chain_cache: &mut HashMap<i64, Vec<i64>>,
        deltas: &mut HashMap<i64, FolderDelta>,
        tx: &Transaction<'_>,
        folder_id: i64,
        count: i64,
        size: i64,
    ) -> Result<(), AppError> {
        let chain = Self::ancestor_chain(folder_id, parent_cache, chain_cache, tx)?;

        for id in chain {
            let d = deltas.entry(id).or_default();
            d.count_delta += count;
            d.size_delta += size;
        }
        Ok(())
    }

    fn resolve_folder_id(
        folder_cache: &mut LruCache<(i64, String), i64>,
        parent_cache: &mut LruCache<i64, Option<i64>>,
        tx: &Transaction<'_>,
        scope: &str,
        watched_folder_id: i64,
        dir_path: &str,
        scan_generation: Option<i64>,
    ) -> Result<i64, AppError> {
        let key = (watched_folder_id, dir_path.to_string());
        if let Some(&id) = folder_cache.get(&key) {
            return Ok(id);
        }

        let parts: Vec<&str> = dir_path.split('/').filter(|s| !s.is_empty()).collect();
        if parts.is_empty() {
            let root_id = get_or_insert_root(tx, scope, watched_folder_id)?;
            folder_cache.put(key, root_id);
            return Ok(root_id);
        }

        let mut current_parent_id = Some(get_or_insert_root(tx, scope, watched_folder_id)?);
        for part in &parts {
            let safe = sanitize_for_hierarchy(part);
            let row: Option<i64> = tx.query_row(
	                "SELECT id FROM folders WHERE name = ? AND parent_id = ? AND watched_folder_id = ? AND scope_tag = ?",
	                params![&safe, current_parent_id, watched_folder_id, scope],
	                |r| r.get(0),
	            ).optional()?;
            let new_id = if let Some(id) = row {
                id
            } else {
                let generation = scan_generation.unwrap_or(0);
                tx.execute(
                    "INSERT INTO folders (name, scope_tag, parent_id, watched_folder_id, scan_generation, indexed_at) VALUES (?, ?, ?, ?, ?, datetime('now'))",
                    params![&safe, scope, current_parent_id, watched_folder_id, generation],
                )?;
                let id = tx.last_insert_rowid();
                parent_cache.put(id, current_parent_id);
                id
            };
            if let Some(generation) = scan_generation {
                tx.execute(
                    "UPDATE folders SET is_deleted = 0, deleted_at = NULL, scan_generation = ? WHERE id = ?",
                    params![generation, new_id],
                )?;
            } else {
                tx.execute(
                    "UPDATE folders SET is_deleted = 0, deleted_at = NULL WHERE id = ?",
                    [new_id],
                )?;
            }
            current_parent_id = Some(new_id);
        }
        let final_id = current_parent_id.unwrap();
        folder_cache.put(key, final_id);
        Ok(final_id)
    }

    /// Returns the watched folder's current scan_generation so live inotify events
    /// are tagged with the same generation the next ScanComplete will reconcile against.
    fn watched_folder_scan_generation(
        tx: &Transaction<'_>,
        scope: &str,
        watched_folder_id: i64,
    ) -> Result<i64, AppError> {
        tx.query_row(
            "SELECT scan_generation FROM watched_folders WHERE id = ?1 AND scope_tag = ?2",
            params![watched_folder_id, scope],
            |row| row.get(0),
        )
        .map_err(AppError::Database)
    }
}

fn get_or_insert_root(
    tx: &Transaction<'_>,
    scope: &str,
    watched_folder_id: i64,
) -> Result<i64, AppError> {
    let row: Option<i64> = tx
        .query_row(
            "SELECT id FROM folders WHERE parent_id IS NULL AND watched_folder_id = ? AND scope_tag = ?",
            params![watched_folder_id, scope],
            |r| r.get(0),
        )
        .optional()?;
    if let Some(id) = row {
        return Ok(id);
    }
    tx.execute(
        "INSERT INTO folders (name, scope_tag, parent_id, watched_folder_id, indexed_at) VALUES ('', ?, NULL, ?, datetime('now'))",
        params![scope, watched_folder_id],
    )?;
    Ok(tx.last_insert_rowid())
}

fn is_retryable_flush_error(err: &AppError) -> bool {
    matches!(
        err,
        AppError::Database(rusqlite::Error::SqliteFailure(code, _))
            if matches!(
                code.code,
                rusqlite::ErrorCode::DatabaseBusy | rusqlite::ErrorCode::DatabaseLocked
            )
    )
}
