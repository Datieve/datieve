use futures_util::{future::join_all, StreamExt};
use keyring::Entry;
use local_ip_address::local_ip;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use crc32fast::Hasher as Crc32Hasher;
use md5::{Digest as Md5Digest, Md5};
use sha1::{Digest as Sha1Digest, Sha1};
use sha2::{Digest as Sha256Digest, Sha256};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use url::Url;

const MAX_AGENT_RESPONSE_BYTES: usize = 2 * 1024 * 1024;
const MAX_DISCOVERY_RESPONSE_BYTES: usize = 64 * 1024;

use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::{verify_tls12_signature, verify_tls13_signature, CryptoProvider};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{Error as RustlsError, SignatureScheme};

pub struct AppState {
    // Used only for untrusted discovery/status checks where we never send secrets.
    discovery_client: Client,
    sse_tasks: Mutex<HashMap<String, tokio::task::JoinHandle<()>>>,
    // Short-timeout client for regular API calls (10s request timeout).
    pinned_clients: Mutex<HashMap<String, (String, Client)>>,
    // No-request-timeout client for SSE long-poll connections (connect timeout only).
    sse_pinned_clients: Mutex<HashMap<String, (String, Client)>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct DatieveAppSettings {
    pub version: u32,
    pub theme: String,
    pub scan_port: u16,
    pub sidebar_width: u16,
    pub local_view_style: String,
    pub sort_by: String,
    pub sort_dir: String,
    pub group_by: String,
    pub folders_first: bool,
    pub show_hidden: bool,
    pub show_extensions: bool,
    pub show_thumbnails: bool,
    pub size_unit: String,
    pub calculate_folder_sizes: bool,
    pub single_click_open: bool,
    pub select_on_hover: bool,
    pub double_click_blank_go_up: bool,
    pub scroll_to_previous_folder_on_up: bool,
    pub confirm_trash: bool,
    pub confirm_permanent_delete: bool,
    pub warn_extension_rename: bool,
    pub default_terminal: String,
    pub context_open_terminal: bool,
    pub context_copy_path: bool,
    pub context_archive: bool,
    pub context_symlink: bool,
    pub context_pin_sidebar: bool,
    pub nas_lazy_loading: bool,
    pub nas_page_size: u16,
    pub ui_scale: f32,
    pub show_info_pane: bool,
    pub info_pane_tab: String,
    pub restore_tabs_on_startup: bool,
    pub toolbar_show_view_toggle: bool,
    pub toolbar_show_hidden_toggle: bool,
    pub toolbar_show_filters: bool,
}

impl Default for DatieveAppSettings {
    fn default() -> Self {
        Self {
            version: 1,
            theme: "system".into(),
            scan_port: 34514,
            sidebar_width: 220,
            local_view_style: "list".into(),
            sort_by: "name".into(),
            sort_dir: "asc".into(),
            group_by: "none".into(),
            folders_first: true,
            show_hidden: false,
            show_extensions: true,
            show_thumbnails: true,
            size_unit: "binary".into(),
            calculate_folder_sizes: false,
            single_click_open: false,
            select_on_hover: false,
            double_click_blank_go_up: false,
            scroll_to_previous_folder_on_up: true,
            confirm_trash: false,
            confirm_permanent_delete: true,
            warn_extension_rename: true,
            default_terminal: String::new(),
            context_open_terminal: true,
            context_copy_path: true,
            context_archive: true,
            context_symlink: true,
            context_pin_sidebar: true,
            nas_lazy_loading: false,
            nas_page_size: 200,
            ui_scale: 1.0,
            show_info_pane: false,
            info_pane_tab: "details".into(),
            restore_tabs_on_startup: true,
            toolbar_show_view_toggle: true,
            toolbar_show_hidden_toggle: true,
            toolbar_show_filters: true,
        }
    }
}

fn app_data_dir() -> Result<std::path::PathBuf, String> {
    let home = std::env::var("HOME")
        .or_else(|_| std::env::var("USERPROFILE"))
        .map(std::path::PathBuf::from)
        .map_err(|_| "Could not determine home directory".to_string())?;
    let dir = home.join(".datieve-app");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    Ok(dir)
}

fn app_settings_path() -> Result<std::path::PathBuf, String> {
    Ok(app_data_dir()?.join("user_settings.json"))
}

fn sanitize_app_settings(mut settings: DatieveAppSettings) -> DatieveAppSettings {
    let defaults = DatieveAppSettings::default();
    settings.version = 1;
    if !matches!(settings.theme.as_str(), "system" | "light" | "dark") {
        settings.theme = defaults.theme;
    }
    if settings.scan_port < 1024 {
        settings.scan_port = defaults.scan_port;
    }
    settings.sidebar_width = settings.sidebar_width.clamp(160, 360);
    if !matches!(settings.local_view_style.as_str(), "list" | "compact") {
        settings.local_view_style = defaults.local_view_style;
    }
    if !matches!(
        settings.sort_by.as_str(),
        "name" | "modified" | "created" | "size" | "type" | "tag"
    ) {
        settings.sort_by = defaults.sort_by;
    }
    if !matches!(settings.sort_dir.as_str(), "asc" | "desc") {
        settings.sort_dir = defaults.sort_dir;
    }
    if !matches!(
        settings.group_by.as_str(),
        "none" | "name" | "modified" | "created" | "size" | "type" | "tag"
    ) {
        settings.group_by = defaults.group_by;
    }
    if !matches!(settings.size_unit.as_str(), "binary" | "decimal") {
        settings.size_unit = defaults.size_unit;
    }
    if !matches!(settings.nas_page_size, 100 | 200 | 500 | 1000) {
        settings.nas_page_size = defaults.nas_page_size;
    }
    settings.ui_scale = settings.ui_scale.clamp(0.5, 2.0);
    if !matches!(settings.info_pane_tab.as_str(), "details" | "preview") {
        settings.info_pane_tab = defaults.info_pane_tab;
    }
    settings
}

pub fn load_app_settings() -> Result<DatieveAppSettings, String> {
    let path = app_settings_path()?;
    if !path.exists() {
        let settings = DatieveAppSettings::default();
        save_app_settings(settings.clone())?;
        return Ok(settings);
    }
    let raw = std::fs::read_to_string(path).map_err(|e| e.to_string())?;
    let parsed = serde_json::from_str::<DatieveAppSettings>(&raw).unwrap_or_default();
    Ok(sanitize_app_settings(parsed))
}

pub fn save_app_settings(settings: DatieveAppSettings) -> Result<DatieveAppSettings, String> {
    let settings = sanitize_app_settings(settings);
    let path = app_settings_path()?;
    let tmp = path.with_extension("json.tmp");
    let json = serde_json::to_string_pretty(&settings).map_err(|e| e.to_string())?;
    {
        let mut file = std::fs::File::create(&tmp).map_err(|e| e.to_string())?;
        file.write_all(json.as_bytes()).map_err(|e| e.to_string())?;
        file.sync_all().map_err(|e| e.to_string())?;
    }
    std::fs::rename(tmp, path).map_err(|e| e.to_string())?;
    Ok(settings)
}

pub fn reset_app_settings() -> Result<DatieveAppSettings, String> {
    let settings = DatieveAppSettings::default();
    save_app_settings(settings.clone())?;
    Ok(settings)
}

#[derive(Serialize)]
pub struct FetchResponse {
    pub status: u16,
    pub body: String,
}

#[derive(Serialize, Clone)]
pub struct DiscoveredAgent {
    pub ip: String,
    pub hostname: String,
    pub version: String,
    pub is_setup: bool,
    pub mode: Option<String>,
    pub demo: bool,
    pub fingerprint: Option<String>,
}

fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hex::encode(hasher.finalize())
}

fn normalize_fingerprint(fp: &str) -> Result<String, String> {
    let normalized = fp
        .trim()
        .to_ascii_lowercase()
        .chars()
        .filter(|c| *c != ':' && *c != '-' && !c.is_whitespace())
        .collect::<String>();

    if normalized.len() == 64 && normalized.chars().all(|c| c.is_ascii_hexdigit()) {
        Ok(normalized)
    } else {
        Err("Invalid SHA-256 fingerprint".into())
    }
}

#[derive(Debug)]
struct FingerprintVerifier {
    expected_fp_hex: String,
    crypto_provider: Arc<CryptoProvider>,
}

impl FingerprintVerifier {
    fn new(expected_fp_hex: String) -> Result<Self, String> {
        let crypto_provider = CryptoProvider::get_default()
            .cloned()
            .ok_or_else(|| "No rustls crypto provider installed".to_string())?;
        Ok(Self {
            expected_fp_hex: normalize_fingerprint(&expected_fp_hex)?,
            crypto_provider,
        })
    }
}

impl ServerCertVerifier for FingerprintVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, RustlsError> {
        let actual = sha256_hex(end_entity.as_ref());
        if actual == self.expected_fp_hex {
            Ok(ServerCertVerified::assertion())
        } else {
            Err(RustlsError::General(
                "Pinned certificate fingerprint mismatch".into(),
            ))
        }
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, RustlsError> {
        verify_tls12_signature(
            _message,
            _cert,
            _dss,
            &self.crypto_provider.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, RustlsError> {
        verify_tls13_signature(
            _message,
            _cert,
            _dss,
            &self.crypto_provider.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        vec![
            SignatureScheme::RSA_PSS_SHA256,
            SignatureScheme::RSA_PSS_SHA384,
            SignatureScheme::RSA_PSS_SHA512,
            SignatureScheme::ECDSA_NISTP256_SHA256,
            SignatureScheme::ECDSA_NISTP384_SHA384,
            SignatureScheme::ECDSA_NISTP521_SHA512,
            SignatureScheme::ED25519,
            SignatureScheme::ED448,
            SignatureScheme::RSA_PKCS1_SHA256,
            SignatureScheme::RSA_PKCS1_SHA384,
            SignatureScheme::RSA_PKCS1_SHA512,
        ]
    }
}

fn build_pinned_client(expected_fp_hex: String, request_timeout: Option<Duration>) -> Result<Client, String> {
    let verifier = Arc::new(FingerprintVerifier::new(expected_fp_hex)?);
    let tls = rustls::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(verifier)
        .with_no_client_auth();

    let mut builder = reqwest::Client::builder()
        .use_preconfigured_tls(tls)
        .pool_max_idle_per_host(2)
        .connect_timeout(Duration::from_secs(10));
    if let Some(t) = request_timeout {
        builder = builder.timeout(t);
    }
    builder.build().map_err(|e| e.to_string())
}

fn normalize_agent_host(host: &str) -> String {
    if host.eq_ignore_ascii_case("localhost") {
        "127.0.0.1".to_string()
    } else {
        host.to_string()
    }
}

fn format_agent_endpoint(host: &str, port: u16) -> String {
    format!("{}:{}", normalize_agent_host(host), port)
}

fn resolve_agent_socket_addr(host: &str, port: u16) -> Result<std::net::SocketAddr, String> {
    use std::net::ToSocketAddrs;
    let host = normalize_agent_host(host);
    (host.as_str(), port)
        .to_socket_addrs()
        .map_err(|e| e.to_string())?
        .find(|addr| addr.is_ipv4())
        .ok_or_else(|| "Could not resolve agent address".into())
}

fn agent_key_from_url(url: &str) -> Result<String, String> {
    let u = validate_agent_url(url)?;
    let host = u.host_str().ok_or("URL missing host")?;
    let port = u.port_or_known_default().unwrap_or(443);
    Ok(format_agent_endpoint(host, port))
}

fn is_supported_agent_port(port: u16) -> bool {
    port > 0
}

fn validate_agent_url(url: &str) -> Result<Url, String> {
    let mut u = Url::parse(url).map_err(|e| e.to_string())?;
    if u.host_str().is_some_and(|host| host.eq_ignore_ascii_case("localhost")) {
        u.set_host(Some("127.0.0.1"))
            .map_err(|e| e.to_string())?;
    }
    if u.scheme() != "https" {
        return Err("Agent URL must use https".into());
    }
    if u.username() != "" || u.password().is_some() {
        return Err("Agent URL must not contain credentials".into());
    }
    if !u.port_or_known_default().is_some_and(is_supported_agent_port) {
        return Err("Agent URL must use a valid port".into());
    }
    let path = u.path();
    let allowed = path == "/api/auth/discovery"
        || path == "/api/auth/verify-code"
        || path == "/api/auth/setup/finalize"
        || path == "/api/auth/me"
        || path == "/api/system/status"
        || path == "/api/search"
        || path == "/api/browse"
        || path == "/api/events"
        || path.starts_with("/api/fs/")
        || path == "/api/demo/index"
        || path == "/api/demo/status"
        || path.starts_with("/api/admin/");
    if !allowed {
        return Err("Unsupported agent API path".into());
    }
    Ok(u)
}

fn validate_agent_key(agent_key: &str) -> Result<String, String> {
    let candidate = if agent_key.contains("://") {
        agent_key_from_url(agent_key)?
    } else {
        agent_key.to_string()
    };
    let (host, port) = candidate.rsplit_once(':').ok_or("Expected host:port")?;
    if !is_safe_agent_host(host) {
        return Err("Invalid agent host".into());
    }
    let port = port.parse::<u16>().map_err(|_| "Invalid agent port")?;
    if !is_supported_agent_port(port) {
        return Err("Invalid agent port".into());
    }
    Ok(format_agent_endpoint(host, port))
}

fn is_safe_agent_host(host: &str) -> bool {
    !host.is_empty()
        && host.len() <= 253
        && !host
            .bytes()
            .any(|b| b.is_ascii_control() || b.is_ascii_whitespace())
        && host
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b':' | b'[' | b']'))
        && !host.contains("..")
        && !host.contains('@')
        && !host.contains('/')
        && !host.contains('\\')
}

fn validate_secure_item_key(key: &str) -> Result<(), String> {
    if let Some(agent) = key.strip_prefix("session_") {
        validate_agent_key(agent)?;
        return Ok(());
    }
    if let Some(agent) = key.strip_prefix("accounts_") {
        validate_agent_key(agent)?;
        return Ok(());
    }

    Err("Unsupported secure item key".into())
}

fn validate_bearer_token(token: &str) -> Result<(), String> {
    if token.len() > 4096
        || token.is_empty()
        || token
            .bytes()
            .any(|b| b.is_ascii_control() || b.is_ascii_whitespace())
    {
        return Err("Invalid bearer token".into());
    }
    Ok(())
}

fn validate_mac_key(mac_key: &str) -> Result<(), String> {
    if mac_key.len() == 64 && mac_key.bytes().all(|b| b.is_ascii_hexdigit()) {
        Ok(())
    } else {
        Err("Invalid request MAC key".into())
    }
}

fn request_nonce() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let thread = std::thread::current().id();
    let mut hasher = Sha256::new();
    hasher.update(now.to_be_bytes());
    hasher.update(format!("{thread:?}").as_bytes());
    hex::encode(&hasher.finalize()[..16])
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

fn request_mac(method: &str, parsed_url: &Url, nonce: &str, mac_key: &str) -> String {
    let path = match parsed_url.query() {
        Some(query) => format!("{}?{}", parsed_url.path(), query),
        None => parsed_url.path().to_string(),
    };
    let canonical = format!("{}\n{}\n{}", method, path, nonce);
    // mac_key is a hex-encoded 32-byte key; decode to binary to match server-side verification
    let key_bytes = hex::decode(mac_key).unwrap_or_else(|_| mac_key.as_bytes().to_vec());
    hmac_sha256_hex(&key_bytes, canonical.as_bytes())
}

async fn read_limited_body(res: reqwest::Response, max_bytes: usize) -> Result<String, String> {
    if let Some(len) = res.content_length() {
        if len > max_bytes as u64 {
            return Err("Response too large".into());
        }
    }

    let mut stream = res.bytes_stream();
    let mut body = Vec::new();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| e.to_string())?;
        if body.len().saturating_add(chunk.len()) > max_bytes {
            return Err("Response too large".into());
        }
        body.extend_from_slice(&chunk);
    }
    String::from_utf8(body).map_err(|_| "Response was not valid UTF-8".into())
}

fn is_discovery_url(url: &str) -> bool {
    // Allowed unpinned: GET /api/auth/discovery (no secrets).
    validate_agent_url(url)
        .ok()
        .map(|u| u.path() == "/api/auth/discovery")
        .unwrap_or(false)
}

#[derive(Debug)]
struct CaptureFingerprintVerifier {
    captured_fp_hex: Arc<std::sync::Mutex<Option<String>>>,
    crypto_provider: Arc<CryptoProvider>,
}

