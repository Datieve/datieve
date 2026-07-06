use glob::Pattern;

#[derive(Clone)]
pub struct PathMatcher {
    patterns: Vec<Pattern>,
}

impl PathMatcher {
    /// Creates a new matcher from a list of wildcard strings (e.g. "*.tmp", ".*").
    pub fn new(raw_patterns: &[String]) -> Self {
        let mut patterns = Vec::new();
        for p in raw_patterns {
            if let Ok(pat) = Pattern::new(p) {
                patterns.push(pat);
            } else {
                tracing::warn!("Invalid exclusion pattern skipped: {}", p);
            }
        }
        Self { patterns }
    }

    /// Returns true if the given path matches ANY of the exclusion patterns.
    /// Checked against both the full path and the individual filename.
    pub fn is_excluded(&self, path: &str) -> bool {
        // 1. Check full path (e.g. for "/volume1/data/.hidden_folder/file.txt")
        for pat in &self.patterns {
            if pat.matches(path) {
                return true;
            }
        }

        // 2. Check individual components (e.g. for ".*" matching hidden folders mid-path)
        let parts = path.split('/');
        for part in parts {
            if part.is_empty() {
                continue;
            }
            for pat in &self.patterns {
                if pat.matches(part) {
                    return true;
                }
            }
        }

        false
    }
}
