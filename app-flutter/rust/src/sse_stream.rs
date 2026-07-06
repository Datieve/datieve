use crate::bridge::bridge;
use crate::frb_generated::StreamSink;
use anyhow::Result;
use std::sync::{mpsc, Arc};

fn stream_runtime() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("sse stream runtime")
}

pub fn stream_sse_events(
    sink: StreamSink<String>,
    listener_id: String,
    url: String,
    token: Option<String>,
    mac_key: Option<String>,
) -> Result<()> {
    let core = bridge().lock().unwrap().core.clone();
    std::thread::spawn(move || {
        let rt = stream_runtime();
        let (tx, rx) = mpsc::channel::<String>();
        let on_event = {
            let tx = tx.clone();
            Arc::new(move |payload: String| {
                let _ = tx.send(payload);
            })
        };
        let listener = listener_id.clone();
        let sse_url = url.clone();
        let sse_token = token.clone();
        let sse_mac = mac_key.clone();
        let core_ref = core.clone();
        rt.block_on(async move {
            let sse_task = tokio::spawn(async move {
                let _ = crate::core::listen_to_sse(
                    &core_ref,
                    listener,
                    sse_url,
                    sse_token,
                    sse_mac,
                    on_event,
                )
                .await;
            });
            while let Ok(msg) = rx.recv() {
                if sink.add(msg).is_err() {
                    break;
                }
            }
            sse_task.abort();
        });
    });
    Ok(())
}