impl ServerCertVerifier for CaptureFingerprintVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, RustlsError> {
        let fp = sha256_hex(end_entity.as_ref());
        if let Ok(mut guard) = self.captured_fp_hex.lock() {
            *guard = Some(fp);
        }
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, RustlsError> {
        verify_tls12_signature(
            _message,
            _cert,
            _dss,
            &self.crypto_provider.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, RustlsError> {
        verify_tls13_signature(
            _message,
            _cert,
            _dss,
            &self.crypto_provider.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        vec![
            SignatureScheme::RSA_PSS_SHA256,
            SignatureScheme::RSA_PSS_SHA384,
            SignatureScheme::RSA_PSS_SHA512,
            SignatureScheme::ECDSA_NISTP256_SHA256,
            SignatureScheme::ECDSA_NISTP384_SHA384,
            SignatureScheme::ECDSA_NISTP521_SHA512,
            SignatureScheme::ED25519,
            SignatureScheme::ED448,
            SignatureScheme::RSA_PKCS1_SHA256,
            SignatureScheme::RSA_PKCS1_SHA384,
            SignatureScheme::RSA_PKCS1_SHA512,
        ]
    }
}

// ── Local filesystem listing ──────────────────────────────────────────────────

#[derive(Serialize, Clone)]
pub struct LocalEntry {
    pub name: String,
    pub is_dir: bool,
    pub is_symlink: bool,
    pub target_path: Option<String>,
    pub size: u64,
    pub modified_secs: u64,
    pub created_secs: u64,
    pub accessed_secs: u64,
    pub absolute_path: String,
    pub is_hidden: bool,
    pub file_ext: Option<String>,
    pub item_type: String,
}

fn is_listable_path(path: &str) -> bool {
    if path.starts_with("//") {
        return false;
    }
    true
}

fn system_time_secs(time: std::io::Result<std::time::SystemTime>) -> u64 {
    time.ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn local_entry_type(name: &str, is_dir: bool, is_symlink: bool) -> (Option<String>, String) {
    if is_dir {
        return (None, if is_symlink { "Linked Folder" } else { "Folder" }.into());
    }

    let ext = std::path::Path::new(name)
        .extension()
        .and_then(|s| s.to_str())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_ascii_lowercase());
    let item_type = match (is_symlink, ext.as_deref()) {
        (true, _) => "Shortcut".to_string(),
        (_, Some(ext)) => format!("{} File", ext.to_ascii_uppercase()),
        (_, None) => "File".to_string(),
    };
    (ext, item_type)
}

/// Reads a directory, invoking `on_entry` for each item as soon as it has been
/// stat'd — no full materialization or sort. Callers that need a stable
/// display order (folders-first, alphabetical) are responsible for sorting
/// once every entry has been observed.
fn read_local_dir_entries(path: &str, mut on_entry: impl FnMut(LocalEntry)) -> Result<(), String> {
    let canonical = std::fs::canonicalize(path)
        .map_err(|e| format!("Cannot access '{}': {}", path, e))?;
    let canonical_str = {
        let s = canonical.to_string_lossy().to_string();
        if s.starts_with(r"\\?\") { s[4..].to_string() } else { s }
    };
    if !is_listable_path(&canonical_str) {
        return Err("Security Block: Restricted path.".into());
    }
    let read_dir = std::fs::read_dir(&canonical)
        .map_err(|e| format!("Cannot read directory: {}", e))?;
    let hide_path = canonical.join(".datievehide");
    let mut hidden_names = std::collections::HashSet::new();
    if hide_path.exists() {
        if let Ok(content) = std::fs::read_to_string(hide_path) {
            for line in content.lines() {
                let trimmed = line.trim();
                if !trimmed.is_empty() {
                    hidden_names.insert(trimmed.to_string());
                }
            }
        }
    }

    for item in read_dir {
        let item = match item { Ok(e) => e, Err(_) => continue };
        let name = item.file_name().to_string_lossy().to_string();
        if hidden_names.contains(&name) {
            continue;
        }
        let path = item.path();
        let lmeta = match std::fs::symlink_metadata(&path) { Ok(m) => m, Err(_) => continue };
        let is_symlink = lmeta.file_type().is_symlink();
        let target_path = if is_symlink {
            std::fs::read_link(&path).ok().map(|p| {
                if p.is_absolute() {
                    p.to_string_lossy().to_string()
                } else {
                    path.parent().unwrap_or_else(|| std::path::Path::new("")).join(p).to_string_lossy().to_string()
                }
            })
        } else {
            None
        };
        let meta = if is_symlink {
            // Follow the symlink to get the target's metadata. If that fails
            // (e.g. the target is on an unavailable mount), try statting the
            // resolved target_path string directly as a last resort.
            std::fs::metadata(&path)
                .or_else(|_| {
                    target_path.as_deref()
                        .map(std::fs::metadata)
                        .unwrap_or(Err(std::io::Error::other("no target")))
                })
                .unwrap_or(lmeta.clone())
        } else {
            lmeta
        };
        let is_dir = meta.is_dir();
        let size = if is_dir { 0 } else { meta.len() };
        let modified_secs = system_time_secs(meta.modified());
        let created_secs = system_time_secs(meta.created());
        let accessed_secs = system_time_secs(meta.accessed());
        let is_hidden = name.starts_with('.');
        let (file_ext, item_type) = local_entry_type(&name, is_dir, is_symlink);
        on_entry(LocalEntry {
            absolute_path: path.to_string_lossy().to_string(),
            name,
            is_dir,
            is_symlink,
            target_path,
            size,
            modified_secs,
            created_secs,
            accessed_secs,
            is_hidden,
            file_ext,
            item_type,
        });
    }
    Ok(())
}

fn sort_local_entries(entries: &mut [LocalEntry]) {
    entries.sort_by(|a, b| match (a.is_dir, b.is_dir) {
        (true, false) => std::cmp::Ordering::Less,
        (false, true) => std::cmp::Ordering::Greater,
        _ => a.name.to_lowercase().cmp(&b.name.to_lowercase()),
    });
}

pub fn list_local_dir(path: String) -> Result<Vec<LocalEntry>, String> {
    let mut entries: Vec<LocalEntry> = Vec::new();
    read_local_dir_entries(&path, |e| entries.push(e))?;
    sort_local_entries(&mut entries);
    Ok(entries)
}

/// Streaming variant of [`list_local_dir`]: invokes `on_entry` as each item is
/// discovered instead of waiting for the whole directory to be read, so large
/// folders can start rendering immediately. Entries arrive in filesystem
/// enumeration order, not sorted — callers must re-sort once the stream ends.
pub fn list_local_dir_stream(path: String, on_entry: impl FnMut(LocalEntry)) -> Result<(), String> {
    read_local_dir_entries(&path, on_entry)
}

pub fn get_user_dirs() -> serde_json::Value {
    let ud = directories::UserDirs::new();
    let dir_str = |p: Option<&std::path::Path>| -> Option<String> {
        p.filter(|p| p.is_dir())
         .map(|p| p.to_string_lossy().to_string())
    };
    let home = dir_str(ud.as_ref().map(|d| d.home_dir()));
    serde_json::json!({
        "home":      home,
        "downloads": dir_str(ud.as_ref().and_then(|d| d.download_dir())),
        "documents": dir_str(ud.as_ref().and_then(|d| d.document_dir())),
        "pictures":  dir_str(ud.as_ref().and_then(|d| d.picture_dir())),
        "music":     dir_str(ud.as_ref().and_then(|d| d.audio_dir())),
        "desktop":   dir_str(ud.as_ref().and_then(|d| d.desktop_dir())),
        "videos":    dir_str(ud.as_ref().and_then(|d| d.video_dir())),
    })
}

// ── Recursive search ──────────────────────────────────────────────────────────

#[derive(Serialize, Clone)]
pub struct SearchEntry {
    pub name: String,
    pub is_dir: bool,
    pub is_symlink: bool,
    pub target_path: Option<String>,
    pub size: u64,
    pub modified_secs: u64,
    pub created_secs: u64,
    pub accessed_secs: u64,
    pub absolute_path: String,
    pub is_hidden: bool,
    pub file_ext: Option<String>,
    pub item_type: String,
    pub parent_path: String,
}

fn glob_match(pattern: &[u8], text: &[u8]) -> bool {
    let (mut p, mut t) = (0usize, 0usize);
    let mut star: Option<usize> = None;
    let mut match_at = 0usize;
    while t < text.len() {
        if p < pattern.len() && (pattern[p] == b'?' || pattern[p] == text[t]) {
            p += 1;
            t += 1;
        } else if p < pattern.len() && pattern[p] == b'*' {
            star = Some(p);
            match_at = t;
            p += 1;
        } else if let Some(star_pos) = star {
            p = star_pos + 1;
            match_at += 1;
            t = match_at;
        } else {
            return false;
        }
    }
    while p < pattern.len() && pattern[p] == b'*' {
        p += 1;
    }
    p == pattern.len()
}

fn search_query_matches(name: &str, query: &str) -> bool {
    if query.contains('*') || query.contains('?') {
        glob_match(query.as_bytes(), name.as_bytes())
    } else {
        name.contains(query)
    }
}

/// Bumped every time a new recursive search starts; a walk in progress checks
/// this and aborts as soon as it goes stale (a newer search superseded it, or
/// the user cancelled), instead of continuing to burn CPU on a walk nobody
/// wants anymore.
static SEARCH_GENERATION: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

pub fn cancel_search() {
    SEARCH_GENERATION.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
}

#[allow(clippy::too_many_arguments)]
fn search_dir(
    dir: &std::path::Path,
    query: &str,
    include_hidden: bool,
    generation: u64,
    visited: &mut usize,
    visit_limit: usize,
    results: &mut Vec<SearchEntry>,
    result_limit: usize,
) -> bool {
    if SEARCH_GENERATION.load(std::sync::atomic::Ordering::Relaxed) != generation { return false; }
    if results.len() >= result_limit || *visited >= visit_limit { return false; }
    let Ok(read_dir) = std::fs::read_dir(dir) else { return true };
    for item in read_dir.filter_map(|e| e.ok()) {
        if SEARCH_GENERATION.load(std::sync::atomic::Ordering::Relaxed) != generation { return false; }
        *visited += 1;
        if *visited >= visit_limit || results.len() >= result_limit { return false; }
        let name = item.file_name().to_string_lossy().to_string();
        let is_hidden = name.starts_with('.');
        if !include_hidden && is_hidden { continue; }
        let path = item.path();
        let abs = path.to_string_lossy().to_string();
        if !is_listable_path(&abs) { continue; }
        let Ok(lmeta) = std::fs::symlink_metadata(&path) else { continue };
        let is_symlink = lmeta.file_type().is_symlink();
        let target_path = if is_symlink {
            std::fs::read_link(&path).ok().map(|p| {
                if p.is_absolute() {
                    p.to_string_lossy().to_string()
                } else {
                    path.parent().unwrap_or_else(|| std::path::Path::new("")).join(p).to_string_lossy().to_string()
                }
            })
        } else {
            None
        };
        let meta = if is_symlink {
            std::fs::metadata(&path)
                .or_else(|_| target_path.as_deref().map(std::fs::metadata).unwrap_or(Err(std::io::Error::other("no target"))))
                .unwrap_or(lmeta.clone())
        } else { lmeta };
        let is_dir = meta.is_dir();
        if search_query_matches(&name.to_lowercase(), query) {
            let size = if is_dir { 0 } else { meta.len() };
            let modified_secs = system_time_secs(meta.modified());
            let created_secs = system_time_secs(meta.created());
            let accessed_secs = system_time_secs(meta.accessed());
            let (file_ext, item_type) = local_entry_type(&name, is_dir, is_symlink);
            results.push(SearchEntry {
                name,
                is_dir,
                is_symlink,
                target_path,
                size,
                modified_secs,
                created_secs,
                accessed_secs,
                absolute_path: abs,
                is_hidden,
                file_ext,
                item_type,
                parent_path: dir.to_string_lossy().to_string(),
            });
        }
        if is_dir && !is_symlink {
            let keep_going = search_dir(
                &path, query, include_hidden, generation, visited, visit_limit, results, result_limit,
            );
            if !keep_going { return false; }
        }
    }
    true
}

/// Directories/files visited before a search gives up even if it hasn't
/// found `RESULT_LIMIT` matches yet — bounds worst-case scan time for
/// low/no-hit queries over huge trees (e.g. searching a home directory).
const SEARCH_VISIT_LIMIT: usize = 300_000;
const SEARCH_RESULT_LIMIT: usize = 2000;

pub fn fs_search_recursive(root: String, query: String, include_hidden: bool) -> Result<Vec<SearchEntry>, String> {
    let canonical = std::fs::canonicalize(&root).map_err(|e| e.to_string())?;
    if !is_listable_path(&canonical.to_string_lossy()) {
        return Err("Security Block: Restricted path.".into());
    }
    let generation = SEARCH_GENERATION.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
    let q = query.to_lowercase();
    let mut results = Vec::new();
    let mut visited = 0usize;
    search_dir(
        &canonical, &q, include_hidden, generation, &mut visited,
        SEARCH_VISIT_LIMIT, &mut results, SEARCH_RESULT_LIMIT,
    );
    Ok(results)
}

pub fn fs_stat_paths(paths: Vec<String>) -> Result<Vec<SearchEntry>, String> {
    let mut results = Vec::new();
    for raw in paths {
        let path = std::path::PathBuf::from(&raw);
        let Ok(lmeta) = std::fs::symlink_metadata(&path) else { continue };
        let is_symlink = lmeta.file_type().is_symlink();
        let target_path = if is_symlink {
            std::fs::read_link(&path).ok().map(|p| {
                if p.is_absolute() { p.to_string_lossy().to_string() }
                else { path.parent().unwrap_or_else(|| std::path::Path::new("")).join(p).to_string_lossy().to_string() }
            })
        } else { None };
        let meta = if is_symlink {
            std::fs::metadata(&path)
                .or_else(|_| target_path.as_deref().map(std::fs::metadata).unwrap_or(Err(std::io::Error::other("no target"))))
                .unwrap_or(lmeta.clone())
        } else { lmeta };
        let is_dir = meta.is_dir();
        let name = path.file_name().and_then(|n| n.to_str()).unwrap_or(&raw).to_string();
        let is_hidden = name.starts_with('.');
        let target_path = if is_symlink { std::fs::read_link(&path).ok().map(|p| p.to_string_lossy().to_string()) } else { None };
        let (file_ext, item_type) = local_entry_type(&name, is_dir, is_symlink);
        results.push(SearchEntry {
            name,
            is_dir,
            is_symlink,
            target_path,
            size: if is_dir { 0 } else { meta.len() },
            modified_secs: system_time_secs(meta.modified()),
            created_secs: system_time_secs(meta.created()),
            accessed_secs: system_time_secs(meta.accessed()),
            absolute_path: path.to_string_lossy().to_string(),
            is_hidden,
            file_ext,
            item_type,
            parent_path: path.parent().map(|p| p.to_string_lossy().to_string()).unwrap_or_default(),
        });
    }
    Ok(results)
}

// ── MIME type detection ────────────────────────────────────────────────────────

fn mime_from_ext(ext: &str) -> &'static str {
    match ext {
        "jpg" | "jpeg" => "image/jpeg",
        "png" => "image/png",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "svg" | "svgz" => "image/svg+xml",
        "bmp" => "image/bmp",
        "ico" => "image/x-icon",
        "tiff" | "tif" => "image/tiff",
        "avif" => "image/avif",
        "heic" | "heif" => "image/heif",
        "mp4" | "m4v" => "video/mp4",
        "mkv" => "video/x-matroska",
        "avi" => "video/x-msvideo",
        "mov" => "video/quicktime",
        "wmv" => "video/x-ms-wmv",
        "flv" => "video/x-flv",
        "webm" => "video/webm",
        "mpeg" | "mpg" => "video/mpeg",
        "mp3" => "audio/mpeg",
        "flac" => "audio/flac",
        "wav" => "audio/wav",
        "ogg" => "audio/ogg",
        "m4a" => "audio/mp4",
        "aac" => "audio/aac",
        "opus" => "audio/opus",
        "wma" => "audio/x-ms-wma",
        "txt" | "text" | "log" | "md" | "rst" => "text/plain",
        "html" | "htm" => "text/html",
        "css" | "scss" | "sass" => "text/css",
        "js" | "mjs" | "cjs" => "text/javascript",
        "ts" | "tsx" | "jsx" => "text/x-typescript",
        "json" | "jsonc" => "application/json",
        "xml" | "xhtml" => "application/xml",
        "csv" => "text/csv",
        "yaml" | "yml" => "text/yaml",
        "toml" => "application/toml",
        "sh" | "bash" | "zsh" | "fish" => "application/x-shellscript",
        "py" => "text/x-python",
        "rs" => "text/x-rust",
        "go" => "text/x-go",
        "c" | "h" => "text/x-c",
        "cpp" | "cc" | "cxx" | "hpp" => "text/x-c++src",
        "java" => "text/x-java",
        "rb" => "application/x-ruby",
        "php" => "application/x-php",
        "lua" => "text/x-lua",
        "swift" => "text/x-swift",
        "kt" | "kts" => "text/x-kotlin",
        "dart" => "application/vnd.dart",
        "zip" => "application/zip",
        "tar" => "application/x-tar",
        "gz" | "tgz" => "application/gzip",
        "bz2" | "tbz2" => "application/x-bzip2",
        "xz" | "txz" => "application/x-xz",
        "7z" => "application/x-7z-compressed",
        "rar" => "application/vnd.rar",
        "zst" => "application/zstd",
        "deb" => "application/vnd.debian.binary-package",
        "rpm" => "application/x-rpm",
        "appimage" => "application/vnd.appimage",
        "pdf" => "application/pdf",
        "doc" => "application/msword",
        "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xls" => "application/vnd.ms-excel",
        "xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "ppt" => "application/vnd.ms-powerpoint",
        "pptx" => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "odt" => "application/vnd.oasis.opendocument.text",
        "ods" => "application/vnd.oasis.opendocument.spreadsheet",
        "odp" => "application/vnd.oasis.opendocument.presentation",
        "ttf" => "font/ttf",
        "otf" => "font/otf",
        "woff" => "font/woff",
        "woff2" => "font/woff2",
        _ => "application/octet-stream",
    }
}

pub fn get_mime_type(path: String) -> String {
    if std::path::Path::new(&path).is_dir() {
        return "inode/directory".to_string();
    }
    let ext = std::path::Path::new(&path)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_lowercase();
    mime_from_ext(&ext).to_string()
}

pub fn read_image_thumbnail(path: String) -> Result<String, String> {
    let canonical = std::fs::canonicalize(&path).map_err(|e| e.to_string())?;
    let path_str = canonical.to_string_lossy();
    if !is_listable_path(&path_str) {
        return Err("Security Block: Restricted path.".into());
    }
    let meta = canonical.metadata().map_err(|e| e.to_string())?;
    if meta.is_dir() {
        return Err("Is a directory.".into());
    }
    if meta.len() > 20 * 1024 * 1024 {
        return Err("File too large for thumbnail.".into());
    }
    let ext = canonical.extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_lowercase();

    // SVG is a vector format — pass it through untouched, no raster resize applies.
    if ext == "svg" {
        let bytes = std::fs::read(&canonical).map_err(|e| e.to_string())?;
        return Ok(format!("data:image/svg+xml;base64,{}", base64_encode_img(&bytes)));
    }

    // Downscale before encoding so we ship a small thumbnail over FFI instead
    // of a full-resolution decode — this is what actually gets painted into a
    // ~64px tile, so sending the original only wastes bandwidth and memory.
    const THUMB_MAX_DIM: u32 = 320;
    if let Ok(img) = image::open(&canonical) {
        let thumb = img.thumbnail(THUMB_MAX_DIM, THUMB_MAX_DIM);
        let mut buf = std::io::Cursor::new(Vec::new());
        let mime = if thumb.color().has_alpha() {
            thumb.write_to(&mut buf, image::ImageFormat::Png).map_err(|e| e.to_string())?;
            "image/png"
        } else {
            let rgb = thumb.to_rgb8();
            let mut encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut buf, 82);
            encoder.encode_image(&rgb).map_err(|e| e.to_string())?;
            "image/jpeg"
        };
        return Ok(format!("data:{};base64,{}", mime, base64_encode_img(buf.get_ref())));
    }

    // Formats the `image` crate can't decode (e.g. AVIF without a native
    // codec) fall back to passing the original bytes through as before.
    let bytes = std::fs::read(&canonical).map_err(|e| e.to_string())?;
    let mime = match ext.as_str() {
        "jpg" | "jpeg" => "image/jpeg",
        "png"          => "image/png",
        "gif"          => "image/gif",
        "webp"         => "image/webp",
        "bmp"          => "image/bmp",
        "ico"          => "image/x-icon",
        "tiff" | "tif" => "image/tiff",
        "avif"         => "image/avif",
        _              => "image/jpeg",
    };
    Ok(format!("data:{};base64,{}", mime, base64_encode_img(&bytes)))
}

pub fn read_local_bytes(path: String) -> Result<Vec<u8>, String> {
    let canonical = std::fs::canonicalize(&path).map_err(|e| e.to_string())?;
    let path_str = canonical.to_string_lossy();
    if !is_listable_path(&path_str) {
        return Err("Security Block: Restricted path.".into());
    }
    let meta = canonical.metadata().map_err(|e| e.to_string())?;
    if meta.is_dir() {
        return Err("Is a directory.".into());
    }
    // Cap at 512 MiB to avoid loading huge files into memory
    if meta.len() > 512 * 1024 * 1024 {
        return Err("File too large to load.".into());
    }
    std::fs::read(&canonical).map_err(|e| e.to_string())
}

fn base64_encode_img(data: &[u8]) -> String {
    const CHARS: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity((data.len() + 2) / 3 * 4);
    for chunk in data.chunks(3) {
        let b0 = chunk[0] as usize;
        let b1 = if chunk.len() > 1 { chunk[1] as usize } else { 0 };
        let b2 = if chunk.len() > 2 { chunk[2] as usize } else { 0 };
        out.push(CHARS[b0 >> 2] as char);
        out.push(CHARS[((b0 & 3) << 4) | (b1 >> 4)] as char);
        if chunk.len() > 1 { out.push(CHARS[((b1 & 15) << 2) | (b2 >> 6)] as char); } else { out.push('='); }
        if chunk.len() > 2 { out.push(CHARS[b2 & 63] as char); } else { out.push('='); }
    }
    out
}

pub fn read_text_preview(path: String) -> Result<String, String> {
    let canonical = std::fs::canonicalize(&path).map_err(|e| e.to_string())?;
    if !is_listable_path(&canonical.to_string_lossy()) {
        return Err("Security Block: Restricted path.".into());
    }
    let meta = canonical.metadata().map_err(|e| e.to_string())?;
    if meta.is_dir() {
        return Err("Cannot preview a folder as text.".into());
    }
    if meta.len() > 512 * 1024 {
        return Err("Text preview is limited to files under 512 KiB.".into());
    }
    let bytes = std::fs::read(&canonical).map_err(|e| e.to_string())?;
    if bytes.contains(&0) {
        return Err("Binary file preview is not available.".into());
    }
    String::from_utf8(bytes).map_err(|_| "File is not valid UTF-8.".into())
}

// ── Open With / app listing ────────────────────────────────────────────────────

#[derive(Serialize, Clone)]
pub struct AppInfo {
    pub id: String,
    pub name: String,
    pub icon: String,
}

// "Open With" app enumeration is based on Linux .desktop files and only
// makes sense on Linux; on macOS/Windows `open_with_app` falls back to the
// OS's native "open with default app" behavior instead (see `open_with_app`).
#[cfg(target_os = "linux")]
fn app_dirs() -> Vec<std::path::PathBuf> {
    let mut dirs = vec![
        std::path::PathBuf::from("/usr/share/applications"),
        std::path::PathBuf::from("/usr/local/share/applications"),
    ];
    if let Ok(home) = std::env::var("HOME") {
        dirs.push(std::path::PathBuf::from(format!("{}/.local/share/applications", home)));
    }
    dirs.push(std::path::PathBuf::from("/var/lib/snapd/desktop/applications"));
    dirs.push(std::path::PathBuf::from("/var/lib/flatpak/exports/share/applications"));
    if let Ok(home) = std::env::var("HOME") {
        dirs.push(std::path::PathBuf::from(format!("{}/.local/share/flatpak/exports/share/applications", home)));
    }
    dirs
}

#[cfg(not(target_os = "linux"))]
fn app_dirs() -> Vec<std::path::PathBuf> {
    Vec::new()
}

fn parse_desktop_file(path: &std::path::Path) -> Option<(String, String, Vec<String>)> {
    // Returns (name, icon, mime_types)
    let content = std::fs::read_to_string(path).ok()?;
    let mut name = String::new();
    let mut icon = String::new();
    let mut mimes: Vec<String> = Vec::new();
    let mut in_entry = false;
    let mut no_display = false;
    let mut is_app = true;

    for line in content.lines() {
        let line = line.trim();
        if line == "[Desktop Entry]" { in_entry = true; continue; }
        if line.starts_with('[') {
            if in_entry { break; }
            continue;
        }
        if !in_entry { continue; }
        if let Some(v) = line.strip_prefix("Type=") {
            if v != "Application" { is_app = false; }
        }
        if let Some(v) = line.strip_prefix("Name=") {
            if name.is_empty() { name = v.to_string(); }
        }
        if let Some(v) = line.strip_prefix("Icon=") {
            if icon.is_empty() { icon = v.to_string(); }
        }
        if let Some(v) = line.strip_prefix("MimeType=") {
            mimes = v.split(';').filter(|s| !s.is_empty()).map(|s| s.to_string()).collect();
        }
        if line == "NoDisplay=true" || line == "Hidden=true" { no_display = true; }
    }

    if !is_app || no_display || name.is_empty() { return None; }
    Some((name, icon, mimes))
}

/// Lists apps capable of opening `path`. Linux matches MIME types declared
/// in .desktop files; macOS asks Launch Services directly via the file URL
/// (it has no MIME/.desktop concept), so `mime_type` is unused there.
/// Windows doesn't populate this list at all — "Open With" there calls the
/// native Explorer picker directly instead (see `open_with_dialog_native`).
pub fn get_apps_for_mime(mime_type: String, path: String) -> Vec<AppInfo> {
    #[cfg(target_os = "macos")]
    {
        let _ = &mime_type;
        return get_apps_for_path_macos(&path);
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = &path;
        let dirs = app_dirs();
        let mut apps: Vec<AppInfo> = Vec::new();
        let mut seen = std::collections::HashSet::new();
        let base_type = mime_type.split('/').next().unwrap_or("").to_string();

        for dir in &dirs {
            let Ok(entries) = std::fs::read_dir(dir) else { continue };
            for entry in entries.filter_map(|e| e.ok()) {
                let path = entry.path();
                if path.extension().and_then(|e| e.to_str()) != Some("desktop") { continue; }
                let id = path.file_stem().unwrap_or_default().to_string_lossy().to_string();
                if seen.contains(&id) { continue; }
                let Some((name, icon, mimes)) = parse_desktop_file(&path) else { continue };
                // Match exact MIME or same base type (e.g. text/*) with wildcard
                let matches = mimes.iter().any(|m| {
                    m == &mime_type
                        || m == &format!("{}/*", base_type)
                        || (mime_type == "inode/directory" && m == "inode/directory")
                });
                if matches {
                    seen.insert(id.clone());
                    apps.push(AppInfo { id, name, icon });
                }
            }
        }

        apps.sort_by(|a, b| a.name.cmp(&b.name));
        apps
    }
}

/// Asks macOS Launch Services (via NSWorkspace) for every application that
/// can open `path`. `AppInfo.id` is the app bundle's absolute path (e.g.
/// "/Applications/TextEdit.app") — `open_with_app` passes it straight back
/// to `NSWorkspace.openFile:withApplication:`, so no separate lookup/registry
/// is needed the way Linux needs a .desktop-file-by-id search.
#[cfg(target_os = "macos")]
fn get_apps_for_path_macos(path: &str) -> Vec<AppInfo> {
    use objc2_app_kit::NSWorkspace;
    use objc2_foundation::NSURL;

    let Some(file_url) = (unsafe { NSURL::from_file_path(path) }) else { return Vec::new() };
    let workspace = NSWorkspace::sharedWorkspace();
    let urls = unsafe { workspace.URLsForApplicationsToOpenURL(&file_url) };

    let mut apps: Vec<AppInfo> = unsafe { urls.to_vec() }
        .into_iter()
        .filter_map(|url| {
            // NSString::to_str needs proof we're inside an autorelease pool
            // scope (the returned &str borrows from it).
            let bundle_path = objc2::rc::autoreleasepool(|pool| {
                let ns_path = unsafe { url.path() }?;
                Some(unsafe { ns_path.to_str(pool) }.to_string())
            })?;
            let name = std::path::Path::new(&bundle_path)
                .file_stem()
                .map(|s| s.to_string_lossy().to_string())
                .unwrap_or_else(|| bundle_path.clone());
            Some(AppInfo { id: bundle_path, name, icon: String::new() })
        })
        .collect();

    apps.sort_by(|a, b| a.name.cmp(&b.name));
    apps
}

#[cfg(target_os = "linux")]
fn find_desktop_file(app_id: &str) -> Option<std::path::PathBuf> {
    let name = format!("{app_id}.desktop");
    app_dirs().into_iter().map(|d| d.join(&name)).find(|p| p.is_file())
}

/// Returns (Exec= value, Terminal=true) for a .desktop file, if it has an Exec line.
#[cfg(target_os = "linux")]
fn parse_desktop_exec(path: &std::path::Path) -> Option<(String, bool)> {
    let content = std::fs::read_to_string(path).ok()?;
    let mut exec = String::new();
    let mut terminal = false;
    let mut in_entry = false;
    for line in content.lines() {
        let line = line.trim();
        if line == "[Desktop Entry]" { in_entry = true; continue; }
        if line.starts_with('[') {
            if in_entry { break; }
            continue;
        }
        if !in_entry { continue; }
        if let Some(v) = line.strip_prefix("Exec=") {
            if exec.is_empty() { exec = v.to_string(); }
        }
        if line == "Terminal=true" { terminal = true; }
    }
    if exec.is_empty() { None } else { Some((exec, terminal)) }
}

/// Splits a desktop Exec= value into argv, expanding the %f/%F/%u/%U field
/// codes to the target path and dropping the ones we don't support (%i/%c/%k).
#[cfg(target_os = "linux")]
fn expand_desktop_exec(exec: &str, path: &str) -> Vec<String> {
    exec.split_whitespace()
        .filter_map(|token| match token {
            "%f" | "%F" | "%u" | "%U" => Some(path.to_string()),
            "%i" | "%c" | "%k" => None,
            other => Some(other.to_string()),
        })
        .collect()
}

/// Runs argv inside a detected terminal emulator. Needed because gtk-launch's
/// own terminal auto-detection (used for Desktop Entries with Terminal=true,
/// e.g. vim/neovim) fails outright on setups without a GLib-recognized
/// terminal — Datieve already has working terminal detection for the
/// "Open Terminal Here" feature, so reuse it instead.
#[cfg(target_os = "linux")]
fn spawn_command_in_terminal(argv: &[String]) -> Result<(), String> {
    if argv.is_empty() { return Err("Nothing to execute.".into()); }
    let terminal = detect_terminal();
    let base = terminal.rsplit('/').next().unwrap_or(&terminal).to_string();
    let mut cmd = std::process::Command::new(&terminal);
    match base.as_str() {
        "gnome-terminal" | "tilix" => { cmd.arg("--"); }
        "wezterm" => { cmd.args(["start", "--"]); }
        _ => { cmd.arg("-e"); }
    }
    cmd.args(argv);
    cmd.spawn().map_err(|e| format!("Cannot launch {terminal}: {e}"))?;
    Ok(())
}

pub async fn open_with_app(app_id: String, path: String) -> Result<(), String> {
    #[cfg(target_os = "linux")]
    {
        if let Some(desktop_path) = find_desktop_file(&app_id) {
            if let Some((exec, terminal)) = parse_desktop_exec(&desktop_path) {
                if terminal {
                    let argv = expand_desktop_exec(&exec, &path);
                    return spawn_command_in_terminal(&argv);
                }
            }
        }
        std::process::Command::new("gtk-launch")
            .arg(format!("{}.desktop", app_id))
            .arg(&path)
            .spawn()
            .map_err(|e| format!("gtk-launch failed: {}", e))?;
        return Ok(());
    }
    #[cfg(target_os = "macos")]
    {
        return open_with_app_macos(app_id, path);
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        let _ = app_id;
        open_file_native(path).await
    }
}

/// `app_id` here is the app bundle path returned by `get_apps_for_path_macos`
/// (e.g. "/Applications/TextEdit.app"). `openFile:withApplication:` is
/// deprecated in favor of an async completion-handler API, but it's
/// synchronous and simple — worth it here to avoid pulling in `block2` for a
/// one-shot fire-and-forget launch.
#[cfg(target_os = "macos")]
fn open_with_app_macos(app_id: String, path: String) -> Result<(), String> {
    use objc2_app_kit::NSWorkspace;
    use objc2_foundation::NSString;

    let workspace = NSWorkspace::sharedWorkspace();
    let ns_path = NSString::from_str(&path);
    let ns_app = NSString::from_str(&app_id);
    #[allow(deprecated)]
    let ok = workspace.openFile_withApplication(&ns_path, Some(&ns_app));
    if ok {
        Ok(())
    } else {
        Err(format!("Could not open with {app_id}"))
    }
}

/// Shows the native "Open With" picker (the same dialog Explorer uses)
/// instead of Datieve's own app-list dialog. Windows-only: there's no
/// equivalent public API to invoke the OS's own picker on Linux or macOS,
/// so those platforms keep using Datieve's list-based dialog
/// (`get_apps_for_mime` + `open_with_app`).
#[cfg(target_os = "windows")]
pub fn open_with_dialog_native(path: String) -> Result<(), String> {
    use std::ffi::OsStr;
    use std::os::windows::ffi::OsStrExt;

    const OAIF_ALLOW_REGISTRATION: u32 = 0x00000001;
    const OAIF_EXEC: u32 = 0x00000004;

    let wide: Vec<u16> = OsStr::new(&path).encode_wide().chain(std::iter::once(0)).collect();
    let info = OpenAsInfo {
        pcsz_file: wide.as_ptr(),
        pcsz_class: std::ptr::null(),
        oaif_in_flags: OAIF_ALLOW_REGISTRATION | OAIF_EXEC,
    };
    // Any non-zero HRESULT here is either the user cancelling the dialog or
    // a shell-level issue Windows already surfaced natively — nothing useful
    // to relay back through our own error path.
    unsafe { SHOpenWithDialog(std::ptr::null_mut(), &info as *const OpenAsInfo) };
    Ok(())
}

#[cfg(not(target_os = "windows"))]
pub fn open_with_dialog_native(path: String) -> Result<(), String> {
    let _ = path;
    Err("The native Open With dialog is only available on Windows.".into())
}

// ── Terminal opener ────────────────────────────────────────────────────────────

fn which_cmd(cmd: &str) -> bool {
    #[cfg(target_os = "windows")]
    let finder = "where";
    #[cfg(not(target_os = "windows"))]
    let finder = "which";
    std::process::Command::new(finder)
        .arg(cmd)
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

fn detect_terminal() -> String {
    // Prefer user-set env first
    if let Ok(t) = std::env::var("DATIEVE_TERMINAL") {
        if !t.is_empty() && which_cmd(&t) { return t; }
    }
    let candidates = [
        "x-terminal-emulator", "gnome-terminal", "konsole", "xfce4-terminal",
        "alacritty", "kitty", "wezterm", "foot", "tilix", "terminator",
        "mate-terminal", "lxterminal", "xterm",
    ];
    for t in &candidates {
        if which_cmd(t) { return t.to_string(); }
    }
    "xterm".to_string()
}

pub async fn open_in_terminal(path: String, terminal_override: Option<String>) -> Result<(), String> {
    #[cfg(target_os = "linux")]
    {
        let terminal = terminal_override
            .filter(|t| !t.trim().is_empty())
            .unwrap_or_else(detect_terminal);

        let base = terminal.split('/').last().unwrap_or(&terminal).to_string();
        let (cmd, args): (&str, Vec<String>) = match base.as_str() {
            "gnome-terminal" | "tilix" | "mate-terminal" =>
                (&terminal, vec![format!("--working-directory={}", path)]),
            "konsole" =>
                (&terminal, vec!["--workdir".into(), path.clone()]),
            "xfce4-terminal" | "terminator" | "lxterminal" | "foot" =>
                (&terminal, vec!["--working-directory".into(), path.clone()]),
            "alacritty" =>
                (&terminal, vec!["--working-directory".into(), path.clone()]),
            "kitty" =>
                (&terminal, vec!["--directory".into(), path.clone()]),
            "wezterm" =>
                (&terminal, vec!["start".into(), "--cwd".into(), path.clone()]),
            _ =>
                (&terminal, vec!["--working-directory".into(), path.clone()]),
        };

        std::process::Command::new(cmd)
            .args(&args)
            .spawn()
            .map_err(|e| format!("Cannot open terminal: {}", e))?;
        return Ok(());
    }
    #[cfg(target_os = "macos")]
    {
        let _ = terminal_override;
        std::process::Command::new("open")
            .args(["-a", "Terminal", &path])
            .spawn()
            .map_err(|e| format!("Cannot open Terminal.app: {}", e))?;
        return Ok(());
    }
    #[cfg(target_os = "windows")]
    {
        let _ = terminal_override;
        std::process::Command::new("cmd")
            .args(["/C", "start", "cmd", "/K", &format!("cd /D \"{}\"", path)])
            .spawn()
            .map_err(|e| format!("Cannot open cmd.exe: {}", e))?;
        return Ok(());
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
    {
        let _ = (path, terminal_override);
        Err("Opening a terminal is not supported on this platform.".to_string())
    }
}

// ── Extract archive ────────────────────────────────────────────────────────────

/// Extracts a `.zip` archive with the pure-Rust `zip` crate — works
/// identically on Linux/macOS/Windows with no external tool dependency.
fn extract_zip_archive(archive: &std::path::Path, dest_dir: &std::path::Path) -> Result<(), String> {
    let file = std::fs::File::open(archive).map_err(|e| e.to_string())?;
    let mut zip = zip::ZipArchive::new(file).map_err(|e| format!("Not a valid zip archive: {e}"))?;
    zip.extract(dest_dir).map_err(|e| format!("Extraction failed: {e}"))
}

/// Non-.zip archives (7z, rar, tar.*) fall back to whatever archive tool is
/// available on the current platform, since Rust doesn't have a good
/// dependency-free crate covering all of those formats.
fn extract_with_external_tool(archive: &std::path::Path, dest_dir: &std::path::Path) -> Result<(), String> {
    let p = archive.to_string_lossy().to_string();
    let dest = dest_dir.to_string_lossy().to_string();

    #[cfg(target_os = "linux")]
    {
        let tried: [&[&str]; 4] = [
            &["file-roller", "--extract-here", &p],
            &["ark", "--batch", "--autodestination", &p],
            &["engrampa", "--extract-here", &p],
            &["xarchiver", "-x", &p],
        ];
        for args in &tried {
            let (cmd, rest) = args.split_first().unwrap();
            if which_cmd(cmd) {
                std::process::Command::new(cmd).args(rest).spawn().map_err(|e| e.to_string())?;
                return Ok(());
            }
        }
        if which_cmd("7z") {
            std::process::Command::new("7z")
                .args(["x", &p, &format!("-o{}", dest), "-y"])
                .spawn().map_err(|e| e.to_string())?;
            return Ok(());
        }
        Err("No archive extractor found for this format. Install file-roller, ark, or p7zip.".into())
    }
    #[cfg(target_os = "macos")]
    {
        if which_cmd("unar") {
            std::process::Command::new("unar").args(["-o", &dest, &p]).spawn().map_err(|e| e.to_string())?;
            return Ok(());
        }
        if which_cmd("7z") {
            std::process::Command::new("7z")
                .args(["x", &p, &format!("-o{}", dest), "-y"])
                .spawn().map_err(|e| e.to_string())?;
            return Ok(());
        }
        Err("No archive extractor found for this format. Install 'unar' (brew install unar) or p7zip.".into())
    }
    #[cfg(target_os = "windows")]
    {
        if which_cmd("7z") {
            std::process::Command::new("7z")
                .args(["x", &p, &format!("-o{}", dest), "-y"])
                .spawn().map_err(|e| e.to_string())?;
            return Ok(());
        }
        let status = std::process::Command::new("tar")
            .args(["-xf", &p, "-C", &dest])
            .status()
            .map_err(|e| format!("Extraction failed: {e}"))?;
        if status.success() { return Ok(()); }
        Err("Could not extract this archive format. Install 7-Zip.".into())
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
    {
        let _ = (p, dest);
        Err("Archive extraction is not supported on this platform.".into())
    }
}

pub async fn fs_extract_here(path: String) -> Result<(), String> {
    let canonical = std::fs::canonicalize(&path).map_err(|e| e.to_string())?;
    if !is_listable_path(&canonical.to_string_lossy()) {
        return Err("Security Block: Restricted path.".into());
    }
    let parent = canonical.parent().ok_or("No parent directory")?.to_path_buf();
    let ext = canonical.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();

    if ext == "zip" {
        return tokio::task::spawn_blocking(move || extract_zip_archive(&canonical, &parent))
            .await.map_err(|e| e.to_string())?;
    }
    tokio::task::spawn_blocking(move || extract_with_external_tool(&canonical, &parent))
        .await.map_err(|e| e.to_string())?
}

// ── Mounted volumes ────────────────────────────────────────────────────────────

#[cfg(target_os = "windows")]
#[link(name = "Kernel32")]
extern "system" {
    fn GetLogicalDrives() -> u32;
    fn GetDiskFreeSpaceExW(
        lpDirectoryName: *const u16,
        lpFreeBytesAvailableToCaller: *mut u64,
        lpTotalNumberOfBytes: *mut u64,
        lpTotalNumberOfFreeBytes: *mut u64,
    ) -> i32;
    fn GetVolumeInformationW(
        lpRootPathName: *const u16,
        lpVolumeNameBuffer: *mut u16,
        nVolumeNameSize: u32,
        lpVolumeSerialNumber: *mut u32,
        lpMaximumComponentLength: *mut u32,
        lpFileSystemFlags: *mut u32,
        lpFileSystemNameBuffer: *mut u16,
        nFileSystemNameSize: u32,
    ) -> i32;
}

#[cfg(target_os = "windows")]
#[link(name = "Shell32")]
extern "system" {
    // SHERB_NOCONFIRMATION=0x1 | SHERB_NOPROGRESSUI=0x2 | SHERB_NOSOUND=0x4
    fn SHEmptyRecycleBinW(
        hwnd: *mut std::ffi::c_void,
        pszRootPath: *const u16,
        dwFlags: u32,
    ) -> i32;
    // Opens a file with its default application. Returns >32 on success.
    fn ShellExecuteW(
        hwnd: *mut std::ffi::c_void,
        lpOperation: *const u16,
        lpFile: *const u16,
        lpParameters: *const u16,
        lpDirectory: *const u16,
        nShowCmd: i32,
    ) -> isize;
    // Shows the native "Open With" picker — the exact dialog Explorer uses.
    fn SHOpenWithDialog(hwndParent: *mut std::ffi::c_void, poainfo: *const OpenAsInfo) -> i32;
}

#[cfg(target_os = "windows")]
#[repr(C)]
struct OpenAsInfo {
    pcsz_file: *const u16,
    pcsz_class: *const u16,
    oaif_in_flags: u32,
}

#[derive(Serialize, Clone)]
pub struct MountEntry {
    pub label: String,
    pub path: String,
    pub fs_type: String,
    pub total_bytes: u64,
    pub used_bytes: u64,
    pub available_bytes: u64,
}

#[cfg(target_os = "linux")]
fn mount_space_bytes(path: &str) -> (u64, u64, u64) {
    let output = std::process::Command::new("df")
        .args(["-P", "-B1", path])
        .output();
    let Ok(output) = output else { return (0, 0, 0); };
    if !output.status.success() { return (0, 0, 0); }
    let text = String::from_utf8_lossy(&output.stdout);
    let Some(line) = text.lines().nth(1) else { return (0, 0, 0); };
    let cols: Vec<&str> = line.split_whitespace().collect();
    if cols.len() < 5 { return (0, 0, 0); }
    let total = cols[1].parse::<u64>().unwrap_or(0);
    let used = cols[2].parse::<u64>().unwrap_or(0);
    let available = cols[3].parse::<u64>().unwrap_or(0);
    (total, used, available)
}

#[cfg(target_os = "linux")]
fn decode_mount_field(value: &str) -> String {
    value
        .replace("\\040", " ")
        .replace("\\011", "\t")
        .replace("\\012", "\n")
        .replace("\\134", "\\")
}

#[cfg(target_os = "macos")]
fn mount_space_bytes_macos(path: &str) -> (u64, u64, u64) {
    let output = std::process::Command::new("df").args(["-k", path]).output();
    let Ok(output) = output else { return (0, 0, 0); };
    if !output.status.success() { return (0, 0, 0); }
    let text = String::from_utf8_lossy(&output.stdout);
    let Some(line) = text.lines().nth(1) else { return (0, 0, 0); };
    let cols: Vec<&str> = line.split_whitespace().collect();
    if cols.len() < 4 { return (0, 0, 0); }
    // df -k reports 1024-byte blocks.
    let total = cols[1].parse::<u64>().unwrap_or(0).saturating_mul(1024);
    let used = cols[2].parse::<u64>().unwrap_or(0).saturating_mul(1024);
    let available = cols[3].parse::<u64>().unwrap_or(0).saturating_mul(1024);
    (total, used, available)
}

pub fn list_mounts() -> Vec<MountEntry> {
    let mut mounts: Vec<MountEntry> = Vec::new();

    #[cfg(target_os = "linux")]
    {
        if let Ok(content) = std::fs::read_to_string("/proc/mounts") {
            for line in content.lines() {
                let parts: Vec<&str> = line.splitn(4, ' ').collect();
                if parts.len() < 3 { continue; }
                let source = decode_mount_field(parts[0]);
                let mount_point = decode_mount_field(parts[1]);
                let fs_type = parts[2];
                let skip_fs = ["sysfs","proc","devtmpfs","devpts","cgroup","cgroup2","tmpfs",
                               "securityfs","pstore","bpf","tracefs","debugfs","autofs","mqueue",
                               "hugetlbfs","fuse.portal","overlay","fusectl","efivarfs",
                               "binfmt_misc","rpc_pipefs","squashfs","ramfs"];
                if skip_fs.contains(&fs_type) { continue; }
                let interesting = mount_point == "/"
                    || source.starts_with("/dev/")
                    || fs_type == "zfs"
                    || fs_type == "btrfs"
                    || mount_point.starts_with("/boot")
                    || mount_point.starts_with("/efi")
                    || mount_point.starts_with("/media/")
                    || mount_point.starts_with("/mnt/")
                    || mount_point.starts_with("/run/media/");
                if !interesting { continue; }
                let label = if mount_point == "/" {
                    "System".to_string()
                } else {
                    std::path::Path::new(&mount_point)
                    .file_name()
                    .map(|n| n.to_string_lossy().to_string())
                    .unwrap_or_else(|| mount_point.to_string())
                };
                if mounts.iter().any(|m: &MountEntry| m.path == mount_point) { continue; }
                let (total_bytes, used_bytes, available_bytes) = mount_space_bytes(&mount_point);
                mounts.push(MountEntry {
                    label,
                    path: mount_point,
                    fs_type: fs_type.to_string(),
                    total_bytes,
                    used_bytes,
                    available_bytes,
                });
            }
        }
    }

    #[cfg(target_os = "macos")]
    {
        let (total_bytes, used_bytes, available_bytes) = mount_space_bytes_macos("/");
        mounts.push(MountEntry {
            label: "Macintosh HD".to_string(),
            path: "/".to_string(),
            fs_type: "apfs".to_string(),
            total_bytes,
            used_bytes,
            available_bytes,
        });
        if let Ok(read_dir) = std::fs::read_dir("/Volumes") {
            for entry in read_dir.filter_map(|e| e.ok()) {
                let path = entry.path();
                // Skip the boot volume's own symlink/alias back into /Volumes.
                let Ok(canonical) = std::fs::canonicalize(&path) else { continue };
                if canonical == std::path::Path::new("/") { continue; }
                let label = entry.file_name().to_string_lossy().to_string();
                let path_str = path.to_string_lossy().to_string();
                let (total_bytes, used_bytes, available_bytes) = mount_space_bytes_macos(&path_str);
                mounts.push(MountEntry {
                    label,
                    path: path_str,
                    fs_type: "apfs".to_string(),
                    total_bytes,
                    used_bytes,
                    available_bytes,
                });
            }
        }
    }

    #[cfg(target_os = "windows")]
    {
        use std::ffi::OsStr;
        use std::os::windows::ffi::OsStrExt;

        let drive_mask = unsafe { GetLogicalDrives() };
        for bit in 0..26u32 {
            if drive_mask & (1 << bit) == 0 {
                continue;
            }
            let letter = (b'A' + bit as u8) as char;
            let drive = format!("{}:\\", letter);
            let wide: Vec<u16> = OsStr::new(&drive)
                .encode_wide()
                .chain(std::iter::once(0))
                .collect();

            let mut name_buf = vec![0u16; 256];
            let mut fs_buf = vec![0u16; 32];
            let vol_ok = unsafe {
                GetVolumeInformationW(
                    wide.as_ptr(),
                    name_buf.as_mut_ptr(),
                    name_buf.len() as u32,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    fs_buf.as_mut_ptr(),
                    fs_buf.len() as u32,
                )
            };
            if vol_ok == 0 {
                continue; // drive not ready (e.g. empty optical drive)
            }

            let nul = |b: &[u16]| b.iter().position(|&c| c == 0).unwrap_or(b.len());
            let vol_label = String::from_utf16_lossy(&name_buf[..nul(&name_buf)]);
            let fs_type = {
                let s = String::from_utf16_lossy(&fs_buf[..nul(&fs_buf)]);
                if s.is_empty() { "Unknown".to_string() } else { s }
            };
            let label = if vol_label.is_empty() {
                format!("Local Disk ({}:)", letter)
            } else {
                format!("{} ({}:)", vol_label, letter)
            };

            let mut free_avail: u64 = 0;
            let mut total: u64 = 0;
            let mut total_free: u64 = 0;
            let space_ok = unsafe {
                GetDiskFreeSpaceExW(
                    wide.as_ptr(),
                    &mut free_avail,
                    &mut total,
                    &mut total_free,
                )
            };
            let (total_bytes, used_bytes, available_bytes) = if space_ok != 0 {
                (total, total.saturating_sub(total_free), free_avail)
            } else {
                (0, 0, 0)
            };

            mounts.push(MountEntry {
                label,
                path: drive,
                fs_type,
                total_bytes,
                used_bytes,
                available_bytes,
            });
        }
    }

    mounts
}

// ── File properties ────────────────────────────────────────────────────────────

#[derive(Serialize, Clone)]
pub struct FileProperties {
    pub name: String,
    pub absolute_path: String,
    pub is_dir: bool,
    pub is_symlink: bool,
    pub symlink_target: Option<String>,
    pub size: u64,
    pub modified_secs: u64,
    pub created_secs: u64,
    pub accessed_secs: u64,
    pub permissions: String,
    pub mime_type: String,
}

#[derive(Serialize, Clone)]
pub struct FileHashes {
    pub md5: String,
    pub sha1: String,
    pub sha256: String,
    pub crc32: String,
}

#[derive(Serialize, Clone)]
pub struct VolumeInfo {
    pub mount_path: String,
    pub device: String,
    pub fs_type: String,
    pub total_bytes: u64,
    pub used_bytes: u64,
    pub available_bytes: u64,
}

#[derive(Serialize, Clone)]
pub struct FolderSummary {
    pub total_size: u64,
    pub file_count: u64,
    pub folder_count: u64,
    pub truncated: bool,
}

pub fn get_file_properties(path: String) -> Result<FileProperties, String> {
    let p = std::path::Path::new(&path);
    let lmeta = p.symlink_metadata().map_err(|e| e.to_string())?;
    let is_symlink = lmeta.file_type().is_symlink();
    let symlink_target = if is_symlink {
        std::fs::read_link(p).ok().map(|t| t.to_string_lossy().to_string())
    } else {
        None
    };
    let meta = p.metadata().map_err(|e| e.to_string())?;
    let is_dir = meta.is_dir();
    let size = meta.len();
    let modified_secs = meta.modified().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_secs()).unwrap_or(0);
    let created_secs  = meta.created().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_secs()).unwrap_or(0);
    let accessed_secs = meta.accessed().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_secs()).unwrap_or(0);

    #[cfg(unix)]
    let permissions = {
        use std::os::unix::fs::PermissionsExt;
        let mode = meta.permissions().mode() & 0o777;
        let bits = |v: u32, r: char, w: char, x: char| {
            format!("{}{}{}",
                if v & 4 != 0 { r } else { '-' },
                if v & 2 != 0 { w } else { '-' },
                if v & 1 != 0 { x } else { '-' })
        };
        format!("{}{}{}", bits(mode >> 6, 'r', 'w', 'x'), bits((mode >> 3) & 7, 'r', 'w', 'x'), bits(mode & 7, 'r', 'w', 'x'))
    };
    #[cfg(not(unix))]
    let permissions = if meta.permissions().readonly() { "read-only".to_string() } else { "read-write".to_string() };

    let name = p.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| path.clone());
    let mime_type = get_mime_type(path.clone());

    Ok(FileProperties { name, absolute_path: path, is_dir, is_symlink, symlink_target, size, modified_secs, created_secs, accessed_secs, permissions, mime_type })
}

pub fn calculate_file_hashes(path: String) -> Result<FileHashes, String> {
    let p = std::path::Path::new(&path);
    let meta = p.metadata().map_err(|e| e.to_string())?;
    if meta.is_dir() {
        return Err("Hashes are only available for files.".into());
    }

    let file = std::fs::File::open(p).map_err(|e| e.to_string())?;
    let mut reader = std::io::BufReader::new(file);
    let mut md5 = Md5::new();
    let mut sha1 = Sha1::new();
    let mut sha256 = Sha256::new();
    let mut crc32 = Crc32Hasher::new();
    let mut buffer = [0u8; 64 * 1024];

    loop {
        let read = reader.read(&mut buffer).map_err(|e| e.to_string())?;
        if read == 0 {
            break;
        }
        let chunk = &buffer[..read];
        md5.update(chunk);
        sha1.update(chunk);
        sha256.update(chunk);
        crc32.update(chunk);
    }

    Ok(FileHashes {
        md5: hex::encode(md5.finalize()),
        sha1: hex::encode(sha1.finalize()),
        sha256: hex::encode(sha256.finalize()),
        crc32: format!("{:08x}", crc32.finalize()),
    })
}

pub fn get_volume_info_for_path(path: String) -> Result<VolumeInfo, String> {
    let canonical = std::fs::canonicalize(&path).map_err(|e| e.to_string())?;
    let target = canonical.to_string_lossy().to_string();

    #[cfg(not(target_os = "linux"))]
    {
        let _ = target;
        Err("Volume info is currently available on Linux.".into())
    }

    #[cfg(target_os = "linux")]
    {
        let content = std::fs::read_to_string("/proc/mounts").map_err(|e| e.to_string())?;
        let mut best: Option<(String, String, String)> = None;
        for line in content.lines() {
            let parts: Vec<&str> = line.splitn(4, ' ').collect();
            if parts.len() < 3 {
                continue;
            }
            let device = decode_mount_field(parts[0]);
            let mount_point = decode_mount_field(parts[1]);
            let fs_type = parts[2].to_string();
            if target.starts_with(&mount_point)
                && mount_point.len() >= best.as_ref().map(|b| b.1.len()).unwrap_or(0)
            {
                best = Some((device, mount_point, fs_type));
            }
        }
        let Some((device, mount_path, fs_type)) = best else {
            return Err("Could not resolve mount point for path.".into());
        };
        let (total_bytes, used_bytes, available_bytes) = mount_space_bytes(&mount_path);
        Ok(VolumeInfo {
            mount_path,
            device,
            fs_type,
            total_bytes,
            used_bytes,
            available_bytes,
        })
    }
}

pub fn calculate_folder_summary(path: String) -> Result<FolderSummary, String> {
    const MAX_VISITED: u64 = 50_000;
    let root = std::fs::canonicalize(&path).map_err(|e| e.to_string())?;
    if !root.is_dir() {
        return Err("Folder summary is only available for folders.".into());
    }
    if !is_listable_path(&root.to_string_lossy()) {
        return Err("Security Block: Restricted path.".into());
    }

    let mut total_size = 0u64;
    let mut file_count = 0u64;
    let mut folder_count = 0u64;
    let mut visited = 0u64;
    let mut truncated = false;
    let mut stack = vec![root];

    while let Some(dir) = stack.pop() {
        if visited >= MAX_VISITED {
            truncated = true;
            break;
        }
        let read_dir = match std::fs::read_dir(&dir) {
            Ok(iter) => iter,
            Err(_) => continue,
        };
        for entry in read_dir.flatten() {
            if visited >= MAX_VISITED {
                truncated = true;
                break;
            }
            visited += 1;
            let path = entry.path();
            let meta = match entry.metadata() {
                Ok(meta) => meta,
                Err(_) => continue,
            };
            if meta.is_dir() {
                folder_count = folder_count.saturating_add(1);
                if !entry.file_type().map(|ft| ft.is_symlink()).unwrap_or(false) {
                    stack.push(path);
                }
            } else if meta.is_file() {
                file_count = file_count.saturating_add(1);
                total_size = total_size.saturating_add(meta.len());
            }
        }
    }

    Ok(FolderSummary { total_size, file_count, folder_count, truncated })
}

// ── Local filesystem CRUD ─────────────────────────────────────────────────────

fn is_safe_filename(name: &str) -> bool {
    const WINDOWS_RESERVED_CHARS: &[char] = &['/', '\\', '\0', ':', '*', '?', '"', '<', '>', '|'];
    const WINDOWS_RESERVED_NAMES: &[&str] = &[
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    ];
    if name.is_empty()
        || name == "."
        || name == ".."
        || name.len() >= 256
        || name.chars().any(|c| WINDOWS_RESERVED_CHARS.contains(&c))
        || name.trim_end_matches(['.', ' ']).is_empty()
    {
        return false;
    }
    // Windows reserved device names are blocked regardless of extension (e.g. "NUL.txt").
    let stem = name.split('.').next().unwrap_or(name);
    if WINDOWS_RESERVED_NAMES.iter().any(|r| r.eq_ignore_ascii_case(stem)) {
        return false;
    }
    true
}

pub fn fs_create_file(dir: String, name: String) -> Result<String, String> {
    if !is_safe_filename(&name) { return Err("Invalid file name.".into()); }
    let canonical = std::fs::canonicalize(&dir).map_err(|e| e.to_string())?;
    if !is_listable_path(&canonical.to_string_lossy()) {
        return Err("Security Block: Restricted path.".into());
    }
    let dest = canonical.join(&name);
    if dest.exists() { return Err("File already exists.".into()); }
    std::fs::File::create(&dest).map_err(|e| e.to_string())?;
    Ok(dest.to_string_lossy().to_string())
}

pub fn fs_create_text_file(dir: String, name: String, content: String) -> Result<String, String> {
    if !is_safe_filename(&name) { return Err("Invalid file name.".into()); }
    if content.len() > 1024 * 1024 { return Err("Template content is too large.".into()); }
    let canonical = std::fs::canonicalize(&dir).map_err(|e| e.to_string())?;
    if !is_listable_path(&canonical.to_string_lossy()) {
        return Err("Security Block: Restricted path.".into());
    }
    let dest = canonical.join(&name);
    if dest.exists() { return Err("File already exists.".into()); }
    std::fs::write(&dest, content).map_err(|e| e.to_string())?;
    Ok(dest.to_string_lossy().to_string())
}

pub async fn fs_compress(paths: Vec<String>, dest_dir: String, format: String) -> Result<(), String> {
    if paths.is_empty() { return Err("No paths provided.".into()); }
    for p in &paths {
        let c = std::fs::canonicalize(p).map_err(|e| e.to_string())?;
        if !is_listable_path(&c.to_string_lossy()) {
            return Err("Security Block: Restricted path.".into());
        }
    }
    let dest_canonical = std::fs::canonicalize(&dest_dir).map_err(|e| e.to_string())?;
    if !is_listable_path(&dest_canonical.to_string_lossy()) {
        return Err("Security Block: Restricted path.".into());
    }
    let base_name = std::path::Path::new(paths.first().unwrap())
        .file_name().map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "archive".to_string());
    let archive_name = format!("{}.{}", base_name, format.to_lowercase());
    let archive_path = dest_canonical.join(&archive_name);
    let archive_str = archive_path.to_str().ok_or("Invalid archive path")?.to_string();
    let fmt = format.to_lowercase();

