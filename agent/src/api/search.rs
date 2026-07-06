// Search API handler (GET /api/search?q=...).
// Runs an FTS5 query against the files index with optional filters
// (size range, date range, deleted files). Returns up to 100 results.
use axum::{
    extract::{Query, State},
    response::IntoResponse,
    Extension, Json,
};
use serde::{Deserialize, Serialize};
use tokio::task::spawn_blocking;

use crate::api::middleware::SessionUser;
use crate::api::AppState;
use crate::error::AppError;

const SEARCH_RESULT_LIMIT: usize = 100;
const MIN_SEARCH_TERM_CHARS: usize = 2;

#[derive(Deserialize)]
pub struct SearchQuery {
    pub q: String,
    pub size_min: Option<u64>,
    pub size_max: Option<u64>,
    pub created_after: Option<String>,
    pub created_before: Option<String>,
    pub modified_after: Option<String>,
    pub modified_before: Option<String>,
    pub include_deleted: Option<bool>,
    pub sort_by: Option<String>,
    pub sort_order: Option<String>,
}

#[derive(Serialize)]
pub struct SearchResult {
    pub id: i64,
    pub folder_id: i64,
    pub name: String,
    pub path: String,
    pub absolute_path: String,
    pub size_bytes: u64,
    pub created_at: String,
    pub modified_at: String,
    pub deleted_at: Option<String>,
    pub is_deleted: bool,
    pub is_symlink: bool,
}

