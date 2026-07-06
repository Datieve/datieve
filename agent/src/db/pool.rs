#![allow(dead_code)]
use rusqlite::{Connection, OpenFlags};
use std::path::Path;

use crate::error::AppError;

// Connection openers
/// Opens the **write** connection. Called once on startup; owned by the batch writer task.
///
/// Sets journal_mode = WAL and wal_autocheckpoint here  - these are global DB settings
/// that only need to be applied by the writer.
pub fn open_write_connection(path: &Path) -> Result<Connection, AppError> {
    let conn = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_WRITE
            | OpenFlags::SQLITE_OPEN_CREATE
            | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    // WAL is a database-wide setting  - applied once by the writer on first start.
    // On subsequent starts the PRAGMA is a no-op (returns "wal").
    conn.execute_batch("PRAGMA journal_mode = WAL;")?;
    conn.execute_batch("PRAGMA wal_autocheckpoint = 1000;")?; // checkpoint every ~4MB
    apply_common_pragmas(&conn)?;
    apply_writer_pragmas(&conn)?;
    Ok(conn)
}

/// Opens the **read** connection. Called once on startup; owned by the Axum AppState.
///
/// Intentionally opened READ_WRITE so the kernel allows writing to the WAL shared-memory
/// index (`.db-shm`). We enforce read-only discipline in code, not via SQLite flags.
/// Opening truly read-only (`SQLITE_OPEN_READ_ONLY`) can fail on NAS systems where the
/// shm file is owned by a different user.
pub fn open_read_connection(path: &Path) -> Result<Connection, AppError> {
    let conn = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    apply_common_pragmas(&conn)?;
    Ok(conn)
}

// PRAGMAs
/// PRAGMAs applied to every connection (both read and write).
fn apply_common_pragmas(conn: &Connection) -> Result<(), AppError> {
    conn.execute_batch(
        r#"
        -- Enforce FK constraints. SQLite ignores them by default; this is a foot-gun
        -- on a production system. Applied per-connection (not persisted in the file).
        PRAGMA foreign_keys = ON;

        -- NORMAL is safe with WAL and gives a significant write speedup over FULL.
        -- In WAL mode, data is never lost even on an abrupt power failure  - the WAL
        -- file is replayed on next open. NORMAL only risks losing the last 1-2 WAL frames,
        -- which SQLite recovers automatically.
        PRAGMA synchronous = NORMAL;

        -- Wait up to 5 seconds on SQLITE_BUSY before failing.
        -- Critical: the write connection holds an exclusive lock during checkpoint
        -- (PRAGMA wal_checkpoint(TRUNCATE)). Without this, read queries would fail
        -- during the ~100ms checkpoint window instead of transparently waiting.
        PRAGMA busy_timeout = 5000;

        -- 16 MB page cache per connection (2 connections = 32 MB total).
        -- Negative value = size in KiB. -16384 = 16384 KiB = 16 MB.
        -- NAS page size is almost always 4096 bytes, giving ~4096 cached pages.
        PRAGMA cache_size = -16384;

        -- Temporary tables and sort buffers live in memory, not the temp file on disk.
        -- Important during FTS queries on large datasets  - avoids unnecessary disk I/O.
        PRAGMA temp_store = MEMORY;

        -- Map up to 128 MB of the database file into virtual address space.
        -- On 64-bit NAS systems (all modern NAS hardware), this dramatically improves
        -- read-heavy workloads (search/browse) by letting the OS page cache serve
        -- reads without read() syscalls. Virtual memory  - not locked RAM; the OS
        -- evicts mmap pages under memory pressure, so this does not contribute to
        -- our 256 MB RSS budget under normal operation.
        PRAGMA mmap_size = 134217728;
    "#,
    )?;
    Ok(())
}

/// Extra PRAGMAs for the dedicated write connection during bulk indexing.
fn apply_writer_pragmas(conn: &Connection) -> Result<(), AppError> {
    conn.execute_batch(
        r#"
        -- Larger page cache for batch upserts during initial scans (~200 MB).
        PRAGMA cache_size = -200000;

        -- Map more of the DB for writer-side btree updates on 64-bit NAS hosts.
        PRAGMA mmap_size = 268435456;
    "#,
    )?;
    Ok(())
}

// Startup integrity check
/// Runs SQLite's built-in quick integrity check on startup.
///
/// Uses `quick_check` (not `integrity_check`) to avoid a full table scan on large
/// databases. `quick_check` detects: corrupt pages, missing/extra entries in indexes,
/// and malformed records  - the most common failure modes after an abrupt power loss
/// or disk error.
///
/// We **refuse to start** if integrity check fails. Silently operating on a corrupt
/// database would make things worse. The operator must restore from backup.
pub fn verify_integrity(conn: &Connection) -> Result<(), AppError> {
    // quick_check returns one row per problem found, with "ok" if clean.
    let mut stmt = conn.prepare("PRAGMA quick_check;")?;
    let results: Vec<String> = stmt
        .query_map([], |row| row.get::<_, String>(0))?
        .collect::<Result<_, _>>()?;

    if results.len() == 1 && results[0] == "ok" {
        return Ok(());
    }

    Err(AppError::Internal(format!(
        "Database integrity check failed ({} issue(s) found). \
         The database may be corrupt  - do not start the agent. \
         Restore from backup and restart. First issue: {}",
        results.len(),
        results.first().map(|s| s.as_str()).unwrap_or("unknown"),
    )))
}

// Connection Pool
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

/// A simple thread-safe connection pool for SQLite read connections.
/// This allows Axum request handlers to check out concurrent read connections
/// and yield them back to the pool, avoiding per-request connection overhead.
#[derive(Clone)]
pub struct DbPool {
    conns: Arc<Mutex<Vec<Connection>>>,
    path: PathBuf,
}

/// A smart pointer that returns the connection to the pool when dropped.
pub struct PooledConnection {
    conn: Option<Connection>,
    pool: DbPool,
}

impl DbPool {
    /// Initializes a connection pool with exactly `size` read connections.
    pub fn new(path: PathBuf, size: usize) -> Result<Self, AppError> {
        let mut conns = Vec::with_capacity(size);
        for _ in 0..size {
            conns.push(open_read_connection(&path)?);
        }
        Ok(Self {
            conns: Arc::new(Mutex::new(conns)),
            path,
        })
    }

    /// Borrows a connection. If the pool is empty (e.g., burst of requests),
    /// we fail fast to avoid unbounded file descriptor / memory usage under abuse.
    pub fn get(&self) -> Result<PooledConnection, AppError> {
        let conn_opt = {
            let mut guard = self
                .conns
                .lock()
                .map_err(|e| AppError::Internal(e.to_string()))?;
            guard.pop()
        };
        let conn = match conn_opt {
            Some(c) => c,
            None => return Err(AppError::RateLimited),
        };
        Ok(PooledConnection {
            conn: Some(conn),
            pool: self.clone(),
        })
    }
}

impl std::ops::Deref for PooledConnection {
    type Target = Connection;
    fn deref(&self) -> &Self::Target {
        self.conn.as_ref().unwrap()
    }
}

impl std::ops::DerefMut for PooledConnection {
    fn deref_mut(&mut self) -> &mut Self::Target {
        self.conn.as_mut().unwrap()
    }
}

impl Drop for PooledConnection {
    fn drop(&mut self) {
        if let Some(conn) = self.conn.take() {
            if let Ok(mut guard) = self.pool.conns.lock() {
                guard.push(conn);
            }
        }
    }
}
