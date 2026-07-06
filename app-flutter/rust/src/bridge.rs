use crate::agent_api::{
    agent_fetch, finalize_setup, transport_error, AgentApi, AgentInfo, SessionData,
};
use crate::core::{
    delete_pinned_fingerprint, discover_agents, get_pinned_fingerprint, init_app_state,
    load_app_settings, probe_agent_fingerprint, save_app_settings, set_pinned_fingerprint,
    AppState, DatieveAppSettings, DiscoveredAgent,
};
use crate::file_manager::{
    browse_nas, list_local, load_places, nas_to_rows, search_nas, FileRow, PlaceItem,
};
use crate::fm_state::{LocalNavState, NasNavState};
use crate::session::{
    clear_session, load_accounts, load_saved_session, persist_session, save_account,
    save_accounts, StoredAccount,
};
use crate::setup_state::{SetupForm, STEP_DESCS, STEP_TITLES, TOTAL_STEPS};
use once_cell::sync::OnceCell;
use std::sync::{Arc, Mutex};

static BRIDGE: OnceCell<Mutex<DatieveBridge>> = OnceCell::new();

pub fn bridge() -> &'static Mutex<DatieveBridge> {
    BRIDGE.get_or_init(|| Mutex::new(DatieveBridge::new().expect("init bridge")))
}

pub struct DatieveBridge {
    pub core: Arc<AppState>,
    pub settings: DatieveAppSettings,
    pub agent: Option<AgentInfo>,
    pub session: Option<SessionData>,
    pub setup: SetupForm,
    pub local: LocalNavState,
    pub nas: NasNavState,
    pub view_mode: String,
}

impl DatieveBridge {
    fn new() -> Result<Self, String> {
        let settings = load_app_settings().unwrap_or_default();
        Ok(Self {
            core: Arc::new(init_app_state()),
            settings,
            agent: None,
            session: None,
            setup: SetupForm::new(),
            local: LocalNavState::new(),
            nas: NasNavState::default(),
            view_mode: "local".into(),
        })
    }

    pub fn api(&self) -> AgentApi {
        AgentApi::new(self.core.clone())
    }

    pub fn agent_row(agent: &DiscoveredAgent) -> AgentItemDto {
        let (status_label, status_kind) = if agent.demo || agent.mode.as_deref() == Some("demo") {
            ("Demo".into(), "demo".into())
        } else if agent.is_setup {
            ("Online".into(), "online".into())
        } else {
            ("Needs Setup".into(), "setup".into())
        };
        AgentItemDto {
            ip: agent.ip.clone(),
            hostname: agent.hostname.clone(),
            status_label,
            status_kind,
            connecting: false,
            fingerprint: agent.fingerprint.clone(),
        }
    }

    pub async fn ensure_pinned(
        _core: &Arc<AppState>,
        ip: &str,
        advertised_fingerprint: Option<&str>,
    ) -> Result<(), String> {
        let endpoint = crate::agent_api::normalize_agent_ip(ip);
        if get_pinned_fingerprint(endpoint.clone())?.is_some() {
            return Ok(());
        }

        let probed = probe_agent_fingerprint(endpoint.clone()).await.ok();
        let probed_fp = probed
            .as_deref()
            .and_then(crate::agent_api::normalize_fingerprint);

        let advertised_fp = advertised_fingerprint
            .and_then(crate::agent_api::normalize_fingerprint);

        if let (Some(adv), Some(probe)) = (&advertised_fp, &probed_fp) {
            if adv != probe {
                return Err(
                    "Agent discovery fingerprint does not match the TLS certificate.".into(),
                );
            }
        }

        let fp = advertised_fp
            .or(probed_fp)
            .ok_or_else(|| "Could not read the agent certificate fingerprint.".to_string())?;

        set_pinned_fingerprint(endpoint, fp)?;
        Ok(())
    }

