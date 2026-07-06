// Crate root. Each submodule handles a distinct concern:
//   api       - HTTP routes and handlers
//   auth      - password hashing and session token helpers
//   cli       - command-line interface and startup sequence
//   config    - config file loading, defaults, validation
//   crypto    - TLS certificate generation
//   db        - SQLite connection management and schema
//   discovery_udp - LAN agent discovery
//   engine    - scope helpers (single-scope build)
//   error     - shared AppError type
//   indexer   - filesystem scanning, inotify, and batch DB writes
pub mod api;
pub mod auth;
pub mod cli;
pub mod discovery_udp;
#[cfg(target_env = "musl")]
mod compat;
pub mod config;
pub mod crypto;
pub mod db;
pub mod engine;
pub mod error;
pub mod indexer;
