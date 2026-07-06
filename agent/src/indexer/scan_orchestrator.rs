use std::collections::HashSet;
use std::sync::{Arc, Mutex};

use crate::db::pool::DbPool;
use crate::error::AppError;

/// Prevents duplicate scanners for the same watched folder across startup and the
/// pending-scan poller.
pub struct ScanOrchestrator {
    in_flight: Mutex<HashSet<i64>>,
}

impl ScanOrchestrator {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            in_flight: Mutex::new(HashSet::new()),
        })
    }

    /// Reset rows left in `scanning` after a crash/restart.
    pub fn recover_stale_scans(db: &DbPool) -> Result<(), AppError> {
        let conn = db.get()?;
        let scope = crate::engine::scope_tag();
        let n = conn.execute(
            "UPDATE watched_folders SET scan_status = 'pending' WHERE scan_status = 'scanning' AND scope_tag = ?",
            [scope],
        )?;
        if n > 0 {
            tracing::info!("Recovered {n} watched folder(s) stuck in scanning state");
        }
        Ok(())
    }

    /// Atomically claim a pending folder for scanning. Returns false if another
    /// task already owns the scan or the row is not pending.
    pub fn try_claim(&self, db: &DbPool, folder_id: i64) -> Result<bool, AppError> {
        {
            let guard = self
                .in_flight
                .lock()
                .map_err(|e| AppError::Internal(e.to_string()))?;
            if guard.contains(&folder_id) {
                return Ok(false);
            }
        }

        let conn = db.get()?;
        let scope = crate::engine::scope_tag();
        let claimed = conn.execute(
            "UPDATE watched_folders SET scan_status = 'scanning' WHERE id = ? AND scan_status = 'pending' AND scope_tag = ?",
            rusqlite::params![folder_id, scope],
        )?;
        if claimed == 0 {
            return Ok(false);
        }

        let mut guard = self
            .in_flight
            .lock()
            .map_err(|e| AppError::Internal(e.to_string()))?;
        guard.insert(folder_id);
        Ok(true)
    }

    pub fn release(&self, folder_id: i64) {
        if let Ok(mut guard) = self.in_flight.lock() {
            guard.remove(&folder_id);
        }
    }
}