    pub async fn route_after_agent(
        core: &Arc<AppState>,
        agent: AgentInfo,
        existing_session: Option<SessionData>,
        skip_auto_code_login: bool,
    ) -> RouteDecision {
        if agent.demo || agent.mode.as_deref() == Some("demo") {
            return RouteDecision {
                screen: "demo".into(),
                login_accounts: vec![],
                session: None,
                needs_setup_reset: false,
            };
        }
        if !agent.is_setup {
            return RouteDecision {
                screen: "setup".into(),
                login_accounts: vec![],
                session: None,
                needs_setup_reset: true,
            };
        }
        // Always load accounts — Dart needs them to show the account chooser after logout.
        let accounts = load_accounts(&agent.ip);
        let account_dtos: Vec<_> = accounts.iter().cloned().map(Into::into).collect();
        if let Some(sess) = existing_session {
            return RouteDecision {
                screen: "file-manager".into(),
                login_accounts: account_dtos,
                session: Some(sess),
                needs_setup_reset: false,
            };
        }
        if let Some(saved) = load_saved_session(&agent.ip) {
            if crate::agent_api::validate_session(
                core,
                &agent.ip,
                &saved.token,
                saved.mac_key.as_deref(),
            )
            .await
            .is_ok()
            {
                return RouteDecision {
                    screen: "file-manager".into(),
                    login_accounts: account_dtos,
                    session: Some(saved),
                    needs_setup_reset: false,
                };
            }
            let _ = clear_session(&agent.ip);
        }
        // After an explicit logout the caller sets skip_auto_code_login so the user
        // sees the account chooser instead of being silently re-authenticated.
        if skip_auto_code_login {
            return RouteDecision {
                screen: "login".into(),
                login_accounts: account_dtos,
                session: None,
                needs_setup_reset: false,
            };
        }
        // Token is missing or expired — try to silently re-login with any stored code.
        let mut accounts = accounts;
        let api = crate::agent_api::AgentApi::new(core.clone());
        let mut i = 0;
        while i < accounts.len() {
            match api.login(&agent.ip, &accounts[i].code).await {
                Ok(new_sess) => {
                    let _ = persist_session(&agent.ip, &new_sess);
                    let dtos: Vec<_> = accounts.iter().cloned().map(Into::into).collect();
                    return RouteDecision {
                        screen: "file-manager".into(),
                        login_accounts: dtos,
                        session: Some(new_sess),
                        needs_setup_reset: false,
                    };
                }
                Err(_) => {
                    // Code rejected — remove it so the user isn't shown a stale account.
                    accounts.remove(i);
                    let _ = crate::session::save_accounts(&agent.ip, &accounts);
                }
            }
            i += 1;
        }
        RouteDecision {
            screen: "login".into(),
            login_accounts: accounts.into_iter().map(Into::into).collect(),
            session: None,
            needs_setup_reset: false,
        }
    }

    pub fn file_list_local(&self) -> FileListResult {
        let path = self.local.current_path.clone();
        let hidden = self.local.show_hidden;
        match list_local(&path, hidden) {
            Ok(rows) => {
                let count = rows.len();
                FileListResult {
                    files: rows.into_iter().map(Into::into).collect(),
                    current_path: path,
                    can_back: self.local.can_back(),
                    can_forward: self.local.can_forward(),
                    show_hidden: hidden,
                    error: None,
                    status: format!("{count} items"),
                }
            }
            Err(e) => FileListResult {
                files: vec![],
                current_path: path,
                can_back: self.local.can_back(),
                can_forward: self.local.can_forward(),
                show_hidden: hidden,
                error: Some(e),
                status: String::new(),
            },
        }
    }

