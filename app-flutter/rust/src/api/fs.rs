use crate::bridge::{
    AppInfoDto, FileHashesDto, FilePropertiesDto, FolderSummaryDto, SearchEntryDto, VolumeInfoDto,
};
use crate::core;

pub struct FsBatchError {
    pub path: String,
    pub error: String,
}

pub struct FsBatchResult {
    pub succeeded: Vec<String>,
    pub failed: Vec<FsBatchError>,
}

fn collect_batch(results: Vec<(String, Result<(), String>)>) -> FsBatchResult {
    let mut succeeded = Vec::new();
    let mut failed = Vec::new();
    for (path, result) in results {
        match result {
            Ok(()) => succeeded.push(path),
            Err(e) => failed.push(FsBatchError { path, error: e }),
        }
    }
    FsBatchResult { succeeded, failed }
}

#[flutter_rust_bridge::frb(sync)]
pub fn fs_create_dir(path: String) -> Result<(), String> {
    core::fs_create_dir(path)
}

#[flutter_rust_bridge::frb(sync)]
pub fn fs_create_file(dir: String, name: String) -> Result<String, String> {
    core::fs_create_file(dir, name)
}

#[flutter_rust_bridge::frb(sync)]
pub fn fs_create_text_file(dir: String, name: String, content: String) -> Result<String, String> {
    core::fs_create_text_file(dir, name, content)
}

#[flutter_rust_bridge::frb(sync)]
pub fn fs_rename(old_path: String, new_name: String) -> Result<String, String> {
    core::fs_rename(old_path, new_name)
}

#[flutter_rust_bridge::frb(sync)]
pub fn fs_bulk_rename(paths: Vec<String>, base_name: String) -> Result<Vec<String>, String> {
    core::fs_bulk_rename(paths, base_name)
}

