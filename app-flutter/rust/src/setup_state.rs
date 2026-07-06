pub const TOTAL_STEPS: i32 = 7;

pub const STEP_TITLES: [&str; 7] = [
    "Agent",
    "Admin",
    "Folders",
    "Exclusions",
    "Users",
    "Management",
    "Confirm",
];

pub const STEP_DESCS: [&str; 7] = [
    "Give this agent a name shown during discovery.",
    "Set a password for the admin account.",
    "Define the root directories to index.",
    "Filter what to ignore during indexing.",
    "Create user accounts and define folder access.",
    "Set a password for saving configuration changes.",
    "Review your configuration before deployment.",
];

#[derive(Clone, Default)]
pub struct SetupUser {
    pub username: String,
    pub code: String,
    pub allowed_paths: Vec<String>,
}

#[derive(Clone, Default)]
pub struct SetupForm {
    pub step: i32,
    pub friendly_name: String,
    pub admin_username: String,
    pub admin_code: String,
    pub watched_paths: Vec<String>,
    pub exclude_hidden: bool,
    pub exclusion_patterns: Vec<String>,
    pub users: Vec<SetupUser>,
    pub manage_username: String,
    pub manage_password: String,
}

impl SetupForm {
    pub fn new() -> Self {
        Self {
            step: 1,
            watched_paths: vec![String::new()],
            exclude_hidden: true,
            exclusion_patterns: vec![
                "@Recycle".into(),
                "#recycle".into(),
                ".Trash-*".into(),
            ],
            users: vec![],
            ..Default::default()
        }
    }

    pub fn valid_watched_paths(&self) -> Vec<String> {
        self.watched_paths
            .iter()
            .map(|p| p.trim().to_string())
            .filter(|p| !p.is_empty())
            .collect()
    }

    pub fn validate_step(&self) -> Result<(), String> {
        match self.step {
            1 if self.friendly_name.trim().is_empty() => Err("Agent name is required.".into()),
            2 if self.admin_code.trim().is_empty() => Err("Admin password is required.".into()),
            3 if self.valid_watched_paths().is_empty() => {
                Err("Add at least one folder to index.".into())
            }
            6 if self.manage_password.trim().is_empty() => {
                Err("Management password is required.".into())
            }
            _ => Ok(()),
        }
    }

    pub fn confirm_summary(&self, agent_ip: &str) -> String {
        let paths = self.valid_watched_paths().join("\n  ");
        format!(
            "Agent: {} ({})\nIndexed paths:\n  {}\nAdmin: {}\nUsers: {}\nManagement: {}",
            self.friendly_name,
            agent_ip,
            paths,
            self.admin_username,
            self.users.len(),
            self.manage_username
        )
    }

    pub fn to_finalize_payload(&self) -> serde_json::Value {
        let mut patterns: Vec<String> = self
            .exclusion_patterns
            .iter()
            .map(|p| p.trim().to_string())
            .filter(|p| !p.is_empty())
            .collect();
        if self.exclude_hidden {
            patterns.push(".*".into());
        }
        serde_json::json!({
            "friendly_name": self.friendly_name.trim(),
            "watched_paths": self.valid_watched_paths(),
            "exclusion_patterns": patterns,
            "app_admin_code": self.admin_code.trim(),
            "admin_username": self.admin_username.trim(),
            "manage_username": self.manage_username.trim(),
            "manage_password": self.manage_password,
            "users": self.users.iter().map(|u| serde_json::json!({
                "username": u.username.trim(),
                "code": u.code.trim(),
                "allowed_paths": u.allowed_paths.iter().map(|p| p.trim()).filter(|p| !p.is_empty()).collect::<Vec<_>>(),
            })).collect::<Vec<_>>(),
            "event_log_max_rows": 10000,
            "ghost_file_prune_days": 30,
        })
    }
}