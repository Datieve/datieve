#![allow(dead_code)]
use crate::error::AppError;
use rusqlite::{Connection, OptionalExtension};

/// Initializes the database schema.
/// Since the project is in pre-deployment, we use a single consolidated block.
pub fn initialize(conn: &Connection) -> Result<(), AppError> {
    // Drop contentless FTS5 table if present  - contentless tables can't handle DELETE,
    // which the writer uses. The regular FTS5 table created below is a drop-in replacement.
    let fts_sql: Option<String> = conn
        .query_row(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name='files_fts'",
            [],
            |r| r.get(0),
        )
        .optional()
        .unwrap_or(None);
    if fts_sql.as_deref().map(|s| s.contains("content=")).unwrap_or(false) {
        conn.execute_batch("DROP TABLE IF EXISTS files_fts")?;
        tracing::info!("Dropped contentless files_fts; recreating as regular FTS5.");
    }

    let tx = conn.unchecked_transaction()?;
    tx.execute_batch(SCHEMA_SQL)?;
    tx.commit()?;
    migrate(conn)?;
    crate::db::scope::migrate_scope_columns(conn)?;
    Ok(())
}

fn migrate(conn: &Connection) -> Result<(), AppError> {
    let folder_columns: Vec<String> = conn
        .prepare("PRAGMA table_info(folders)")?
        .query_map([], |row| row.get::<_, String>(1))?
        .filter_map(Result::ok)
        .collect();
    if !folder_columns.iter().any(|name| name == "counts_dirty") {
        conn.execute(
            "ALTER TABLE folders ADD COLUMN counts_dirty INTEGER NOT NULL DEFAULT 0",
            [],
        )?;
        conn.execute_batch(
            "CREATE INDEX IF NOT EXISTS idx_folders_counts_dirty ON folders(counts_dirty) WHERE counts_dirty = 1;",
        )?;
    }
    if !folder_columns.iter().any(|name| name == "scan_generation") {
        conn.execute(
            "ALTER TABLE folders ADD COLUMN scan_generation INTEGER NOT NULL DEFAULT 0",
            [],
        )?;
        conn.execute_batch(
            "CREATE INDEX IF NOT EXISTS idx_folders_scan_generation ON folders(watched_folder_id, scan_generation);",
        )?;
    }
    if !folder_columns.iter().any(|name| name == "indexed_at") {
        conn.execute(
            "ALTER TABLE folders ADD COLUMN indexed_at TEXT",
            [],
        )?;
    }
    if !folder_columns.iter().any(|name| name == "created_at") {
        conn.execute(
            "ALTER TABLE folders ADD COLUMN created_at TEXT",
            [],
        )?;
    }

    let file_columns: Vec<String> = conn
        .prepare("PRAGMA table_info(files)")?
        .query_map([], |row| row.get::<_, String>(1))?
        .filter_map(Result::ok)
        .collect();
    if !file_columns.iter().any(|name| name == "scan_generation") {
        conn.execute(
            "ALTER TABLE files ADD COLUMN scan_generation INTEGER NOT NULL DEFAULT 0",
            [],
        )?;
        conn.execute_batch(
            "CREATE INDEX IF NOT EXISTS idx_files_scan_generation ON files(folder_id, scan_generation);",
        )?;
    }
    if !file_columns.iter().any(|name| name == "absolute_path") {
        conn.execute(
            "ALTER TABLE files ADD COLUMN absolute_path TEXT NOT NULL DEFAULT ''",
            [],
        )?;
    }

    let watched_columns: Vec<String> = conn
        .prepare("PRAGMA table_info(watched_folders)")?
        .query_map([], |row| row.get::<_, String>(1))?
        .filter_map(Result::ok)
        .collect();
    if !watched_columns.iter().any(|name| name == "scan_generation") {
        conn.execute(
            "ALTER TABLE watched_folders ADD COLUMN scan_generation INTEGER NOT NULL DEFAULT 0",
            [],
        )?;
    }
    if !watched_columns
        .iter()
        .any(|name| name == "reconcile_requested_at")
    {
        conn.execute(
            "ALTER TABLE watched_folders ADD COLUMN reconcile_requested_at TEXT",
            [],
        )?;
    }
    if !watched_columns
        .iter()
        .any(|name| name == "rescan_after_scan")
    {
        conn.execute(
            "ALTER TABLE watched_folders ADD COLUMN rescan_after_scan INTEGER NOT NULL DEFAULT 0",
            [],
        )?;
    }

    let uf_columns: Vec<String> = conn
        .prepare("PRAGMA table_info(user_folders)")?
        .query_map([], |row| row.get::<_, String>(1))?
        .filter_map(Result::ok)
        .collect();
    if !uf_columns.iter().any(|name| name == "path_prefix") {
        conn.execute("ALTER TABLE user_folders ADD COLUMN path_prefix TEXT", [])?;
    }
    // Migrate user_folders to allow multiple path entries per (user, folder).
    // Old schema: PRIMARY KEY (user_id, watched_folder_id)  - only one row per pair.
    // New schema: id AUTOINCREMENT PK, unique index on (user_id, watched_folder_id, COALESCE(path_prefix,''), scope_tag).
    if !uf_columns.iter().any(|name| name == "id") {
        conn.execute_batch(
            "CREATE TABLE user_folders_new (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER NOT NULL,
                watched_folder_id INTEGER NOT NULL,
                scope_tag TEXT NOT NULL DEFAULT '',
                allow_deleted INTEGER NOT NULL DEFAULT 0,
                path_prefix TEXT
            );
            INSERT INTO user_folders_new (user_id, watched_folder_id, scope_tag, allow_deleted, path_prefix)
                SELECT user_id, watched_folder_id, scope_tag, allow_deleted, path_prefix FROM user_folders;
            DROP TABLE user_folders;
            ALTER TABLE user_folders_new RENAME TO user_folders;
            CREATE UNIQUE INDEX IF NOT EXISTS idx_uf_unique
                ON user_folders(user_id, watched_folder_id, COALESCE(path_prefix,''), scope_tag);",
        )?;
    }

    // Open-source builds use a single empty scope tag for all rows.
    for table in crate::db::scope::SCOPED_TABLES {
        conn.execute(
            &format!("UPDATE {table} SET scope_tag = '' WHERE scope_tag != ''"),
            [],
        )?;
    }

    Ok(())
}

