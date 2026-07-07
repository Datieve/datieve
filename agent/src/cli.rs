use clap::{Parser, Subcommand};
use std::path::PathBuf;
use std::sync::Arc;

use crate::api::ScanStatus;
use crate::config::Config;
use crate::error::AppError;

use reqwest;

#[derive(Parser)]
#[command(
    name = "datieve",
    about = "Datieve NAS Indexing Agent",
    version,
    propagate_version = true
)]
pub struct Cli {
    /// Log level (info, debug, trace, etc.)
    #[arg(long, global = true, default_value = "info")]
    pub log: String,

    #[command(subcommand)]
    pub command: Command,
}

#[derive(Subcommand)]
pub enum Command {
    /// Start the indexing agent and HTTP API server
    Serve,

    /// Download and install the latest agent binary from GitHub
    Update,
}

pub async fn run(cli: Cli) -> Result<(), AppError> {
    let data_dir = resolve_data_dir()?;
    std::fs::create_dir_all(&data_dir).map_err(AppError::Io)?;

    let config_path = data_dir.join("config.json");
    let cfg = crate::config::load(&config_path, &data_dir)?;

    match cli.command {
        Command::Serve => commands::serve(cfg, config_path).await,
        Command::Update => commands::update_binary(cfg).await,
    }
}

fn resolve_data_dir() -> Result<PathBuf, AppError> {
    let exe = std::env::current_exe().map_err(AppError::Io)?;
    let dir = exe
        .parent()
        .map(PathBuf::from)
        .ok_or_else(|| AppError::Config("Could not determine binary directory".into()))?;
    tracing::debug!("Agent binary: {}", exe.display());
    tracing::debug!("Agent data directory: {}", dir.display());
    Ok(dir)
}

mod commands {
    use super::*;
    use governor::RateLimiter;
    use std::num::NonZeroU32;
    use tokio::sync::watch;

    pub async fn serve(cfg: Config, config_path: PathBuf) -> Result<(), AppError> {
        std::fs::create_dir_all(&cfg.data_dir).map_err(AppError::Io)?;

        if let Some(parent) = cfg.db_path().parent() {
            std::fs::create_dir_all(parent)?;
        }

        {
            let init_conn = crate::db::pool::open_write_connection(&cfg.db_path())?;
            crate::db::schema::initialize(&init_conn)?;
            crate::db::pool::verify_integrity(&init_conn)?;
        }

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ =
                std::fs::set_permissions(&cfg.db_path(), std::fs::Permissions::from_mode(0o600));
        }

        let pool_size = std::cmp::max(4, std::cmp::min(cfg.max_connections, 32));
        let db_pool = crate::db::pool::DbPool::new(cfg.db_path(), pool_size)?;

        let (tx, rx) = tokio::sync::mpsc::channel(cfg.writer_channel_capacity);
        let (status_tx, status_rx) = watch::channel(ScanStatus::Ready);
        let sync_status = if cfg.is_setup {
            crate::api::SnapshotSyncStatus::Healthy
        } else {
            crate::api::SnapshotSyncStatus::Unavailable
        };
        let (sync_status_tx, sync_status_rx) = watch::channel(sync_status);
        let (file_change_tx_inner, file_change_rx) = watch::channel(0u64);
        let file_change_tx = Arc::new(file_change_tx_inner);
        let shared_config = Arc::new(tokio::sync::RwLock::new(cfg.clone()));

        let batch_size = cfg.writer_flush_batch_size;
        let flush_interval = cfg.writer_flush_interval_ms;
        let write_conn = crate::db::pool::open_write_connection(&cfg.db_path())?;
        let writer = crate::indexer::writer::WriterState::new(
            rx,
            write_conn,
            status_tx.clone(),
            file_change_tx.clone(),
        );

        std::thread::spawn(move || {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap();
            rt.block_on(async {
                writer.run(batch_size, flush_interval).await;
            });
        });

        let scan_orchestrator = crate::indexer::scan_orchestrator::ScanOrchestrator::new();

