use axum::{
    extract::{ConnectInfo, OriginalUri, Request, State},
    http::header,
    middleware::Next,
    response::Response,
    Extension,
};
use std::net::SocketAddr;
use tracing::warn;

use super::AppState;
use crate::error::AppError;
use rusqlite::OptionalExtension;
use serde::Serialize;
use sha2::{Digest, Sha256};

const NONCE_HEADER: &str = "x-datieve-nonce";
const MAC_HEADER: &str = "x-datieve-mac";

/// Session metadata injected into `axum::Extension` upon successful auth.
/// Contains the list of IDs this user is physically allowed to see.
#[derive(Clone, Debug, Serialize)]
pub struct SessionUser {
    pub role: String, // "admin" or "user"
    pub user_id: Option<i64>,
    pub username: Option<String>,
    /// Watched folder IDs this user may access (for ownership checks).
    pub allowed_folder_ids: Vec<i64>,
    /// Watched folders where this user is permitted to see deleted entries.
    /// Admin implicitly has this for all folders.
    pub allowed_deleted_folder_ids: Vec<i64>,
    /// Convenience flag for UI logic; true if any folder allows deleted.
    pub allow_deleted: bool,
    /// Resolved folder-table IDs that serve as the user's root browse entry points.
    /// Accounts for path_prefix: if a user has access to `/barrel/A`, this is the
    /// folder.id for `A` within the `/barrel` watched tree, not the root.
    pub entry_folder_ids: Vec<i64>,
}

pub async fn require_auth(
    State(state): State<AppState>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    mut req: Request,
    next: Next,
) -> Result<Response, AppError> {
    if state.api_limiter.check_key(&addr.ip()).is_err() {
        return Err(AppError::RateLimited);
    }

    let auth_header = req
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .ok_or(AppError::Unauthorized)?;

    if !auth_header.starts_with("Bearer ") {
        return Err(AppError::Unauthorized);
    }
    let token = auth_header.trim_start_matches("Bearer ").trim().to_string();
    let token_lookup_key = crate::auth::session_token_lookup_key(&token)?;
    let cache_key = crate::engine::session_cache_key(&token_lookup_key);
    let request_mac_key = crate::auth::session_request_mac_key(&token);
    verify_request_mac(&req, &request_mac_key)?;

    // 1. Optional in-memory LRU cache (disabled by default so revocations apply immediately)
    if state.auth_cache_ttl_ms > 0 {
        let mut cache = state.session_cache.write().await;
        if let Some((cached_session, timestamp)) = cache.get(&cache_key) {
            if timestamp.elapsed().as_millis() < state.auth_cache_ttl_ms as u128 {
                match cached_session {
                    Some(session) => {
                        req.extensions_mut().insert(session.clone());
                        return Ok(next.run(req).await);
                    }
                    None => return Err(AppError::Unauthorized),
                }
            } else {
                cache.pop(&cache_key);
            }
        }
    }

    let token_lookup_key_for_db = token_lookup_key.clone();
    let db_pool = state.db.clone();
    let scope = crate::engine::scope_tag().to_string();
    let admin_username = state.config.read().await.admin_username.clone();

    let session_opt =
        tokio::task::spawn_blocking(move || {
            let conn = db_pool.get()?;

            let session_info: Option<(String, Option<i64>, i64)> = conn.query_row(
            "SELECT role, user_id, last_used_at < datetime('now', '-5 minutes') FROM sessions \
             WHERE token = ? AND scope_tag = ? AND expires_at > datetime('now')",
            rusqlite::params![token_lookup_key_for_db, scope],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        ).optional()?;

            let (role, uid, should_update_last_used) = match session_info {
                Some(info) => info,
                None => return Ok(None),
            };

            if should_update_last_used != 0 {
                let _ = conn.execute(
                    "UPDATE sessions SET last_used_at = datetime('now') WHERE token = ? AND scope_tag = ?",
                    rusqlite::params![token_lookup_key_for_db, scope],
                );
            }

            let username: Option<String> = if role == "admin" {
                Some(admin_username)
            } else if let Some(user_id) = uid {
                conn.query_row(
                    "SELECT username FROM users WHERE id = ? AND scope_tag = ?",
                    rusqlite::params![user_id, scope],
                    |r| r.get(0),
                )
                .optional()?
            } else {
                None
            };

            let (allowed_folder_ids, allowed_deleted_folder_ids, entry_folder_ids): (Vec<i64>, Vec<i64>, Vec<i64>) =
                if role == "admin" {
                    let mut wf_stmt =
                        conn.prepare("SELECT id FROM watched_folders WHERE scope_tag = ?")?;
                    let wf_ids: Vec<i64> = wf_stmt
                        .query_map([&scope], |r| r.get(0))?
                        .filter_map(Result::ok)
                        .collect();
                    // Admin entry points are the root folders of every watched folder.
                    let mut root_ids = Vec::new();
                    for wfid in &wf_ids {
                        let root_id: Option<i64> = conn.query_row(
                            "SELECT id FROM folders WHERE watched_folder_id = ? AND parent_id IS NULL AND scope_tag = ?",
                            rusqlite::params![wfid, scope],
                            |r| r.get(0),
                        ).optional()?;
                        if let Some(rid) = root_id { root_ids.push(rid); }
                    }
                    (wf_ids.clone(), wf_ids, root_ids)
                } else if let Some(user_id) = uid {
                    let mut f_stmt = conn.prepare(
                "SELECT uf.watched_folder_id, uf.allow_deleted, uf.path_prefix FROM user_folders uf
                 JOIN users u ON u.id = uf.user_id
                 WHERE uf.user_id = ? AND uf.scope_tag = ? AND u.scope_tag = ?",
            )?;
                    let mut allowed = Vec::new();
                    let mut del_allowed = Vec::new();
                    let mut entry_ids = Vec::new();
                    let rows = f_stmt.query_map(rusqlite::params![user_id, scope, scope], |r| {
                        Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?, r.get::<_, Option<String>>(2)?))
                    })?;
                    for row in rows {
                        let (wfid, allow_deleted, path_prefix) = row?;
                        allowed.push(wfid);
                        if allow_deleted == 1 { del_allowed.push(wfid); }

                        // Resolve the entry-point folder for this grant.
                        let root_id: Option<i64> = conn.query_row(
                            "SELECT id FROM folders WHERE watched_folder_id = ? AND parent_id IS NULL AND scope_tag = ?",
                            rusqlite::params![wfid, scope],
                            |r| r.get(0),
                        ).optional()?;

                        if let Some(root_folder_id) = root_id {
                            if let Some(prefix) = path_prefix {
                                // Walk the folder tree along the prefix components.
                                let mut current = root_folder_id;
                                let mut ok = true;
                                for part in prefix.split('/').filter(|s| !s.is_empty()) {
                                    let next: Option<i64> = conn.query_row(
                                        "SELECT id FROM folders WHERE parent_id = ? AND name = ? AND is_deleted = 0 AND scope_tag = ?",
                                        rusqlite::params![current, part, scope],
                                        |r| r.get(0),
                                    ).optional()?;
                                    match next {
                                        Some(id) => current = id,
                                        None => { ok = false; break; }
                                    }
                                }
                                if ok { entry_ids.push(current); }
                                // If the sub-path isn't indexed yet, we omit it from entry_ids
                                // (root browse returns empty for this grant until indexing catches up).
                            } else {
                                entry_ids.push(root_folder_id);
                            }
                        }
                    }
                    (allowed, del_allowed, entry_ids)
                } else {
                    (vec![], vec![], vec![])
                };

            Ok::<_, AppError>(Some(SessionUser {
                role,
                user_id: uid,
                username,
                allowed_folder_ids,
                allowed_deleted_folder_ids: allowed_deleted_folder_ids.clone(),
                allow_deleted: !allowed_deleted_folder_ids.is_empty(),
                entry_folder_ids,
            }))
        })
        .await
        .map_err(|e| {
            warn!("Auth task panic: {}", e);
            AppError::Internal("Auth task failed".into())
        })??;

    if state.auth_cache_ttl_ms > 0 {
        let mut cache = state.session_cache.write().await;
        cache.put(
            cache_key.clone(),
            (session_opt.clone(), std::time::Instant::now()),
        );
    }

    match session_opt {
        Some(session) => {
            req.extensions_mut().insert(session);
            Ok(next.run(req).await)
        }
        None => Err(AppError::Unauthorized),
    }
}

