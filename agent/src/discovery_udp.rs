//! LAN discovery: desktop app sends `DATIEVE_PING`, agent replies with JSON.

use std::path::Path;
use std::sync::Arc;

use serde_json::json;
use tokio::net::UdpSocket;
use tokio::sync::RwLock;

use crate::config::Config;

pub const DISCOVERY_PING: &[u8] = b"DATIEVE_PING";

pub fn discovery_udp_port(https_port: u16) -> u16 {
    https_port.saturating_add(2)
}

pub fn spawn_udp_discovery(shared_config: Arc<RwLock<Config>>, data_dir: std::path::PathBuf) {
    tokio::spawn(async move {
        if let Err(e) = run_udp_discovery(shared_config, data_dir).await {
            tracing::warn!("UDP discovery listener stopped: {}", e);
        }
    });
}

async fn run_udp_discovery(
    shared_config: Arc<RwLock<Config>>,
    data_dir: std::path::PathBuf,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let port = {
        let cfg = shared_config.read().await;
        discovery_udp_port(cfg.port)
    };

    let bind = format!("0.0.0.0:{port}");
    let sock = UdpSocket::bind(&bind).await?;
    tracing::info!("LAN discovery ping on udp://{bind}");

    let mut buf = [0u8; 1024];
    loop {
        let (n, peer) = sock.recv_from(&mut buf).await?;
        if n < DISCOVERY_PING.len() || &buf[..DISCOVERY_PING.len()] != DISCOVERY_PING {
            continue;
        }
        let reply = build_discovery_reply(&shared_config, &data_dir).await;
        let _ = sock.send_to(reply.as_bytes(), peer).await;
    }
}

async fn build_discovery_reply(
    shared_config: &Arc<RwLock<Config>>,
    data_dir: &Path,
) -> String {
    let cfg = shared_config.read().await;
    let fingerprint = std::fs::read_to_string(data_dir.join("agent.cert.fingerprint.der"))
        .ok()
        .map(|fp| fp.trim().to_string())
        .filter(|fp| !fp.is_empty());

    let payload = json!({
        "hostname": cfg.friendly_name,
        "version": env!("CARGO_PKG_VERSION"),
        "is_setup": cfg.is_setup,
        "port": cfg.port,
        "fingerprint": fingerprint,
    });

    payload.to_string()
}