    // Run compression in a blocking thread so Tauri's async runtime stays free
    tokio::task::spawn_blocking(move || {
        let status = match fmt.as_str() {
            #[cfg(target_os = "windows")]
            "zip" => std::process::Command::new("powershell")
                .args(["-NoProfile", "-Command", "Compress-Archive"])
                .arg("-Path").args(&paths)
                .arg("-DestinationPath").arg(&archive_str)
                .arg("-Force")
                .current_dir(&dest_canonical).status()
                .map_err(|e| format!("Failed to launch PowerShell for compression: {e}"))?,
            #[cfg(not(target_os = "windows"))]
            "zip" => std::process::Command::new("zip")
                .arg("-r").arg(&archive_str).args(&paths)
                .current_dir(&dest_canonical).status()
                .map_err(|_| "zip not found. Install the 'zip' package.".to_string())?,
            "7z" => std::process::Command::new("7z")
                .arg("a").arg(&archive_str).args(&paths)
                .current_dir(&dest_canonical).status()
                .map_err(|_| {
                    #[cfg(target_os = "windows")]
                    { "7z not found. Install 7-Zip and ensure 7z.exe is on PATH.".to_string() }
                    #[cfg(target_os = "macos")]
                    { "7z not found. Install it via 'brew install p7zip'.".to_string() }
                    #[cfg(not(any(target_os = "windows", target_os = "macos")))]
                    { "7z not found. Install the 'p7zip' package.".to_string() }
                })?,
            _ => return Err(format!("Unsupported format: {}", fmt)),
        };
        if !status.success() { return Err(format!("Compression failed (exit {:?})", status.code())); }
        Ok(())
    }).await.map_err(|e| e.to_string())?
}