    pub fn file_list_nas(&mut self, parent_id: Option<i64>) -> FileListResult {
        let agent = match self.agent.clone() {
            Some(a) => a,
            None => {
                return FileListResult {
                    files: vec![],
                    current_path: String::new(),
                    can_back: false,
                    can_forward: false,
                    show_hidden: false,
                    error: Some("No agent connected.".into()),
                    status: String::new(),
                }
            }
        };
        let session = match self.session.clone() {
            Some(s) => s,
            None => {
                return FileListResult {
                    files: vec![],
                    current_path: String::new(),
                    can_back: false,
                    can_forward: false,
                    show_hidden: false,
                    error: Some("login_required".into()),
                    status: String::new(),
                }
            }
        };
        self.nas.parent_id = parent_id;
        let api = self.api();
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("nas list runtime");
        let result = rt.block_on(browse_nas(&api, &agent.ip, &session, parent_id));
        match result {
            Ok(items) => {
                let rows = nas_to_rows(&items);
                let count = rows.len();
                FileListResult {
                    files: rows.into_iter().map(Into::into).collect(),
                    current_path: parent_id.map(|id| id.to_string()).unwrap_or_default(),
                    can_back: parent_id.is_some(),
                    can_forward: false,
                    show_hidden: false,
                    error: None,
                    status: format!("{count} items"),
                }
            }
            Err(e) => FileListResult {
                files: vec![],
                current_path: String::new(),
                can_back: false,
                can_forward: false,
                show_hidden: false,
                error: Some(e),
                status: String::new(),
            },
        }
    }

    pub fn setup_state_dto(&self) -> SetupStateDto {
        let idx = (self.setup.step - 1).clamp(0, TOTAL_STEPS - 1) as usize;
        SetupStateDto {
            step: self.setup.step,
            step_title: STEP_TITLES[idx].to_string(),
            step_desc: STEP_DESCS[idx].to_string(),
            friendly_name: self.setup.friendly_name.clone(),
            admin_username: self.setup.admin_username.clone(),
            admin_code: self.setup.admin_code.clone(),
            watched_paths: self.setup.watched_paths.clone(),
            exclude_hidden: self.setup.exclude_hidden,
            exclusion_patterns: self.setup.exclusion_patterns.clone(),
            users: self
                .setup
                .users
                .iter()
                .map(|u| SetupUserDto {
                    username: u.username.clone(),
                    code: u.code.clone(),
                    allowed_paths: u.allowed_paths.clone(),
                })
                .collect(),
            manage_username: self.setup.manage_username.clone(),
            manage_password: self.setup.manage_password.clone(),
            confirm_summary: self
                .agent
                .as_ref()
                .map(|a| self.setup.confirm_summary(&a.ip))
                .unwrap_or_default(),
        }
    }
}

// DTOs shared with Flutter via FRB
#[derive(Clone)]
pub struct AgentItemDto {
    pub ip: String,
    pub hostname: String,
    pub status_label: String,
    pub status_kind: String,
    pub connecting: bool,
    pub fingerprint: Option<String>,
}

#[derive(Clone)]
pub struct AgentInfoDto {
    pub ip: String,
    pub hostname: String,
    pub is_setup: bool,
    pub demo: bool,
}

impl From<AgentInfo> for AgentInfoDto {
    fn from(a: AgentInfo) -> Self {
        Self {
            ip: a.ip,
            hostname: a.hostname,
            is_setup: a.is_setup,
            demo: a.demo,
        }
    }
}

#[derive(Clone)]
pub struct AccountDto {
    pub username: String,
    pub role: String,
    pub code: String,
}

impl From<StoredAccount> for AccountDto {
    fn from(a: StoredAccount) -> Self {
        Self {
            username: a.username,
            role: a.role,
            code: a.code,
        }
    }
}

#[derive(Clone)]
pub struct FileItemDto {
    pub name: String,
    pub path: String,
    pub detail: String,
    pub is_dir: bool,
    pub is_symlink: bool,
    pub size: u64,
    pub modified_secs: u64,
    pub created_secs: u64,
    pub accessed_secs: u64,
    pub is_hidden: bool,
    pub file_ext: Option<String>,
    pub item_type: String,
    pub parent_path: String,
}

impl From<FileRow> for FileItemDto {
    fn from(r: FileRow) -> Self {
        Self {
            name: r.name,
            path: r.path,
            detail: r.detail,
            is_dir: r.is_dir,
            is_symlink: r.is_symlink,
            size: r.size,
            modified_secs: r.modified_secs,
            created_secs: r.created_secs,
            accessed_secs: r.accessed_secs,
            is_hidden: r.is_hidden,
            file_ext: r.file_ext,
            item_type: r.item_type,
            parent_path: r.parent_path,
        }
    }
}

