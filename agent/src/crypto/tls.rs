use crate::error::AppError;
use rcgen::{CertificateParams, DistinguishedName, KeyPair};
use sha2::{Digest, Sha256};
use std::path::Path;

/// Ensures that a self-signed TLS certificate and private key exist in the config directory.
/// If they don't, generates a new 10-year certificate with LAN-friendly SANs.
/// Also writes a fingerprint file for optional client-side pinning/TOFU.
pub fn ensure_certs(cert_path: &Path, key_path: &Path) -> Result<(), AppError> {
    if cert_path.exists() && key_path.exists() {
        tracing::info!("Secure app connection is ready.");
        return Ok(());
    }

    tracing::info!("Preparing secure app connection.");

    let mut params = CertificateParams::default();
    params.not_before = time::OffsetDateTime::now_utc();
    params.not_after = time::OffsetDateTime::now_utc() + time::Duration::days(3650); // 10 years
    params.distinguished_name = DistinguishedName::new();
    params
        .distinguished_name
        .push(rcgen::DnType::CommonName, "Datieve Sentinel Agent");
    params
        .distinguished_name
        .push(rcgen::DnType::OrganizationName, "Datieve Infrastructure");

    // LAN-friendly SANs (self-signed, no browser involved  - this is for the Tauri app + local tools)
    let mut sans = vec![
        rcgen::SanType::DnsName("localhost".parse().unwrap()),
        rcgen::SanType::DnsName("datieve".parse().unwrap()),
        rcgen::SanType::DnsName("datieve.local".parse().unwrap()),
        rcgen::SanType::DnsName("agent.local".parse().unwrap()),
        rcgen::SanType::IpAddress(std::net::IpAddr::V4(std::net::Ipv4Addr::new(127, 0, 0, 1))),
    ];

    if let Ok(ip) = local_ip_address::local_ip() {
        tracing::info!("Adding local IP to TLS SAN list: {}", ip);
        sans.push(rcgen::SanType::IpAddress(ip));
    }

    params.subject_alt_names = sans;

    let key_pair = KeyPair::generate()?;
    let cert = params
        .self_signed(&key_pair)
        .map_err(|e| AppError::Crypto(format!("Cert generation failed: {e}")))?;

    let cert_pem = cert.pem();
    crate::config::write_private_file(cert_path, cert_pem.as_bytes())?;
    crate::config::write_private_file(key_path, key_pair.serialize_pem().as_bytes())?;

    // Write stable fingerprints for client pinning/TOFU.
    // Prefer DER fingerprint (matches what TLS clients see), but also write PEM fingerprint for
    // backwards compatibility with older app versions.
    let mut hasher = Sha256::new();
    hasher.update(cert.der());
    let fingerprint_der = format!("{:x}", hasher.finalize());

    let mut hasher = Sha256::new();
    hasher.update(cert_pem.as_bytes());
    let fingerprint_pem = format!("{:x}", hasher.finalize());
    if let Some(parent) = cert_path.parent() {
        let fp_path = parent.join("agent.cert.fingerprint");
        let fp_der_path = parent.join("agent.cert.fingerprint.der");
        let _ = crate::config::write_private_file(&fp_path, fingerprint_pem.as_bytes());
        let _ = crate::config::write_private_file(&fp_der_path, fingerprint_der.as_bytes());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&fp_path, std::fs::Permissions::from_mode(0o600));
            let _ = std::fs::set_permissions(&fp_der_path, std::fs::Permissions::from_mode(0o600));
        }
        tracing::debug!("TLS certificate fingerprint written to agent.cert.fingerprint.der.");
        tracing::debug!("Agent TLS fingerprint (DER SHA-256): {}", fingerprint_der);
        tracing::info!("Secure app connection is ready.");
    }

    // Enforce 0600 permissions
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(cert_path, std::fs::Permissions::from_mode(0o600));
        let _ = std::fs::set_permissions(key_path, std::fs::Permissions::from_mode(0o600));
    }

    Ok(())
}
