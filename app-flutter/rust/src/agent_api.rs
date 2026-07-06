use crate::core::{secure_fetch, AppState, FetchResponse};
use serde::Deserialize;
use std::sync::Arc;

#[derive(Debug, Clone, Deserialize)]
pub struct DiscoveryStatus {
    pub is_setup: bool,
    pub demo: Option<bool>,
    pub mode: Option<String>,
    pub hostname: Option<String>,
    pub version: Option<String>,
}

#[derive(Debug, Clone)]
pub struct AgentInfo {
    pub ip: String,
    pub hostname: String,
    pub is_setup: bool,
    pub demo: bool,
    pub mode: Option<String>,
}

pub fn normalize_agent_ip(ip: &str) -> String {
    let trimmed = ip.trim();
    if trimmed.contains(':') {
        trimmed.to_string()
    } else {
        format!("{trimmed}:34514")
    }
}

pub fn normalize_fingerprint(fp: &str) -> Option<String> {
    let normalized: String = fp
        .trim()
        .to_lowercase()
        .chars()
        .filter(|c| c.is_ascii_hexdigit())
        .collect();
    if normalized.len() == 64 {
        Some(normalized)
    } else {
        None
    }
}

pub fn agent_error_message(body: &str, fallback: &str) -> String {
    if body.is_empty() {
        return fallback.into();
    }
    if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(body) {
        if let Some(msg) = parsed.get("message").and_then(|v| v.as_str()) {
            return msg.to_string();
        }
        if let Some(err) = parsed.get("error").and_then(|v| v.as_str()) {
            return err.to_string();
        }
    }
    body.to_string()
}

pub fn transport_error(err: &str, action: &str) -> String {
    if err.contains("Pinned certificate fingerprint mismatch") {
        return "This agent certificate changed. Select the agent again before continuing.".into();
    }
    if err.contains("Unpaired agent TLS") {
        return "Could not pair with this agent. Select the agent again and retry.".into();
    }
    if err.contains("Connection refused")
        || err.contains("connection refused")
        || err.contains("Agent unreachable")
    {
        return "That agent is no longer reachable. Go back and scan again.".into();
    }
    format!("Could not {action}. Check that the agent is still running and try again.")
}

pub async fn check_agent_status(state: &AppState, ip: &str) -> Result<DiscoveryStatus, String> {
    let endpoint = normalize_agent_ip(ip);
    let res = secure_fetch(
        state,
        format!("https://{endpoint}/api/auth/discovery"),
        "GET".into(),
        None,
        None,
        None,
    )
    .await?;
    if res.status == 200 {
        serde_json::from_str(&res.body).map_err(|e| e.to_string())
    } else {
        Err(agent_error_message(
            &res.body,
            &format!("Agent returned status {}.", res.status),
        ))
    }
}

pub async fn agent_fetch(
    state: &AppState,
    ip: &str,
    path: &str,
    method: &str,
    body: Option<String>,
    token: Option<String>,
    mac_key: Option<String>,
) -> Result<FetchResponse, String> {
    let endpoint = normalize_agent_ip(ip);
    secure_fetch(
        state,
        format!("https://{endpoint}{path}"),
        method.into(),
        body,
        token,
        mac_key,
    )
    .await
}

pub async fn verify_login_code(
    state: &AppState,
    ip: &str,
    code: &str,
) -> Result<serde_json::Value, String> {
    let res = agent_fetch(
        state,
        ip,
        "/api/auth/verify-code",
        "POST",
        Some(serde_json::json!({ "code": code }).to_string()),
        None,
        None,
    )
    .await?;
    if res.status == 200 {
        serde_json::from_str(&res.body).map_err(|e| e.to_string())
    } else {
        Err(agent_error_message(&res.body, "Invalid code."))
    }
}

pub async fn validate_session(
    state: &AppState,
    ip: &str,
    token: &str,
    mac_key: Option<&str>,
) -> Result<serde_json::Value, String> {
    let res = agent_fetch(
        state,
        ip,
        "/api/auth/me",
        "GET",
        None,
        Some(token.to_string()),
        mac_key.map(|s| s.to_string()),
    )
    .await?;
    if res.status == 200 {
        serde_json::from_str(&res.body).map_err(|e| e.to_string())
    } else {
        Err(agent_error_message(&res.body, "Session expired."))
    }
}

pub async fn finalize_setup(
    state: &AppState,
    ip: &str,
    payload: serde_json::Value,
) -> Result<(), String> {
    let res = agent_fetch(
        state,
        ip,
        "/api/auth/setup/finalize",
        "POST",
        Some(payload.to_string()),
        None,
        None,
    )
    .await?;
    if res.status == 200 {
        Ok(())
    } else {
        Err(agent_error_message(
            &res.body,
            "Check your values and try again.",
        ))
    }
}

#[derive(Debug, Clone)]
pub struct SessionData {
    pub token: String,
    pub mac_key: Option<String>,
    pub username: Option<String>,
    pub role: Option<String>,
}

impl SessionData {
    pub fn from_json(_v: serde_json::Value) -> Self {
        let v = _v;
        let token = v
            .get("token")
            .and_then(|t| t.as_str())
            .unwrap_or_default()
            .to_string();
        let mac_key = v
            .get("mac_key")
            .and_then(|t| t.as_str())
            .map(|s| s.to_string());
        let username = v
            .get("username")
            .and_then(|t| t.as_str())
            .map(|s| s.to_string());
        let role = v
            .get("role")
            .and_then(|t| t.as_str())
            .map(|s| s.to_string());
        Self {
            token,
            mac_key,
            username,
            role,
        }
    }

    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "token": self.token,
            "mac_key": self.mac_key,
            "username": self.username,
            "role": self.role,
        })
    }
}

pub struct AgentApi {
    pub state: Arc<AppState>,
}

impl AgentApi {
    pub fn new(state: Arc<AppState>) -> Self {
        Self { state }
    }

    pub async fn check_status(&self, ip: &str) -> Result<DiscoveryStatus, String> {
        check_agent_status(&self.state, ip).await
    }

    pub async fn login(&self, ip: &str, code: &str) -> Result<SessionData, String> {
        let json = verify_login_code(&self.state, ip, code).await?;
        Ok(SessionData::from_json(json))
    }
}