pub fn fs_create_dir(path: String) -> Result<(), String> {
    let p = std::path::Path::new(&path);
    let parent = p.parent().ok_or("No parent directory")?;
    let canonical_parent = std::fs::canonicalize(parent).map_err(|e| e.to_string())?;
    if !is_listable_path(&canonical_parent.to_string_lossy()) {
        return Err("Security Block: Restricted path.".into());
    }
    let name = p.file_name().ok_or("No directory name")?.to_string_lossy();
    if !is_safe_filename(&name) { return Err("Invalid directory name.".into()); }
    std::fs::create_dir(canonical_parent.join(&*name)).map_err(|e| e.to_string())
}

pub fn fs_rename(old_path: String, new_name: String) -> Result<String, String> {
    if !is_safe_filename(&new_name) { return Err("Invalid file name.".into()); }
    let canonical = std::fs::canonicalize(&old_path).map_err(|e| e.to_string())?;
    if !is_listable_path(&canonical.to_string_lossy()) {
        return Err("Security Block: Restricted path.".into());
    }
    let parent = canonical.parent().ok_or("No parent directory")?;
    let new_path = parent.join(&new_name);
    std::fs::rename(&canonical, &new_path).map_err(|e| e.to_string())?;
    Ok(new_path.to_string_lossy().to_string())
}

