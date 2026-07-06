use argon2::{
    password_hash::{rand_core::OsRng, PasswordHash, PasswordHasher, PasswordVerifier, SaltString},
    Argon2,
};

use crate::error::AppError;

/// Hash a plaintext password using Argon2id with OWASP recommended defaults.
pub fn hash(password: &str) -> Result<String, AppError> {
    hash_bytes(password.as_bytes())
}

pub fn verify(password: &str, stored_hash: &str) -> Result<bool, AppError> {
    verify_bytes(password.as_bytes(), stored_hash)
}

fn hash_bytes(bytes: &[u8]) -> Result<String, AppError> {
    let salt = SaltString::generate(&mut OsRng);
    let argon2 = Argon2::default();
    let password_hash = argon2
        .hash_password(bytes, &salt)
        .map_err(|e| AppError::Internal(format!("Failed to hash password: {}", e)))?;
    Ok(password_hash.to_string())
}

fn verify_bytes(bytes: &[u8], stored_hash: &str) -> Result<bool, AppError> {
    let parsed_hash = PasswordHash::new(stored_hash)
        .map_err(|e| AppError::Internal(format!("Malformed password hash in database: {}", e)))?;
    let argon2 = Argon2::default();
    Ok(argon2.verify_password(bytes, &parsed_hash).is_ok())
}