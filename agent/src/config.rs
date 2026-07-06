use serde::{Deserialize, Serialize};
use std::io::Write;
use std::path::{Path, PathBuf};

use crate::error::AppError;

// Platform
/// The NAS platform running the agent.
/// Used for platform-specific setup and discovery.
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Platform {
    /// Unraid OS (Slackware-based)
    #[default]
    Unraid,
    /// TrueNAS SCALE (Debian-based)
    TrueNas,
}

impl Platform {
    pub fn detect() -> Self {
        if std::path::Path::new("/etc/unraid-version").exists() {
            return Platform::Unraid;
        }
        if let Ok(os_release) = std::fs::read_to_string("/etc/os-release") {
            if os_release.to_lowercase().contains("truenas") {
                return Platform::TrueNas;
            }
        }
        Platform::Unraid
    }
}

// Config struct
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    /// HTTP port to bind on
    #[serde(default = "defaults::port")]
    pub port: u16,

    /// Address to bind to (use "0.0.0.0" for all interfaces)
    #[serde(default = "defaults::bind_address")]
    pub bind_address: String,

    /// Runtime-only: always set to the directory containing the agent binary.
    /// Not read from or written to config.json (avoids stale paths after moves).
    #[serde(skip)]
    pub data_dir: PathBuf,

    /// Maximum simultaneous HTTP connections
    #[serde(default = "defaults::max_connections")]
    pub max_connections: usize,

    /// Session expiry in hours (default: 168 = 7 days)
    #[serde(default = "defaults::session_expiry_hours")]
    pub session_expiry_hours: u64,

    /// Login rate limit: max attempts per minute per IP
    #[serde(default = "defaults::login_rate_limit_per_minute")]
    pub login_rate_limit_per_minute: u32,

    /// General API rate limit: max requests per minute per IP
    #[serde(default = "defaults::general_rate_limit_per_minute")]
    pub general_rate_limit_per_minute: u32,

    /// Auth cache TTL (milliseconds). 0 disables caching so revocations take effect immediately.
    #[serde(default = "defaults::auth_cache_ttl_ms")]
    pub auth_cache_ttl_ms: u64,

    /// Allowed CORS origins (typically Tauri app + local dev)
    #[serde(default = "defaults::allowed_origins")]
    pub allowed_origins: Vec<String>,

    /// IndexEvent channel capacity (backpressure buffer)
    #[serde(default = "defaults::writer_channel_capacity")]
    pub writer_channel_capacity: usize,

    /// Max events to flush per SQLite transaction
    #[serde(default = "defaults::writer_flush_batch_size")]
    pub writer_flush_batch_size: usize,

    /// Max time to wait before flushing a partial batch (milliseconds)
    #[serde(default = "defaults::writer_flush_interval_ms")]
    pub writer_flush_interval_ms: u64,

    /// Is Setup Wizard complete? Looked up by UI router.
    #[serde(default)]
    pub is_setup: bool,

    /// How often to run FTS5 optimize (hours)
    #[serde(default = "defaults::fts_optimize_interval_hours")]
    pub fts_optimize_interval_hours: u64,

    /// Trickle Sync speed: files per second (100 - 1000)
    #[serde(default = "defaults::trickle_sync_files_per_second")]
    pub trickle_sync_files_per_second: u32,

    /// Friendly name for LAN discovery (e.g. "ABC Company")
    #[serde(default = "defaults::friendly_name")]
    pub friendly_name: String,

    /// How often the snapshot diff sync runs (seconds). User-configurable 2-10.
    #[serde(default = "defaults::snapshot_sync_interval_secs")]
    pub snapshot_sync_interval_secs: u64,

    /// Auto-prune deleted files from the database after X days.
    #[serde(default)]
    pub deleted_file_prune_days: Option<u32>,

    /// Display name for the admin account (shown in file manager header).
    #[serde(default = "defaults::admin_username")]
    pub admin_username: String,

    /// Username for management actions (config changes). Stored in config, not DB.
    #[serde(default = "defaults::management_username")]
    pub management_username: String,

    /// Global exclusion patterns applied to every watched folder.
    /// Glob-style: ".*" = all dotfiles, "*.tmp", "@Recycle", etc.
    #[serde(default = "defaults::exclusion_patterns")]
    pub exclusion_patterns: Vec<String>,

    /// When multiple watched folders exist, merge their immediate children into
    /// a single flat Home view (true) or show each root as a named entry (false).
    #[serde(default = "defaults::merge_root_folders")]
    pub merge_root_folders: bool,
}