pub fn fs_bulk_rename(paths: Vec<String>, base_name: String) -> Result<Vec<String>, String> {
    let base = base_name.trim();
    if !is_safe_filename(base) || base.contains('.') {
        return Err("Enter a valid base name without an extension.".into());
    }
    if paths.len() < 2 {
        return Err("Select at least two items to bulk rename.".into());
    }
    if paths.len() > 500 {
        return Err("Bulk rename is limited to 500 items at a time.".into());
    }

    let mut planned: Vec<(std::path::PathBuf, std::path::PathBuf)> = Vec::new();
    let mut reserved = std::collections::HashSet::<std::path::PathBuf>::new();

    for (index, path) in paths.iter().enumerate() {
        let canonical = std::fs::canonicalize(path).map_err(|e| e.to_string())?;
        if !is_listable_path(&canonical.to_string_lossy()) {
            return Err("Security Block: Restricted path.".into());
        }
        let parent = canonical.parent().ok_or("No parent directory")?;
        let meta = canonical.metadata().map_err(|e| e.to_string())?;
        let ext = if meta.is_file() {
            canonical.extension().and_then(|e| e.to_str()).unwrap_or("")
        } else {
            ""
        };
        let candidate_name = if ext.is_empty() {
            format!("{} {}", base, index + 1)
        } else {
            format!("{} {}.{}", base, index + 1, ext)
        };
        if !is_safe_filename(&candidate_name) {
            return Err("Generated file name is invalid.".into());
        }
        let mut dest = parent.join(candidate_name);
        if dest.exists() || reserved.contains(&dest) {
            dest = unique_path_for_collision(&dest)?;
            while reserved.contains(&dest) {
                dest = unique_path_for_collision(&dest)?;
            }
        }
        reserved.insert(dest.clone());
        planned.push((canonical, dest));
    }

    let mut renamed = Vec::with_capacity(planned.len());
    for (source, dest) in planned {
        std::fs::rename(&source, &dest).map_err(|e| e.to_string())?;
        renamed.push(dest.to_string_lossy().to_string());
    }
    Ok(renamed)
}

