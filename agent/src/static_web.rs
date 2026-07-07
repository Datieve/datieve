// Serves the built web UI (agent/web/dist/) embedded directly into the binary,
// so running the agent never depends on a loose folder of assets sitting next
// to it - same single-binary distribution model as everything else here.
use axum::{
    body::Body,
    http::{header, StatusCode, Uri},
    response::Response,
};
use rust_embed::RustEmbed;

#[derive(RustEmbed)]
#[folder = "web/dist/"]
struct WebAssets;

pub async fn static_handler(uri: Uri) -> Response {
    let path = uri.path().trim_start_matches('/');
    // Anything under /api that didn't match a real route is a genuine 404,
    // not an SPA client-side route - never mask it with the HTML shell.
    if path == "api" || path.starts_with("api/") {
        return not_found();
    }
    serve_embedded(path)
        .or_else(|| serve_embedded("index.html"))
        .unwrap_or_else(not_found)
}

fn serve_embedded(path: &str) -> Option<Response> {
    let asset = WebAssets::get(path)?;
    let mime = mime_guess::from_path(path).first_or_octet_stream();
    Response::builder()
        .header(header::CONTENT_TYPE, mime.as_ref())
        .header(
            header::CONTENT_SECURITY_POLICY,
            "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; connect-src 'self'; font-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'",
        )
        .header(header::X_CONTENT_TYPE_OPTIONS, "nosniff")
        .header(header::REFERRER_POLICY, "strict-origin-when-cross-origin")
        .body(Body::from(asset.data.into_owned()))
        .ok()
}

fn not_found() -> Response {
    Response::builder()
        .status(StatusCode::NOT_FOUND)
        .body(Body::from("Not found"))
        .unwrap()
}