pub async fn search(
    State(state): State<AppState>,
    Extension(session): Extension<SessionUser>,
    Query(params): Query<SearchQuery>,
) -> Result<impl IntoResponse, AppError> {
    if params.q.trim().is_empty() {
        return Ok(Json(Vec::<SearchResult>::new()));
    }
    if params.q.len() > 512 {
        return Err(AppError::BadRequest("Query too long".into()));
    }
    let mut fts_query = String::new();
    for term in params.q.split_whitespace() {
        let clean = term.replace('"', "").replace('\'', "").replace('*', "");
        if clean.chars().count() >= MIN_SEARCH_TERM_CHARS {
            if !fts_query.is_empty() {
                fts_query.push(' ');
            }
            fts_query.push_str(&format!("\"{}\"*", clean));
        }
    }
    if fts_query.is_empty() {
        return Ok(Json(Vec::<SearchResult>::new()));
    }

    tracing::debug!(q = %params.q, user = %session.username.as_deref().unwrap_or("?"), "search");

    let results = spawn_blocking(move || {
        let conn = state.db.get()?;

        if session.allowed_folder_ids.is_empty() { return Ok::<_, AppError>(Vec::new()); }

        let mut filter_clauses = Vec::new();
        let mut filter_params: Vec<rusqlite::types::Value> = Vec::new();

        if let Some(min) = params.size_min {
            filter_clauses.push("f.size_bytes >= ?");
            filter_params.push(rusqlite::types::Value::from(min as i64));
        }
        if let Some(max) = params.size_max {
            if max > 0 {
                filter_clauses.push("f.size_bytes <= ?");
                filter_params.push(rusqlite::types::Value::from(max as i64));
            }
        }
        if let Some(after) = params.created_after {
            if !after.is_empty() {
                filter_clauses.push("f.created_at >= ?");
                filter_params.push(rusqlite::types::Value::from(after));
            }
        }
        if let Some(before) = params.created_before {
            if !before.is_empty() {
                filter_clauses.push("f.created_at <= ?");
                filter_params.push(rusqlite::types::Value::from(before));
            }
        }
        if let Some(after) = params.modified_after {
            if !after.is_empty() {
                filter_clauses.push("f.modified_at >= ?");
                filter_params.push(rusqlite::types::Value::from(after));
            }
        }
        if let Some(before) = params.modified_before {
            if !before.is_empty() {
                filter_clauses.push("f.modified_at <= ?");
                filter_params.push(rusqlite::types::Value::from(before));
            }
        }

        let include_del_req = params.include_deleted.unwrap_or(false);
        let enforce_per_folder_deleted = include_del_req && session.role != "admin";

        let order_col = match params.sort_by.as_deref() {
            Some("name") => "f.name",
            Some("size") => "f.size_bytes",
            Some("created") => "f.created_at",
            Some("modified") => "f.modified_at",
            _ => "rank",
        };
        // FTS5 bm25 rank is better when smaller, so default to ASC when sorting by rank.
        let order_dir = if params.sort_by.is_none() {
            "ASC"
        } else {
            match params.sort_order.as_deref() {
                Some("asc") => "ASC",
                _ => "DESC",
            }
        };
        let order_clause = format!(
            "ORDER BY {} {}, rank ASC, f.id ASC LIMIT {}",
            order_col, order_dir, SEARCH_RESULT_LIMIT
        );

        let placeholders = std::iter::repeat("?").take(session.allowed_folder_ids.len()).collect::<Vec<_>>().join(",");
        let mut sql_params: Vec<rusqlite::types::Value> = vec![rusqlite::types::Value::from(fts_query)];
        for id in &session.allowed_folder_ids { sql_params.push(rusqlite::types::Value::from(*id)); }
        // If include_deleted requested for a non-admin user, enforce per-folder allow_deleted policy
        // for deleted rows. Non-deleted rows remain visible everywhere.
        let del_placeholders = if enforce_per_folder_deleted {
            std::iter::repeat("?")
                .take(session.allowed_deleted_folder_ids.len().max(1))
                .collect::<Vec<_>>()
                .join(",")
        } else {
            String::new()
        };
        if enforce_per_folder_deleted && !session.allowed_deleted_folder_ids.is_empty() {
            for id in &session.allowed_deleted_folder_ids {
                sql_params.push(rusqlite::types::Value::from(*id));
            }
        } else if enforce_per_folder_deleted {
            // No folders allow deleted -> make the IN() clause impossible.
            sql_params.push(rusqlite::types::Value::from(-1i64));
        }
        sql_params.extend(filter_params);
        let scope = crate::engine::scope_tag().to_string();
        sql_params.push(rusqlite::types::Value::from(scope.clone()));
        sql_params.push(rusqlite::types::Value::from(scope));

        let mut extra_filters = String::new();
        // Default: never include deleted.
        // If explicitly requested, include deleted only where policy allows it.
        let include_del = include_del_req;
        if !include_del {
            extra_filters.push_str(" AND f.is_deleted = 0");
        } else if enforce_per_folder_deleted {
            extra_filters.push_str(&format!(
                " AND (f.is_deleted = 0 OR fo.watched_folder_id IN ({}))",
                del_placeholders
            ));
        }
        for clause in &filter_clauses { extra_filters.push_str(&format!(" AND {}", clause)); }
        extra_filters.push_str(" AND f.scope_tag = ? AND fo.scope_tag = ?");

        let sql = format!(
            "SELECT f.id, f.folder_id, f.name, f.absolute_path, f.size_bytes, f.created_at, f.modified_at, f.is_deleted, f.deleted_at, f.is_symlink, bm25(files_fts) AS rank
             FROM files_fts
             JOIN files f ON files_fts.rowid = f.id
             JOIN folders fo ON f.folder_id = fo.id
             WHERE files_fts MATCH ?
               AND fo.watched_folder_id IN ({})
               {} {}",
            placeholders, extra_filters, order_clause
        );

        let mut stmt = conn.prepare(&sql)?;
        let rows = stmt.query_map(rusqlite::params_from_iter(sql_params), |row| {
            let name: String = row.get(2)?;
            let absolute_path: String = row.get(3)?;
            Ok(SearchResult {
                id: row.get(0)?,
                folder_id: row.get(1)?,
                name: name.clone(),
                path: absolute_path.clone(),
                absolute_path,
                size_bytes: row.get::<_, i64>(4)? as u64,
                created_at: row.get(5)?,
                modified_at: row.get(6)?,
                is_deleted: row.get::<_, i64>(7)? == 1,
                deleted_at: row.get(8)?,
                is_symlink: row.get::<_, i64>(9)? == 1,
            })
        })?;

        let mut items = Vec::new();
        for r in rows { items.push(r?); }

        Ok::<_, AppError>(items)
    }).await.map_err(|_| AppError::Internal("Task Panic".into()))??;

    Ok(Json(results))
}