pub fn fs_trash(paths: Vec<String>) -> Vec<(String, Result<(), String>)> {
    paths.into_iter().map(|path| {
        let result = (|| {
            let src_path = std::path::Path::new(&path);
            let lmeta = src_path.symlink_metadata().map_err(|e| e.to_string())?;
            if lmeta.file_type().is_symlink() {
                // Security check on parent dir, not the (possibly dangling) target.
                let parent = src_path.parent().ok_or("No parent dir")?;
                let canonical_parent = std::fs::canonicalize(parent).map_err(|e| e.to_string())?;
                if !is_listable_path(&canonical_parent.to_string_lossy()) {
                    return Err("Security Block: Restricted path.".into());
                }
                // Trash the symlink itself, not the canonical target.
                trash::delete(src_path).map_err(|e| e.to_string())
            } else {
                let canonical = std::fs::canonicalize(src_path).map_err(|e| e.to_string())?;
                if !is_listable_path(&canonical.to_string_lossy()) {
                    return Err("Security Block: Restricted path.".into());
                }
                trash::delete(&canonical).map_err(|e| e.to_string())
            }
        })();
        (path, result)
    }).collect()
}

#[cfg(target_os = "linux")]
fn xdg_trash_dirs() -> Result<(std::path::PathBuf, std::path::PathBuf), String> {
    let home = std::env::var("HOME").map_err(|_| "HOME is not set.".to_string())?;
    let base = std::path::PathBuf::from(home).join(".local/share/Trash");
    Ok((base.join("files"), base.join("info")))
}

#[cfg(target_os = "linux")]
fn percent_decode_path(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(hex) = u8::from_str_radix(&input[i + 1..i + 3], 16) {
                out.push(hex);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).to_string()
}

#[cfg(target_os = "linux")]
fn trash_info_for_path(path: &std::path::Path) -> Result<std::path::PathBuf, String> {
    let (_, info_dir) = xdg_trash_dirs()?;
    let name = path.file_name().ok_or("Trash item has no file name.")?;
    Ok(info_dir.join(format!("{}.trashinfo", name.to_string_lossy())))
}

#[cfg(target_os = "linux")]
fn original_path_from_trash_info(info_path: &std::path::Path) -> Result<std::path::PathBuf, String> {
    let content = std::fs::read_to_string(info_path).map_err(|e| e.to_string())?;
    for line in content.lines() {
        if let Some(path) = line.strip_prefix("Path=") {
            return Ok(std::path::PathBuf::from(percent_decode_path(path)));
        }
    }
    Err("Trash metadata is missing the original path.".into())
}

// Parses a Windows $I metadata file and returns (original_path, deletion_filetime).
// Supports both the Vista/7 (v1) and Windows 8+ (v2) formats.
#[cfg(target_os = "windows")]
fn parse_windows_recycle_i_file(
    i_file: &std::path::Path,
) -> Result<(std::path::PathBuf, u64), String> {
    let data = std::fs::read(i_file).map_err(|e| e.to_string())?;
    if data.len() < 28 {
        return Err(format!("$I file too small: {} bytes", data.len()));
    }
    let version = u64::from_le_bytes(data[0..8].try_into().unwrap());
    let filetime = u64::from_le_bytes(data[16..24].try_into().unwrap());

    let path_utf16: Vec<u16> = if version == 2 {
        // Windows 8+ format: [24..28] = path length in UTF-16 code units, then path
        let path_len = u32::from_le_bytes(data[24..28].try_into().unwrap()) as usize;
        let end = 28 + path_len * 2;
        if data.len() < end {
            return Err("$I file path truncated".into());
        }
        data[28..end].chunks(2).map(|c| u16::from_le_bytes([c[0], c[1]])).collect()
    } else {
        // Windows Vista/7 format: null-terminated UTF-16 starting at offset 24
        let path_data = &data[24..];
        let pairs: Vec<u16> = path_data
            .chunks(2)
            .filter(|c| c.len() == 2)
            .map(|c| u16::from_le_bytes([c[0], c[1]]))
            .collect();
        let end = pairs.iter().position(|&c| c == 0).unwrap_or(pairs.len());
        pairs[..end].to_vec()
    };

    let original = String::from_utf16(&path_utf16).map_err(|e| e.to_string())?;
    Ok((std::path::PathBuf::from(original), filetime))
}

