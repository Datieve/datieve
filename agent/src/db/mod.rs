// Database layer.
//   pool   - SQLite connection pool (one write connection, N read connections)
//   schema - table definitions and idempotent migrations
//   scope  - scope_tag column helpers (always empty in this build)
pub mod pool;
pub mod schema;
pub mod scope;