/// Minimal advanced overrides (loaded from advanced_config-*.json next to main config if present; suffixed per build).
/// Keep this tiny - only things that are genuinely "advanced" like port conflicts.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct AdvancedConfig {
    #[serde(default)]
    pub port: Option<u16>,
    #[serde(default)]
    pub bind_address: Option<String>,
}

impl Config {
    /// Path to the SQLite database.
    pub fn db_path(&self) -> PathBuf {
        self.data_dir.join("datieve.db")
    }

    /// Save the current configuration securely to disk.
    pub fn save(&self, path: &Path) -> Result<(), AppError> {
        let serialized = serde_json::to_string_pretty(self)
            .map_err(|e| AppError::Config(format!("Failed to serialize config: {}", e)))?;
        write_private_file(path, serialized.as_bytes())?;
        Ok(())
    }

    /// Recursively ensures that all files in the data directory have secure permissions.
    pub fn enforce_security(&self) -> Result<(), AppError> {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if std::fs::symlink_metadata(&self.data_dir)
                .map(|m| m.file_type().is_dir())
                .unwrap_or(false)
            {
                let _ = std::fs::set_permissions(
                    &self.data_dir,
                    std::fs::Permissions::from_mode(0o700),
                );
            }

            let critical_files = vec![
                self.db_path(),
                self.data_dir.join("agent.tls.key"),
                self.data_dir.join("agent.crt"),
                self.data_dir.join("config.json"),
            ];

            for file in critical_files {
                if std::fs::symlink_metadata(&file)
                    .map(|m| m.file_type().is_file())
                    .unwrap_or(false)
                {
                    let _ = std::fs::set_permissions(file, std::fs::Permissions::from_mode(0o600));
                }
            }
        }
        Ok(())
    }
}

pub fn write_private_file(path: &Path, contents: &[u8]) -> Result<(), AppError> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(AppError::Io)?;
    }

    let file_name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("file");
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let temp_path = path.with_file_name(format!(".{file_name}.tmp-{}-{nanos}", std::process::id()));

    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&temp_path).map_err(AppError::Io)?;
    file.write_all(contents).map_err(AppError::Io)?;
    file.sync_all().map_err(AppError::Io)?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&temp_path, std::fs::Permissions::from_mode(0o600));
    }

    std::fs::rename(&temp_path, path).map_err(AppError::Io)?;
    Ok(())
}

// Load / validate
pub fn load(path: &Path, data_dir: &Path) -> Result<Config, AppError> {
    if !path.exists() {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(AppError::Io)?;
        }
        let cfg = Config::default_for(data_dir);
        // First-boot hardening: write config with strict perms and enforce data-dir perms.
        cfg.save(path)?;
        cfg.enforce_security()?;
        return Ok(cfg);
    }

    let raw = std::fs::read_to_string(path).map_err(AppError::Io)?;
    let mut cfg: Config = serde_json::from_str(&raw)
        .map_err(|e| AppError::Config(format!("Failed to parse {}: {}", path.display(), e)))?;

    // Always trust the resolved runtime directory, never a stale value in config.json.
    cfg.data_dir = data_dir.to_path_buf();

    // Load optional advanced_config.json next to main config.
    let config_dir = path.parent().unwrap_or_else(|| std::path::Path::new("."));
    let advanced_path = config_dir.join("advanced_config.json");
    if advanced_path.exists() {
        if let Ok(adv_raw) = std::fs::read_to_string(&advanced_path) {
            if let Ok(adv) = serde_json::from_str::<AdvancedConfig>(&adv_raw) {
                if let Some(p) = adv.port {
                    cfg.port = p;
                }
                if let Some(b) = adv.bind_address {
                    cfg.bind_address = b;
                }
            }
        }
    }

    if let Ok(env_port) = std::env::var("DATIEVE_PORT") {
        if let Ok(p) = env_port.parse::<u16>() {
            cfg.port = p;
        }
    }
    if let Ok(env_bind) = std::env::var("DATIEVE_BIND") {
        cfg.bind_address = env_bind;
    }
    validate(&cfg)?;
    cfg.enforce_security()?;
    Ok(cfg)
}