#[derive(Clone)]
pub struct SearchEntryDto {
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

impl From<crate::core::SearchEntry> for SearchEntryDto {
    fn from(e: crate::core::SearchEntry) -> Self {
        Self {
            name: e.name,
            is_dir: e.is_dir,
            is_symlink: e.is_symlink,
            target_path: e.target_path,
            size: e.size,
            modified_secs: e.modified_secs,
            created_secs: e.created_secs,
            accessed_secs: e.accessed_secs,
            absolute_path: e.absolute_path,
            is_hidden: e.is_hidden,
            file_ext: e.file_ext,
            item_type: e.item_type,
            parent_path: e.parent_path,
        }
    }
}

impl From<SearchEntryDto> for FileItemDto {
    fn from(e: SearchEntryDto) -> Self {
        let detail = if e.is_dir {
            if e.is_symlink {
                "Linked Folder".to_string()
            } else {
                "Folder".to_string()
            }
        } else {
            crate::file_manager::format_bytes(e.size)
        };
        Self {
            name: e.name,
            path: e.absolute_path,
            detail,
            is_dir: e.is_dir,
            is_symlink: e.is_symlink,
            size: e.size,
            modified_secs: e.modified_secs,
            created_secs: e.created_secs,
            accessed_secs: e.accessed_secs,
            is_hidden: e.is_hidden,
            file_ext: e.file_ext,
            item_type: e.item_type,
            parent_path: e.parent_path,
        }
    }
}

#[derive(Clone)]
pub struct AppInfoDto {
    pub id: String,
    pub name: String,
    pub icon: String,
}

impl From<crate::core::AppInfo> for AppInfoDto {
    fn from(a: crate::core::AppInfo) -> Self {
        Self {
            id: a.id,
            name: a.name,
            icon: a.icon,
        }
    }
}

#[derive(Clone)]
pub struct PlaceDto {
    pub label: String,
    pub path: String,
}

impl From<PlaceItem> for PlaceDto {
    fn from(p: PlaceItem) -> Self {
        Self {
            label: p.label,
            path: p.path,
        }
    }
}

#[derive(Clone)]
pub struct MountEntryDto {
    pub label: String,
    pub path: String,
    pub fs_type: String,
    pub total_bytes: u64,
    pub used_bytes: u64,
    pub available_bytes: u64,
}

impl From<crate::core::MountEntry> for MountEntryDto {
    fn from(m: crate::core::MountEntry) -> Self {
        Self {
            label: m.label,
            path: m.path,
            fs_type: m.fs_type,
            total_bytes: m.total_bytes,
            used_bytes: m.used_bytes,
            available_bytes: m.available_bytes,
        }
    }
}

#[derive(Clone)]
pub struct AppSettingsDto {
    pub theme: String,
    pub scan_port: u16,
    pub sidebar_width: u32,
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
    pub nas_page_size: u32,
    pub ui_scale: f32,
    pub show_info_pane: bool,
    pub info_pane_tab: String,
    pub restore_tabs_on_startup: bool,
    pub toolbar_show_view_toggle: bool,
    pub toolbar_show_hidden_toggle: bool,
    pub toolbar_show_filters: bool,
}

impl From<DatieveAppSettings> for AppSettingsDto {
    fn from(s: DatieveAppSettings) -> Self {
        Self {
            theme: s.theme,
            scan_port: s.scan_port,
            sidebar_width: s.sidebar_width as u32,
            local_view_style: s.local_view_style,
            sort_by: s.sort_by,
            sort_dir: s.sort_dir,
            group_by: s.group_by,
            folders_first: s.folders_first,
            show_hidden: s.show_hidden,
            show_extensions: s.show_extensions,
            show_thumbnails: s.show_thumbnails,
            size_unit: s.size_unit,
            calculate_folder_sizes: s.calculate_folder_sizes,
            single_click_open: s.single_click_open,
            select_on_hover: s.select_on_hover,
            double_click_blank_go_up: s.double_click_blank_go_up,
            scroll_to_previous_folder_on_up: s.scroll_to_previous_folder_on_up,
            confirm_trash: s.confirm_trash,
            confirm_permanent_delete: s.confirm_permanent_delete,
            warn_extension_rename: s.warn_extension_rename,
            default_terminal: s.default_terminal,
            context_open_terminal: s.context_open_terminal,
            context_copy_path: s.context_copy_path,
            context_archive: s.context_archive,
            context_symlink: s.context_symlink,
            context_pin_sidebar: s.context_pin_sidebar,
            nas_lazy_loading: s.nas_lazy_loading,
            nas_page_size: s.nas_page_size as u32,
            ui_scale: s.ui_scale,
            show_info_pane: s.show_info_pane,
            info_pane_tab: s.info_pane_tab,
            restore_tabs_on_startup: s.restore_tabs_on_startup,
            toolbar_show_view_toggle: s.toolbar_show_view_toggle,
            toolbar_show_hidden_toggle: s.toolbar_show_hidden_toggle,
            toolbar_show_filters: s.toolbar_show_filters,
        }
    }
}

impl From<AppSettingsDto> for DatieveAppSettings {
    fn from(d: AppSettingsDto) -> Self {
        Self {
            version: 1,
            theme: d.theme,
            scan_port: d.scan_port,
            sidebar_width: d.sidebar_width.clamp(160, 360) as u16,
            local_view_style: d.local_view_style,
            sort_by: d.sort_by,
            sort_dir: d.sort_dir,
            group_by: d.group_by,
            folders_first: d.folders_first,
            show_hidden: d.show_hidden,
            show_extensions: d.show_extensions,
            show_thumbnails: d.show_thumbnails,
            size_unit: d.size_unit,
            calculate_folder_sizes: d.calculate_folder_sizes,
            single_click_open: d.single_click_open,
            select_on_hover: d.select_on_hover,
            double_click_blank_go_up: d.double_click_blank_go_up,
            scroll_to_previous_folder_on_up: d.scroll_to_previous_folder_on_up,
            confirm_trash: d.confirm_trash,
            confirm_permanent_delete: d.confirm_permanent_delete,
            warn_extension_rename: d.warn_extension_rename,
            default_terminal: d.default_terminal,
            context_open_terminal: d.context_open_terminal,
            context_copy_path: d.context_copy_path,
            context_archive: d.context_archive,
            context_symlink: d.context_symlink,
            context_pin_sidebar: d.context_pin_sidebar,
            nas_lazy_loading: d.nas_lazy_loading,
            nas_page_size: d.nas_page_size.clamp(50, 5000) as u16,
            ui_scale: d.ui_scale.clamp(0.5, 2.0),
            show_info_pane: d.show_info_pane,
            info_pane_tab: d.info_pane_tab,
            restore_tabs_on_startup: d.restore_tabs_on_startup,
            toolbar_show_view_toggle: d.toolbar_show_view_toggle,
            toolbar_show_hidden_toggle: d.toolbar_show_hidden_toggle,
            toolbar_show_filters: d.toolbar_show_filters,
        }
    }
}

#[derive(Clone)]
pub struct RouteDecision {
    pub screen: String,
    pub login_accounts: Vec<AccountDto>,
    pub session: Option<SessionData>,
    pub needs_setup_reset: bool,
}

pub struct ConnectResult {
    pub screen: String,
    pub agent: Option<AgentInfoDto>,
    pub login_accounts: Vec<AccountDto>,
    pub error: Option<String>,
}

#[derive(Clone)]
pub struct FileListMetaDto {
    pub current_path: String,
    pub can_back: bool,
    pub can_forward: bool,
    pub show_hidden: bool,
    pub status: String,
}

impl DatieveBridge {
    pub fn file_list_meta(&self) -> FileListMetaDto {
        FileListMetaDto {
            current_path: self.local.current_path.clone(),
            can_back: self.local.can_back(),
            can_forward: self.local.can_forward(),
            show_hidden: self.local.show_hidden,
            status: String::new(),
        }
    }

