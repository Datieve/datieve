use axum::{
    extract::State,
    routing::{delete, get, post},
    Router,
};
use std::sync::Arc;
use std::time::Duration;
use tower::limit::ConcurrencyLimitLayer;
use tower_http::cors::{AllowOrigin, CorsLayer};
use tower_http::limit::RequestBodyLimitLayer;
use tower_http::timeout::TimeoutLayer;
use tower_http::trace::{DefaultMakeSpan, DefaultOnFailure, DefaultOnResponse, TraceLayer};

use crate::config::Config;
use crate::db::pool::DbPool;

pub mod admin;
pub mod auth;
pub mod bookmarks;
pub mod browse;
pub mod fs;
pub mod fs_access;
pub mod middleware;
pub mod search;

use governor::{
    clock::QuantaClock, state::direct::NotKeyed, state::keyed::DefaultKeyedStateStore,
    state::InMemoryState, RateLimiter,
};
use std::net::IpAddr;

pub type IpRateLimiter = RateLimiter<IpAddr, DefaultKeyedStateStore<IpAddr>, QuantaClock>;
pub type GlobalRateLimiter = RateLimiter<NotKeyed, InMemoryState, QuantaClock>;

use tokio::sync::watch;

#[derive(Clone, Copy, Debug, PartialEq, serde::Serialize)]
pub enum ScanStatus {
    Scanning,
    Ready,
    WaitingForSnapshotSync,
    FolderUnmounted,
}

#[derive(Clone, Copy, Debug, PartialEq, serde::Serialize)]
pub enum SnapshotSyncStatus {
    Healthy,
    Unavailable,
    Syncing,
}

#[derive(Clone)]
pub struct AppState {
    pub config: Arc<tokio::sync::RwLock<Config>>,
    pub config_path: std::path::PathBuf,
    pub db: DbPool,
    pub indexer_tx: tokio::sync::mpsc::Sender<crate::indexer::IndexEvent>,
    pub login_limiter: Arc<IpRateLimiter>,
    pub global_login_limiter: Arc<GlobalRateLimiter>,
    pub api_limiter: Arc<IpRateLimiter>,
    pub allowed_origins: Vec<String>,
    pub status_tx: watch::Sender<ScanStatus>,
    pub _status_rx: watch::Receiver<ScanStatus>,
    pub sync_status_tx: watch::Sender<SnapshotSyncStatus>,
    pub sync_status_rx: watch::Receiver<SnapshotSyncStatus>,
    /// Incremented by the writer after each non-empty DB flush. SSE clients use this to push
    /// "FileChanged" events so the frontend can reload without polling.
    pub file_change_tx: Arc<watch::Sender<u64>>,
    pub file_change_rx: watch::Receiver<u64>,
    pub start_time: std::time::Instant,
    pub session_cache: Arc<
        tokio::sync::RwLock<
            lru::LruCache<
                String,
                (
                    Option<crate::api::middleware::SessionUser>,
                    std::time::Instant,
                ),
            >,
        >,
    >,
    /// Upper bound on in-flight requests handled concurrently.
    pub max_concurrency: usize,
    /// If 0, auth caching is disabled (revocations apply immediately).
    pub auth_cache_ttl_ms: u64,
    pub scan_orchestrator: Arc<crate::indexer::scan_orchestrator::ScanOrchestrator>,
    /// Per-folder mutex map preventing concurrent writes to the same directory.
    pub folder_locks: crate::api::fs_access::FolderLocks,
}

