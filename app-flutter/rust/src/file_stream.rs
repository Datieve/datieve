use crate::agent_api::AgentApi;
use crate::bridge::{bridge, FileItemDto, FileListMetaDto, FileStreamEvent};
use crate::file_manager::{browse_nas, list_local_stream, nas_to_rows, search_nas};
use crate::frb_generated::StreamSink;
use anyhow::Result;

fn stream_runtime() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("stream runtime")
}

fn push_meta(sink: &StreamSink<FileStreamEvent>, meta: FileListMetaDto) {
    sink.add(FileStreamEvent {
        event_type: "meta".into(),
        item: None,
        meta: Some(meta),
        message: None,
    });
}

fn push_item(sink: &StreamSink<FileStreamEvent>, item: FileItemDto) {
    sink.add(FileStreamEvent {
        event_type: "item".into(),
        item: Some(item),
        meta: None,
        message: None,
    });
}

fn push_done(sink: &StreamSink<FileStreamEvent>, status: String) {
    sink.add(FileStreamEvent {
        event_type: "done".into(),
        item: None,
        meta: None,
        message: Some(status),
    });
}

pub fn stream_local_files(sink: StreamSink<FileStreamEvent>) -> Result<()> {
    let (path, hidden, meta) = {
        let b = bridge().lock().unwrap();
        let meta = FileListMetaDto {
            status: String::new(),
            ..b.file_list_meta()
        };
        (b.local.current_path.clone(), b.local.show_hidden, meta)
    };

    std::thread::spawn(move || {
        let run = || -> Result<()> {
            push_meta(&sink, meta);
            let mut count = 0usize;
            list_local_stream(&path, hidden, |row| {
                count += 1;
                push_item(&sink, row.into());
            })
            .map_err(anyhow::Error::msg)?;
            push_done(&sink, format!("{count} items"));
            Ok(())
        };
        if let Err(e) = run() {
            let _ = sink.add_error(e);
        }
    });
    Ok(())
}

pub fn stream_nas_files(sink: StreamSink<FileStreamEvent>, parent_id: Option<i64>) -> Result<()> {
    let (agent_ip, session, core, meta) = {
        let b = bridge().lock().unwrap();
        let agent = b
            .agent
            .clone()
            .ok_or_else(|| anyhow::anyhow!("No agent connected."))?;
        let session = b
            .session
            .clone()
            .ok_or_else(|| anyhow::anyhow!("login_required"))?;
        let meta = b.nas_meta(parent_id);
        (agent.ip, session, b.core.clone(), meta)
    };

    {
        let mut b = bridge().lock().unwrap();
        b.nas.parent_id = parent_id;
    }

    std::thread::spawn(move || {
        let run = || -> Result<()> {
            push_meta(&sink, meta.clone());
            let api = AgentApi::new(core);
            let runtime = stream_runtime();
            let items = runtime
                .block_on(browse_nas(&api, &agent_ip, &session, parent_id))
                .map_err(anyhow::Error::msg)?;
            // Update meta with the real absolute path from the browse response.
            let real_path = items.current_absolute_path.clone().unwrap_or_default();
            if real_path != meta.current_path {
                push_meta(&sink, FileListMetaDto {
                    current_path: real_path,
                    ..meta
                });
            }
            let rows = nas_to_rows(&items);
            let count = rows.len();
            for row in rows {
                push_item(&sink, row.into());
            }
            push_done(&sink, format!("{count} items"));
            Ok(())
        };
        if let Err(e) = run() {
            let _ = sink.add_error(e);
        }
    });
    Ok(())
}

pub fn stream_nas_search(sink: StreamSink<FileStreamEvent>, query: String) -> Result<()> {
    let (agent_ip, session, core) = {
        let b = bridge().lock().unwrap();
        let agent = b
            .agent
            .clone()
            .ok_or_else(|| anyhow::anyhow!("No agent connected."))?;
        let session = b
            .session
            .clone()
            .ok_or_else(|| anyhow::anyhow!("login_required"))?;
        (agent.ip, session, b.core.clone())
    };

    std::thread::spawn(move || {
        let run = || -> Result<()> {
            let meta = FileListMetaDto {
                current_path: String::new(),
                can_back: false,
                can_forward: false,
                show_hidden: false,
                status: format!("Searching \"{query}\""),
            };
            push_meta(&sink, meta);
            let api = AgentApi::new(core);
            let runtime = stream_runtime();
            let rows = runtime
                .block_on(search_nas(&api, &agent_ip, &session, &query))
                .map_err(anyhow::Error::msg)?;
            let count = rows.len();
            for row in rows {
                push_item(&sink, row.into());
            }
            push_done(&sink, format!("{count} results"));
            Ok(())
        };
        if let Err(e) = run() {
            let _ = sink.add_error(e);
        }
    });
    Ok(())
}

pub fn stream_demo_files(sink: StreamSink<FileStreamEvent>) -> Result<()> {
    let (agent_ip, core) = {
        let b = bridge().lock().unwrap();
        let agent = b
            .agent
            .clone()
            .ok_or_else(|| anyhow::anyhow!("No agent connected."))?;
        (agent.ip, b.core.clone())
    };

    std::thread::spawn(move || {
        let run = || -> Result<()> {
            let runtime = stream_runtime();
            let mut status_line = String::new();
            if let Ok(res) = runtime.block_on(crate::agent_api::agent_fetch(
                &core,
                &agent_ip,
                "/api/demo/status",
                "GET",
                None,
                None,
                None,
            )) {
                if res.status == 200 {
                    if let Ok(v) = serde_json::from_str::<serde_json::Value>(&res.body) {
                        let st = v.get("status").cloned().unwrap_or_default();
                        status_line = format!(
                            "{} · {} files · {} folders",
                            st.get("state").and_then(|x| x.as_str()).unwrap_or("idle"),
                            st.get("indexed_files").and_then(|x| x.as_u64()).unwrap_or(0),
                            st.get("indexed_folders").and_then(|x| x.as_u64()).unwrap_or(0),
                        );
                    }
                }
            }

            push_meta(
                &sink,
                FileListMetaDto {
                    current_path: String::new(),
                    can_back: false,
                    can_forward: false,
                    show_hidden: false,
                    status: status_line,
                },
            );

            if let Ok(res) = runtime.block_on(crate::agent_api::agent_fetch(
                &core,
                &agent_ip,
                "/api/demo/browse",
                "GET",
                None,
                None,
                None,
            )) {
                if res.status == 200 {
                    if let Ok(items) =
                        serde_json::from_str::<crate::file_manager::BrowseItems>(&res.body)
                    {
                        let rows = nas_to_rows(&items);
                        let count = rows.len();
                        for row in rows {
                            push_item(&sink, row.into());
                        }
                        push_done(&sink, format!("{count} items"));
                        return Ok(());
                    }
                }
            }
            push_done(&sink, "0 items".into());
            Ok(())
        };
        if let Err(e) = run() {
            let _ = sink.add_error(e);
        }
    });
    Ok(())
}