        if cfg.is_setup {
            let watched_folders: Vec<(i64, String, Vec<String>, String)> = {
                let conn = db_pool.get()?;
                let scope = crate::engine::scope_tag();
                let mut stmt = conn.prepare(
                    "SELECT id, path, exclusion_patterns, scan_status FROM watched_folders WHERE scope_tag = ?",
                )?;
                let rows = stmt.query_map([scope], |row| {
                    let id: i64 = row.get(0)?;
                    let path: String = row.get(1)?;
                    let patterns_json: String = row.get(2)?;
                    let scan_status: String = row.get(3)?;
                    let patterns = crate::indexer::parse_exclusions(&patterns_json);
                    Ok((id, path, patterns, scan_status))
                })?;
                rows.collect::<Result<Vec<_>, _>>()?
            };

            let mut scan_jobs = Vec::new();
            crate::indexer::scan_orchestrator::ScanOrchestrator::recover_stale_scans(&db_pool)?;

            for (id, path, patterns, _scan_status) in &watched_folders {
                scan_jobs.push((*id, path.clone(), patterns.clone()));
            }

            crate::indexer::inotify::spawn_inotify_watcher(
                db_pool.clone(),
                tx.clone(),
                status_tx.clone(),
                Some(cfg.data_dir.clone()),
            );

            let tx_scanner = tx.clone();
            let status_tx_scanner = status_tx.clone();
            let db_scanner = db_pool.clone();
            let orch_startup = scan_orchestrator.clone();
            let orch_pending = scan_orchestrator.clone();
            let scan_speed = cfg.trickle_sync_files_per_second;

            crate::indexer::scanner::spawn_pending_scan_watcher(
                db_pool.clone(),
                tx.clone(),
                status_tx.clone(),
                scan_speed,
                orch_pending,
            );
            crate::indexer::consistency::spawn_consistency_task(db_pool.clone());

            tracing::info!(
                "Launching startup scans for {} watched folder(s). \
                 Scanning to catch any changes since last run.",
                scan_jobs.len()
            );
            tokio::spawn(async move {
                for (id, path, patterns) in scan_jobs {
                    let Ok(true) = orch_startup.try_claim(&db_scanner, id) else {
                        continue;
                    };
                    tracing::info!("Startup scan starting for folder {id}: {path}");
                    let handle = crate::indexer::scanner::spawn_scanner(
                        tx_scanner.clone(),
                        status_tx_scanner.clone(),
                        id,
                        path,
                        patterns,
                        scan_speed,
                    );
                    let _ = handle.await;
                    orch_startup.release(id);
                }
                tracing::info!("Startup scan batch complete.");
            });

            crate::indexer::maintenance::spawn_maintenance_task(
                cfg.db_path(),
                900,
                cfg.fts_optimize_interval_hours * 3600,
                cfg.deleted_file_prune_days,
            );
        } else {
            tracing::info!(
                "Setup not complete. Waiting for the desktop app at https://{}:{}",
                cfg.bind_address,
                cfg.port
            );
        }

        let login_quota = governor::Quota::per_minute(
            NonZeroU32::new(cfg.login_rate_limit_per_minute)
                .unwrap_or_else(|| NonZeroU32::new(20).unwrap()),
        );
        let global_login_quota = governor::Quota::per_minute(NonZeroU32::new(120).unwrap());
        let api_quota = governor::Quota::per_minute(
            NonZeroU32::new(cfg.general_rate_limit_per_minute)
                .unwrap_or_else(|| NonZeroU32::new(600).unwrap()),
        );

        let udp_config = shared_config.clone();
        let udp_data_dir = cfg.data_dir.clone();

        let state = crate::api::AppState {
            config: shared_config,
            config_path,
            db: db_pool,
            indexer_tx: tx,
            login_limiter: Arc::new(RateLimiter::keyed(login_quota)),
            global_login_limiter: Arc::new(RateLimiter::direct(global_login_quota)),
            api_limiter: Arc::new(RateLimiter::keyed(api_quota)),
            allowed_origins: cfg.allowed_origins.clone(),
            status_tx: status_tx.clone(),
            _status_rx: status_rx,
            sync_status_tx,
            sync_status_rx,
            file_change_tx,
            file_change_rx,
            start_time: std::time::Instant::now(),
            session_cache: Arc::new(tokio::sync::RwLock::new(lru::LruCache::new(
                std::num::NonZeroUsize::new(10_000).unwrap(),
            ))),
            max_concurrency: pool_size,
            auth_cache_ttl_ms: cfg.auth_cache_ttl_ms,
            scan_orchestrator,
            folder_locks: std::sync::Arc::new(std::sync::RwLock::new(std::collections::HashMap::new())),
        };

        let cert_path = cfg.data_dir.join("agent.crt");
        let key_path = cfg.data_dir.join("agent.tls.key");
        crate::crypto::tls::ensure_certs(&cert_path, &key_path)?;

