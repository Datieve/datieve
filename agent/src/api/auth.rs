// Authentication API handlers.
//
// Public routes (no session required):
//   POST /api/auth/verify-code    - exchange an access code for a session token
//   GET  /api/auth/discovery      - return agent info for the app's connection screen
//   POST /api/auth/setup/finalize - complete first-time setup
//
// Protected route:
//   GET  /api/auth/me             - return info about the current session
use axum::{
    extract::{ConnectInfo, State},
    http::StatusCode,
    response::IntoResponse,
    Extension, Json,
};
use hex;
use rand::{thread_rng, RngCore};
use serde::Deserialize;
use serde_json::json;
use std::net::SocketAddr;
use tokio::task::spawn_blocking;

use crate::api::middleware::SessionUser;
use crate::api::AppState;
use crate::error::AppError;
use rusqlite::OptionalExtension;

fn verify_admin_code(code: &str, stored_hash: &str) -> bool {
    crate::auth::password::verify(&crate::auth::admin_code_preimage(code), stored_hash)
        .unwrap_or(false)
}

fn verify_user_code(code: &str, stored_hash: &str, user_id: i64) -> bool {
    crate::auth::password::verify(
        &crate::auth::user_code_preimage(code, user_id),
        stored_hash,
    )
    .unwrap_or(false)
}

#[derive(Deserialize)]
pub struct VerifyCodePayload {
    pub code: String,
}

pub async fn verify_code(
    State(state): State<AppState>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    Json(payload): Json<VerifyCodePayload>,
) -> Result<impl IntoResponse, AppError> {
    let ip = addr.ip();
    if state.login_limiter.check_key(&ip).is_err() || state.global_login_limiter.check().is_err() {
        return Err(AppError::RateLimited);
    }

    if payload.code.is_empty() {
        return Err(AppError::BadRequest("Code required".into()));
    }
    if payload.code.len() > 128 {
        return Err(AppError::BadRequest("Input too long".into()));
    }

    tracing::debug!(ip = %ip, "login attempt");
    let expiry_hours = state.config.read().await.session_expiry_hours;
    let admin_username = state.config.read().await.admin_username.clone();
    let scope = crate::engine::setup_scope();
    let session_data = spawn_blocking(move || {
        let conn = state.db.get()?;

        let mut user_info = None;

        let admin_hash: Option<String> = conn
            .query_row(
                "SELECT code_hash FROM admin_code WHERE id = 1 AND scope_tag = ?",
                [&scope],
                |row| row.get(0),
            )
            .optional()?;

        if let Some(hash) = admin_hash {
            if verify_admin_code(&payload.code, &hash) {
                user_info = Some(("admin".to_string(), None, Some(admin_username.clone())));
            }
        }

        if user_info.is_none() {
            let lookup = crate::auth::user_code_lookup_key(&payload.code)?;
            let user_candidate: Option<(i64, String, String)> = conn
                .query_row(
                    "SELECT u.id, u.username, u.code_hash
                 FROM user_code_lookup l
                 JOIN users u ON u.id = l.user_id
                 WHERE l.lookup = ? AND l.scope_tag = ? AND u.scope_tag = ?",
                    rusqlite::params![lookup, scope, scope],
                    |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
                )
                .optional()?;

            if let Some((uid, username, hash)) = user_candidate {
                if verify_user_code(&payload.code, &hash, uid) {
                    user_info = Some(("user".to_string(), Some(uid), Some(username)));
                }
            }
        }

        if let Some((role, uid, username)) = user_info {
            let mut bytes = [0u8; 32];
            thread_rng().fill_bytes(&mut bytes);
            let token = hex::encode(bytes);
            let token_lookup_key = crate::auth::session_token_lookup_key(&token)?;
            let mac_key = crate::auth::session_request_mac_key(&token);

            let expiry_clause = format!("+{} hours", expiry_hours);
            conn.execute(
                "INSERT INTO sessions (token, scope_tag, role, user_id, expires_at) VALUES (?, ?, ?, ?, datetime('now', ?))",
                rusqlite::params![token_lookup_key, scope, role, uid, expiry_clause],
            )?;

            tracing::info!(ip = %ip, %role, username = ?username, "login ok");
            let resp = json!({ "token": token, "mac_key": mac_key, "role": role, "username": username });
            return Ok(resp);
        }

        tracing::warn!(ip = %ip, "login failed: invalid code");
        Err(AppError::Unauthorized)
    })
    .await
    .map_err(|_| AppError::Internal("Task failed".into()))??;

    Ok(Json(session_data))
}

// One-time setup
#[derive(Deserialize)]
pub struct FinalizeSetupPayload {
    pub friendly_name: String,
    pub watched_paths: Vec<String>,
    pub exclusion_patterns: Vec<String>,
    pub app_admin_code: String,
    pub admin_username: String,
    pub users: Vec<UserSetup>,

    #[serde(default = "default_snapshot_sync")]
    pub snapshot_sync_interval_secs: u64,
    pub ghost_file_prune_days: Option<u32>,

    pub manage_username: String,
    pub manage_password: String,
}