// SQL
const SCHEMA_SQL: &str = r##"
CREATE TABLE IF NOT EXISTS admin_tokens (
    id INTEGER PRIMARY KEY CHECK(id = 1),
    token_hash TEXT NOT NULL,
    scope_tag TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    is_active INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS admin_code (
    id INTEGER PRIMARY KEY CHECK(id = 1),
    code_hash TEXT NOT NULL,
    scope_tag TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS admin_manage_code (
    id INTEGER PRIMARY KEY DEFAULT 1,
    code_hash TEXT NOT NULL,
    scope_tag TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS watched_folders (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    path TEXT NOT NULL UNIQUE,
    scope_tag TEXT NOT NULL DEFAULT '',
    device_id INTEGER,
    exclusion_patterns TEXT NOT NULL DEFAULT '[".zfs",".datieve",".snapshot","@recently-snapshot","@Recycle","#recycle",".Trash-*"]',
    added_at TEXT NOT NULL DEFAULT (datetime('now')),
    scan_status TEXT NOT NULL DEFAULT 'pending',
    total_files_estimate INTEGER NOT NULL DEFAULT 0,
    files_scanned INTEGER NOT NULL DEFAULT 0,
    scan_generation INTEGER NOT NULL DEFAULT 0,
    reconcile_requested_at TEXT,
    rescan_after_scan INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS folders (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    scope_tag TEXT NOT NULL DEFAULT '',
    parent_id INTEGER REFERENCES folders(id) ON DELETE CASCADE,
    watched_folder_id INTEGER NOT NULL REFERENCES watched_folders(id) ON DELETE CASCADE,
    file_count INTEGER NOT NULL DEFAULT 0,
    total_size_bytes INTEGER NOT NULL DEFAULT 0,
    device_id INTEGER,
    inode INTEGER,
    is_deleted INTEGER NOT NULL DEFAULT 0,
    deleted_at TEXT,
    counts_dirty INTEGER NOT NULL DEFAULT 0,
    scan_generation INTEGER NOT NULL DEFAULT 0,
    indexed_at TEXT,
    UNIQUE(name, parent_id, watched_folder_id)
);
CREATE INDEX IF NOT EXISTS idx_folders_parent ON folders(parent_id);
CREATE INDEX IF NOT EXISTS idx_folders_browse ON folders(parent_id, is_deleted, scope_tag, name);
CREATE INDEX IF NOT EXISTS idx_folders_counts_dirty ON folders(counts_dirty) WHERE counts_dirty = 1;
CREATE INDEX IF NOT EXISTS idx_folders_watched ON folders(watched_folder_id);
CREATE INDEX IF NOT EXISTS idx_folders_inode ON folders(device_id, inode) WHERE inode IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_folders_scan_generation ON folders(watched_folder_id, scan_generation);
CREATE UNIQUE INDEX IF NOT EXISTS idx_folders_single_root ON folders(watched_folder_id) WHERE parent_id IS NULL;

CREATE TABLE IF NOT EXISTS files (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    scope_tag TEXT NOT NULL DEFAULT '',
    extension TEXT,
    folder_id INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
    size_bytes INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    modified_at TEXT NOT NULL,
    device_id INTEGER,
    inode INTEGER,
    is_deleted INTEGER NOT NULL DEFAULT 0,
    deleted_at TEXT,
    last_seen_at TEXT NOT NULL DEFAULT (datetime('now')),
    indexed_at TEXT NOT NULL DEFAULT (datetime('now')),
    is_symlink INTEGER NOT NULL DEFAULT 0,
    scan_generation INTEGER NOT NULL DEFAULT 0,
    absolute_path TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_files_inode ON files(device_id, inode) WHERE inode IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_files_active_name ON files(name, folder_id) WHERE is_deleted = 0;
CREATE INDEX IF NOT EXISTS idx_files_folder ON files(folder_id);
CREATE INDEX IF NOT EXISTS idx_files_browse ON files(folder_id, is_deleted, scope_tag, name);
CREATE INDEX IF NOT EXISTS idx_files_scan_generation ON files(folder_id, scan_generation);

CREATE VIRTUAL TABLE IF NOT EXISTS files_fts USING fts5(name, tokenize='unicode61 remove_diacritics 2', prefix='2');

	CREATE TABLE IF NOT EXISTS users (
	    id INTEGER PRIMARY KEY AUTOINCREMENT,
	    username TEXT NOT NULL UNIQUE,
	    email TEXT NOT NULL UNIQUE,
	    code_hash TEXT NOT NULL,
	    scope_tag TEXT NOT NULL DEFAULT '',
	    created_at TEXT NOT NULL DEFAULT (datetime('now'))
	);
	CREATE UNIQUE INDEX IF NOT EXISTS idx_users_email ON users(email);

	CREATE TABLE IF NOT EXISTS user_code_lookup (
	    lookup TEXT PRIMARY KEY,
	    scope_tag TEXT NOT NULL DEFAULT '',
	    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE
	);
	CREATE INDEX IF NOT EXISTS idx_user_code_lookup_user ON user_code_lookup(user_id);

CREATE TABLE IF NOT EXISTS user_folders (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    watched_folder_id INTEGER NOT NULL REFERENCES watched_folders(id) ON DELETE CASCADE,
    scope_tag TEXT NOT NULL DEFAULT '',
    allow_deleted INTEGER NOT NULL DEFAULT 0,
    path_prefix TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_uf_unique
    ON user_folders(user_id, watched_folder_id, COALESCE(path_prefix,''), scope_tag);

CREATE TABLE IF NOT EXISTS sessions (
    token TEXT PRIMARY KEY,
    scope_tag TEXT NOT NULL DEFAULT '',
    role TEXT NOT NULL, -- 'admin' or 'user'
    user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    expires_at TEXT NOT NULL,
    last_used_at TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Saved shortcuts into the browse tree (web UI "bookmarks"). Owned either by
-- the single admin (role = 'admin', user_id NULL) or by a specific user.
CREATE TABLE IF NOT EXISTS bookmarks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    role TEXT NOT NULL,
    user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
    scope_tag TEXT NOT NULL DEFAULT '',
    kind TEXT NOT NULL, -- 'folder' or 'file'
    target_id INTEGER NOT NULL,
    label TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_bookmarks_owner ON bookmarks(role, user_id, scope_tag);


"##;
