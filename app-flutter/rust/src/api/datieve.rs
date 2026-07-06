use crate::agent_api::{
    agent_error_message, agent_fetch, check_agent_status, finalize_setup, transport_error,
};
use crate::bridge::{
    bridge, AccountDto, AgentInfoDto, AgentItemDto, AppSettingsDto, ConnectResult,
    DatieveBridge, FetchResponseDto, FileListMetaDto, FileStreamEvent, MountEntryDto, PlaceDto,
    SessionAuthDto, SessionDto, SetupStateDto, SetupUserDto,
};
use crate::core::{list_mounts, secure_fetch};
use crate::core::{
    discover_agents as core_discover_agents, reset_app_settings, save_app_settings,
};
use crate::file_manager::{default_home, load_places};
use crate::frb_generated::StreamSink;

use crate::session::{clear_session, load_accounts, persist_session, save_account, StoredAccount};
use crate::setup_state::{SetupForm, SetupUser, TOTAL_STEPS};

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
    let _ = rustls::crypto::ring::default_provider().install_default();
    let _ = bridge();
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_settings() -> AppSettingsDto {
    bridge().lock().unwrap().settings.clone().into()
}

#[flutter_rust_bridge::frb(sync)]
pub fn save_theme(theme: String) -> AppSettingsDto {
    let mut b = bridge().lock().unwrap();
    b.settings.theme = theme;
    if let Ok(saved) = save_app_settings(b.settings.clone()) {
        b.settings = saved;
    }
    b.settings.clone().into()
}

#[flutter_rust_bridge::frb(sync)]
pub fn save_scan_port(port: u16) -> AppSettingsDto {
    let mut b = bridge().lock().unwrap();
    if (1024..65535).contains(&port) {
        b.settings.scan_port = port;
        if let Ok(saved) = save_app_settings(b.settings.clone()) {
            b.settings = saved;
        }
    }
    b.settings.clone().into()
}

#[flutter_rust_bridge::frb(sync)]
pub fn save_settings(settings: AppSettingsDto) -> AppSettingsDto {
    let mut b = bridge().lock().unwrap();
    let next: crate::core::DatieveAppSettings = settings.into();
    if let Ok(saved) = save_app_settings(next) {
        b.settings = saved;
    }
    b.settings.clone().into()
}

#[flutter_rust_bridge::frb(sync)]
pub fn reset_settings() -> AppSettingsDto {
    let mut b = bridge().lock().unwrap();
    if let Ok(saved) = reset_app_settings() {
        b.settings = saved;
    }
    b.settings.clone().into()
}

