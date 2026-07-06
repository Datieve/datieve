pub mod password;

use sha2::{Digest, Sha256};

// All hashes here use domain-separated preimages so that the same raw code
// cannot be replayed across different contexts (admin vs user vs management).
// e.g. an admin code "abc" hashes to a different value than a user code "abc".

/// SHA-256 of the raw session token, stored in the sessions table as the lookup key.
/// Raw tokens never touch the DB.
pub fn session_token_lookup_key(token: &str) -> Result<String, crate::error::AppError> {
    Ok(hex::encode(Sha256::digest(token.as_bytes())))
}

/// HMAC key derived from the session token, used by the client to sign each request.
pub fn session_request_mac_key(token: &str) -> String {
    hex::encode(Sha256::digest(format!("DATIEVE-MAC-V1:{token}").as_bytes()))
}

/// Lookup key for user access codes, stored in the user_code_lookup table.
pub fn user_code_lookup_key(code: &str) -> Result<String, crate::error::AppError> {
    Ok(hex::encode(Sha256::digest(format!("DATIEVE-USER-CODE-V1:{code}").as_bytes())))
}

/// Preimage fed to Argon2 for admin code hashing. Domain-prefixed to prevent cross-context reuse.
pub fn admin_code_preimage(code: &str) -> String {
    format!("admin:{code}")
}

/// Preimage for user code hashing. Includes user_id so the same code produces a different
/// hash for different users.
pub fn user_code_preimage(code: &str, user_id: i64) -> String {
    format!("user:{user_id}:{code}")
}

/// Preimage for the management password.
pub fn manage_password_preimage(password: &str) -> String {
    format!("manage:{password}")
}