use axum::{
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde_json::json;
use thiserror::Error;

/// Top-level error type for the Datieve agent.
///
/// Internal errors (DB, I/O, crypto) are logged server-side but their details
/// are never forwarded to HTTP clients  - callers only see a generic 500 message.
/// Only user-facing errors (auth, validation, rate limit) expose a human message.
#[derive(Debug, Error)]
pub enum AppError {
    #[error("Database error: {0}")]
    Database(#[from] rusqlite::Error),

    #[error("Config error: {0}")]
    Config(String),

    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Not found")]
    NotFound,

    #[error("Unauthorized")]
    Unauthorized,

    #[error("Forbidden: {0}")]
    Forbidden(String),

    #[error("Bad request: {0}")]
    BadRequest(String),

    #[error("Rate limit exceeded")]
    RateLimited,

    #[error("Crypto error: {0}")]
    Crypto(String),

    #[error("Internal error: {0}")]
    Internal(String),
}

impl From<serde_json::Error> for AppError {
    fn from(e: serde_json::Error) -> Self {
        AppError::Internal(e.to_string())
    }
}

impl From<rcgen::Error> for AppError {
    fn from(e: rcgen::Error) -> Self {
        AppError::Crypto(format!("TLS generation failed: {e}"))
    }
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, code, message) = match &self {
            AppError::NotFound => (StatusCode::NOT_FOUND, "not_found", self.to_string()),
            AppError::Unauthorized => (StatusCode::UNAUTHORIZED, "unauthorized", self.to_string()),
            AppError::Forbidden(s) => (StatusCode::FORBIDDEN, "forbidden", s.clone()),
            AppError::BadRequest(s) => (StatusCode::BAD_REQUEST, "bad_request", s.clone()),
            AppError::RateLimited => (
                StatusCode::TOO_MANY_REQUESTS,
                "rate_limited",
                "Too many requests. Try again later.".to_string(),
            ),
            // Internal errors: log the real cause, return a generic message
            _ => {
                tracing::error!("{}", self);
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "internal_error",
                    "An internal error occurred.".to_string(),
                )
            }
        };

        (status, Json(json!({ "error": code, "message": message }))).into_response()
    }
}
