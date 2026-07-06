# Install Guide

---

## Agent

**1. Download and extract**

Download the agent from the releases page and extract it:

```bash
tar -xzf datieve-agent*.tar.gz
cd datieve-agent
```

**2. Make it executable**

```bash
chmod +x datieve-agent
```

**3. Run it**

```bash
./datieve-agent serve
```

The agent will start and begin listening on port 34514.

**Optional — run from anywhere**

```bash
sudo ln -s /path/to/datieve-agent-folder/datieve-agent /usr/local/bin/datieve-agent
```

The symlink name can be anything. `dv` works if `datieve-agent` is too long.

---

## App Setup

Once the agent is running, open the app and click **NAS** in the sidebar. If the agent is active on the same LAN, it will appear in the discovery list. Click it to start setup.

### 1. Name

Give this agent a name. This is what appears in the discovery list after setup.

### 2. Admin account

Set the admin username and access code. The admin account has full access to the entire index. Regular user accounts (set up later) can be scoped to specific folders.

### 3. Watched folders

Add the folders you want indexed. The agent will crawl these on first run and keep them updated via inotify. You can add or remove folders later from the management console.

### 4. Exclusions

Set patterns for things you don't want indexed. The agent applies these globally across all watched folders. Examples: `@Recycle`, `#recycle`, `.Trash-*`, `.*` (all dotfiles). Defaults are already set for common NAS folders you may not want indexed, but that's subjective. You can add your own exclusion patterns.

### 5. Users (optional)

Create user accounts for anyone else who accesses the agent. Each user gets their own code and can be limited to specific folders.

### 6. Wait for the initial scan

The first crawl takes time proportional to how much storage you gave it.

---

## Running as a Service

For a persistent setup, run the agent under systemd so it starts automatically.

```ini
[Unit]
Description=Datieve Agent
After=network.target

[Service]
ExecStart=/usr/local/bin/datieve-agent serve
Restart=on-failure
RestartSec=5
User=your-user

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable --now datieve-agent
```

---

## Updating

**Agent:**

```bash
datieve-agent update
```

Checks the latest release on GitHub and replaces the binary in place. Restart the agent after it completes.

**App:**

The app checks for updates on startup. If a newer version is available, it shows a notification in Settings → About with a link to the releases page. Download and replace the app binary manually.

---

## Where things are stored

**Agent:** stores everything (database, config, TLS certificates, etc.) in the same folder as the binary. More precisely: wherever `current_exe()` resolves to, so symlinks are followed. If your binary lives at `/opt/datieve/datieve-agent` and you symlink it to `/usr/local/bin/datieve-agent`, the data still goes into `/opt/datieve/`. Nothing is written outside that folder.

**App** - stores its config (saved connections, settings, session tokens, etc.) in:
- Linux / macOS: `~/.datieve-app`
- Windows: `%USERPROFILE%\.datieve-app`

The app creates this folder automatically on first run. There is no setup prompt for it.

---

## Uninstalling

**Agent**: delete the agent's folder and remove the binary (or symlink).

**App**: delete the app binary and `~/.datieve-app` (or `%USERPROFILE%\.datieve-app` on Windows).