        let rustls_config =
            axum_server::tls_rustls::RustlsConfig::from_pem_file(&cert_path, &key_path)
                .await
                .map_err(|e| AppError::Internal(format!("TLS config failed: {}", e)))?;

        let addr: std::net::SocketAddr = format!("{}:{}", cfg.bind_address, cfg.port)
            .parse()
            .map_err(|e| AppError::Internal(format!("Invalid bind address: {}", e)))?;

        tracing::info!(
            "Datieve Agent active at https://{} (data directory: {})",
            addr,
            cfg.data_dir.display()
        );

        crate::discovery_udp::spawn_udp_discovery(udp_config, udp_data_dir);

        let app = crate::api::build_router(state);
        axum_server::bind_rustls(addr, rustls_config)
            .serve(app.into_make_service_with_connect_info::<std::net::SocketAddr>())
            .await
            .map_err(|e| {
                if e.kind() == std::io::ErrorKind::AddrInUse {
                    AppError::Internal(format!(
                        "Port {} is already in use on {}. Ensure no other process is bound to it and restart the agent.",
                        cfg.port, cfg.bind_address
                    ))
                } else {
                    AppError::Internal(e.to_string())
                }
            })?;

        Ok(())
    }

    pub async fn update_binary(_cfg: Config) -> Result<(), AppError> {
        const REPO: &str = "Datieve/datieve";
        const ASSET: &str = "datieve-agent";
        const CURRENT: &str = env!("CARGO_PKG_VERSION");

        println!("Checking for updates (current: v{CURRENT})...");

        let client = reqwest::Client::builder()
            .user_agent(concat!("datieve-agent/", env!("CARGO_PKG_VERSION")))
            .build()
            .map_err(|e| AppError::Internal(e.to_string()))?;

        let url = format!("https://api.github.com/repos/{REPO}/releases/latest");
        let resp: serde_json::Value = client
            .get(&url)
            .header("Accept", "application/vnd.github+json")
            .send()
            .await
            .map_err(|e| AppError::Internal(format!("GitHub request failed: {e}")))?
            .json()
            .await
            .map_err(|e| AppError::Internal(format!("Invalid response: {e}")))?;

        let tag = resp["tag_name"]
            .as_str()
            .unwrap_or("")
            .trim_start_matches('v');

        if tag.is_empty() {
            return Err(AppError::Internal("Could not read tag_name from release".into()));
        }

        println!("Latest version:  v{tag}");

        if !is_newer(tag, CURRENT) {
            println!("Already up to date.");
            return Ok(());
        }

        let download_url = resp["assets"]
            .as_array()
            .and_then(|arr| arr.iter().find(|a| a["name"].as_str() == Some(ASSET)))
            .and_then(|a| a["browser_download_url"].as_str())
            .ok_or_else(|| {
                AppError::Internal(format!(
                    "No asset named '{ASSET}' in release v{tag}. \
                     Check https://github.com/{REPO}/releases for available assets."
                ))
            })?
            .to_owned();

        println!("Downloading from: {download_url}");

        let bytes = client
            .get(&download_url)
            .send()
            .await
            .map_err(|e| AppError::Internal(format!("Download failed: {e}")))?
            .bytes()
            .await
            .map_err(|e| AppError::Internal(format!("Download incomplete: {e}")))?;

        let exe = std::env::current_exe().map_err(AppError::Io)?;
        let tmp = exe.with_extension("new");

        std::fs::write(&tmp, &bytes)
            .map_err(|e| AppError::Internal(format!("Failed to write update: {e}")))?;

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(&tmp).map_err(AppError::Io)?.permissions();
            perms.set_mode(0o755);
            std::fs::set_permissions(&tmp, perms).map_err(AppError::Io)?;
        }

        std::fs::rename(&tmp, &exe).map_err(|e| {
            AppError::Internal(format!(
                "Failed to replace binary (need write access to install dir? same filesystem?): {e}"
            ))
        })?;

        println!("Updated to v{tag}. Restart the agent to apply:");
        println!("  datieve-agent serve");
        Ok(())
    }

    fn is_newer(latest: &str, current: &str) -> bool {
        let parse = |s: &str| -> (u32, u32, u32) {
            let mut it = s.splitn(3, '.').map(|p| p.parse::<u32>().unwrap_or(0));
            (it.next().unwrap_or(0), it.next().unwrap_or(0), it.next().unwrap_or(0))
        };
        parse(latest) > parse(current)
    }
}