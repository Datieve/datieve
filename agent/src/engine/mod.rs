//! Engine-level scope helpers.
//!
//! In this open-source build, everything lives in a single scope (the empty
//! string ""). The scope_tag is included in every DB query so multi-scope
//! support can be added later without a schema migration  - the index already
//! stores the tag on every row, it's just always "".
//!
//! If you see scope_tag peppered throughout the SQL, that's why.

/// The scope tag used for all data in this build. Always empty.
pub fn scope_tag() -> &'static str {
    ""
}

/// The scope used during first-time agent setup. Same as scope_tag here.
pub fn setup_scope() -> String {
    String::new()
}

/// Cache key for a session token. No transformation needed in this build.
pub fn session_cache_key(token_lookup_key: &str) -> String {
    token_lookup_key.to_string()
}