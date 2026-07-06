pub mod consistency;
pub mod inotify;
pub mod maintenance;
pub mod matcher;
pub mod scan_orchestrator;
pub mod scanner;
mod statx;
pub mod writer;

pub fn parse_exclusions(json: &str) -> Vec<String> {
    serde_json::from_str(json).unwrap_or_else(|_| vec![
        ".zfs".into(), ".datieve".into(), ".snapshot".into(),
        "@recently-snapshot".into(), "@Recycle".into(), "#recycle".into(),
        ".Trash-*".into(),
    ])
}

pub fn is_internal_exclude_name(name: &str) -> bool {
    matches!(
        name,
        ".zfs" | ".datieve" | ".snapshot" | "@recently-snapshot" | "@Recycle" | "#recycle"
    ) || name.starts_with(".Trash-")
}

/// Events produced by the initial scanner and the snapshot sync loop.
/// The batch writer is the sole consumer  - it drains these into SQLite.
#[derive(Debug, Clone)]
pub enum IndexEvent {
    /// A full reconciliation scan started for this watched folder.
    ScanStarted {
        watched_folder_id: i64,
        generation: i64,
    },
    /// A file was found (initial scan or snapshot diff upsert).
    FileFound {
        watched_folder_id: i64,
        /// Relative path within the watched folder (e.g. `/docs/file.txt`).
        path: String,
        /// Full absolute path on disk (e.g. `/data/nas/docs/file.txt`).
        absolute_path: String,
        name: String,
        extension: Option<String>,
        size_bytes: u64,
        created_at: chrono::DateTime<chrono::Utc>,
        modified_at: chrono::DateTime<chrono::Utc>,
        device_id: Option<u64>,
        inode: Option<u64>,
        is_symlink: bool,
        scan_generation: Option<i64>,
    },
    /// A folder was found (initial scan or snapshot diff upsert).
    FolderFound {
        watched_folder_id: i64,
        path: String,
        name: String,
        device_id: Option<u64>,
        inode: Option<u64>,
        scan_generation: Option<i64>,
        created_at: Option<chrono::DateTime<chrono::Utc>>,
    },
    /// A file was deleted or moved out of the watched tree.
    FileRemoved {
        watched_folder_id: i64,
        path: String,
    },
    /// A folder was deleted or moved out of the watched tree.
    FolderRemoved {
        watched_folder_id: i64,
        path: String,
    },
    /// Progress update from the initial scanner (for admin stats endpoint).
    ScanProgress {
        watched_folder_id: i64,
        scanned: u64,
        total_estimate: Option<u64>,
    },
    /// Initial scan completed for this watched folder.
    ScanComplete {
        watched_folder_id: i64,
        scanned: u64,
    },
    /// Live event backend overflowed; the full index must be reconciled.
    FullRescanRequested { reason: String },
}

impl IndexEvent {
    pub fn watched_folder_id(&self) -> Option<i64> {
        match self {
            IndexEvent::ScanStarted {
                watched_folder_id, ..
            }
            | IndexEvent::FileFound {
                watched_folder_id, ..
            }
            | IndexEvent::FolderFound {
                watched_folder_id, ..
            }
            | IndexEvent::FileRemoved {
                watched_folder_id, ..
            }
            | IndexEvent::FolderRemoved {
                watched_folder_id, ..
            }
            | IndexEvent::ScanProgress {
                watched_folder_id, ..
            }
            | IndexEvent::ScanComplete {
                watched_folder_id, ..
            } => Some(*watched_folder_id),
            IndexEvent::FullRescanRequested { .. } => None,
        }
    }
}