#[flutter_rust_bridge::frb]
pub async fn fs_trash(paths: Vec<String>) -> Result<FsBatchResult, String> {
    match tokio::task::spawn_blocking(move || -> Result<FsBatchResult, String> {
        Ok(collect_batch(core::fs_trash(paths)))
    }).await {
        Ok(r) => r,
        Err(e) => Err(e.to_string()),
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn fs_restore_trash(paths: Vec<String>) -> Result<(), String> {
    core::fs_restore_trash(paths)
}

#[flutter_rust_bridge::frb(sync)]
pub fn fs_empty_trash() -> Result<(), String> {
    core::fs_empty_trash()
}

#[flutter_rust_bridge::frb]
pub async fn fs_delete_permanent(paths: Vec<String>) -> Result<FsBatchResult, String> {
    match tokio::task::spawn_blocking(move || -> Result<FsBatchResult, String> {
        Ok(collect_batch(core::fs_delete_permanent(paths)))
    }).await {
        Ok(r) => r,
        Err(e) => Err(e.to_string()),
    }
}

#[flutter_rust_bridge::frb]
pub async fn fs_copy(
    src_paths: Vec<String>,
    dest_dir: String,
    collision: Option<String>,
) -> Result<FsBatchResult, String> {
    match tokio::task::spawn_blocking(move || -> Result<FsBatchResult, String> {
        core::fs_copy(src_paths, dest_dir, collision).map(collect_batch)
    }).await {
        Ok(r) => r,
        Err(e) => Err(e.to_string()),
    }
}

#[flutter_rust_bridge::frb]
pub async fn fs_move_paths(
    src_paths: Vec<String>,
    dest_dir: String,
    collision: Option<String>,
) -> Result<FsBatchResult, String> {
    match tokio::task::spawn_blocking(move || -> Result<FsBatchResult, String> {
        core::fs_move_paths(src_paths, dest_dir, collision).map(collect_batch)
    }).await {
        Ok(r) => r,
        Err(e) => Err(e.to_string()),
    }
}

#[flutter_rust_bridge::frb]
pub async fn fs_duplicate(paths: Vec<String>) -> Result<Vec<String>, String> {
    match tokio::task::spawn_blocking(move || -> Result<Vec<String>, String> {
        core::fs_duplicate(paths)
    }).await {
        Ok(r) => r,
        Err(e) => Err(e.to_string()),
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn fs_create_symlink(link_path: String, target: String) -> Result<(), String> {
    core::fs_create_symlink(link_path, target)
}

#[flutter_rust_bridge::frb(sync)]
pub fn fs_rotate_image(path: String, direction: String) -> Result<(), String> {
    core::fs_rotate_image(path, direction)
}

#[flutter_rust_bridge::frb(sync)]
pub fn fs_extract_to_subfolder(path: String) -> Result<(), String> {
    core::fs_extract_to_subfolder(path)
}

#[flutter_rust_bridge::frb]
pub async fn fs_extract_here(path: String) -> Result<(), String> {
    core::fs_extract_here(path).await
}

#[flutter_rust_bridge::frb]
pub async fn fs_compress(
    paths: Vec<String>,
    dest_dir: String,
    format: String,
) -> Result<(), String> {
    core::fs_compress(paths, dest_dir, format).await
}

#[flutter_rust_bridge::frb]
pub async fn open_file_native(path: String) -> Result<(), String> {
    core::open_file_native(path).await
}

#[flutter_rust_bridge::frb]
pub async fn open_in_terminal(
    path: String,
    terminal_override: Option<String>,
) -> Result<(), String> {
    core::open_in_terminal(path, terminal_override).await
}

#[flutter_rust_bridge::frb(sync)]
pub fn pick_folder() -> Result<Option<String>, String> {
    core::pick_folder()
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_file_properties(path: String) -> Result<FilePropertiesDto, String> {
    core::get_file_properties(path).map(Into::into)
}

#[flutter_rust_bridge::frb(sync)]
pub fn calculate_file_hashes(path: String) -> Result<FileHashesDto, String> {
    core::calculate_file_hashes(path).map(Into::into)
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_volume_info_for_path(path: String) -> Result<VolumeInfoDto, String> {
    core::get_volume_info_for_path(path).map(Into::into)
}

#[flutter_rust_bridge::frb(sync)]
pub fn calculate_folder_summary(path: String) -> Result<FolderSummaryDto, String> {
    core::calculate_folder_summary(path).map(Into::into)
}

#[flutter_rust_bridge::frb]
pub async fn read_image_thumbnail(path: String) -> Result<String, String> {
    tokio::task::spawn_blocking(move || core::read_image_thumbnail(path))
        .await
        .map_err(|e| e.to_string())?
}

#[flutter_rust_bridge::frb]
pub async fn fs_search_recursive(
    root: String,
    query: String,
    include_hidden: bool,
) -> Result<Vec<SearchEntryDto>, String> {
    match tokio::task::spawn_blocking(move || -> Result<Vec<SearchEntryDto>, String> {
        core::fs_search_recursive(root, query, include_hidden)
            .map(|rows| rows.into_iter().map(Into::into).collect())
    }).await {
        Ok(r) => r,
        Err(e) => Err(e.to_string()),
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn cancel_search() {
    core::cancel_search()
}

#[flutter_rust_bridge::frb(sync)]
pub fn fs_stat_paths(paths: Vec<String>) -> Result<Vec<SearchEntryDto>, String> {
    core::fs_stat_paths(paths)
        .map(|rows| rows.into_iter().map(Into::into).collect())
}

#[flutter_rust_bridge::frb(sync)]
pub fn read_text_preview(path: String) -> Result<String, String> {
    core::read_text_preview(path)
}

#[flutter_rust_bridge::frb(sync)]
pub fn read_local_bytes(path: String) -> Result<Vec<u8>, String> {
    core::read_local_bytes(path)
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_mime_type(path: String) -> String {
    core::get_mime_type(path)
}

#[flutter_rust_bridge::frb(sync)]
pub fn get_apps_for_mime(mime_type: String, path: String) -> Vec<AppInfoDto> {
    core::get_apps_for_mime(mime_type, path)
        .into_iter()
        .map(Into::into)
        .collect()
}

#[flutter_rust_bridge::frb]
pub async fn open_with_app(app_id: String, path: String) -> Result<(), String> {
    core::open_with_app(app_id, path).await
}

#[flutter_rust_bridge::frb(sync)]
pub fn open_with_dialog_native(path: String) -> Result<(), String> {
    core::open_with_dialog_native(path)
}