fn validate(cfg: &Config) -> Result<(), AppError> {
    if cfg.port == 0 {
        return Err(AppError::Config("port cannot be 0".into()));
    }
    if cfg.data_dir.as_os_str().is_empty() {
        return Err(AppError::Config("data_dir cannot be empty".into()));
    }
    if cfg.max_connections == 0 {
        return Err(AppError::Config("max_connections must be > 0".into()));
    }
    if cfg.writer_flush_batch_size == 0 {
        return Err(AppError::Config(
            "writer_flush_batch_size must be > 0".into(),
        ));
    }
    if cfg.writer_channel_capacity == 0 {
        return Err(AppError::Config(
            "writer_channel_capacity must be > 0".into(),
        ));
    }
    if cfg.snapshot_sync_interval_secs < 2 || cfg.snapshot_sync_interval_secs > 10 {
        return Err(AppError::Config(
            "snapshot_sync_interval_secs must be between 2 and 10".into(),
        ));
    }
    Ok(())
}

// Default impl
impl Config {
    pub fn default_for(data_dir: &Path) -> Self {
        let mut cfg = Self::default();
        cfg.data_dir = data_dir.to_path_buf();
        cfg
    }
}

impl Default for Config {
    fn default() -> Self {
        Self {
            port: defaults::port(),
            bind_address: defaults::bind_address(),
            data_dir: PathBuf::from("."),
            max_connections: defaults::max_connections(),
            session_expiry_hours: defaults::session_expiry_hours(),
            login_rate_limit_per_minute: defaults::login_rate_limit_per_minute(),
            general_rate_limit_per_minute: defaults::general_rate_limit_per_minute(),
            auth_cache_ttl_ms: defaults::auth_cache_ttl_ms(),
            allowed_origins: defaults::allowed_origins(),
            writer_channel_capacity: defaults::writer_channel_capacity(),
            writer_flush_batch_size: defaults::writer_flush_batch_size(),
            writer_flush_interval_ms: defaults::writer_flush_interval_ms(),
            is_setup: false,
            fts_optimize_interval_hours: defaults::fts_optimize_interval_hours(),
            trickle_sync_files_per_second: defaults::trickle_sync_files_per_second(),
            friendly_name: defaults::friendly_name(),
            snapshot_sync_interval_secs: defaults::snapshot_sync_interval_secs(),
            deleted_file_prune_days: None,
            admin_username: defaults::admin_username(),
            management_username: defaults::management_username(),
            exclusion_patterns: defaults::exclusion_patterns(),
            merge_root_folders: defaults::merge_root_folders(),
        }
    }
}

mod defaults {
    pub fn port() -> u16 {
        34514
    }
    pub fn bind_address() -> String {
        "0.0.0.0".into()
    }
    pub fn max_connections() -> usize {
        100
    }
    pub fn session_expiry_hours() -> u64 {
        24
    }
    pub fn login_rate_limit_per_minute() -> u32 {
        20
    }
    pub fn general_rate_limit_per_minute() -> u32 {
        1200
    }
    pub fn auth_cache_ttl_ms() -> u64 {
        10_000
    }
    pub fn allowed_origins() -> Vec<String> {
        vec!["tauri://localhost".into(), "http://localhost:1420".into()]
    }
    pub fn writer_channel_capacity() -> usize {
        50_000
    }
    pub fn writer_flush_batch_size() -> usize {
        25_000
    }
    pub fn writer_flush_interval_ms() -> u64 {
        500
    }
    pub fn fts_optimize_interval_hours() -> u64 {
        24
    }
    pub fn trickle_sync_files_per_second() -> u32 {
        0
    }
    pub fn friendly_name() -> String {
        "Datieve Agent".into()
    }
    pub fn snapshot_sync_interval_secs() -> u64 {
        5
    }
    pub fn admin_username() -> String {
        "admin".into()
    }

    pub fn management_username() -> String {
        "admin".into()
    }
    pub fn merge_root_folders() -> bool {
        true
    }
    pub fn exclusion_patterns() -> Vec<String> {
        vec![
            "@Recycle".into(), "#recycle".into(), ".Trash-*".into(),
            ".zfs".into(), ".datieve".into(), ".snapshot".into(),
            "@recently-snapshot".into(), ".*".into(),
        ]
    }
}