fn default_snapshot_sync() -> u64 {
    5
}

#[derive(Deserialize)]
pub struct UserSetup {
    pub username: String,
    pub code: String,
    pub allowed_paths: Vec<String>,
}

pub async fn finalize_setup(
    State(state): State<AppState>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    Json(payload): Json<FinalizeSetupPayload>,
) -> Result<impl IntoResponse, AppError> {
    let ip = addr.ip();
    if state.login_limiter.check_key(&ip).is_err() || state.global_login_limiter.check().is_err() {
        return Err(AppError::RateLimited);
    }

    if state.config.read().await.is_setup {
        return Err(AppError::Forbidden("Setup already completed".into()));
    }

    if payload.friendly_name.trim().is_empty() {
        return Err(AppError::BadRequest("Name required".into()));
    }
    tracing::info!("Desktop app submitted final setup configuration.");
    if payload.app_admin_code.is_empty() {
        return Err(AppError::BadRequest("Admin code required".into()));
    }
    if payload.admin_username.trim().is_empty() {
        return Err(AppError::BadRequest("Admin name required".into()));
    }
    if payload.manage_password.is_empty() {
        return Err(AppError::BadRequest("Management password required".into()));
    }
    if payload.watched_paths.is_empty() {
        return Err(AppError::BadRequest("At least one path required".into()));
    }

    let mut sanitized_watched_paths = Vec::new();
    let mut watched_path_set = std::collections::HashSet::new();
    for path in &payload.watched_paths {
        let safe_path = crate::api::admin::normalize_path(path)?;
        if !safe_path.exists() || !safe_path.is_dir() {
            return Err(AppError::BadRequest(format!(
                "Path does not exist or is not a directory: {}",
                path
            )));
        }
        let path_str = safe_path.to_string_lossy().into_owned();
        if !watched_path_set.insert(path_str.clone()) {
            return Err(AppError::BadRequest(format!(
                "Duplicate watched path: {}",
                path_str
            )));
        }
        sanitized_watched_paths.push(path_str);
    }

    let mut usernames = std::collections::HashSet::new();
    let mut user_code_lookups = std::collections::HashSet::new();
    let mut sanitized_users = Vec::new();
    for user in &payload.users {
        if user.username.trim().is_empty() {
            return Err(AppError::BadRequest("Username cannot be empty".into()));
        }
        if user.code.is_empty() {
            return Err(AppError::BadRequest(format!(
                "Code for {} is required",
                user.username
            )));
        }
        if user.code.len() > 128 {
            return Err(AppError::BadRequest(format!(
                "Code for {} is too long",
                user.username
            )));
        }
        if !usernames.insert(user.username.clone()) {
            return Err(AppError::BadRequest(format!(
                "Duplicate username: {}",
                user.username
            )));
        }
        let lookup = crate::auth::user_code_lookup_key(&user.code)?;
        if !user_code_lookups.insert(lookup) {
            return Err(AppError::BadRequest(
                "Duplicate user codes are not allowed".into(),
            ));
        }

        let mut allowed_paths = Vec::new();
        for path in &user.allowed_paths {
            let safe_path = crate::api::admin::normalize_path(path)?;
            let path_str = safe_path.to_string_lossy().into_owned();
            let within_any_root = sanitized_watched_paths.iter().any(|root| {
                path_str == *root || path_str.starts_with(&format!("{}/", root))
            });
            if !within_any_root {
                return Err(AppError::BadRequest(format!(
                    "User {} references a path outside any watched folder: {}",
                    user.username, path
                )));
            }
            allowed_paths.push(path_str);
        }

        sanitized_users.push(UserSetup {
            username: user.username.clone(),
            code: user.code.clone(),
            allowed_paths,
        });
    }

    let config_path = state.config_path.clone();
    let exclusions = payload.exclusion_patterns.clone();
    let scanner_exclusions = exclusions.clone();
    let friendly_name = payload.friendly_name.clone();
    let app_admin_code = payload.app_admin_code.clone();
    let new_admin_username = payload.admin_username.trim().to_string();
    let manage_username = payload.manage_username.trim().to_string();
    let manage_password = payload.manage_password.clone();
    let snapshot_sync_interval_secs = payload.snapshot_sync_interval_secs.clamp(2, 10);
    let deleted_file_prune_days = payload.ghost_file_prune_days;
    let old_config = state.config.read().await.clone();
    let mut new_config = old_config.clone();
    new_config.is_setup = true;
    new_config.friendly_name = friendly_name;
    new_config.admin_username = new_admin_username;
    new_config.management_username = manage_username.clone();
    new_config.snapshot_sync_interval_secs = snapshot_sync_interval_secs;
    new_config.trickle_sync_files_per_second = 0;
    new_config.deleted_file_prune_days = deleted_file_prune_days;
    if !payload.exclusion_patterns.is_empty() {
        new_config.exclusion_patterns = payload.exclusion_patterns.clone();
    }
    let db = state.db.clone();
    let config_path_for_setup = config_path.clone();
    let new_config_for_setup = new_config.clone();
    let old_config_for_setup = old_config.clone();

    let scope = crate::engine::setup_scope();
    let mounted_folders = spawn_blocking(move || {
        let mut conn = db.get()?;

        let app_admin_hash =
            crate::auth::password::hash(&crate::auth::admin_code_preimage(&app_admin_code))?;
        let manage_hash = crate::auth::password::hash(&crate::auth::manage_password_preimage(
            &manage_password,
        ))?;

        let tx = conn.transaction().map_err(AppError::Database)?;

        let exclusions_json = serde_json::to_string(&exclusions).unwrap_or_default();
        let mut mounted = Vec::new();
        for path in sanitized_watched_paths {
            tx.execute(
                "INSERT INTO watched_folders (path, exclusion_patterns, scope_tag) VALUES (?, ?, ?)",
                rusqlite::params![path, exclusions_json, scope],
            )?;
            let id = tx.last_insert_rowid();
            tx.execute(
                "INSERT OR IGNORE INTO folders (name, scope_tag, parent_id, watched_folder_id) VALUES ('', ?, NULL, ?)",
                rusqlite::params![scope, id],
            )?;
            mounted.push((id, path));
        }

        for user_data in sanitized_users {
            let u_email = format!("{}@local.lan", user_data.username.to_lowercase());
            tx.execute(
                "INSERT INTO users (username, email, code_hash, scope_tag) VALUES (?, ?, '', ?)",
                rusqlite::params![&user_data.username, &u_email, scope],
            )?;
            let uid = tx.last_insert_rowid();
            let u_hash = crate::auth::password::hash(&crate::auth::user_code_preimage(
                &user_data.code,
                uid,
            ))?;
            tx.execute(
                "UPDATE users SET code_hash = ? WHERE id = ? AND scope_tag = ?",
                rusqlite::params![u_hash, uid, scope],
            )?;
            let lookup = crate::auth::user_code_lookup_key(&user_data.code)?;
            tx.execute(
                "INSERT INTO user_code_lookup (lookup, scope_tag, user_id) VALUES (?, ?, ?)",
                rusqlite::params![lookup, scope, uid],
            )?;

            for path in user_data.allowed_paths {
                if let Some((fid, watched_root)) = mounted.iter().find(|(_, root)| {
                    path == *root || path.starts_with(&format!("{}/", root))
                }) {
                    let path_prefix: Option<String> = if path == *watched_root {
                        None
                    } else {
                        Some(path[watched_root.len() + 1..].to_string())
                    };
                    tx.execute(
                        "INSERT INTO user_folders (user_id, watched_folder_id, scope_tag, allow_deleted, path_prefix) VALUES (?, ?, ?, 1, ?)",
                        rusqlite::params![uid, fid, scope, path_prefix],
                    )?;
                }
            }
        }

        tx.execute(
            "INSERT OR REPLACE INTO admin_code (id, code_hash, scope_tag) VALUES (1, ?, ?)",
            rusqlite::params![app_admin_hash, scope],
        )?;

        tx.execute(
            "INSERT OR REPLACE INTO admin_manage_code (id, code_hash, scope_tag) VALUES (1, ?, ?)",
            rusqlite::params![manage_hash, scope],
        )?;

        tx.commit().map_err(AppError::Database)?;
        if let Err(e) = new_config_for_setup.save(&config_path_for_setup) {
            let _ = old_config_for_setup.save(&config_path_for_setup);
            return Err(e);
        }
        Ok::<_, AppError>(mounted)
    })
    .await
    .map_err(|_| AppError::Internal("Task failed".into()))??;

    for (id, path) in mounted_folders {
        if !state.scan_orchestrator.try_claim(&state.db, id)? {
            continue;
        }
        let orch = state.scan_orchestrator.clone();
        let tx = state.indexer_tx.clone();
        let status_tx = state.status_tx.clone();
        let exclusions = scanner_exclusions.clone();
        tokio::spawn(async move {
            let handle = crate::indexer::scanner::spawn_scanner(
                tx,
                status_tx,
                id,
                path,
                exclusions,
                0,
            );
            let _ = handle.await;
            orch.release(id);
        });
    }

    {
        let mut cfg = state.config.write().await;
        *cfg = new_config;
    }

    tracing::info!("Setup complete. Indexing has started.");
    Ok(StatusCode::OK)
}

pub async fn discovery(State(state): State<AppState>) -> Result<impl IntoResponse, AppError> {
    let cfg = state.config.read().await;
    let name = cfg.friendly_name.clone();
    let is_setup = cfg.is_setup;
    let fingerprint = std::fs::read_to_string(cfg.data_dir.join("agent.cert.fingerprint.der"))
        .ok()
        .map(|fp| fp.trim().to_string())
        .filter(|fp| !fp.is_empty());
    Ok(Json(json!({
        "hostname": name,
        "version": env!("CARGO_PKG_VERSION"),
        "is_setup": is_setup,
        "fingerprint": fingerprint
    })))
}

pub async fn me(Extension(session): Extension<SessionUser>) -> Result<impl IntoResponse, AppError> {
    Ok(Json(session))
}