    pub fn nas_meta(&self, parent_id: Option<i64>) -> FileListMetaDto {
        FileListMetaDto {
            current_path: parent_id.map(|id| id.to_string()).unwrap_or_default(),
            can_back: parent_id.is_some(),
            can_forward: false,
            show_hidden: false,
            status: String::new(),
        }
    }
}

#[derive(Clone)]
pub struct FileStreamEvent {
    pub event_type: String,
    pub item: Option<FileItemDto>,
    pub meta: Option<FileListMetaDto>,
    pub message: Option<String>,
}

#[derive(Clone)]
pub struct FileListResult {
    pub files: Vec<FileItemDto>,
    pub current_path: String,
    pub can_back: bool,
    pub can_forward: bool,
    pub show_hidden: bool,
    pub error: Option<String>,
    pub status: String,
}

#[derive(Clone)]
pub struct SetupUserDto {
    pub username: String,
    pub code: String,
    pub allowed_paths: Vec<String>,
}

#[derive(Clone)]
pub struct SetupStateDto {
    pub step: i32,
    pub step_title: String,
    pub step_desc: String,
    pub friendly_name: String,
    pub admin_username: String,
    pub admin_code: String,
    pub watched_paths: Vec<String>,
    pub exclude_hidden: bool,
    pub exclusion_patterns: Vec<String>,
    pub users: Vec<SetupUserDto>,
    pub manage_username: String,
    pub manage_password: String,
    pub confirm_summary: String,
}

#[derive(Clone)]
pub struct SessionDto {
    pub username: String,
    pub role: String,
    pub is_admin: bool,
}

#[derive(Clone)]
pub struct SessionAuthDto {
    pub token: String,
    pub mac_key: Option<String>,
}

impl From<SessionData> for SessionAuthDto {
    fn from(s: SessionData) -> Self {
        Self {
            token: s.token,
            mac_key: s.mac_key,
        }
    }
}

#[derive(Clone)]
pub struct FilePropertiesDto {
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

impl From<crate::core::FileProperties> for FilePropertiesDto {
    fn from(p: crate::core::FileProperties) -> Self {
        Self {
            name: p.name,
            absolute_path: p.absolute_path,
            is_dir: p.is_dir,
            is_symlink: p.is_symlink,
            symlink_target: p.symlink_target,
            size: p.size,
            modified_secs: p.modified_secs,
            created_secs: p.created_secs,
            accessed_secs: p.accessed_secs,
            permissions: p.permissions,
            mime_type: p.mime_type,
        }
    }
}

#[derive(Clone)]
pub struct FileHashesDto {
    pub md5: String,
    pub sha1: String,
    pub sha256: String,
    pub crc32: String,
}

impl From<crate::core::FileHashes> for FileHashesDto {
    fn from(h: crate::core::FileHashes) -> Self {
        Self {
            md5: h.md5,
            sha1: h.sha1,
            sha256: h.sha256,
            crc32: h.crc32,
        }
    }
}

#[derive(Clone)]
pub struct VolumeInfoDto {
    pub mount_path: String,
    pub device: String,
    pub fs_type: String,
    pub total_bytes: u64,
    pub used_bytes: u64,
    pub available_bytes: u64,
}

impl From<crate::core::VolumeInfo> for VolumeInfoDto {
    fn from(v: crate::core::VolumeInfo) -> Self {
        Self {
            mount_path: v.mount_path,
            device: v.device,
            fs_type: v.fs_type,
            total_bytes: v.total_bytes,
            used_bytes: v.used_bytes,
            available_bytes: v.available_bytes,
        }
    }
}

#[derive(Clone)]
pub struct FolderSummaryDto {
    pub total_size: u64,
    pub file_count: u64,
    pub folder_count: u64,
    pub truncated: bool,
}

impl From<crate::core::FolderSummary> for FolderSummaryDto {
    fn from(s: crate::core::FolderSummary) -> Self {
        Self {
            total_size: s.total_size,
            file_count: s.file_count,
            folder_count: s.folder_count,
            truncated: s.truncated,
        }
    }
}

#[derive(Clone)]
pub struct FetchResponseDto {
    pub status: u16,
    pub body: String,
}

impl From<crate::core::FetchResponse> for FetchResponseDto {
    fn from(r: crate::core::FetchResponse) -> Self {
        Self {
            status: r.status,
            body: r.body,
        }
    }
}

#[derive(Clone)]
pub struct DemoStatusDto {
    pub status_line: String,
    pub files: Vec<FileItemDto>,
    pub error: Option<String>,
}