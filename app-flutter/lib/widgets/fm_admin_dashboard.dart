import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../state/datieve_state.dart';
import '../theme/css_tokens.dart';
import '../widgets/ui/spinners.dart';

const _adminTabs = [
  (id: 'stats', label: 'Overview', icon: LucideIcons.activity),
  (id: 'agent', label: 'Agent Name', icon: LucideIcons.server),
  (id: 'admin', label: 'Admin Account', icon: LucideIcons.shield),
  (id: 'folders', label: 'Watched Folders', icon: LucideIcons.folder),
  (id: 'exclusions', label: 'Exclusions', icon: LucideIcons.x),
  (id: 'users', label: 'Users', icon: LucideIcons.users),
  (id: 'management', label: 'Management', icon: LucideIcons.settings),
  (id: 'maintenance', label: 'Maintenance', icon: LucideIcons.trash2),
];

class FmAdminDashboard extends StatefulWidget {
  final DatieveState state;

  const FmAdminDashboard({super.key, required this.state});

  @override
  State<FmAdminDashboard> createState() => _FmAdminDashboardState();
}

class _FmAdminDashboardState extends State<FmAdminDashboard> {
  String view = 'stats';
  bool loading = true;
  String adminError = '';
  String saveSuccess = '';
  bool saving = false;

  // Password gate
  bool _unlocked = false;
  bool _verifying = false;
  String _gateError = '';
  final _gateCodeCtrl = TextEditingController();

  bool _showMgmtPwd = false;

  Map<String, dynamic>? statsData;
  List<dynamic> foldersData = [];
  List<dynamic> usersData = [];

  final _mgmtPassword = TextEditingController();
  final _mgmtNewPassword = TextEditingController();
  final _friendlyName = TextEditingController();
  final _adminUsername = TextEditingController();
  final _adminCode = TextEditingController();
  final _newFolderPath = TextEditingController();
  final _newUserName = TextEditingController();
  final _newUserCode = TextEditingController();
  List<String> exclusionPatterns = [];

  @override
  void initState() {
    super.initState();
    // Don't load data until management code verified.
  }

  @override
  void dispose() {
    _gateCodeCtrl.dispose();
    _mgmtPassword.dispose();
    _mgmtNewPassword.dispose();
    _friendlyName.dispose();
    _adminUsername.dispose();
    _adminCode.dispose();
    _newFolderPath.dispose();
    _newUserName.dispose();
    _newUserCode.dispose();
    super.dispose();
  }

  Future<void> _unlockWithCode() async {
    final code = _gateCodeCtrl.text.trim();
    if (code.isEmpty) return;
    setState(() { _verifying = true; _gateError = ''; });
    final ok = await widget.state.verifyManagementCode(code);
    if (!mounted) return;
    if (ok) {
      setState(() { _unlocked = true; _verifying = false; });
      await _loadAll();
    } else {
      setState(() { _gateError = 'Wrong management code.'; _verifying = false; });
    }
  }

