//! Scope-tag schema helpers.
//!
//! Every table that holds user data has a `scope_tag` column. In this build
//! the tag is always the empty string (see engine/mod.rs), but the column is
//! present and indexed so the schema stays compatible if scopes are ever used.
//!
//! `migrate_scope_columns` is called on every startup and is idempotent  - safe
//! to run against a fresh DB or one that already has the column.

use rusqlite::Connection;

use crate::error::AppError;

pub const SCOPED_TABLES: &[&str] = &[
    "admin_tokens",
    "admin_code",
    "admin_manage_code",
    "users",
    "user_code_lookup",
    "sessions",
    "user_folders",
    "watched_folders",
    "folders",
    "files",
];

/// Add `scope_tag` column to any table that doesn't have it yet (idempotent).
pub fn migrate_scope_columns(conn: &Connection) -> Result<(), AppError> {
    for table in SCOPED_TABLES {
        let has_column = conn
            .prepare(&format!("PRAGMA table_info({table})"))?
            .query_map([], |row| row.get::<_, String>(1))?
            .filter_map(Result::ok)
            .any(|name| name == "scope_tag");
        if !has_column {
            conn.execute(
                &format!("ALTER TABLE {table} ADD COLUMN scope_tag TEXT NOT NULL DEFAULT ''"),
                [],
            )?;
            conn.execute(
                &format!("CREATE INDEX IF NOT EXISTS idx_{table}_scope ON {table}(scope_tag)"),
                [],
            )?;
        }
    }
    Ok(())
}