#[flutter_rust_bridge::frb]
pub async fn discover_agents() -> Vec<AgentItemDto> {
    let (port, core) = {
        let b = bridge().lock().unwrap();
        (b.settings.scan_port, b.core.clone())
    };
    match core_discover_agents(&core, Some(port), None).await {
        Ok(agents) => agents.iter().map(DatieveBridge::agent_row).collect(),
        Err(_) => vec![],
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn delete_pinned_fingerprint(agent_ip: String) -> Result<(), String> {
    crate::core::delete_pinned_fingerprint(agent_ip)
}

fn loopback_fallback_endpoint(endpoint: &str) -> Option<String> {
    let (host, port) = endpoint.rsplit_once(':')?;
    if host == "127.0.0.1" || host == "localhost" {
        return None;
    }
    Some(format!("127.0.0.1:{port}"))
}

#[flutter_rust_bridge::frb]
pub async fn connect_agent(ip: String, fingerprint: Option<String>, skip_auto_login: bool) -> ConnectResult {
    let (core, existing_session) = {
        let b = bridge().lock().unwrap();
        (b.core.clone(), b.session.clone())
    };

    let mut target_ip = crate::agent_api::normalize_agent_ip(&ip);
    let advertised = fingerprint.as_deref();

    let mut pin_err = None;
    if let Err(e) = DatieveBridge::ensure_pinned(&core, &target_ip, advertised).await {
        pin_err = Some(e);
        let _ = crate::core::delete_pinned_fingerprint(target_ip.clone());
    }

    let mut status_err = None;
    let mut status = None;
    if pin_err.is_none() {
        match check_agent_status(&core, &target_ip).await {
            Ok(s) => status = Some(s),
            Err(e) => {
                let msg = transport_error(&e, "connect to this agent");
                let _ = crate::core::delete_pinned_fingerprint(target_ip.clone());
                status_err = Some(msg);
            }
        }
    }

    // Retry via loopback when LAN connect fails but agent is on this machine.
    if status.is_none() {
        let loopback = loopback_fallback_endpoint(&target_ip);
        if let Some(loopback_ip) = loopback {
            let _ = crate::core::delete_pinned_fingerprint(target_ip.clone());
            target_ip = loopback_ip.clone();
            pin_err = None;
            status_err = None;
            if let Err(e) = DatieveBridge::ensure_pinned(&core, &target_ip, advertised).await {
                pin_err = Some(e);
            } else {
                match check_agent_status(&core, &target_ip).await {
                    Ok(s) => status = Some(s),
                    Err(e) => {
                        let _ = crate::core::delete_pinned_fingerprint(target_ip.clone());
                        status_err = Some(transport_error(&e, "connect to this agent"));
                    }
                }
            }
        }
    }

    if let Some(e) = pin_err {
        return ConnectResult {
            screen: "discovery".into(),
            agent: None,
            login_accounts: vec![],
            error: Some(e),
        };
    }
    if let Some(msg) = status_err {
        return ConnectResult {
            screen: "discovery".into(),
            agent: None,
            login_accounts: vec![],
            error: Some(msg),
        };
    }

    let status = status.expect("status checked above");

    let agent = crate::agent_api::AgentInfo {
        ip: target_ip.clone(),
        hostname: status.hostname.unwrap_or_else(|| "Agent".into()),
        is_setup: status.is_setup,
        demo: status.demo.unwrap_or(false),
        mode: status.mode,
    };

    let route = DatieveBridge::route_after_agent(&core, agent.clone(), existing_session, skip_auto_login).await;
    let mut b = bridge().lock().unwrap();
    b.agent = Some(agent.clone());
    b.session = route.session;
    if route.needs_setup_reset {
        b.setup = SetupForm::new();
    }
    ConnectResult {
        screen: route.screen,
        agent: Some(agent.into()),
        login_accounts: route.login_accounts,
        error: None,
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn disconnect_agent() {
    let mut b = bridge().lock().unwrap();
    if let Some(agent) = b.agent.as_ref() {
        let _ = clear_session(&agent.ip);
    }
    b.agent = None;
    b.session = None;
    b.view_mode = "local".into();
}

/// Clears the stored session for the current agent without disconnecting.
/// Used for explicit logout: keeps the agent connection so the UI can
/// immediately show the login/account-chooser screen.
#[flutter_rust_bridge::frb(sync)]
pub fn logout_session() {
    let mut b = bridge().lock().unwrap();
    if let Some(agent) = b.agent.as_ref() {
        let _ = crate::session::clear_session(&agent.ip);
    }
    b.session = None;
}

#[flutter_rust_bridge::frb(sync)]
pub fn forget_account(code: String) {
    let b = bridge().lock().unwrap();
    if let Some(agent) = b.agent.as_ref() {
        let ip = agent.ip.clone();
        drop(b);
        let mut accounts = crate::session::load_accounts(&ip);
        accounts.retain(|a| a.code != code);
        let _ = crate::session::save_accounts(&ip, &accounts);
    }
}

#[flutter_rust_bridge::frb]
pub async fn login_with_code(code: String) -> Result<SessionDto, String> {
    let (agent_ip, core) = {
        let b = bridge().lock().unwrap();
        let agent = b.agent.clone().ok_or("No agent selected.")?;
        (agent.ip, b.core.clone())
    };

    let api = crate::agent_api::AgentApi::new(core);
    let sess = api.login(&agent_ip, &code).await?;
    let _ = persist_session(&agent_ip, &sess);
    let username = sess.username.clone().unwrap_or_default();
    let role = sess.role.clone().unwrap_or_else(|| "user".into());
    let _ = save_account(
        &agent_ip,
        &StoredAccount {
            username: username.clone(),
            role: role.clone(),
            code: code.clone(),
        },
    );

    let mut b = bridge().lock().unwrap();
    b.session = Some(sess);
    Ok(SessionDto {
        username,
        role: role.clone(),
        is_admin: role == "admin",
    })
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_setup_state() -> SetupStateDto {
    bridge().lock().unwrap().setup_state_dto()
}

#[flutter_rust_bridge::frb(sync)]
pub fn update_setup_state(state: SetupStateDto) -> SetupStateDto {
    let mut b = bridge().lock().unwrap();
    b.setup.step = state.step;
    b.setup.friendly_name = state.friendly_name;
    b.setup.admin_username = state.admin_username;
    b.setup.admin_code = state.admin_code;
    b.setup.watched_paths = state.watched_paths;
    b.setup.exclude_hidden = state.exclude_hidden;
    b.setup.exclusion_patterns = state.exclusion_patterns;
    b.setup.users = state
        .users
        .into_iter()
        .map(|u| SetupUser {
            username: u.username,
            code: u.code,
            allowed_paths: u.allowed_paths,
        })
        .collect();
    b.setup.manage_username = state.manage_username;
    b.setup.manage_password = state.manage_password;
    b.setup_state_dto()
}

#[flutter_rust_bridge::frb(sync)]
pub fn setup_next_step() -> Result<SetupStateDto, String> {
    let mut b = bridge().lock().unwrap();
    b.setup.validate_step()?;
    if b.setup.step < TOTAL_STEPS {
        b.setup.step += 1;
    }
    Ok(b.setup_state_dto())
}

#[flutter_rust_bridge::frb(sync)]
pub fn setup_prev_step() -> SetupStateDto {
    let mut b = bridge().lock().unwrap();
    if b.setup.step > 1 {
        b.setup.step -= 1;
    }
    b.setup_state_dto()
}

#[flutter_rust_bridge::frb]
pub async fn setup_finalize() -> Result<(), String> {
    let (agent_ip, payload, core) = {
        let b = bridge().lock().unwrap();
        let agent = b.agent.clone().ok_or("No agent.")?;
        (
            agent.ip,
            b.setup.to_finalize_payload(),
            b.core.clone(),
        )
    };

    finalize_setup(&core, &agent_ip, payload).await?;
    let mut b = bridge().lock().unwrap();
    if let Some(a) = b.agent.as_mut() {
        a.is_setup = true;
    }
    b.setup = SetupForm::new();
    Ok(())
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_places() -> Vec<PlaceDto> {
    load_places().into_iter().map(Into::into).collect()
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_mounts() -> Vec<MountEntryDto> {
    list_mounts().into_iter().map(Into::into).collect()
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_trash_path() -> Option<String> {
    #[cfg(target_os = "linux")]
    {
        let home = default_home();
        if home.is_empty() { return None; }
        let base = home.trim_end_matches('/');
        Some(format!("{base}/.local/share/Trash/files"))
    }
    #[cfg(target_os = "macos")]
    {
        let home = default_home();
        if home.is_empty() { return None; }
        let base = home.trim_end_matches('/');
        Some(format!("{base}/.Trash"))
    }
    #[cfg(target_os = "windows")]
    {
        // Each drive's Recycle Bin is at <drive>\$Recycle.Bin\<user-SID>\
        // Find the first subfolder inside C:\$Recycle.Bin that we can read —
        // that's the current user's bin.
        let sys_drive = std::env::var("SYSTEMDRIVE").unwrap_or_else(|_| "C:".to_string());
        let base = format!("{}\\$Recycle.Bin", sys_drive);
        if let Ok(entries) = std::fs::read_dir(&base) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.is_dir() && std::fs::read_dir(&path).is_ok() {
                    return Some(path.to_string_lossy().to_string());
                }
            }
        }
        None
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
    {
        None
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_view_mode() -> String {
    bridge().lock().unwrap().view_mode.clone()
}

#[flutter_rust_bridge::frb(sync)]
pub fn set_view_mode(mode: String) -> String {
    let mut b = bridge().lock().unwrap();
    b.view_mode = mode;
    b.view_mode.clone()
}

#[flutter_rust_bridge::frb]
pub fn stream_local_files(sink: StreamSink<FileStreamEvent>) -> anyhow::Result<()> {
    crate::file_stream::stream_local_files(sink)
}

#[flutter_rust_bridge::frb]
pub fn stream_nas_files(sink: StreamSink<FileStreamEvent>, parent_id: Option<i64>) -> anyhow::Result<()> {
    crate::file_stream::stream_nas_files(sink, parent_id)
}

#[flutter_rust_bridge::frb]
pub fn stream_nas_search(sink: StreamSink<FileStreamEvent>, query: String) -> anyhow::Result<()> {
    crate::file_stream::stream_nas_search(sink, query)
}

#[flutter_rust_bridge::frb]
pub fn stream_demo_files(sink: StreamSink<FileStreamEvent>) -> anyhow::Result<()> {
    crate::file_stream::stream_demo_files(sink)
}

#[flutter_rust_bridge::frb(sync)]
pub fn local_navigate(path: String) -> FileListMetaDto {
    let mut b = bridge().lock().unwrap();
    b.local.navigate(path);
    b.file_list_meta()
}

#[flutter_rust_bridge::frb(sync)]
pub fn local_back() -> FileListMetaDto {
    let mut b = bridge().lock().unwrap();
    b.local.back();
    b.file_list_meta()
}

#[flutter_rust_bridge::frb(sync)]
pub fn local_forward() -> FileListMetaDto {
    let mut b = bridge().lock().unwrap();
    b.local.forward();
    b.file_list_meta()
}

#[flutter_rust_bridge::frb(sync)]
pub fn local_home() -> FileListMetaDto {
    let mut b = bridge().lock().unwrap();
    b.local.home();
    b.file_list_meta()
}

#[flutter_rust_bridge::frb(sync)]
pub fn local_toggle_hidden() -> FileListMetaDto {
    let mut b = bridge().lock().unwrap();
    b.local.show_hidden = !b.local.show_hidden;
    b.file_list_meta()
}

#[flutter_rust_bridge::frb(sync)]
pub fn open_place(path: String) -> FileListMetaDto {
    let mut b = bridge().lock().unwrap();
    b.local.navigate(path);
    b.view_mode = "local".into();
    b.file_list_meta()
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_session_info() -> Option<SessionDto> {
    let b = bridge().lock().unwrap();
    b.session.as_ref().map(|s| SessionDto {
        username: s.username.clone().unwrap_or_else(|| "User".into()),
        role: s.role.clone().unwrap_or_else(|| "user".into()),
        is_admin: s.role.as_deref() == Some("admin"),
    })
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_current_agent() -> Option<AgentInfoDto> {
    bridge().lock().unwrap().agent.clone().map(Into::into)
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_session_auth() -> Option<SessionAuthDto> {
    bridge()
        .lock()
        .unwrap()
        .session
        .clone()
        .map(SessionAuthDto::from)
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_local_current_path() -> String {
    bridge().lock().unwrap().local.current_path.clone()
}

#[flutter_rust_bridge::frb]
pub async fn agent_secure_fetch(
    url: String,
    method: String,
    body: Option<String>,
    token: Option<String>,
    mac_key: Option<String>,
) -> Result<FetchResponseDto, String> {
    let core = bridge().lock().unwrap().core.clone();
    let res = secure_fetch(&core, url, method, body, token, mac_key).await?;
    Ok(res.into())
}

#[flutter_rust_bridge::frb]
pub fn stream_sse_events(
    sink: StreamSink<String>,
    listener_id: String,
    url: String,
    token: Option<String>,
    mac_key: Option<String>,
) -> anyhow::Result<()> {
    crate::sse_stream::stream_sse_events(sink, listener_id, url, token, mac_key)
}

#[flutter_rust_bridge::frb]
pub async fn stop_sse(agent: Option<String>) -> Result<(), String> {
    let core = bridge().lock().unwrap().core.clone();
    crate::core::stop_sse(&core, agent).await
}

#[flutter_rust_bridge::frb]
pub async fn demo_start_index(path: String) -> Result<(), String> {
    let (agent_ip, core) = {
        let b = bridge().lock().unwrap();
        let agent = b.agent.clone().ok_or("No agent.")?;
        (agent.ip, b.core.clone())
    };

    let body = serde_json::json!({ "path": path.trim() }).to_string();
    let res = agent_fetch(
        &core,
        &agent_ip,
        "/api/demo/index",
        "POST",
        Some(body),
        None,
        None,
    )
    .await?;
    if res.status == 200 {
        Ok(())
    } else {
        Err(agent_error_message(
            &res.body,
            "Demo agent rejected that folder.",
        ))
    }
}