pub fn fs_restore_trash(paths: Vec<String>) -> Result<(), String> {
    #[cfg(target_os = "linux")]
    {
        let (trash_files_dir, _) = xdg_trash_dirs()?;
        let trash_root = std::fs::canonicalize(&trash_files_dir).map_err(|e| e.to_string())?;
        for path in paths {
            let source = std::fs::canonicalize(&path).map_err(|e| e.to_string())?;
            if !source.starts_with(&trash_root) {
                return Err("Only items inside the local Trash can be restored.".into());
            }
            let info_path = trash_info_for_path(&source)?;
            let destination = original_path_from_trash_info(&info_path)?;
            if destination.exists() {
                return Err(format!("Restore target already exists: {}", destination.to_string_lossy()));
            }
            if let Some(parent) = destination.parent() {
                std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
            }
            std::fs::rename(&source, &destination).map_err(|e| e.to_string())?;
            let _ = std::fs::remove_file(info_path);
        }
        return Ok(());
    }
    #[cfg(target_os = "windows")]
    {
        for path in paths {
            let src = std::path::Path::new(&path);
            let file_name = src
                .file_name()
                .ok_or("No file name")?
                .to_string_lossy();
            // Expect $R<id> files; skip $I files silently
            if !file_name.starts_with("$R") && !file_name.starts_with("$r") {
                continue;
            }
            let i_name = format!("$I{}", &file_name[2..]);
            let i_path = src.parent().unwrap_or(src).join(i_name);
            let (destination, _) = parse_windows_recycle_i_file(&i_path)?;
            if destination.exists() {
                return Err(format!(
                    "Restore target already exists: {}",
                    destination.to_string_lossy()
                ));
            }
            if let Some(parent) = destination.parent() {
                std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
            }
            std::fs::rename(src, &destination).map_err(|e| e.to_string())?;
            let _ = std::fs::remove_file(&i_path);
        }
        return Ok(());
    }
    #[cfg(target_os = "macos")]
    {
        let _ = paths;
        return Err("Restore from Trash is not supported on macOS — original path metadata is not available.".into());
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
    {
        let _ = paths;
        Err("Trash restore is not supported on this platform.".into())
    }
}

pub fn fs_empty_trash() -> Result<(), String> {
    #[cfg(target_os = "linux")]
    {
        let (files_dir, info_dir) = xdg_trash_dirs()?;
        if files_dir.exists() {
            for entry in std::fs::read_dir(&files_dir).map_err(|e| e.to_string())? {
                let path = entry.map_err(|e| e.to_string())?.path();
                if path.is_dir() {
                    std::fs::remove_dir_all(&path).map_err(|e| e.to_string())?;
                } else {
                    std::fs::remove_file(&path).map_err(|e| e.to_string())?;
                }
            }
        }
        if info_dir.exists() {
            for entry in std::fs::read_dir(&info_dir).map_err(|e| e.to_string())? {
                let path = entry.map_err(|e| e.to_string())?.path();
                if path.is_file() {
                    std::fs::remove_file(&path).map_err(|e| e.to_string())?;
                }
            }
        }
        return Ok(());
    }
    #[cfg(target_os = "windows")]
    {
        // SHERB_NOCONFIRMATION=0x1 | SHERB_NOPROGRESSUI=0x2 | SHERB_NOSOUND=0x4
        const FLAGS: u32 = 0x0007;
        let result = unsafe { SHEmptyRecycleBinW(std::ptr::null_mut(), std::ptr::null(), FLAGS) };
        // S_OK=0, S_FALSE=1 (already empty) are both success
        if result < 0 {
            return Err(format!("SHEmptyRecycleBinW failed: 0x{:08X}", result as u32));
        }
        return Ok(());
    }
    #[cfg(target_os = "macos")]
    {
        let home = std::env::var("HOME").map_err(|_| "HOME is not set.".to_string())?;
        let trash = std::path::PathBuf::from(home).join(".Trash");
        if trash.exists() {
            for entry in std::fs::read_dir(&trash).map_err(|e| e.to_string())? {
                let path = entry.map_err(|e| e.to_string())?.path();
                if path.is_dir() {
                    std::fs::remove_dir_all(&path).map_err(|e| e.to_string())?;
                } else {
                    std::fs::remove_file(&path).map_err(|e| e.to_string())?;
                }
            }
        }
        return Ok(());
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
    {
        Err("Empty Trash is not supported on this platform.".into())
    }
}

pub fn fs_delete_permanent(paths: Vec<String>) -> Vec<(String, Result<(), String>)> {
    paths.into_iter().map(|path| {
        let result = (|| {
            let src_path = std::path::Path::new(&path);
            let lmeta = src_path.symlink_metadata().map_err(|e| e.to_string())?;
            if lmeta.file_type().is_symlink() {
                // Symlinks: check parent, then remove the link itself (not the target).
                let parent = src_path.parent().ok_or("No parent dir")?;
                let canonical_parent = std::fs::canonicalize(parent).map_err(|e| e.to_string())?;
                if !is_listable_path(&canonical_parent.to_string_lossy()) {
                    return Err("Security Block: Restricted path.".into());
                }
                std::fs::remove_file(src_path).map_err(|e| e.to_string())
            } else {
                let canonical = std::fs::canonicalize(src_path).map_err(|e| e.to_string())?;
                if !is_listable_path(&canonical.to_string_lossy()) {
                    return Err("Security Block: Restricted path.".into());
                }
                if canonical.is_dir() {
                    std::fs::remove_dir_all(&canonical).map_err(|e| e.to_string())
                } else {
                    std::fs::remove_file(&canonical).map_err(|e| e.to_string())
                }
            }
        })();
        (path, result)
    }).collect()
}

pub fn fs_rotate_image(path: String, direction: String) -> Result<(), String> {
    let canonical = std::fs::canonicalize(&path).map_err(|e| e.to_string())?;
    if !is_listable_path(&canonical.to_string_lossy()) { return Err("Security block".into()); }

    // Pure-Rust rotation via the `image` crate — identical behavior on every
    // platform, no dependency on jpegtran/imagemagick being installed.
    let img = image::open(&canonical).map_err(|e| format!("Could not read image: {e}"))?;
    let rotated = if direction == "left" { img.rotate270() } else { img.rotate90() };

    let ext = canonical.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();
    if ext == "jpg" || ext == "jpeg" {
        let mut buf = std::io::Cursor::new(Vec::new());
        let rgb = rotated.to_rgb8();
        let mut encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut buf, 92);
        encoder.encode_image(&rgb).map_err(|e| e.to_string())?;
        std::fs::write(&canonical, buf.into_inner()).map_err(|e| e.to_string())?;
    } else {
        rotated.save(&canonical).map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[cfg(target_os = "windows")]
#[link(name = "User32")]
extern "system" {
    fn SystemParametersInfoW(
        ui_action: u32,
        ui_param: u32,
        pv_param: *mut u16,
        f_win_ini: u32,
    ) -> i32;
}

pub fn set_wallpaper(path: String) -> Result<(), String> {
    let canonical = std::fs::canonicalize(&path).map_err(|e| e.to_string())?;
    let p = canonical.to_string_lossy().to_string();

    #[cfg(target_os = "linux")]
    {
        let uri = format!("file://{}", p);
        if std::process::Command::new("gsettings")
            .args(["set", "org.gnome.desktop.background", "picture-uri", &uri])
            .status().map(|s| s.success()).unwrap_or(false) {
            let _ = std::process::Command::new("gsettings")
                .args(["set", "org.gnome.desktop.background", "picture-uri-dark", &uri])
                .status();
            return Ok(());
        }
        if std::process::Command::new("feh").args(["--bg-fill", &p]).status().map(|s| s.success()).unwrap_or(false) {
            return Ok(());
        }
        return Err("Could not set wallpaper. Install feh, or use a GNOME-based desktop.".into());
    }
    #[cfg(target_os = "macos")]
    {
        let script = format!(
            "tell application \"System Events\" to tell every desktop to set picture to \"{}\"",
            p.replace('\\', "\\\\").replace('"', "\\\"")
        );
        let status = std::process::Command::new("osascript").arg("-e").arg(&script).status();
        if status.map(|s| s.success()).unwrap_or(false) {
            return Ok(());
        }
        return Err("Could not set wallpaper via System Events.".into());
    }
    #[cfg(target_os = "windows")]
    {
        use std::ffi::OsStr;
        use std::os::windows::ffi::OsStrExt;
        const SPI_SETDESKWALLPAPER: u32 = 0x0014;
        const SPIF_UPDATEINIFILE: u32 = 0x01;
        const SPIF_SENDCHANGE: u32 = 0x02;
        let mut wide: Vec<u16> = OsStr::new(&p).encode_wide().chain(std::iter::once(0)).collect();
        let ok = unsafe {
            SystemParametersInfoW(
                SPI_SETDESKWALLPAPER,
                0,
                wide.as_mut_ptr(),
                SPIF_UPDATEINIFILE | SPIF_SENDCHANGE,
            )
        };
        if ok != 0 {
            return Ok(());
        }
        return Err("Could not set wallpaper via SystemParametersInfoW.".into());
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
    {
        let _ = p;
        Err("Setting the wallpaper is not supported on this platform.".into())
    }
}

pub fn fs_extract_to_subfolder(path: String) -> Result<(), String> {
    let canonical = std::fs::canonicalize(&path).map_err(|e| e.to_string())?;
    let p = canonical.to_string_lossy().to_string();
    if !is_listable_path(&p) { return Err("Security block".into()); }
    let stem = canonical.file_stem().and_then(|s| s.to_str()).unwrap_or("extracted");
    let parent = canonical.parent().unwrap_or(std::path::Path::new("."));
    let dest = parent.join(stem);
    std::fs::create_dir_all(&dest).map_err(|e| e.to_string())?;

    let ext = p.split('.').next_back().unwrap_or("").to_lowercase();
    if ext == "zip" {
        return extract_zip_archive(&canonical, &dest);
    }
    extract_with_external_tool(&canonical, &dest)
}

fn unique_path_for_collision(dest: &std::path::Path) -> Result<std::path::PathBuf, String> {
    let parent = dest.parent().ok_or("No parent directory")?;
    let file_name = dest
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or("Invalid file name")?;
    let is_file_like = dest.extension().is_some();
    let (stem, ext) = if is_file_like {
        let stem = dest.file_stem().and_then(|s| s.to_str()).unwrap_or(file_name);
        let ext = dest.extension().and_then(|e| e.to_str()).unwrap_or("");
        (stem.to_string(), ext.to_string())
    } else {
        (file_name.to_string(), String::new())
    };
    for index in 1..10_000 {
        let suffix = if index == 1 { " copy".to_string() } else { format!(" copy {}", index) };
        let candidate_name = if ext.is_empty() {
            format!("{}{}", stem, suffix)
        } else {
            format!("{}{}.{}", stem, suffix, ext)
        };
        let candidate = parent.join(candidate_name);
        if !candidate.exists() {
            return Ok(candidate);
        }
    }
    Err("Could not find a free collision name.".into())
}

fn resolve_collision_dest(dest: &std::path::Path, collision: &str) -> Result<Option<std::path::PathBuf>, String> {
    if !dest.exists() {
        return Ok(Some(dest.to_path_buf()));
    }
    match collision {
        "skip" => Ok(None),
        "replace" => {
            if dest.is_dir() {
                std::fs::remove_dir_all(dest).map_err(|e| e.to_string())?;
            } else {
                std::fs::remove_file(dest).map_err(|e| e.to_string())?;
            }
            Ok(Some(dest.to_path_buf()))
        }
        "fail" => Err(format!("Destination already exists: {}", dest.to_string_lossy())),
        _ => Ok(Some(unique_path_for_collision(dest)?)),
    }
}

fn copy_entry(src: &std::path::Path, dest_dir: &std::path::Path, collision: &str) -> Result<(), String> {
    if src.is_dir() && dest_dir.starts_with(src) {
        return Err("Cannot copy a folder into itself.".into());
    }
    let name = src.file_name().ok_or("No file name")?;
    let dest = dest_dir.join(name);
    if let Some(dest) = resolve_collision_dest(&dest, collision)? {
        copy_entry_to(src, &dest)
    } else {
        Ok(())
    }
}

static COPY_SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

fn temp_name() -> String {
    let seq = COPY_SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    format!(".datieve_tmp_{}_{}", std::process::id(), seq)
}

fn copy_file_atomic(src: &std::path::Path, dest: &std::path::Path) -> Result<(), String> {
    let parent = dest.parent().ok_or("No parent directory for destination")?;
    let tmp = parent.join(temp_name());
    let result = std::fs::copy(src, &tmp).map(|_| ());
    if let Err(e) = result {
        let _ = std::fs::remove_file(&tmp);
        return Err(e.to_string());
    }
    if let Err(e) = std::fs::rename(&tmp, dest) {
        let _ = std::fs::remove_file(&tmp);
        return Err(e.to_string());
    }
    Ok(())
}

fn copy_dir_recursive(src: &std::path::Path, dest: &std::path::Path) -> Result<(), String> {
    use std::collections::VecDeque;
    let mut work: VecDeque<(std::path::PathBuf, std::path::PathBuf)> = VecDeque::new();
    work.push_back((src.to_path_buf(), dest.to_path_buf()));
    while let Some((src_dir, dest_dir)) = work.pop_front() {
        std::fs::create_dir_all(&dest_dir).map_err(|e| e.to_string())?;
        for entry in std::fs::read_dir(&src_dir).map_err(|e| e.to_string())? {
            let entry = entry.map_err(|e| e.to_string())?;
            let child_dest = dest_dir.join(entry.file_name());
            // file_type() does not follow symlinks — safe against directory symlink loops
            let file_type = entry.file_type().map_err(|e| e.to_string())?;
            if file_type.is_symlink() {
                #[cfg(unix)]
                {
                    let target = std::fs::read_link(entry.path()).map_err(|e| e.to_string())?;
                    std::os::unix::fs::symlink(&target, &child_dest)
                        .map_err(|e| e.to_string())?;
                }
            } else if file_type.is_dir() {
                work.push_back((entry.path(), child_dest));
            } else {
                copy_file_atomic(&entry.path(), &child_dest)?;
            }
        }
    }
    Ok(())
}

fn copy_entry_to(src: &std::path::Path, dest: &std::path::Path) -> Result<(), String> {
    if src.is_dir() {
        let parent = dest.parent().ok_or("No parent directory for destination")?;
        let tmp = parent.join(temp_name());
        let result = copy_dir_recursive(src, &tmp);
        if let Err(e) = result {
            let _ = std::fs::remove_dir_all(&tmp);
            return Err(e);
        }
        if let Err(e) = std::fs::rename(&tmp, dest) {
            let _ = std::fs::remove_dir_all(&tmp);
            return Err(e.to_string());
        }
    } else {
        copy_file_atomic(src, dest)?;
    }
    Ok(())
}

fn duplicate_path_for(src: &std::path::Path) -> Result<std::path::PathBuf, String> {
    let parent = src.parent().ok_or("No parent directory")?;
    let file_name = src
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or("Invalid file name")?;
    let (stem, ext) = if src.is_file() {
        let stem = src.file_stem().and_then(|s| s.to_str()).unwrap_or(file_name);
        let ext = src.extension().and_then(|e| e.to_str()).unwrap_or("");
        (stem.to_string(), ext.to_string())
    } else {
        (file_name.to_string(), String::new())
    };
    for index in 1..10_000 {
        let suffix = if index == 1 {
            " copy".to_string()
        } else {
            format!(" copy {}", index)
        };
        let candidate_name = if ext.is_empty() {
            format!("{}{}", stem, suffix)
        } else {
            format!("{}{}.{}", stem, suffix, ext)
        };
        let candidate = parent.join(candidate_name);
        if !candidate.exists() {
            return Ok(candidate);
        }
    }
    Err("Could not find a free duplicate name.".into())
}

pub fn fs_copy(
    src_paths: Vec<String>,
    dest_dir: String,
    collision: Option<String>,
) -> Result<Vec<(String, Result<(), String>)>, String> {
    let collision = collision.unwrap_or_else(|| "rename".into());
    let canonical_dest = std::fs::canonicalize(&dest_dir).map_err(|e| e.to_string())?;
    if !is_listable_path(&canonical_dest.to_string_lossy()) {
        return Err("Security Block: Restricted destination.".into());
    }
    let results = src_paths.into_iter().map(|src| {
        let result = (|| {
            let src_path = std::path::Path::new(&src);
            let lmeta = src_path.symlink_metadata().map_err(|e| e.to_string())?;
            if lmeta.file_type().is_symlink() {
                // Symlinks: recreate the link at the destination (copy the pointer,
                // not the target's content).
                let parent = src_path.parent().ok_or("No parent dir")?;
                let canonical_parent = std::fs::canonicalize(parent).map_err(|e| e.to_string())?;
                if !is_listable_path(&canonical_parent.to_string_lossy()) {
                    return Err("Security Block: Restricted source.".into());
                }
                let link_target = std::fs::read_link(src_path).map_err(|e| e.to_string())?;
                let name = src_path.file_name().ok_or("No file name")?;
                let dest = canonical_dest.join(name);
                let Some(dest) = resolve_collision_dest(&dest, &collision)? else {
                    return Ok(());
                };
                #[cfg(unix)]
                std::os::unix::fs::symlink(&link_target, &dest).map_err(|e| e.to_string())?;
                #[cfg(windows)]
                {
                    let t = std::path::Path::new(&link_target);
                    if t.is_dir() {
                        std::os::windows::fs::symlink_dir(&link_target, &dest).map_err(|e| e.to_string())?;
                    } else {
                        std::os::windows::fs::symlink_file(&link_target, &dest).map_err(|e| e.to_string())?;
                    }
                }
                Ok(())
            } else {
                let canonical_src = std::fs::canonicalize(src_path).map_err(|e| e.to_string())?;
                if !is_listable_path(&canonical_src.to_string_lossy()) {
                    return Err("Security Block: Restricted source.".into());
                }
                copy_entry(&canonical_src, &canonical_dest, &collision)
            }
        })();
        (src, result)
    }).collect();
    Ok(results)
}

pub fn fs_duplicate(paths: Vec<String>) -> Result<Vec<String>, String> {
    let mut duplicated = Vec::new();
    for src in &paths {
        let canonical_src = std::fs::canonicalize(src).map_err(|e| e.to_string())?;
        if !is_listable_path(&canonical_src.to_string_lossy()) {
            return Err("Security Block: Restricted source.".into());
        }
        let dest = duplicate_path_for(&canonical_src)?;
        copy_entry_to(&canonical_src, &dest)?;
        duplicated.push(dest.to_string_lossy().to_string());
    }
    Ok(duplicated)
}

pub fn fs_move_paths(
    src_paths: Vec<String>,
    dest_dir: String,
    collision: Option<String>,
) -> Result<Vec<(String, Result<(), String>)>, String> {
    let collision = collision.unwrap_or_else(|| "rename".into());
    let canonical_dest = std::fs::canonicalize(&dest_dir).map_err(|e| e.to_string())?;
    if !is_listable_path(&canonical_dest.to_string_lossy()) {
        return Err("Security Block: Restricted destination.".into());
    }
    let results = src_paths.into_iter().map(|src| {
        let result = (|| {
            let src_path = std::path::Path::new(&src);
            // Use lstat (symlink_metadata) so we don't follow symlinks.
            let is_symlink = src_path.symlink_metadata()
                .map(|m| m.file_type().is_symlink())
                .unwrap_or(false);

            // Security: check that the containing directory is allowed.
            let src_parent = src_path.parent().ok_or("No parent dir")?;
            let canonical_parent = std::fs::canonicalize(src_parent).map_err(|e| e.to_string())?;
            if !is_listable_path(&canonical_parent.to_string_lossy()) {
                return Err("Security Block: Restricted source.".into());
            }

            // Subtree guard: prevent moving a real directory into itself.
            // Skip for symlinks — the link itself is not a directory tree.
            if !is_symlink {
                let canonical_src = std::fs::canonicalize(src_path).map_err(|e| e.to_string())?;
                if canonical_src.is_dir() && canonical_dest.starts_with(&canonical_src) {
                    return Err("Cannot move a folder into itself.".into());
                }
            }

            // Preserve the entry's own name (symlink name, not the resolved target name).
            let name = src_path.file_name().ok_or("No file name")?;
            let dest = canonical_dest.join(name);
            let Some(dest) = resolve_collision_dest(&dest, &collision)? else {
                return Ok(());
            };

            // Fast path: rename works atomically on the same filesystem.
            // Pass the original src_path so symlinks move as symlinks.
            if std::fs::rename(src_path, &dest).is_ok() {
                return Ok(());
            }

            // Cross-device fallback: copy then delete.
            if is_symlink {
                let link_target = std::fs::read_link(src_path).map_err(|e| e.to_string())?;
                #[cfg(unix)]
                std::os::unix::fs::symlink(&link_target, &dest).map_err(|e| e.to_string())?;
                #[cfg(windows)]
                {
                    let t = std::path::Path::new(&link_target);
                    if t.is_dir() {
                        std::os::windows::fs::symlink_dir(&link_target, &dest).map_err(|e| e.to_string())?;
                    } else {
                        std::os::windows::fs::symlink_file(&link_target, &dest).map_err(|e| e.to_string())?;
                    }
                }
                std::fs::remove_file(src_path).map_err(|e| e.to_string())?;
            } else {
                let canonical_src = std::fs::canonicalize(src_path).map_err(|e| e.to_string())?;
                copy_entry_to(&canonical_src, &dest)?;
                if canonical_src.is_dir() {
                    std::fs::remove_dir_all(&canonical_src).map_err(|e| e.to_string())?;
                } else {
                    std::fs::remove_file(&canonical_src).map_err(|e| e.to_string())?;
                }
            }
            Ok(())
        })();
        (src, result)
    }).collect();
    Ok(results)
}

pub fn fs_create_symlink(link_path: String, target: String) -> Result<(), String> {
    let p = std::path::Path::new(&link_path);
    let parent = p.parent().ok_or("No parent directory")?;
    let canonical_parent = std::fs::canonicalize(parent).map_err(|e| e.to_string())?;
    if !is_listable_path(&canonical_parent.to_string_lossy()) {
        return Err("Security Block: Restricted path.".into());
    }
    let name = p.file_name().ok_or("No link name")?.to_string_lossy();
    if !is_safe_filename(&name) { return Err("Invalid link name.".into()); }
    let full_link = canonical_parent.join(&*name);
    #[cfg(unix)]
    std::os::unix::fs::symlink(&target, &full_link).map_err(|e| e.to_string())?;
    #[cfg(windows)]
    {
        let target_path = std::path::Path::new(&target);
        if target_path.is_dir() {
            std::os::windows::fs::symlink_dir(&target, &full_link).map_err(|e| e.to_string())?;
        } else {
            std::os::windows::fs::symlink_file(&target, &full_link).map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

fn is_path_safe(path: &str) -> bool {
    let lower_path = path.to_lowercase();

    // Block UNC / device paths
    if lower_path.starts_with(r"\\") || lower_path.starts_with("//") {
        return false;
    }

    #[cfg(target_os = "windows")]
    {
        let forbidden = [
            "c:\\windows",
            "c:\\program files",
            "c:\\programdata",
        ];
        !forbidden.iter().any(|f| lower_path.starts_with(f))
    }
    #[cfg(not(target_os = "windows"))]
    {
        // Block kernel/OS virtual filesystems only — user files on any real path are allowed.
        let system_paths = ["/proc", "/sys", "/dev", "/run"];
        !system_paths.iter().any(|s| path == *s || path.starts_with(&format!("{}/", s)))
    }
}

fn resolve_and_verify(path: &str) -> Result<String, String> {
    if !is_path_safe(path) {
        return Err("Security Block: Restricted path.".into());
    }
    let canonical = std::fs::canonicalize(path).map_err(|e| e.to_string())?;
    let canonical_str = canonical.to_string_lossy().to_string();
    let final_path = if canonical_str.starts_with(r"\\?\") {
        canonical_str[4..].to_string()
    } else {
        canonical_str
    };
    if !is_path_safe(&final_path) {
        return Err("Security Block: Restricted link target.".into());
    }
    Ok(final_path)
}

pub fn pick_folder() -> Result<Option<String>, String> {
    // Try zenity (GNOME/GTK), then kdialog (KDE)
    for (cmd, args) in [
        ("zenity", vec!["--file-selection", "--directory", "--title=Choose folder to index"]),
        ("kdialog", vec!["--getexistingdirectory", "/", "--title", "Choose folder to index"]),
    ] {
        if let Ok(out) = std::process::Command::new(cmd).args(&args).output() {
            if out.status.success() {
                let path = String::from_utf8_lossy(&out.stdout).trim().to_string();
                if !path.is_empty() {
                    return Ok(Some(path));
                }
            }
        }
    }
    Ok(None)
}

pub async fn open_file_native(path: String) -> Result<(), String> {
    #[cfg(target_os = "windows")]
    {
        use std::ffi::OsStr;
        use std::os::windows::ffi::OsStrExt;
        let op: Vec<u16> = OsStr::new("open").encode_wide().chain(std::iter::once(0)).collect();
        let file: Vec<u16> = OsStr::new(&path).encode_wide().chain(std::iter::once(0)).collect();
        let result = unsafe {
            ShellExecuteW(std::ptr::null_mut(), op.as_ptr(), file.as_ptr(), std::ptr::null(), std::ptr::null(), 1)
        };
        if result <= 32 {
            return Err(format!("Cannot open file (ShellExecute code {})", result));
        }
        return Ok(());
    }
    #[cfg(target_os = "macos")]
    {
        let safe_path = resolve_and_verify(&path)?;
        std::process::Command::new("open")
            .arg(&safe_path)
            .spawn()
            .map_err(|e| e.to_string())?;
        return Ok(());
    }
    #[cfg(target_os = "linux")]
    {
        let safe_path = resolve_and_verify(&path)?;
        std::process::Command::new("xdg-open")
            .arg(&safe_path)
            .spawn()
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

pub async fn reveal_in_explorer(path: String) -> Result<(), String> {
    let safe_path = resolve_and_verify(&path)?;
    #[cfg(target_os = "windows")]
    {
        std::process::Command::new("explorer")
            .args(["/select,", &safe_path])
            .spawn()
            .map_err(|e| e.to_string())?;
    }
    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("open")
            .args(["-R", &safe_path])
            .spawn()
            .map_err(|e| e.to_string())?;
    }
    #[cfg(target_os = "linux")]
    {
        if let Some(parent) = std::path::Path::new(&safe_path).parent() {
            std::process::Command::new("xdg-open")
                .arg(parent)
                .spawn()
                .map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

fn friendly_transport_error(message: &str) -> String {
    let lower = message.to_ascii_lowercase();
    if lower.contains("connection refused") {
        return "Agent unreachable.".into();
    }
    if lower.contains("pinned certificate fingerprint mismatch") {
        return "Agent certificate changed. Select the agent again.".into();
    }
    message.to_string()
}

const DISCOVERY_PING: &[u8] = b"DATIEVE_PING";
const UDP_DISCOVERY_LISTEN_MS: u64 = 300;

fn discovery_udp_port(https_port: u16) -> u16 {
    https_port.saturating_add(2)
}

fn parse_discovery_json(
    body: &str,
    source_host: &str,
    default_https_port: u16,
) -> Option<DiscoveredAgent> {
    let json = serde_json::from_str::<serde_json::Value>(body).ok()?;
    let hostname = json["hostname"].as_str()?;
    let version = json["version"].as_str()?;
    let https_port = json["port"]
        .as_u64()
        .map(|p| p as u16)
        .unwrap_or(default_https_port);
    Some(DiscoveredAgent {
        ip: format_agent_endpoint(source_host, https_port),
        hostname: hostname.to_string(),
        version: version.to_string(),
        is_setup: json["is_setup"].as_bool().unwrap_or(true),
        mode: json["mode"].as_str().map(str::to_string),
        demo: json["demo"].as_bool().unwrap_or(false) || json["mode"].as_str() == Some("demo"),
        fingerprint: json["fingerprint"].as_str().map(str::to_string),
    })
}

fn discovery_source_host(addr: &std::net::SocketAddr) -> String {
    match addr.ip() {
        std::net::IpAddr::V4(v4) => v4.to_string(),
        std::net::IpAddr::V6(v6) => v6.to_string(),
    }
}

fn collect_ping_hosts(hint_ips: &[String]) -> Vec<String> {
    let mut hosts = vec![normalize_agent_host("127.0.0.1")];
    for hint in hint_ips {
        let host = hint.split(':').next().unwrap_or(hint).trim();
        if host.is_empty() {
            continue;
        }
        let normalized = normalize_agent_host(host);
        if !hosts.iter().any(|h| h == &normalized) {
            hosts.push(normalized);
        }
    }
    if let Ok(my_ip) = local_ip() {
        if let std::net::IpAddr::V4(ipv4) = my_ip {
            let octets = ipv4.octets();
            let subnet_broadcast = format!("{}.{}.{}.255", octets[0], octets[1], octets[2]);
            if !hosts.iter().any(|h| h == &subnet_broadcast) {
                hosts.push(subnet_broadcast);
            }
            if !hosts.iter().any(|h| h == "255.255.255.255") {
                hosts.push("255.255.255.255".into());
            }
        }
    }
    hosts
}

fn push_unique_agent(found: &mut Vec<DiscoveredAgent>, agent: DiscoveredAgent) {
    if found.iter().any(|a| {
        a.ip == agent.ip
            || a
                .fingerprint
                .as_ref()
                .zip(agent.fingerprint.as_ref())
                .map(|(a, b)| a == b)
                .unwrap_or(false)
    }) {
        return;
    }
    found.push(agent);
}

async fn discover_via_udp(https_ports: &[u16], hint_ips: &[String]) -> Result<Vec<DiscoveredAgent>, String> {
    let socket = tokio::net::UdpSocket::bind("0.0.0.0:0")
        .await
        .map_err(|e| e.to_string())?;
    socket
        .set_broadcast(true)
        .map_err(|e| e.to_string())?;

    let default_https_port = https_ports.first().copied().unwrap_or(34514);
    for host in collect_ping_hosts(hint_ips) {
        for &https_port in https_ports {
            let udp_port = discovery_udp_port(https_port);
            let target = format!("{host}:{udp_port}");
            let _ = socket.send_to(DISCOVERY_PING, &target).await;
        }
    }

    let mut found = Vec::new();
    let deadline = std::time::Instant::now() + Duration::from_millis(UDP_DISCOVERY_LISTEN_MS);
    let mut buf = [0u8; 2048];

    while std::time::Instant::now() < deadline {
        let remaining = deadline.saturating_duration_since(std::time::Instant::now());
        if remaining.is_zero() {
            break;
        }
        match tokio::time::timeout(remaining, socket.recv_from(&mut buf)).await {
            Ok(Ok((n, from))) => {
                if let Ok(body) = std::str::from_utf8(&buf[..n]) {
                    if let Some(agent) =
                        parse_discovery_json(body, &discovery_source_host(&from), default_https_port)
                    {
                        push_unique_agent(&mut found, agent);
                    }
                }
            }
            _ => break,
        }
    }

    Ok(found)
}

async fn discover_via_http_hints(
    client: Client,
    https_ports: &[u16],
    hint_ips: &[String],
) -> Vec<DiscoveredAgent> {
    let mut hosts = collect_ping_hosts(hint_ips);
    hosts.retain(|h| h != "255.255.255.255");
    let default_https_port = https_ports.first().copied().unwrap_or(34514);

    let mut tasks = Vec::new();
    for host in hosts {
        for &https_port in https_ports {
            let client = client.clone();
            let host = host.clone();
            tasks.push(async move {
                let url = format!("https://{host}:{https_port}/api/auth/discovery");
                match client
                    .get(&url)
                    .timeout(Duration::from_millis(250))
                    .send()
                    .await
                {
                    Ok(res) => {
                        if let Ok(body) = read_limited_body(res, MAX_DISCOVERY_RESPONSE_BYTES).await
                        {
                            return parse_discovery_json(&body, &host, default_https_port);
                        }
                    }
                    Err(_) => {}
                }
                None
            });
        }
    }

    let mut found = Vec::new();
    for agent in join_all(tasks).await.into_iter().flatten() {
        push_unique_agent(&mut found, agent);
    }
    found
}

fn finalize_discovered(mut all_found: Vec<DiscoveredAgent>) -> Vec<DiscoveredAgent> {
    let mut seen_fps: Vec<String> = Vec::new();
    // Prefer loopback when the same agent is seen on LAN + localhost (more reliable TLS).
    all_found.sort_by_key(|a| if a.ip.starts_with("127.0.0.1") { 0 } else { 1 });
    let mut discovered = Vec::new();
    for agent in all_found {
        if let Some(ref fp) = agent.fingerprint {
            if seen_fps.iter().any(|s| s == fp) {
                continue;
            }
            seen_fps.push(fp.clone());
        }
        discovered.push(agent);
    }
    discovered
}

pub async fn discover_agents(
    state: &AppState,
    port: Option<u16>,
    hint_ips: Option<Vec<String>>,
) -> Result<Vec<DiscoveredAgent>, String> {
    let https_ports: Vec<u16> = match port {
        Some(p) => vec![p],
        None => vec![34514u16, 34515u16],
    };
    let hints = hint_ips.unwrap_or_default();

    let mut all_found = discover_via_udp(&https_ports, &hints).await?;
    if all_found.is_empty() {
        all_found = discover_via_http_hints(state.discovery_client.clone(), &https_ports, &hints).await;
    }

    Ok(finalize_discovered(all_found))
}

pub async fn secure_fetch(
    state: &AppState,
    url: String,
    method: String,
    body: Option<String>,
    token: Option<String>, // Bearer session token, or None for public auth/discovery calls.
    mac_key: Option<String>,
) -> Result<FetchResponse, String> {
    // Small retry for LAN flakiness (wake, brief network hiccup) — not for security.
    let parsed_url = validate_agent_url(&url)?;
    let agent_key = agent_key_from_url(&url)?;

    // If no fingerprint is pinned yet, only allow the public discovery endpoint.
    let pinned = get_pinned_fingerprint(agent_key.clone())?;
    let client = if let Some(fp) = pinned {
        // Reuse the cached client if the fingerprint is unchanged; rebuild only when it changes.
        let mut cache = state.pinned_clients.lock().unwrap();
        if let Some((cached_fp, cached_client)) = cache.get(&agent_key) {
            if cached_fp == &fp {
                cached_client.clone()
            } else {
                let c = build_pinned_client(fp.clone(), Some(Duration::from_secs(10)))?;
                cache.insert(agent_key.clone(), (fp, c.clone()));
                c
            }
        } else {
            let c = build_pinned_client(fp.clone(), Some(Duration::from_secs(10)))?;
            cache.insert(agent_key.clone(), (fp, c.clone()));
            c
        }
    } else {
        if !is_discovery_url(&url) || method != "GET" || token.is_some() || body.is_some() {
            return Err(format!(
                "Unpaired agent TLS for {}. Pin the agent certificate fingerprint before sending credentials.",
                agent_key
            ));
        }
        state.discovery_client.clone()
    };
    let mut last_err = "connection failed".to_string();
    for attempt in 0..3u32 {
        let mut req_builder = match method.as_str() {
            "GET" => client.get(parsed_url.clone()),
            "POST" => client.post(parsed_url.clone()),
            "PUT" => client.put(parsed_url.clone()),
            "DELETE" => client.delete(parsed_url.clone()),
            _ => return Err("Invalid method".to_string()),
        };

        if let Some(t) = &token {
            validate_bearer_token(t)?;
            req_builder = req_builder.header("Authorization", format!("Bearer {}", t));
        }
        if let Some(k) = &mac_key {
            validate_mac_key(k)?;
            let nonce = request_nonce();
            let mac = request_mac(method.as_str(), &parsed_url, &nonce, k);
            req_builder = req_builder
                .header("X-Datieve-Nonce", nonce)
                .header("X-Datieve-Mac", mac);
        }
        if let Some(b) = &body {
            req_builder = req_builder
                .header("Content-Type", "application/json")
                .body(b.clone());
        }

        match req_builder.send().await {
            Ok(r) => {
                let status = r.status().as_u16();
                let body_str = read_limited_body(r, MAX_AGENT_RESPONSE_BYTES).await?;
                return Ok(FetchResponse {
                    status,
                    body: body_str,
                });
            }
            Err(e) => {
                last_err = e.to_string();
                if attempt < 2 {
                    tokio::time::sleep(std::time::Duration::from_millis(
                        250 * (attempt as u64 + 1),
                    ))
                    .await;
                }
            }
        }
    }
    Err(friendly_transport_error(&last_err))
}

pub fn set_secure_item(key: String, value: String) -> Result<(), String> {
    validate_secure_item_key(&key)?;
    let entry = Entry::new("com.datieve.navigator", &key).map_err(|e| e.to_string())?;
    entry.set_password(&value).map_err(|e| e.to_string())?;
    Ok(())
}

pub fn get_secure_item(key: String) -> Result<Option<String>, String> {
    validate_secure_item_key(&key)?;
    let entry = Entry::new("com.datieve.navigator", &key).map_err(|e| e.to_string())?;
    match entry.get_password() {
        Ok(p) => Ok(Some(p)),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(e) => Err(e.to_string()),
    }
}

pub fn delete_secure_item(key: String) -> Result<(), String> {
    validate_secure_item_key(&key)?;
    let entry = Entry::new("com.datieve.navigator", &key).map_err(|e| e.to_string())?;
    match entry.delete_credential() {
        Ok(_) => Ok(()),
        Err(keyring::Error::NoEntry) => Ok(()),
        Err(e) => Err(e.to_string()),
    }
}

/// Per-agent pinned certificate fingerprint support (now that agent writes agent.cert.fingerprint).
/// Allows the app to remember the expected SHA-256 for TOFU/pinning workflows on LAN self-signed certs.
pub fn set_pinned_fingerprint(agent_ip: String, fingerprint: String) -> Result<(), String> {
    let agent_ip = validate_agent_key(&agent_ip)?;
    let fingerprint = normalize_fingerprint(&fingerprint)?;
    let key = format!("fingerprint_{}", agent_ip);
    let entry = Entry::new("com.datieve.navigator", &key).map_err(|e| e.to_string())?;
    entry.set_password(&fingerprint).map_err(|e| e.to_string())
}

pub fn delete_pinned_fingerprint(agent_ip: String) -> Result<(), String> {
    let agent_ip = validate_agent_key(&agent_ip)?;
    let key = format!("fingerprint_{}", agent_ip);
    let entry = Entry::new("com.datieve.navigator", &key).map_err(|e| e.to_string())?;
    match entry.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(e) => Err(e.to_string()),
    }
}

pub fn get_pinned_fingerprint(agent_ip: String) -> Result<Option<String>, String> {
    let agent_ip = validate_agent_key(&agent_ip)?;
    let key = format!("fingerprint_{}", agent_ip);
    let entry = Entry::new("com.datieve.navigator", &key).map_err(|e| e.to_string())?;
    match entry.get_password() {
        Ok(p) => Ok(Some(p)),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(e) => Err(e.to_string()),
    }
}

pub async fn probe_agent_fingerprint(agent: String) -> Result<String, String> {
    tokio::task::spawn_blocking(move || {
        let agent_key = validate_agent_key(&agent)?;
        let (host, port) = match agent_key.rsplit_once(':') {
            Some((h, p)) => (h.to_string(), p.parse::<u16>().map_err(|_| "Invalid port")?),
            None => return Err("Expected host:port".to_string()),
        };

        let server_name = ServerName::try_from(host.clone()).map_err(|_| "Invalid server name")?;
        let captured = Arc::new(std::sync::Mutex::new(None::<String>));
        let crypto_provider = CryptoProvider::get_default()
            .cloned()
            .ok_or_else(|| "No rustls crypto provider installed".to_string())?;
        let verifier = Arc::new(CaptureFingerprintVerifier {
            captured_fp_hex: captured.clone(),
            crypto_provider,
        });
        let tls = rustls::ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(verifier)
            .with_no_client_auth();

        let mut conn =
            rustls::ClientConnection::new(Arc::new(tls), server_name).map_err(|e| e.to_string())?;

        let addr = resolve_agent_socket_addr(&host, port)?;
        let mut sock = std::net::TcpStream::connect_timeout(
            &addr,
            std::time::Duration::from_secs(2),
        )
        .map_err(|e| friendly_transport_error(&e.to_string()))?;
        let _ = sock.set_read_timeout(Some(std::time::Duration::from_secs(3)));
        let _ = sock.set_write_timeout(Some(std::time::Duration::from_secs(3)));

        while conn.is_handshaking() {
            conn.complete_io(&mut sock).map_err(|e| e.to_string())?;
        }

        let fp = captured
            .lock()
            .ok()
            .and_then(|g| g.clone())
            .ok_or_else(|| "Could not capture fingerprint".to_string())?;
        Ok(fp)
    })
    .await
    .map_err(|e| e.to_string())?
}

pub async fn listen_to_sse(
    state: &AppState,
    listener_id: String,
    url: String,
    token: Option<String>,
    mac_key: Option<String>,
    on_event: std::sync::Arc<dyn Fn(String) + Send + Sync>,
) -> Result<(), String> {
    let parsed_url = validate_agent_url(&url)?;
    let agent_key = agent_key_from_url(&url)?;
    let task_key = format!("{}:{}", listener_id, agent_key);
    let pinned = get_pinned_fingerprint(agent_key.clone())?;
    let client = if let Some(fp) = pinned {
        // SSE connections must not have a request timeout — they stream indefinitely.
        let mut cache = state.sse_pinned_clients.lock().unwrap();
        if let Some((cached_fp, cached_client)) = cache.get(&agent_key) {
            if cached_fp == &fp {
                cached_client.clone()
            } else {
                let c = build_pinned_client(fp.clone(), None)?;
                cache.insert(agent_key.clone(), (fp, c.clone()));
                c
            }
        } else {
            let c = build_pinned_client(fp.clone(), None)?;
            cache.insert(agent_key.clone(), (fp, c.clone()));
            c
        }
    } else {
        return Err(format!(
            "Unpaired agent TLS for {}. Pin the agent certificate fingerprint before connecting.",
            agent_key
        ));
    };

    {
        let mut tasks = state
            .sse_tasks
            .lock()
            .map_err(|_| "SSE task registry is unavailable".to_string())?;
        if let Some(previous) = tasks.remove(&task_key) {
            previous.abort();
        }
    }

    let handle = tokio::spawn(async move {
        let mut req_builder = client.get(parsed_url.clone());
        if let Some(t) = token {
            if let Err(e) = validate_bearer_token(&t) {
                eprintln!("SSE token rejected: {}", e);
                return;
            }
            req_builder = req_builder.header("Authorization", format!("Bearer {}", t));
        }
        if let Some(k) = mac_key {
            if let Err(e) = validate_mac_key(&k) {
                eprintln!("SSE MAC key rejected: {}", e);
                return;
            }
            let nonce = request_nonce();
            let mac = request_mac("GET", &parsed_url, &nonce, &k);
            req_builder = req_builder
                .header("X-Datieve-Nonce", nonce)
                .header("X-Datieve-Mac", mac);
        }

        let res = match req_builder.send().await {
            Ok(r) => r,
            Err(e) => {
                eprintln!("SSE Connection failed: {}", e);
                return;
            }
        };

        use futures_util::StreamExt;
        let mut stream = res.bytes_stream();

        while let Some(item) = stream.next().await {
            match item {
                Ok(bytes) => {
                    let text = String::from_utf8_lossy(&bytes);
                    for line in text.lines() {
                        if line.starts_with("data:") {
                            let data = line.strip_prefix("data:").unwrap_or("").trim();
                            on_event(data.to_string());
                        }
                    }
                }
                Err(e) => {
                    eprintln!("SSE stream error: {}", e);
                    break;
                }
            }
        }
    });
    state
        .sse_tasks
        .lock()
        .map_err(|_| "SSE task registry is unavailable".to_string())?
        .insert(task_key, handle);
    Ok(())
}

pub async fn stop_sse(state: &AppState, agent: Option<String>) -> Result<(), String> {
    let normalized_agent = match agent {
        Some(agent) => Some(validate_agent_key(&agent)?),
        None => None,
    };

    let mut tasks = state
        .sse_tasks
        .lock()
        .map_err(|_| "SSE task registry is unavailable".to_string())?;
    let keys = tasks.keys().cloned().collect::<Vec<_>>();
    for key in keys {
        let should_stop = normalized_agent
            .as_ref()
            .map(|agent_key| key.ends_with(agent_key))
            .unwrap_or(true);
        if should_stop {
            if let Some(handle) = tasks.remove(&key) {
                handle.abort();
            }
        }
    }
    Ok(())
}

pub fn log_ui_error(message: String) {
    eprintln!("[UI] {}", message);
}


pub fn init_app_state() -> AppState {
    AppState {
        discovery_client: Client::builder()
            .pool_max_idle_per_host(0)
            .danger_accept_invalid_certs(true)
            .build()
            .expect("discovery client"),
        sse_tasks: Mutex::new(HashMap::new()),
        pinned_clients: Mutex::new(HashMap::new()),
        sse_pinned_clients: Mutex::new(HashMap::new()),
    }
}