  Future<void> _loadAll() async {
    setState(() {
      loading = true;
      adminError = '';
    });
    try {
      final results = await Future.wait([
        widget.state.adminRequest('stats'),
        widget.state.adminRequest('folders'),
        widget.state.adminRequest('users'),
      ]);
      statsData = results[0] is Map<String, dynamic>
          ? results[0] as Map<String, dynamic>
          : null;
      foldersData = results[1] is List ? results[1] as List : [];
      usersData = results[2] is List ? results[2] as List : [];
      await _loadSettings();
    } catch (e) {
      adminError = e.toString();
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> _loadSettings() async {
    try {
      final s = await widget.state.adminRequest('settings');
      if (s == null) return;
      _friendlyName.text = s['friendly_name']?.toString() ?? '';
      _adminUsername.text = s['admin_username']?.toString() ?? '';
      exclusionPatterns = (s['exclusion_patterns'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          [];
      setState(() {});
    } catch (e) {
      adminError = e.toString();
    }
  }

  Future<void> _saveSettings() async {
    setState(() {
      saving = true;
      adminError = '';
      saveSuccess = '';
    });
    try {
      await widget.state.adminRequest(
        'settings',
        method: 'POST',
        body: {
          'management_password': _mgmtPassword.text,
          'friendly_name': _friendlyName.text,
          'admin_username': _adminUsername.text,
          if (_adminCode.text.isNotEmpty) 'admin_code': _adminCode.text,
          if (_mgmtNewPassword.text.isNotEmpty)
            'management_password_new': _mgmtNewPassword.text,
          'exclusion_patterns':
              exclusionPatterns.map((p) => p.trim()).where((p) => p.isNotEmpty).toList(),
        },
      );
      saveSuccess = 'Settings saved.';
      _mgmtNewPassword.clear();
    } catch (e) {
      adminError = e.toString();
    }
    if (mounted) {
      setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tw = Tw(widget.state.colors);

    if (!_unlocked) {
      return _ManagementGate(
        tw: tw,
        controller: _gateCodeCtrl,
        error: _gateError,
        verifying: _verifying,
        onUnlock: _unlockWithCode,
        onClose: widget.state.closeFmAdmin,
      );
    }

    final tabLabel = _adminTabs.firstWhere((t) => t.id == view).label;

    return ColoredBox(
      color: tw.white,
      child: Column(
        children: [
          Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: tw.slate50,
              border: Border(bottom: BorderSide(color: tw.slate100)),
            ),
            child: Row(
              children: [
                Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: tw.slate900,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Center(
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: tw.white,
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'Management Console',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: tw.ink,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: Icon(LucideIcons.x, size: 14, color: tw.slate400),
                  onPressed: widget.state.closeFmAdmin,
                  padding: const EdgeInsets.all(6),
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 176,
                  child: ColoredBox(
                    color: tw.slate50,
                    child: ListView(
                      children: [
                        for (final tab in _adminTabs)
                          Material(
                            color: view == tab.id ? tw.white : Colors.transparent,
                            child: InkWell(
                              onTap: () => setState(() => view = tab.id),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 10,
                                ),
                                decoration: BoxDecoration(
                                  border: Border(
                                    bottom: BorderSide(color: tw.slate100),
                                    right: view == tab.id
                                        ? BorderSide(color: tw.slate900, width: 2)
                                        : BorderSide.none,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Icon(tab.icon, size: 13, color: tw.slate500),
                                    const SizedBox(width: 10),
                                    Text(
                                      tab.label,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: view == tab.id
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                        color: view == tab.id ? tw.ink : tw.slate500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        height: 40,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        decoration: BoxDecoration(
                          border: Border(bottom: BorderSide(color: tw.slate100)),
                        ),
                        child: Row(
                          children: [
                            Text(
                              tabLabel,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: tw.slate700,
                              ),
                            ),
                            const Spacer(),
                            SizedBox(
                              width: 160,
                              height: 30,
                              child: TextField(
                                controller: _mgmtPassword,
                                obscureText: !_showMgmtPwd,
                                style: const TextStyle(fontSize: 12),
                                decoration: InputDecoration(
                                  hintText: 'Management password',
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(4),
                                    borderSide: BorderSide(color: tw.slate200),
                                  ),
                                  suffixIcon: IconButton(
                                    icon: Icon(
                                      _showMgmtPwd ? LucideIcons.eye : LucideIcons.eyeOff,
                                      size: 14,
                                      color: tw.slate400,
                                    ),
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(
                                      minWidth: 28,
                                      minHeight: 28,
                                    ),
                                    onPressed: () => setState(() => _showMgmtPwd = !_showMgmtPwd),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            FilledButton(
                              onPressed: saving ? null : _saveSettings,
                              style: FilledButton.styleFrom(
                                backgroundColor: tw.slate900,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 8,
                                ),
                              ),
                              child: Text(
                                saving ? 'Saving…' : 'Save',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (adminError.isNotEmpty)
                        Container(
                          margin: const EdgeInsets.all(12),
                          padding: const EdgeInsets.all(8),
                          color: tw.red50,
                          child: Text(
                            adminError,
                            style: TextStyle(fontSize: 12, color: tw.red700),
                          ),
                        ),
                      if (saveSuccess.isNotEmpty)
                        Container(
                          margin: const EdgeInsets.all(12),
                          padding: const EdgeInsets.all(8),
                          color: const Color(0xFFF0FDF4),
                          child: Text(
                            saveSuccess,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF15803D),
                            ),
                          ),
                        ),
                      Expanded(
                        child: loading
                            ? Center(
                                child: SlateSpinner(
                                  size: 24,
                                  stroke: 3,
                                  colors: widget.state.colors,
                                ),
                              )
                            : _buildView(tw),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildView(Tw tw) {
    switch (view) {
      case 'stats':
        return _StatsView(tw: tw, stats: statsData);
      case 'agent':
        return _AgentView(tw: tw, controller: _friendlyName);
      case 'admin':
        return _AdminAccountView(
          tw: tw,
          username: _adminUsername,
          code: _adminCode,
        );
      case 'folders':
        return _FoldersView(
          tw: tw,
          folders: foldersData,
          pathController: _newFolderPath,
          onAdd: _addFolder,
          onDelete: _deleteFolder,
        );
      case 'exclusions':
        return _ExclusionsView(
          tw: tw,
          patterns: exclusionPatterns,
          onChanged: (next) => setState(() => exclusionPatterns = next),
        );
      case 'users':
        return _UsersView(
          tw: tw,
          users: usersData,
          nameController: _newUserName,
          codeController: _newUserCode,
          onAdd: _createUser,
          onDelete: _deleteUser,
        );
      case 'management':
        return _ManagementView(tw: tw, newPassword: _mgmtNewPassword);
      case 'maintenance':
        return _MaintenanceView(tw: tw, state: widget.state);
      default:
        return const SizedBox.shrink();
    }
  }

  Future<void> _addFolder() async {
    final path = _newFolderPath.text.trim();
    if (!path.startsWith('/')) {
      setState(() => adminError = 'Enter an absolute NAS path.');
      return;
    }
    try {
      await widget.state.adminRequest('folders', method: 'POST', body: path);
      _newFolderPath.clear();
      await _loadAll();
    } catch (e) {
      setState(() => adminError = e.toString());
    }
  }

  Future<void> _deleteFolder(dynamic folder) async {
    try {
      await widget.state.adminRequest(
        'folders/${folder['id']}',
        method: 'DELETE',
      );
      await _loadAll();
    } catch (e) {
      setState(() => adminError = e.toString());
    }
  }

  Future<void> _createUser() async {
    try {
      await widget.state.adminRequest(
        'users',
        method: 'POST',
        body: {
          'username': _newUserName.text.trim(),
          'code': _newUserCode.text,
        },
      );
      _newUserName.clear();
      _newUserCode.clear();
      await _loadAll();
    } catch (e) {
      setState(() => adminError = e.toString());
    }
  }

  Future<void> _deleteUser(dynamic user) async {
    try {
      await widget.state.adminRequest('users/${user['id']}', method: 'DELETE');
      await _loadAll();
    } catch (e) {
      setState(() => adminError = e.toString());
    }
  }
}

class _StatsView extends StatelessWidget {
  final Tw tw;
  final Map<String, dynamic>? stats;

  const _StatsView({required this.tw, required this.stats});

  @override
  Widget build(BuildContext context) {
    if (stats == null) {
      return Center(child: Text('No stats', style: TextStyle(color: tw.slate400)));
    }
    final files = stats!['total_files'] ?? 0;
    final folders = stats!['total_folders'] ?? 0;
    final watched = stats!['watched_folders'] as List? ?? [];

    return ListView(
      children: [
        Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'FILES INDEXED',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2,
                        color: tw.slate400,
                      ),
                    ),
                    Text(
                      '$files',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                        color: tw.ink,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'DIRECTORIES',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2,
                        color: tw.slate400,
                      ),
                    ),
                    Text(
                      '$folders',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                        color: tw.ink,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        for (final wf in watched)
          ListTile(
            title: Text(
              wf['path']?.toString() ?? '',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              '${wf['status']} · ${wf['scanned'] ?? 0} / ${wf['estimate'] ?? 0} scanned',
              style: TextStyle(fontSize: 11, color: tw.slate400),
            ),
          ),
      ],
    );
  }
}

class _AgentView extends StatelessWidget {
  final Tw tw;
  final TextEditingController controller;

  const _AgentView({required this.tw, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'AGENT NAME',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w900,
              letterSpacing: 2,
              color: tw.slate400,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: controller,
            decoration: InputDecoration(
              hintText: 'e.g. Home Server',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
            ),
          ),
        ],
      ),
    );
  }
}

class _AdminAccountView extends StatelessWidget {
  final Tw tw;
  final TextEditingController username;
  final TextEditingController code;

  const _AdminAccountView({
    required this.tw,
    required this.username,
    required this.code,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('ADMIN DISPLAY NAME', style: TextStyle(fontSize: 10, color: tw.slate400)),
          const SizedBox(height: 8),
          TextField(
            controller: username,
            decoration: InputDecoration(border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          Text('NEW ADMIN CODE', style: TextStyle(fontSize: 10, color: tw.slate400)),
          const SizedBox(height: 8),
          TextField(
            controller: code,
            obscureText: true,
            decoration: InputDecoration(
              hintText: 'Blank = keep current',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
    );
  }
}

class _ManagementView extends StatelessWidget {
  final Tw tw;
  final TextEditingController newPassword;

  const _ManagementView({required this.tw, required this.newPassword});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'NEW MANAGEMENT PASSWORD',
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 2, color: tw.slate400),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: newPassword,
            obscureText: true,
            decoration: InputDecoration(
              hintText: 'Blank = keep current password',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Enter the current management password in the header bar and click Save to apply.',
            style: TextStyle(fontSize: 11, color: tw.slate400),
          ),
        ],
      ),
    );
  }
}

class _FoldersView extends StatelessWidget {
  final Tw tw;
  final List<dynamic> folders;
  final TextEditingController pathController;
  final VoidCallback onAdd;
  final ValueChanged<dynamic> onDelete;

  const _FoldersView({
    required this.tw,
    required this.folders,
    required this.pathController,
    required this.onAdd,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: pathController,
                  decoration: InputDecoration(
                    hintText: '/mnt/tank/archive',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: onAdd, child: const Text('Add Folder')),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: folders.length,
            itemBuilder: (context, i) {
              final f = folders[i];
              return ListTile(
                title: Text(f['path']?.toString() ?? ''),
                subtitle: Text(
                  '${f['status']} · ${f['scanned'] ?? 0} / ${f['estimate'] ?? 0}',
                  style: TextStyle(fontSize: 11, color: tw.slate400),
                ),
                trailing: TextButton(
                  onPressed: () => onDelete(f),
                  child: Text('Delete', style: TextStyle(color: tw.red600)),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ExclusionsView extends StatelessWidget {
  final Tw tw;
  final List<String> patterns;
  final ValueChanged<List<String>> onChanged;

  const _ExclusionsView({
    required this.tw,
    required this.patterns,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        for (var i = 0; i < patterns.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: TextEditingController(text: patterns[i]),
                    onChanged: (v) {
                      final next = [...patterns];
                      next[i] = v;
                      onChanged(next);
                    },
                    decoration: InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: 'e.g. .* or *.tmp',
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(LucideIcons.x, size: 14, color: tw.slate300),
                  onPressed: () {
                    onChanged([...patterns]..removeAt(i));
                  },
                ),
              ],
            ),
          ),
        TextButton(
          onPressed: () => onChanged([...patterns, '']),
          child: const Text('Add Pattern'),
        ),
      ],
    );
  }
}

class _UsersView extends StatelessWidget {
  final Tw tw;
  final List<dynamic> users;
  final TextEditingController nameController;
  final TextEditingController codeController;
  final VoidCallback onAdd;
  final ValueChanged<dynamic> onDelete;

  const _UsersView({
    required this.tw,
    required this.users,
    required this.nameController,
    required this.codeController,
    required this.onAdd,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: nameController,
                  decoration: InputDecoration(
                    labelText: 'Username',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: codeController,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: 'User Code',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: onAdd, child: const Text('Add User')),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: users.length,
            itemBuilder: (context, i) {
              final u = users[i];
              return ListTile(
                title: Text(u['username']?.toString() ?? ''),
                subtitle: Text(
                  'Joined ${(u['created_at']?.toString() ?? '').split(' ').first}',
                  style: TextStyle(fontSize: 11, color: tw.slate400),
                ),
                trailing: TextButton(
                  onPressed: () => onDelete(u),
                  child: Text('Delete', style: TextStyle(color: tw.red600)),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _MaintenanceView extends StatelessWidget {
  final Tw tw;
  final DatieveState state;

  const _MaintenanceView({required this.tw, required this.state});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ListTile(
          title: const Text('Rescan now'),
          subtitle: Text(
            'Trigger a full filesystem rescan',
            style: TextStyle(fontSize: 11, color: tw.slate400),
          ),
          trailing: OutlinedButton(
            onPressed: () => state.adminRequest('rescan', method: 'POST', body: {}),
            child: const Text('Rescan'),
          ),
        ),
        ListTile(
          title: const Text('Restart agent'),
          subtitle: Text(
            'The app will reconnect automatically',
            style: TextStyle(fontSize: 11, color: tw.slate400),
          ),
          trailing: OutlinedButton(
            onPressed: () => state.adminRequest('restart', method: 'POST', body: {}),
            child: Text('Restart', style: TextStyle(color: tw.red600)),
          ),
        ),
      ],
    );
  }
}

class _ManagementGate extends StatelessWidget {
  final Tw tw;
  final TextEditingController controller;
  final String error;
  final bool verifying;
  final VoidCallback onUnlock;
  final VoidCallback onClose;

  const _ManagementGate({
    required this.tw,
    required this.controller,
    required this.error,
    required this.verifying,
    required this.onUnlock,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: tw.white,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(LucideIcons.shield, size: 18, color: tw.slate600),
                    const SizedBox(width: 10),
                    Text(
                      'Management Console',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: tw.ink),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: Icon(LucideIcons.x, size: 16, color: tw.slate400),
                      onPressed: onClose,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Enter the management code to access admin controls.',
                  style: TextStyle(fontSize: 13, color: tw.slate500),
                ),
                const SizedBox(height: 24),
                if (error.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.all(10),
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: tw.red50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: tw.red100),
                    ),
                    child: Text(error, style: TextStyle(fontSize: 12, color: tw.red900)),
                  ),
                TextField(
                  controller: controller,
                  obscureText: true,
                  autofocus: true,
                  onSubmitted: (_) => onUnlock(),
                  decoration: InputDecoration(
                    hintText: 'Management code',
                    hintStyle: TextStyle(color: tw.slate400),
                    filled: true,
                    fillColor: tw.slate50,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: tw.slate200),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: tw.slate200),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                  style: TextStyle(fontSize: 15, fontFamily: 'monospace', color: tw.ink),
                ),
                const SizedBox(height: 14),
                GestureDetector(
                  onTapDown: verifying ? null : (_) => onUnlock(),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    decoration: BoxDecoration(
                      color: verifying ? tw.slate900.withValues(alpha: 0.5) : tw.slate900,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      verifying ? 'Verifying...' : 'Unlock',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: tw.onBrand),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}