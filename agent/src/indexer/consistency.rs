// Scheduled consistency task. Runs once every ~24 hours (targeting ~3 AM local
// time) and triggers a full reconciliation scan to catch anything inotify missed
// (e.g. events that fired while the agent was down, or unmounted/remounted volumes).
use std::time::Duration;

use crate::db::pool::DbPool;
use crate::error::AppError;

pub fn spawn_consistency_task(db: DbPool) {
    tokio::spawn(async move {
        let mut next_full =
            next_rough_3am_after(chrono::Local::now() + chrono::Duration::hours(20));
        let mut last_seen_request = latest_reconcile_request(&db).unwrap_or(None);
        loop {
            let now = chrono::Local::now();
            let sleep_for = match (next_full - now).to_std() {
                Ok(d) => d,
                Err(_) => Duration::from_secs(0),
            };
            tokio::time::sleep(sleep_for).await;

            let now = chrono::Local::now();

            // If an external trigger (inotify overflow, moved dir) came in, just reset the timer.
            match latest_reconcile_request(&db) {
                Ok(latest) if latest != last_seen_request => {
                    last_seen_request = latest;
                    next_full = next_rough_3am_after(now + chrono::Duration::hours(20));
                    continue;
                }
                Ok(_) => {}
                Err(e) => tracing::warn!("Failed to read reconciliation marker: {e}"),
            }

            if now >= next_full {
                match request_full_rescan(&db, "scheduled 24h reconciliation") {
                    Ok(()) => {
                        next_full = next_rough_3am_after(now + chrono::Duration::hours(20));
                        last_seen_request = latest_reconcile_request(&db).unwrap_or(None);
                    }
                    Err(e) => tracing::warn!("Failed to schedule 24h reconciliation: {e}"),
                }
            }
        }
    });
}

pub fn request_full_rescan(db: &DbPool, reason: &str) -> Result<(), AppError> {
    let conn = db.get()?;
    let scope = crate::engine::scope_tag();
    let changed = conn.execute(
        "UPDATE watched_folders
         SET scan_status = CASE WHEN scan_status = 'scanning' THEN scan_status ELSE 'pending' END,
             rescan_after_scan = CASE WHEN scan_status = 'scanning' THEN 1 ELSE rescan_after_scan END,
             files_scanned = CASE WHEN scan_status = 'scanning' THEN files_scanned ELSE 0 END,
             total_files_estimate = CASE WHEN scan_status = 'scanning' THEN total_files_estimate ELSE 0 END,
             reconcile_requested_at = datetime('now')
         WHERE scope_tag = ?1",
        [scope],
    )?;
    tracing::info!("Queued full reconciliation for {changed} watched folders: {reason}");
    Ok(())
}

fn latest_reconcile_request(db: &DbPool) -> Result<Option<String>, AppError> {
    let conn = db.get()?;
    let scope = crate::engine::scope_tag();
    conn.query_row(
        "SELECT MAX(reconcile_requested_at) FROM watched_folders WHERE scope_tag = ?1",
        [scope],
        |row| row.get(0),
    )
    .map_err(AppError::Database)
}

fn next_rough_3am_after(after: chrono::DateTime<chrono::Local>) -> chrono::DateTime<chrono::Local> {
    let date = after.date_naive();
    let today_3 = date.and_hms_opt(3, 0, 0).unwrap();
    let candidate = today_3
        .and_local_timezone(chrono::Local)
        .earliest()
        .unwrap_or(after);
    if candidate > after {
        candidate
    } else {
        (date + chrono::Duration::days(1))
            .and_hms_opt(3, 0, 0)
            .unwrap()
            .and_local_timezone(chrono::Local)
            .earliest()
            .unwrap_or(after + chrono::Duration::hours(24))
    }
}