fn verify_request_mac(req: &Request, mac_key_hex: &str) -> Result<(), AppError> {
    let nonce = req
        .headers()
        .get(NONCE_HEADER)
        .and_then(|value| value.to_str().ok())
        .ok_or(AppError::Unauthorized)?;
    let supplied = req
        .headers()
        .get(MAC_HEADER)
        .and_then(|value| value.to_str().ok())
        .ok_or(AppError::Unauthorized)?;

    if nonce.is_empty()
        || nonce.len() > 128
        || supplied.len() != 64
        || !supplied.bytes().all(|b| b.is_ascii_hexdigit())
    {
        return Err(AppError::Unauthorized);
    }

    // Use OriginalUri (axum nest() strips the /api prefix from req.uri() before the
    // middleware sees it, but the client computes the MAC against the full path it sent).
    let path = req
        .extensions()
        .get::<OriginalUri>()
        .map(|u| u.path_and_query().map(|pq| pq.as_str()).unwrap_or(u.path()).to_string())
        .unwrap_or_else(|| {
            req.uri()
                .path_and_query()
                .map(|pq| pq.as_str().to_string())
                .unwrap_or_else(|| req.uri().path().to_string())
        });
    let mac_key = hex::decode(mac_key_hex).map_err(|_| AppError::Unauthorized)?;
    let canonical = format!("{}\n{}\n{}", req.method().as_str(), path, nonce);
    let expected = hmac_sha256_hex(&mac_key, canonical.as_bytes());
    if constant_time_eq(expected.as_bytes(), supplied.as_bytes()) {
        Ok(())
    } else {
        Err(AppError::Unauthorized)
    }
}

fn hmac_sha256_hex(key: &[u8], message: &[u8]) -> String {
    let mut key_block = [0u8; 64];
    if key.len() > 64 {
        key_block[..32].copy_from_slice(&Sha256::digest(key));
    } else {
        key_block[..key.len()].copy_from_slice(key);
    }

    let mut ipad = [0x36u8; 64];
    let mut opad = [0x5cu8; 64];
    for i in 0..64 {
        ipad[i] ^= key_block[i];
        opad[i] ^= key_block[i];
    }

    let mut inner = Sha256::new();
    inner.update(ipad);
    inner.update(message);
    let inner_hash = inner.finalize();

    let mut outer = Sha256::new();
    outer.update(opad);
    outer.update(inner_hash);
    hex::encode(outer.finalize())
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

pub async fn require_admin(
    Extension(session): Extension<SessionUser>,
    req: Request,
    next: Next,
) -> Result<Response, AppError> {
    if session.role != "admin" {
        return Err(AppError::Forbidden("Administrative access required".into()));
    }
    Ok(next.run(req).await)
}
