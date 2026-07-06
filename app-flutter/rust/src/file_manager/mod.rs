use crate::agent_api::{agent_error_message, agent_fetch, AgentApi, SessionData};
use crate::core::{get_user_dirs, list_local_dir, list_local_dir_stream, list_mounts, LocalEntry};
use serde::Deserialize;
use std::path::Path;

fn parse_iso_secs(s: &str) -> u64 {
    chrono::DateTime::parse_from_rfc3339(s)
        .map(|dt| dt.timestamp().max(0) as u64)
        .unwrap_or(0)
}

pub use local::format_bytes;

mod local;

#[derive(Clone, Debug, Default)]
pub struct FileRow {
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

impl From<&LocalEntry> for FileRow {
    fn from(e: &LocalEntry) -> Self {
        let detail = if e.is_dir {
            if e.is_symlink {
                "Linked Folder".to_string()
            } else {
                "Folder".to_string()
            }
        } else {
            format_bytes(e.size)
        };
        let parent_path = std::path::Path::new(&e.absolute_path)
            .parent()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_else(|| "/".into());
        Self {
            name: e.name.clone(),
            path: e.absolute_path.clone(),
            detail,
            is_dir: e.is_dir,
            is_symlink: e.is_symlink,
            size: e.size,
            modified_secs: e.modified_secs,
            created_secs: e.created_secs,
            accessed_secs: e.accessed_secs,
            is_hidden: e.is_hidden,
            file_ext: e.file_ext.clone(),
            item_type: e.item_type.clone(),
            parent_path,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct BrowseItems {
    pub folders: Vec<NasFolder>,
    pub files: Vec<NasFile>,
    #[serde(default)]
    pub current_absolute_path: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct NasFolder {
    pub id: i64,
    pub name: String,
    #[serde(default)]
    pub file_count: i64,
    #[serde(default)]
    pub absolute_path: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct NasFile {
    pub id: i64,
    pub name: String,
    #[serde(default)]
    pub size_bytes: u64,
    #[serde(default)]
    pub is_symlink: bool,
    #[serde(default)]
    pub modified_at: Option<String>,
    #[serde(default)]
    pub absolute_path: String,
}

#[derive(Debug, Clone)]
pub struct PlaceItem {
    pub label: String,
    pub path: String,
}

pub fn default_home() -> String {
    get_user_dirs()
        .get("home")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .unwrap_or_else(|| "/".into())
}

pub fn load_places() -> Vec<PlaceItem> {
    let dirs = get_user_dirs();
    let mut out = Vec::new();
    for key in [
        ("home", "Home"),
        ("desktop", "Desktop"),
        ("documents", "Documents"),
        ("downloads", "Downloads"),
        ("music", "Music"),
        ("pictures", "Pictures"),
        ("videos", "Videos"),
    ] {
        if let Some(p) = dirs.get(key.0).and_then(|v| v.as_str()) {
            if !p.is_empty() {
                out.push(PlaceItem {
                    label: key.1.to_string(),
                    path: p.to_string(),
                });
            }
        }
    }
    out
}

pub fn list_local(path: &str, show_hidden: bool) -> Result<Vec<FileRow>, String> {
    let entries = list_local_dir(path.to_string())?;
    Ok(entries
        .iter()
        .filter(|e| show_hidden || !e.is_hidden)
        .map(FileRow::from)
        .collect())
}

/// Streaming variant of [`list_local`] — invokes `on_row` per entry as it is
/// discovered, in filesystem order (not sorted). Used by the directory
/// listing stream so large folders render progressively instead of stalling
/// until the whole directory has been scanned.
pub fn list_local_stream(
    path: &str,
    show_hidden: bool,
    mut on_row: impl FnMut(FileRow),
) -> Result<(), String> {
    list_local_dir_stream(path.to_string(), |e| {
        if show_hidden || !e.is_hidden {
            on_row(FileRow::from(&e));
        }
    })
}

pub fn parent_path(path: &str) -> Option<String> {
    let p = Path::new(path);
    p.parent().map(|parent| parent.to_string_lossy().to_string())
}

pub async fn browse_nas(
    api: &AgentApi,
    ip: &str,
    session: &SessionData,
    parent_id: Option<i64>,
) -> Result<BrowseItems, String> {
    let path = match parent_id {
        Some(id) => format!("/api/browse?parent_id={id}"),
        None => "/api/browse".into(),
    };
    let res = agent_fetch(
        &api.state,
        ip,
        &path,
        "GET",
        None,
        Some(session.token.clone()),
        session.mac_key.clone(),
    )
    .await?;
    if res.status == 200 {
        serde_json::from_str(&res.body).map_err(|e| e.to_string())
    } else {
        Err(agent_error_message(&res.body, "Could not browse NAS."))
    }
}

pub fn nas_to_rows(items: &BrowseItems) -> Vec<FileRow> {
    let mut rows = Vec::new();
    for f in &items.folders {
        rows.push(FileRow {
            name: f.name.clone(),
            path: f.absolute_path.clone(),
            parent_path: f.id.to_string(),
            detail: format!("{} files", f.file_count),
            is_dir: true,
            is_symlink: false,
            size: 0,
            item_type: "Folder".into(),
            ..Default::default()
        });
    }
    for f in &items.files {
        let ext = std::path::Path::new(&f.name)
            .extension()
            .and_then(|s| s.to_str())
            .filter(|s| !s.is_empty())
            .map(|s| s.to_ascii_lowercase());
        rows.push(FileRow {
            name: f.name.clone(),
            path: f.absolute_path.clone(),
            parent_path: f.id.to_string(),
            detail: if f.is_symlink {
                "Symlink".to_string()
            } else {
                format_bytes(f.size_bytes)
            },
            is_dir: false,
            is_symlink: f.is_symlink,
            size: f.size_bytes,
            file_ext: ext,
            item_type: if f.is_symlink {
                "Shortcut".into()
            } else {
                "File".into()
            },
            ..Default::default()
        });
    }
    rows
}

pub async fn search_nas(
    api: &AgentApi,
    ip: &str,
    session: &SessionData,
    query: &str,
) -> Result<Vec<FileRow>, String> {
    let path = format!("/api/search?q={}", urlencoding_encode(query));
    let res = agent_fetch(
        &api.state,
        ip,
        &path,
        "GET",
        None,
        Some(session.token.clone()),
        session.mac_key.clone(),
    )
    .await?;
    if res.status == 200 {
        let files: Vec<NasFile> = serde_json::from_str(&res.body).map_err(|e| e.to_string())?;
        Ok(files
            .into_iter()
            .map(|f| {
                let ext = std::path::Path::new(&f.name)
                    .extension()
                    .and_then(|s| s.to_str())
                    .filter(|s| !s.is_empty())
                    .map(|s| s.to_ascii_lowercase());
                let parent_dir = Path::new(&f.absolute_path)
                    .parent()
                    .and_then(|p| p.to_str())
                    .unwrap_or("")
                    .to_string();
                let modified = f.modified_at.as_deref().map(parse_iso_secs).unwrap_or(0);
                FileRow {
                    name: f.name,
                    path: f.absolute_path.clone(),
                    parent_path: f.id.to_string(),
                    detail: parent_dir,
                    is_dir: false,
                    is_symlink: f.is_symlink,
                    size: f.size_bytes,
                    modified_secs: modified,
                    file_ext: ext,
                    item_type: if f.is_symlink {
                        "Shortcut".into()
                    } else {
                        "File".into()
                    },
                    ..Default::default()
                }
            })
            .collect())
    } else {
        Err(agent_error_message(&res.body, "Could not search NAS."))
    }
}

fn urlencoding_encode(s: &str) -> String {
    url::form_urlencoded::byte_serialize(s.as_bytes()).collect()
}