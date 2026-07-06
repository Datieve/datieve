use crate::agent_api::{normalize_agent_ip, SessionData};
use crate::core::{delete_secure_item, get_secure_item, set_secure_item};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredAccount {
    pub username: String,
    pub role: String,
    pub code: String,
}

pub fn load_accounts(ip: &str) -> Vec<StoredAccount> {
    let key = format!("accounts_{}", normalize_agent_ip(ip));
    get_secure_item(key)
        .ok()
        .flatten()
        .and_then(|raw| serde_json::from_str(&raw).ok())
        .unwrap_or_default()
}

pub fn save_accounts(ip: &str, accounts: &[StoredAccount]) -> Result<(), String> {
    let key = format!("accounts_{}", normalize_agent_ip(ip));
    set_secure_item(key, serde_json::to_string(accounts).map_err(|e| e.to_string())?)
}

pub fn save_account(ip: &str, entry: &StoredAccount) -> Result<(), String> {
    let mut accounts = load_accounts(ip);
    if let Some(idx) = accounts
        .iter()
        .position(|a| a.username == entry.username && a.role == entry.role)
    {
        accounts[idx] = entry.clone();
    } else {
        accounts.push(entry.clone());
    }
    save_accounts(ip, &accounts)
}

pub fn load_saved_session(ip: &str) -> Option<SessionData> {
    let key = format!("session_{}", normalize_agent_ip(ip));
    let raw = get_secure_item(key).ok().flatten()?;
    let v: serde_json::Value = serde_json::from_str(&raw).ok()?;
    Some(SessionData::from_json(v))
}

pub fn persist_session(ip: &str, session: &SessionData) -> Result<(), String> {
    let key = format!("session_{}", normalize_agent_ip(ip));
    set_secure_item(key, session.to_json().to_string())
}

pub fn clear_session(ip: &str) -> Result<(), String> {
    let key = format!("session_{}", normalize_agent_ip(ip));
    delete_secure_item(key)
}