pub fn build_router(state: AppState) -> Router {
    let allowed_origins = state.allowed_origins.clone();
    let max_concurrency = state.max_concurrency;
    let cors = CorsLayer::new()
        .allow_origin(AllowOrigin::predicate(move |origin, _| {
            allowed_origins
                .iter()
                .any(|o| origin.as_bytes() == o.as_bytes())
        }))
        .allow_methods([
            axum::http::Method::GET,
            axum::http::Method::POST,
            axum::http::Method::PUT,
            axum::http::Method::DELETE,
        ])
        .allow_headers([
            axum::http::header::AUTHORIZATION,
            axum::http::header::CONTENT_TYPE,
        ]);

    // Public API
    let public_api = Router::new()
        .route("/auth/discovery", get(auth::discovery))
        .route("/auth/verify-code", post(auth::verify_code))
        .route("/auth/setup/finalize", post(auth::finalize_setup))
        .route(
            "/system/status",
            get(|State(state): State<AppState>| async move {
                let is_setup = state.config.read().await.is_setup;
                axum::Json(serde_json::json!({
                    "is_setup": is_setup
                }))
            }),
        );

    // Protected API (Require session token in Authorization: Bearer <TOKEN>)
    let admin_routes = Router::new()
        .route("/stats", get(admin::stats))
        .route(
            "/admin-code",
            get(admin::get_admin_code_status).post(admin::set_admin_code),
        )
        // User management (Household RBAC)
        .route("/users", get(admin::get_users).post(admin::create_user))
        .route("/users/:id", delete(admin::delete_user))
        .route("/users/:id/code", axum::routing::put(admin::change_user_code))
        .route(
            "/users/:id/folders",
            get(admin::get_user_folders).post(admin::assign_user_folder),
        )
        .route(
            "/users/:id/folders/:folder_id",
            delete(admin::remove_user_folder),
        )
        .route(
            "/users/:id/folder-entries/:entry_id",
            delete(admin::remove_user_folder_entry),
        )
        .route(
            "/folders",
            get(admin::get_watched_folders).post(admin::add_watched_folder),
        )
        .route(
            "/folders/:id",
            delete(admin::delete_watched_folder).put(admin::update_watched_folder_exclusions),
        )
        .route(
            "/settings",
            get(admin::get_settings).post(admin::update_settings),
        )
        .route("/system/sync/status", get(admin::sync_status_stream))
        .route("/nas/browse", post(admin::browse_nas_folders))
        .route("/prune", post(admin::prune_system))
        .route("/ghost/:id", delete(admin::delete_ghost))
        .route("/ghost-folder/:id", delete(admin::delete_ghost_folder))
        .route("/restart", post(admin::restart_agent))
        .route("/rescan", post(admin::rescan_now))
        .route("/management/verify", post(admin::verify_management_code));

    let protected_api = Router::new()
        .route("/auth/me", get(auth::me))
        .route("/search", get(search::search))
        .route("/browse", get(browse::browse))
        .route("/events", get(browse::file_events_stream))
        .route("/fs/mkdir", post(fs::mkdir))
        .route("/fs/create-file", post(fs::create_file))
        .route("/fs/create-text-file", post(fs::create_text_file))
        .route("/fs/rename", post(fs::rename_path))
        .route("/fs/copy", post(fs::copy_paths))
        .route("/fs/move", post(fs::move_paths))
        .route("/fs/delete", post(fs::delete_paths))
        .route("/fs/symlink", post(fs::create_symlink))
        .route("/fs/duplicate", post(fs::duplicate_paths))
        .route("/fs/bulk-rename", post(fs::bulk_rename))
        .route("/fs/compress", post(fs::compress_paths_handler))
        .route("/fs/extract-here", post(fs::extract_here))
        .route("/fs/extract-to-subfolder", post(fs::extract_to_subfolder))
        .route("/fs/rotate-image", post(fs::rotate_image))
        .route("/fs/read", get(fs::read_file))
        .route("/fs/write", post(fs::write_file))
        .route("/fs/trash", post(fs::trash_paths))
        .route("/fs/download", get(fs::download_file))
        .route(
            "/bookmarks",
            get(bookmarks::list_bookmarks).post(bookmarks::create_bookmark),
        )
        .route("/bookmarks/:id", delete(bookmarks::delete_bookmark))
        .nest(
            "/admin",
            admin_routes.layer(axum::middleware::from_fn(middleware::require_admin)),
        )
        .layer(axum::middleware::from_fn_with_state(
            state.clone(),
            middleware::require_auth,
        ));

    // Assembly
    Router::new()
        .nest("/api", public_api)
        .nest("/api", protected_api)
        .fallback(crate::static_web::static_handler)
        .layer(ConcurrencyLimitLayer::new(max_concurrency))
        .layer(RequestBodyLimitLayer::new(10 * 1024 * 1024))
        .layer(TimeoutLayer::new(Duration::from_secs(30)))
        .layer(
            TraceLayer::new_for_http()
                .make_span_with(DefaultMakeSpan::new().level(tracing::Level::INFO))
                .on_response(DefaultOnResponse::new().level(tracing::Level::INFO))
                .on_failure(DefaultOnFailure::new().level(tracing::Level::WARN)),
        )
        .layer(cors)
        .with_state(state)
}
