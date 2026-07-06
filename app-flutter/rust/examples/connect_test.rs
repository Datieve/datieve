use datieve_core::agent_api::{check_agent_status, normalize_agent_ip};
use datieve_core::core::{
    discover_agents, get_pinned_fingerprint, init_app_state, probe_agent_fingerprint,
    set_pinned_fingerprint,
};
use std::sync::Arc;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let core = Arc::new(init_app_state());
    let agents = discover_agents(&core, Some(34514), None).await?;
    println!("discovered {} agents", agents.len());
    for a in &agents {
        println!("  {} {} fp={:?}", a.ip, a.hostname, a.fingerprint);
    }
    if let Some(agent) = agents.first() {
        let ip = normalize_agent_ip(&agent.ip);
        println!("connecting to {}", ip);
        println!("pinned before: {:?}", get_pinned_fingerprint(ip.clone())?);
        let probed = probe_agent_fingerprint(ip.clone()).await?;
        println!("probed fp: {}", probed);
        if get_pinned_fingerprint(ip.clone())?.is_none() {
            set_pinned_fingerprint(ip.clone(), probed)?;
        }
        match check_agent_status(&core, &ip).await {
            Ok(s) => println!("status ok: {:?}", s.hostname),
            Err(e) => println!("status ERR: {}", e),
        }
    }
    Ok(())
}
