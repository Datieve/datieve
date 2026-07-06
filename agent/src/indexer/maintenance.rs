// Maintenance task. Runs periodically in the background on a timer:
//   - Expired session cleanup
//   - Optional ghost file pruning (if deleted_file_prune_days is set in config)
//   - Dirty folder count recalculation (file_count / total_size_bytes)
//   - FTS5 index optimization (merge, then WAL checkpoint)
use std::path::PathBuf;
use std::time::Duration;

pub fn spawn_maintenance_task(
    db_path: PathBuf,
    session_cleanup_interval_secs: u64,
    fts_optimize_interval_secs: u64,
    deleted_file_prune_days: Option<u32>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        tracing::info!("Maintenance task started.");
        let mut next_cleanup = tokio::time::Instant::now();
        let mut next_fts_optimize =
            tokio::time::Instant::now() + Duration::from_secs(fts_optimize_interval_secs);

        loop {
            let now = tokio::time::Instant::now();
            let wait = next_cleanup
                .saturating_duration_since(now)
                .min(next_fts_optimize.saturating_duration_since(now))
                .max(Duration::from_secs(60));
            tokio::time::sleep(wait).await;

            let now = tokio::time::Instant::now();
            let do_cleanup = now >= next_cleanup;
            let do_fts = now >= next_fts_optimize;

            if !do_cleanup && !do_fts {
                continue;
            }

            let path = db_path.clone();
            let _ = tokio::task::spawn_blocking(move || {
                let conn = match crate::db::pool::open_write_connection(&path) {
                    Ok(c) => c,
                    Err(e) => {
                        tracing::warn!("Maintenance: cannot open DB: {e}");
                        return;
                    }
                };

                if do_cleanup {
                    let scope = crate::engine::scope_tag();

                    let _ = conn.execute(
                        "DELETE FROM sessions WHERE expires_at < datetime('now') AND scope_tag = ?",
                        [scope],
                    );

                    if let Some(days) = deleted_file_prune_days {
                        let limit = format!("-{} days", days);
                        let _ = conn.execute(
                            "DELETE FROM files_fts WHERE rowid IN (SELECT id FROM files WHERE is_deleted = 1 AND deleted_at < datetime('now', ?) AND scope_tag = ?)",
                            rusqlite::params![limit, scope],
                        );
                        let _ = conn.execute(
                            "DELETE FROM files WHERE is_deleted = 1 AND deleted_at < datetime('now', ?) AND scope_tag = ?",
                            rusqlite::params![limit, scope],
                        );
                    }

                    let dirty_ids: Vec<i64> = conn
                        .prepare("SELECT id FROM folders WHERE counts_dirty = 1 AND scope_tag = ? LIMIT 1000")
                        .and_then(|mut stmt| {
                            let rows = stmt.query_map([scope], |row| row.get::<_, i64>(0))?;
                            rows.collect::<Result<Vec<_>, _>>()
                        })
                        .unwrap_or_default();

                    // Only recalculate when folders are actually dirty  - no speculative random scan.
                    for folder_id in dirty_ids {
                        let totals = conn.query_row(
                            "WITH RECURSIVE tree(id) AS (
                                SELECT ?
                                UNION ALL
                                SELECT f.id FROM folders f JOIN tree ON f.parent_id = tree.id
                             )
                            SELECT COUNT(*), COALESCE(SUM(size_bytes), 0)
                             FROM files
                             WHERE is_deleted = 0 AND scope_tag = ?
                               AND folder_id IN (SELECT id FROM tree)",
                            rusqlite::params![folder_id, scope],
                            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
                        );

                        if let Ok((file_count, total_size_bytes)) = totals {
                            let _ = conn.execute(
                                "UPDATE folders SET file_count = ?, total_size_bytes = ?, counts_dirty = 0 WHERE id = ? AND scope_tag = ?",
                                rusqlite::params![file_count, total_size_bytes, folder_id, scope],
                            );
                        }
                    }
                }

                if do_fts {
                    let _ = conn.execute(
                        "INSERT INTO files_fts(files_fts, rank) VALUES('merge', 16)",
                        [],
                    );
                    let _ = conn.execute("PRAGMA wal_checkpoint(TRUNCATE)", []);
                }
            })
            .await;

            if do_cleanup {
                next_cleanup = tokio::time::Instant::now()
                    + Duration::from_secs(session_cleanup_interval_secs);
            }
            if do_fts {
                next_fts_optimize = tokio::time::Instant::now()
                    + Duration::from_secs(fts_optimize_interval_secs);
            }
        }
    })
}
