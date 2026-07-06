use crate::file_manager::{default_home, parent_path};

#[derive(Clone, Debug)]
pub struct LocalNavState {
    pub current_path: String,
    pub history: Vec<String>,
    pub history_idx: usize,
    pub show_hidden: bool,
}

impl LocalNavState {
    pub fn new() -> Self {
        let home = default_home();
        Self {
            current_path: home.clone(),
            history: vec![home],
            history_idx: 0,
            show_hidden: false,
        }
    }

    pub fn navigate(&mut self, path: String) {
        if path == self.current_path {
            return;
        }
        self.history.truncate(self.history_idx + 1);
        self.history.push(path.clone());
        self.history_idx = self.history.len() - 1;
        self.current_path = path;
    }

    pub fn back(&mut self) -> bool {
        if self.history_idx == 0 {
            return false;
        }
        self.history_idx -= 1;
        self.current_path = self.history[self.history_idx].clone();
        true
    }

    pub fn forward(&mut self) -> bool {
        if self.history_idx + 1 >= self.history.len() {
            return false;
        }
        self.history_idx += 1;
        self.current_path = self.history[self.history_idx].clone();
        true
    }

    pub fn home(&mut self) {
        let home = default_home();
        self.navigate(home);
    }

    pub fn can_back(&self) -> bool {
        self.history_idx > 0
    }

    pub fn can_forward(&self) -> bool {
        self.history_idx + 1 < self.history.len()
    }

    pub fn go_up(&mut self) -> bool {
        if let Some(parent) = parent_path(&self.current_path) {
            self.navigate(parent);
            true
        } else {
            false
        }
    }
}

#[derive(Clone, Default)]
pub struct NasNavState {
    pub parent_id: Option<i64>,
}