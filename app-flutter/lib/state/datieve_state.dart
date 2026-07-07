import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/bookmark.dart';
import '../models/file_tag.dart';
import '../models/fm_clipboard.dart';
import '../models/fm_menu_state.dart';
import '../models/fm_operation_card.dart';
import '../models/fm_undo_item.dart';
import '../models/fm_search_filters.dart';
import '../models/local_tab.dart';
import '../models/palette_command.dart';
import '../src/rust/api/datieve.dart';
import '../src/rust/api/fs.dart' as fs_api;
import '../src/rust/bridge.dart';
import '../theme/datieve_theme.dart';
import '../utils/bookmark_store.dart';
import '../utils/hidden_devices_store.dart';
import '../utils/mount_mappings_store.dart';
import '../utils/places_aliases_store.dart';
import '../utils/fm_visible_files.dart';
import '../utils/search_entry_helpers.dart';
import '../utils/settings_helpers.dart';
import '../utils/setup_helpers.dart';
import '../utils/tag_store.dart';
import '../utils/custom_folder_icons_store.dart';
import '../utils/custom_places_store.dart';
import '../utils/trash_settings_store.dart';
import '../utils/trash_purge.dart';
import '../widgets/fm_open_with_dialog.dart';

// Cross-platform path helpers (handles both / and \ separators).

String _normPath(String p) {
  var s = p;
  while (s.length > 1 && (s.endsWith('/') || s.endsWith('\\'))) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

String _pathParent(String p) {
  final s = _normPath(p);
  final fwd = s.lastIndexOf('/');
  final back = s.lastIndexOf('\\');
  final sep = fwd > back ? fwd : back;
  if (sep < 0) return s.contains('\\') ? '' : '/';
  if (sep == 0) return '/';
  final parent = s.substring(0, sep);
  // Windows drive root: "C:\" — preserve trailing separator
  if (parent.length == 2 && parent[1] == ':') return '$parent\\';
  return parent;
}

// Case-insensitive on Windows (paths can have mixed casing from different sources).
bool _pathEq(String a, String b) {
  final na = _normPath(a).replaceAll('\\', '/');
  final nb = _normPath(b).replaceAll('\\', '/');
  return Platform.isWindows ? na.toLowerCase() == nb.toLowerCase() : na == nb;
}

bool _isSubpath({required String child, required String of}) {
  final normChild = child.replaceAll('\\', '/');
  final normParent = _normPath(of).replaceAll('\\', '/');
  if (Platform.isWindows) {
    return normChild.toLowerCase().startsWith('${normParent.toLowerCase()}/');
  }
  return normChild.startsWith('$normParent/');
}

enum AppScreen { discovery, login, setup, demo, fileManager }

class DatieveState extends ChangeNotifier {
  bool loading = true;
  AppScreen screen = AppScreen.fileManager;
  String? globalError;
  double gridZoom = 1.4;

  AppSettingsDto settings = getSettings();
  List<AgentItemDto> agents = [];
  bool scanning = false;
  bool connecting = false;
  String? connectingIp;
  String discoveryError = '';
  String revokedUsername = '';
  bool _autoSelected = false;
  String portDraft = '';
  bool showPortInput = false;

  AgentInfoDto? agent;
  List<AccountDto> loginAccounts = [];
  bool loginLoading = false;
  String loginError = '';
  bool loginShowCode = true;
  String loginCode = '';
  // Set when the user explicitly logs out so the next connect shows the account
  // chooser instead of silently re-authenticating with stored codes.
  bool _skipAutoCodeLogin = false;

  SetupStateDto setup = getSetupState();
  bool setupLoading = false;
  String setupError = '';

  SessionDto? session;
  String viewMode = 'local';
  List<PlaceDto> places = getPlaces();
  List<CustomPlace> customPlaces = [];

  FileListMetaDto fmMeta = const FileListMetaDto(
    currentPath: '',
    canBack: false,
    canForward: false,
    showHidden: false,
    status: '',
  );
  List<FileItemDto> fmFiles = [];
  bool fmLoading = false;
  String fmError = '';
  String fmSearchQuery = '';
  bool nasSearchActive = false;
  String localSearchQuery = '';
  String localSearchMode = 'browse';
  List<FileItemDto> localSearchResults = [];
  bool localSearchLoading = false;
  bool fmShowFilters = false;
  FmSearchFilters fmSearchFilters = const FmSearchFilters();
  bool fmShowSettings = false;
  bool fmShowAdmin = false;
  bool managementUnlocked = false;
  bool fmShowCommandPalette = false;
  bool fmShowShortcuts = false;
  bool fmShowAddBookmark = false;
  bool fmRequestPathEdit = false;
  String fmCommandQuery = '';
  String bookmarkDraftLabel = '';
  String bookmarkDraftPath = '';

  Set<String> fmSelectedPaths = {};
  FileItemDto? fmSelectedFile;

  List<Bookmark> bookmarks = [];
  List<MountEntryDto> mounts = [];
  String? trashPath;
  List<FileTag> fileTags = defaultFileTags();
  Map<String, List<String>> tagAssignments = {};
  String? activeTagId;

  String? updateAvailableVersion;

  String syncStatus = 'Healthy';
  bool nasDirty = false;
  String? dragOverPath;
  List<String> draggingPaths = [];
  List<FmOperationCard> operationCards = [];
  OpenWithDialogState? openWithDialog;
  TabCtxMenu? tabCtxMenu;
  List<LocalTab> closedLocalTabs = [];

  List<({String label, String path})> localBreadcrumbs = [];
  Set<String> hiddenDevices = {};
  bool fmShowDeviceManager = false;
  bool nasExpanded = true;
  List<FileItemDto> nasNavRoots = [];
  int? _nasCurrentParentId;
  String nasCurrentName = '';
  List<({int? id, String name})> nasBackStack = [];
  List<({int? id, String name})> nasForwardStack = [];
  int? _pendingSelectAfterDelete;
  Map<String, String> placesAliases = {};
  Set<String> hiddenPlaces = {};
  List<MountMapping> mountMappings = [];
  String mountMappingNasDraft = '';
  String mountMappingLocalDraft = '';
  SidebarCtxMenu? fmSidebarRenameMenu;

  FmClipboard? fmClipboard;
  LocalCtxMenu? fmLocalCtxMenu;
  EmptyCtxMenu? fmEmptyCtxMenu;
  SidebarCtxMenu? fmSidebarCtxMenu;
  NasCtxMenu? fmNasCtxMenu;
  String fmEmptySubMenu = '';
  Offset? fmEmptySubMenuAnchor;
  String fmItemSubMenu = '';
  Offset? fmItemSubMenuAnchor;
  Timer? _emptySubMenuTimer;
  Timer? _itemSubMenuTimer;

  FileItemDto? fmPropertiesFile;
  ({String path, String name})? folderIconPicker;

  Map<String, String> customFolderIcons = {};
  TrashSettings trashSettings = const TrashSettings();
  String? selectionAnchorPath;

  bool fmShowRename = false;
  String fmRenamePath = '';
  String fmRenameValue = '';
  bool fmRenameBulk = false;

  // Delete-permanently confirmation
  bool fmShowDeleteConfirm = false;
  List<String> fmDeleteConfirmPaths = [];
  bool fmDeleteConfirmIsNas = false;

  // Paste conflict resolution
  bool fmShowPasteConflict = false;
  List<String> fmPasteConflictNames = [];
  FmClipboard? fmPendingPaste;
  String fmPendingPasteDestDir = '';

  // Rename extension change warning
  bool fmShowExtWarn = false;
  String fmExtWarnPendingName = '';

  // Undo stack (rename + trash)
  final List<FmUndoItem> undoStack = [];

  List<LocalTab> localTabs = [
    const LocalTab(id: 'tab_1', label: 'Home', path: '/'),
  ];
  String activeLocalTabId = 'tab_1';

  String demoFolderPath = '';
  String demoStatus = '';
  List<FileItemDto> demoFiles = [];
  bool demoLoading = false;
  String demoError = '';

  StreamSubscription<FileStreamEvent>? _fileStreamSub;
  StreamSubscription<FileStreamEvent>? _demoStreamSub;
  StreamSubscription<String>? _sseSub;
  StreamSubscription<String>? _sseAdminSub;
  Timer? _sseFallbackTimer;
  Timer? _sseReconnectTimer;
  int _fileStreamGeneration = 0;
  int _demoStreamGeneration = 0;
  String? _watchedPath;
  StreamSubscription<FileSystemEvent>? _localDirWatcher;
  StreamSubscription<FileSystemEvent>? _localParentWatcher;

  Brightness platformBrightness = Brightness.light;

  void updatePlatformBrightness(Brightness brightness) {
    if (platformBrightness != brightness) {
      platformBrightness = brightness;
      notifyListeners();
    }
  }

  bool get isDark {
    switch (settings.theme) {
      case 'dark':
        return true;
      case 'light':
        return false;
      default:
        return platformBrightness == Brightness.dark;
    }
  }

  DatieveColors get colors =>
      isDark ? DatieveColors.dark : DatieveColors.light;

  bool get syncing =>
      syncStatus.toLowerCase().contains('sync') &&
      !syncStatus.toLowerCase().contains('healthy');

  /// Inline NAS content phase when [viewMode] is `nas` (matches App.tsx FileManager).
  String? get nasInlinePhase {
    if (viewMode != 'nas') return null;
    final a = agent;
    if (a == null) return 'discovery';
    if (a.demo) return 'demo';
    if (!a.isSetup) return 'setup';
    if (session == null) return 'login';
    return null;
  }

  List<FileItemDto> get visibleFmFiles {
    final visible = computeVisibleFiles(
      source: fmFiles,
      showHidden: fmMeta.showHidden,
      localSearchMode: localSearchMode,
      searchResults: localSearchResults,
      filters: fmSearchFilters,
      sortBy: settings.sortBy,
      sortDir: settings.sortDir,
      foldersFirst: settings.foldersFirst,
      tagAssignments: tagAssignments,
      fileTags: fileTags,
    );
    return visible.all;
  }

  @override
  void dispose() {
    _fileStreamSub?.cancel();
    _demoStreamSub?.cancel();
    _sseSub?.cancel();
    _sseAdminSub?.cancel();
    _sseFallbackTimer?.cancel();
    _emptySubMenuTimer?.cancel();
    _itemSubMenuTimer?.cancel();
    _localDirWatcher?.cancel();
    _localParentWatcher?.cancel();
    super.dispose();
  }

  static const kAppVersion = '1.0.0';

  Future<void> init() async {
    settings = getSettings();
    portDraft = settings.scanPort.toString();
    places = getPlaces();
    customPlaces = loadCustomPlaces();
    hiddenDevices = loadHiddenDevices();
    placesAliases = loadPlacesAliases();
    hiddenPlaces = loadHiddenPlaces();
    mountMappings = loadMountMappings();
    customFolderIcons = loadCustomFolderIcons();
    trashSettings = loadTrashSettings();
    viewMode = setViewMode(mode: 'local');
    screen = AppScreen.fileManager;
    _rebuildCrumbsFromPath(getLocalCurrentPath());
    await refreshFileManager();
    await _runTrashAutoPurge();
    loading = false;
    notifyListeners();
    unawaited(_checkForUpdate());
  }

  Future<void> _checkForUpdate() async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);
      final req = await client.getUrl(
        Uri.parse('https://api.github.com/repos/Datieve/datieve/releases/latest'),
      );
      req.headers.set('User-Agent', 'datieve-app/$kAppVersion');
      req.headers.set('Accept', 'application/vnd.github+json');
      final resp = await req.close();
      if (resp.statusCode != 200) return;
      final body = await resp.transform(const Utf8Decoder()).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final tag = ((data['tag_name'] as String?) ?? '').replaceFirst('v', '');
      if (tag.isNotEmpty && _isNewerVersion(tag, kAppVersion)) {
        updateAvailableVersion = tag;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> openReleasePage() async {
    const url = 'https://github.com/Datieve/datieve/releases/latest';
    if (Platform.isLinux) {
      await Process.run('xdg-open', [url]);
    } else if (Platform.isMacOS) {
      await Process.run('open', [url]);
    } else if (Platform.isWindows) {
      await Process.run('cmd', ['/c', 'start', url]);
    }
  }

  static bool _isNewerVersion(String latest, String current) {
    List<int> parse(String s) =>
        s.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    final l = parse(latest);
    final c = parse(current);
    for (var i = 0; i < 3; i++) {
      final lv = i < l.length ? l[i] : 0;
      final cv = i < c.length ? c[i] : 0;
      if (lv > cv) return true;
      if (lv < cv) return false;
    }
    return false;
  }

  Future<void> _runTrashAutoPurge() async {
    if (!trashSettings.autoDeleteEnabled) return;
    try {
      final removed = purgeOldTrashItems(maxAgeDays: trashSettings.autoDeleteDays);
      if (removed > 0 && isTrashView) {
        await refreshFileManager();
      }
    } catch (_) {}
  }

  void setTrashAutoDeleteDays(int days) {
    trashSettings = trashSettings.copyWith(autoDeleteDays: days.clamp(0, 365));
    saveTrashSettings(trashSettings);
    notifyListeners();
    unawaited(_runTrashAutoPurge());
  }

  void setCustomFolderIcon(String path, String iconId) {
    final next = Map<String, String>.from(customFolderIcons);
    next[path] = normalizeFolderIconId(iconId);
    customFolderIcons = next;
    saveCustomFolderIcons(customFolderIcons);
    notifyListeners();
  }

  void clearCustomFolderIcon(String path) {
    final next = Map<String, String>.from(customFolderIcons);
    next.remove(path);
    customFolderIcons = next;
    saveCustomFolderIcons(customFolderIcons);
    notifyListeners();
  }

  void openFolderIconPicker(String path, String name) {
    closeAllMenus();
    folderIconPicker = (path: path, name: name);
    notifyListeners();
  }

  void closeFolderIconPicker() {
    folderIconPicker = null;
    notifyListeners();
  }

  Future<void> refreshDiscovery({bool autoSelect = false}) async {
    scanning = true;
    discoveryError = '';
    _autoSelected = false;
    notifyListeners();
    agents = await discoverAgents();
    scanning = false;
    notifyListeners();
    if (autoSelect && !_autoSelected && agents.isNotEmpty) {
      _autoSelected = true;
      await selectAgent(agents.first.ip, fingerprint: agents.first.fingerprint);
    }
  }

  Future<void> selectAgent(String ip, {String? fingerprint}) async {
    connecting = true;
    connectingIp = ip;
    discoveryError = '';
    notifyListeners();
    final skipLogin = _skipAutoCodeLogin;
    final result = await connectAgent(ip: ip, fingerprint: fingerprint, skipAutoLogin: skipLogin);
    connecting = false;
    connectingIp = null;
    if (result.error != null) {
      discoveryError = result.error!;
      try {
        deletePinnedFingerprint(agentIp: ip);
      } catch (_) {}
      notifyListeners();
      return;
    }
    agent = result.agent;
    // Rust now returns accounts on all routes so the account chooser is
    // populated even after auto-login or soft logout.
    loginAccounts = result.loginAccounts;
    loginShowCode = loginAccounts.isEmpty;
    screen = AppScreen.fileManager;
    await _handlePostConnect(result.screen);
    notifyListeners();
  }

  Future<void> _handlePostConnect(String route) async {
    switch (route) {
      case 'file-manager':
        session = getSessionInfo();
        await refreshFileManager();
        _startSse();
      case 'demo':
        startDemoStream();
      case 'setup':
        setup = getSetupState();
      case 'login':
        session = null;
    }
  }

  /// Soft logout: clears the session but keeps the agent connected so the UI
  /// immediately shows the account chooser for the same NAS.
  void softLogout() {
    _fileStreamSub?.cancel();
    _demoStreamSub?.cancel();
    _stopSse();
    logoutSession();  // Rust: clears b.session + persisted token, keeps b.agent
    session = null;
    loginError = '';
    loginCode = '';
    managementUnlocked = false;
    loginShowCode = loginAccounts.isEmpty;
    notifyListeners();
  }

  void disconnect() {
    _fileStreamSub?.cancel();
    _demoStreamSub?.cancel();
    _stopSse();
    disconnectAgent();
    _skipAutoCodeLogin = true;  // Next connect must show login, not auto-login
    agent = null;
    session = null;
    loginAccounts = [];
    loginError = '';
    loginCode = '';
    revokedUsername = '';
    discoveryError = '';
    nasSearchActive = false;
    fmSearchQuery = '';
    managementUnlocked = false;
    screen = AppScreen.fileManager;
    if (viewMode == 'nas') {
      refreshDiscovery();
    }
    notifyListeners();
  }

  Future<void> login(String code) async {
    loginLoading = true;
    loginError = '';
    notifyListeners();
    try {
      session = await loginWithCode(code: code);
      _skipAutoCodeLogin = false;
      final s = session;
      if (s != null) {
        final newAcc = AccountDto(username: s.username, role: s.role, code: code);
        final idx = loginAccounts.indexWhere((a) => a.username == newAcc.username);
        if (idx >= 0) {
          loginAccounts = [...loginAccounts]..[idx] = newAcc;
        } else {
          loginAccounts = [newAcc, ...loginAccounts];
        }
      }
      await refreshFileManager();
      _startSse();
    } catch (e) {
      loginError = e.toString();
    }
    loginLoading = false;
    notifyListeners();
  }

  Future<void> setupNext() async {
    var s = _applySetupDefaults(setup);
    setup = updateSetupState(state: s);
    try {
      setup = setupNextStep();
      setupError = '';
    } catch (e) {
      setupError = e.toString();
    }
    notifyListeners();
  }

  SetupStateDto _applySetupDefaults(SetupStateDto s) {
    // Auto-fill hidden username fields so the user only needs to enter passwords.
    if (s.adminUsername.trim().isEmpty) s = s.copyWith(adminUsername: 'admin');
    if (s.manageUsername.trim().isEmpty) s = s.copyWith(manageUsername: 'admin');
    return s;
  }

  void setupBack() {
    if (setup.step <= 1) {
      disconnect();
      return;
    }
    setup = setupPrevStep();
    notifyListeners();
  }

  Future<void> setupFinish() async {
    setupLoading = true;
    setupError = '';
    notifyListeners();
    final adminCode = setup.adminCode.trim();
    try {
      setup = updateSetupState(state: _applySetupDefaults(setup));
      await setupFinalize();
      agent = getCurrentAgent();
      loginAccounts = [];
      loginError = '';
      if (adminCode.isNotEmpty) {
        session = await loginWithCode(code: adminCode);
        _skipAutoCodeLogin = false;
        final s = session;
        if (s != null) {
          loginAccounts = [
            AccountDto(username: s.username, role: s.role, code: adminCode),
          ];
        }
        loginShowCode = false;
        await refreshFileManager();
        _startSse();
      } else {
        loginShowCode = true;
        loginCode = '';
      }
    } catch (e) {
      setupError = e.toString();
    }
    setupLoading = false;
    notifyListeners();
  }

  void _listenFileStream(Stream<FileStreamEvent> stream) {
    final gen = ++_fileStreamGeneration;
    _fileStreamSub?.cancel();
    fmFiles = [];
    fmLoading = true;
    fmError = '';
    if (viewMode == 'nas' && _nasCurrentParentId == null) nasNavRoots = [];
    notifyListeners();

    final List<FileItemDto> pending = [];
    final List<FileItemDto> pendingRoots = [];

    void flush() {
      if (pending.isNotEmpty) {
        fmFiles = [...fmFiles, ...pending];
        pending.clear();
      }
      if (pendingRoots.isNotEmpty) {
        nasNavRoots = [...nasNavRoots, ...pendingRoots];
        pendingRoots.clear();
      }
    }

    _fileStreamSub = stream.listen(
      (event) {
        if (gen != _fileStreamGeneration) return;
        switch (event.eventType) {
          case 'meta':
            if (event.meta != null) fmMeta = event.meta!;
            notifyListeners();
          case 'item':
            if (event.item != null) {
              final item = event.item!;
              pending.add(item);
              if (viewMode == 'nas' && _nasCurrentParentId == null && item.isDir) {
                pendingRoots.add(item);
              }
              if (pending.length >= 50) {
                flush();
                notifyListeners();
              }
            }
          case 'done':
            flush();
            // Entries can arrive in filesystem order (not sorted) since the
            // backend now streams them as they're discovered rather than
            // waiting to sort the whole directory first — sort once here so
            // the final view is still folders-first, alphabetical.
            final sorted = [...fmFiles];
            sorted.sort((a, b) {
              if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
              return a.name.toLowerCase().compareTo(b.name.toLowerCase());
            });
            fmFiles = sorted;
            fmLoading = false;
            if (event.message != null && event.message!.isNotEmpty) {
              fmMeta = FileListMetaDto(
                currentPath: fmMeta.currentPath,
                canBack: fmMeta.canBack,
                canForward: fmMeta.canForward,
                showHidden: fmMeta.showHidden,
                status: event.message!,
              );
            }
            final pendingIdx = _pendingSelectAfterDelete;
            if (pendingIdx != null && fmFiles.isNotEmpty) {
              _pendingSelectAfterDelete = null;
              final idx = pendingIdx.clamp(0, fmFiles.length - 1);
              fmSelectedPaths = {fmFiles[idx].path};
              fmSelectedFile = fmFiles[idx];
            }
            notifyListeners();
          case 'error':
            flush();
            fmLoading = false;
            fmError = event.message ?? 'Unknown stream error';
            notifyListeners();
        }
      },
      onError: (Object e) {
        if (gen != _fileStreamGeneration) return;
        fmLoading = false;
        fmError = e.toString();
        if (fmError.contains('login_required')) {
          session = null;
        }
        notifyListeners();
      },
      onDone: () {
        if (gen != _fileStreamGeneration) return;
        fmLoading = false;
        notifyListeners();
      },
    );
  }

  Future<void> refreshFileManager() async {
    session = getSessionInfo();
    agent = getCurrentAgent();
    places = getPlaces();
    mounts = getMounts();
    bookmarks = loadBookmarks();
    trashPath = getTrashPath();
    fileTags = loadFileTags();
    tagAssignments = loadTagAssignments();
    notifyListeners();

    _setupLocalDirWatcher();

    if (localSearchMode == 'recursive' || localSearchMode == 'tag') {
      return;
    }
    if (viewMode == 'nas') {
      _listenFileStream(streamNasFiles(parentId: _nasCurrentParentId));
    } else {
      _listenFileStream(streamLocalFiles());
    }
  }

  Future<void> nasNavigateBack() async {
    if (nasBackStack.isEmpty) return;
    nasSearchActive = false;
    fmSearchQuery = '';
    final agentName = agent?.hostname ?? 'NAS';
    final prev = nasBackStack.last;
    nasForwardStack = [...nasForwardStack, (id: _nasCurrentParentId, name: nasCurrentName.isEmpty ? agentName : nasCurrentName)];
    nasBackStack = nasBackStack.sublist(0, nasBackStack.length - 1);
    _nasCurrentParentId = prev.id;
    nasCurrentName = prev.name;
    _listenFileStream(streamNasFiles(parentId: prev.id));
    notifyListeners();
  }

  Future<void> nasNavigateForward() async {
    if (nasForwardStack.isEmpty) return;
    nasSearchActive = false;
    fmSearchQuery = '';
    final agentName = agent?.hostname ?? 'NAS';
    final next = nasForwardStack.last;
    nasBackStack = [...nasBackStack, (id: _nasCurrentParentId, name: nasCurrentName.isEmpty ? agentName : nasCurrentName)];
    nasForwardStack = nasForwardStack.sublist(0, nasForwardStack.length - 1);
    _nasCurrentParentId = next.id;
    nasCurrentName = next.name;
    _listenFileStream(streamNasFiles(parentId: next.id));
    notifyListeners();
  }

  Future<void> nasNavigateHome() async {
    nasSearchActive = false;
    fmSearchQuery = '';
    nasBackStack = [];
    nasForwardStack = [];
    _nasCurrentParentId = null;
    nasCurrentName = '';
    _listenFileStream(streamNasFiles(parentId: null));
    notifyListeners();
  }

  Future<void> nasOpenRoot(FileItemDto root) async {
    nasSearchActive = false;
    fmSearchQuery = '';
    nasBackStack = [];
    nasForwardStack = [];
    final id = int.tryParse(root.parentPath);
    _nasCurrentParentId = id;
    nasCurrentName = root.name;
    _listenFileStream(streamNasFiles(parentId: id));
    notifyListeners();
  }

  Future<void> nasNavigateToBreadcrumb(int stackIndex) async {
    if (stackIndex < 0 || stackIndex >= nasBackStack.length) return;
    nasSearchActive = false;
    fmSearchQuery = '';
    final target = nasBackStack[stackIndex];
    final agentName = agent?.hostname ?? 'NAS';
    final currentEntry = (id: _nasCurrentParentId, name: nasCurrentName.isEmpty ? agentName : nasCurrentName);
    final fwdItems = nasBackStack.sublist(stackIndex + 1).map((e) => (id: e.id, name: e.name)).toList();
    nasForwardStack = [...fwdItems, currentEntry, ...nasForwardStack];
    nasBackStack = nasBackStack.sublist(0, stackIndex);
    _nasCurrentParentId = target.id;
    nasCurrentName = target.name;
    _listenFileStream(streamNasFiles(parentId: target.id));
    notifyListeners();
  }

  void _setupLocalDirWatcher() {
    if (viewMode != 'local' || localCurrentDir.isEmpty || localSearchMode != 'browse') {
      _cancelLocalDirWatchers();
      return;
    }

    if (_watchedPath == localCurrentDir) return;

    _cancelLocalDirWatchers();
    _watchedPath = localCurrentDir;

    try {
      final currentDir = Directory(localCurrentDir);
      if (currentDir.existsSync()) {
        _localDirWatcher = currentDir.watch().listen((event) {
          refreshFileManager();
        }, onError: (e) {
          _handleWatchedDirectoryMissing();
        });

        final parentDir = currentDir.parent;
        if (parentDir.existsSync() && parentDir.path != currentDir.path) {
          _localParentWatcher = parentDir.watch().listen((event) {
            if (!currentDir.existsSync()) {
              _handleWatchedDirectoryMissing();
            }
          }, onError: (e) {
            _handleWatchedDirectoryMissing();
          });
        }
      } else {
        _handleWatchedDirectoryMissing();
      }
    } catch (e) {
      // ignore
    }
  }

  void _handleWatchedDirectoryMissing() {
    var dir = Directory(localCurrentDir);
    while (true) {
      final parent = dir.parent;
      if (parent.path == dir.path) {
        unawaited(fmNavigateTo(parent.path));
        break;
      }
      if (parent.existsSync()) {
        unawaited(fmNavigateTo(parent.path));
        break;
      }
      dir = parent;
    }
  }

  void _cancelLocalDirWatchers() {
    _localDirWatcher?.cancel();
    _localDirWatcher = null;
    _localParentWatcher?.cancel();
    _localParentWatcher = null;
    _watchedPath = null;
  }

  void _startSse() {
    final auth = getSessionAuth();
    final ip = agent?.ip;
    if (auth == null || ip == null) return;

    _sseSub?.cancel();
    _sseAdminSub?.cancel();
    _sseFallbackTimer?.cancel();

    _sseSub = streamSseEvents(
      listenerId: 'fm_events',
      url: 'https://$ip/api/events',
      token: auth.token,
      macKey: auth.macKey,
    ).listen(
      (payload) {
        if (payload == 'FileChanged' || payload == 'changed') {
          if (viewMode == 'nas' && localSearchMode == 'browse') {
            refreshFileManager();
          } else {
            nasDirty = true;
          }
        } else {
          syncStatus = payload;
        }
        notifyListeners();
      },
      onError: (_) => _scheduleReconnect(),
      onDone: _scheduleReconnect,
      cancelOnError: false,
    );

    if (session?.isAdmin ?? false) {
      Future.delayed(const Duration(milliseconds: 500), () {
        if (agent?.ip != ip) return;
        _sseAdminSub = streamSseEvents(
          listenerId: 'fm_admin_sync',
          url: 'https://$ip/api/admin/system/sync/status',
          token: auth.token,
          macKey: auth.macKey,
        ).listen((payload) {
          syncStatus = payload;
          notifyListeners();
        });
      });
    }

    _sseFallbackTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (viewMode == 'nas') {
        // Don't auto-refresh NAS via timer — SSE events handle updates,
        // and calling refreshFileManager here was resetting navigation to root.
        nasDirty = true;
        notifyListeners();
      } else if (localSearchMode == 'browse') {
        refreshFileManager();
      } else {
        nasDirty = true;
        notifyListeners();
      }
    });
  }

  void _stopSse() {
    _sseReconnectTimer?.cancel();
    _sseReconnectTimer = null;
    _sseSub?.cancel();
    _sseAdminSub?.cancel();
    _sseFallbackTimer?.cancel();
    _sseSub = null;
    _sseAdminSub = null;
    _sseFallbackTimer = null;
    final ip = agent?.ip;
    if (ip != null) {
      stopSse(agent: ip);
    }
  }

  void _scheduleReconnect() {
    if (_sseReconnectTimer != null || agent?.ip == null) return;
    _sseReconnectTimer = Timer(const Duration(seconds: 5), () {
      _sseReconnectTimer = null;
      if (agent?.ip != null) _startSse();
    });
  }

  void toggleFmFilters() {
    fmShowFilters = !fmShowFilters;
    notifyListeners();
  }

  void setSearchFilters(FmSearchFilters next) {
    fmSearchFilters = next;
    notifyListeners();
  }

  void setLocalSearchQuery(String q) {
    localSearchQuery = q;
    if (q.trim().isEmpty) clearRecursiveSearch();
    notifyListeners();
  }

  int _searchGeneration = 0;

  Future<void> doRecursiveSearch([String? query]) async {
    final q = (query ?? localSearchQuery).trim();
    if (q.isEmpty || viewMode != 'local') return;
    final gen = ++_searchGeneration;
    localSearchMode = 'recursive';
    localSearchLoading = true;
    localSearchResults = [];
    notifyListeners();
    try {
      // Runs off the UI isolate on the Rust side (spawn_blocking), so this no
      // longer freezes the app for the duration of a large recursive scan.
      final entries = await fs_api.fsSearchRecursive(
        root: localCurrentDir,
        query: q,
        includeHidden: fmMeta.showHidden,
      );
      if (gen != _searchGeneration) return;
      localSearchResults = entries.map(searchEntryToFileItem).toList();
    } catch (_) {
      if (gen != _searchGeneration) return;
      localSearchResults = [];
    }
    localSearchLoading = false;
    notifyListeners();
  }

  void clearRecursiveSearch() {
    _searchGeneration++;
    fs_api.cancelSearch();
    localSearchMode = 'browse';
    localSearchResults = [];
    activeTagId = null;
    notifyListeners();
  }

  String addOperationCard(String kind, String label, [String message = 'Working...']) {
    final id = 'op_${DateTime.now().millisecondsSinceEpoch}';
    final card = FmOperationCard(
      id: id,
      kind: kind,
      label: label,
      status: 'in-progress',
      message: message,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    operationCards = [card, ...operationCards].take(40).toList();
    notifyListeners();
    return id;
  }

  void finishOperationCard(String id, String status, String message) {
    operationCards = operationCards
        .map((c) => c.id == id ? c.copyWith(status: status, message: message) : c)
        .toList();
    notifyListeners();
  }

  void _applyBatchResult(String cardId, fs_api.FsBatchResult result, String verb) {
    final total = result.succeeded.length + result.failed.length;
    if (result.failed.isEmpty) {
      finishOperationCard(cardId, 'done', '$verb ${result.succeeded.length} item${result.succeeded.length == 1 ? '' : 's'}');
    } else if (result.succeeded.isEmpty) {
      final msg = result.failed.first.error;
      finishOperationCard(cardId, 'failed', msg);
      fmError = msg;
      notifyListeners();
    } else {
      finishOperationCard(cardId, 'partial', '${result.succeeded.length} of $total succeeded');
      fmError = '${result.failed.length} item${result.failed.length == 1 ? '' : 's'} failed: ${result.failed.first.error}';
      notifyListeners();
    }
  }

  void _applyNasBatchResult(String cardId, dynamic result, String verb) {
    if (result == null) {
      finishOperationCard(cardId, 'done', verb);
      return;
    }
    final succeeded = (result['succeeded'] as List?)?.cast<String>() ?? <String>[];
    final failed = (result['failed'] as List?) ?? [];
    final total = succeeded.length + failed.length;
    if (failed.isEmpty) {
      finishOperationCard(cardId, 'done', '$verb ${succeeded.length} item${succeeded.length == 1 ? '' : 's'}');
    } else if (succeeded.isEmpty) {
      final msg = (failed.first as Map)['error']?.toString() ?? 'Operation failed';
      finishOperationCard(cardId, 'failed', msg);
      fmError = msg;
      notifyListeners();
    } else {
      finishOperationCard(cardId, 'partial', '${succeeded.length} of $total succeeded');
      fmError = '${failed.length} item${failed.length == 1 ? '' : 's'} failed: ${(failed.first as Map)['error']}';
      notifyListeners();
    }
  }

  void setDragOverPath(String? path) {
    dragOverPath = path;
    notifyListeners();
  }

  void startDragging(List<String> paths) {
    draggingPaths = paths;
    notifyListeners();
  }

  void finishDragging() {
    draggingPaths = [];
    dragOverPath = null;
    notifyListeners();
  }

  /// [internal] is true when the source is a Datieve tile being dragged
  /// within the app (which moves by default); external OS drags always copy.
  /// [forceCopy] reflects the copy-modifier key (Ctrl/Option) held at drop
  /// time, which overrides an internal drag to copy instead of move.
  Future<void> dropPathsIntoDir(
    List<String> paths,
    String destDir, {
    required bool internal,
    bool forceCopy = false,
  }) async {
    if (paths.isEmpty || destDir.isEmpty) return;
    final unique = paths.toSet().toList();

    // Filter out: folder dropped onto itself, folder dropped into its own subtree,
    // and files dropped into the folder they already live in (same-folder no-op).
    // Handles both POSIX (/) and Windows (\) separators.
    final filtered = unique.where((src) {
      if (_pathEq(src, destDir)) return false;
      if (_isSubpath(child: destDir, of: src)) return false;
      if (_pathEq(_pathParent(src), destDir)) return false;
      return true;
    }).toList();

    if (filtered.isEmpty) {
      finishDragging();
      return;
    }

    final doCopy = !internal || forceCopy;
    final cb = FmClipboard(op: doCopy ? 'copy' : 'move', paths: filtered, scope: 'local');

    // Pre-flight conflict check using actual filesystem stat, same as
    // pasteIntoFolder — reuses the existing keep-both/replace/skip dialog
    // instead of silently auto-renaming on a name collision.
    final candidatePaths = filtered.map((p) => '$destDir/${p.split('/').last}').toList();
    try {
      final existing = fs_api.fsStatPaths(paths: candidatePaths);
      if (existing.isNotEmpty) {
        final conflictNames = existing.map((e) => e.name).toList()..sort();
        fmPendingPaste = cb;
        fmPendingPasteDestDir = destDir;
        fmPasteConflictNames = conflictNames;
        fmShowPasteConflict = true;
        notifyListeners();
        return;
      }
    } catch (_) {
      // stat failure is non-fatal; proceed without pre-flight check.
    }

    await _executePaste(cb, destDir, 'rename');
  }

  Future<void> openOpenWithDialog(String path) async {
    // Windows has its own native "Open With" picker (the same one Explorer
    // uses) — call it directly instead of showing Datieve's own list dialog,
    // which only has a way to enumerate apps on Linux/macOS.
    if (Platform.isWindows) {
      closeAllMenus();
      fmError = '';
      try {
        fs_api.openWithDialogNative(path: path);
      } catch (e) {
        fmError = e.toString();
      }
      notifyListeners();
      return;
    }

    openWithDialog = OpenWithDialogState(path: path, apps: [], loading: true);
    closeAllMenus();
    notifyListeners();
    try {
      final mime = fs_api.getMimeType(path: path);
      final apps = fs_api.getAppsForMime(mimeType: mime, path: path);
      openWithDialog = OpenWithDialogState(path: path, apps: apps, loading: false);
    } catch (_) {
      openWithDialog = OpenWithDialogState(path: path, apps: [], loading: false);
    }
    notifyListeners();
  }

  void closeOpenWithDialog() {
    openWithDialog = null;
    notifyListeners();
  }

  Future<void> openWithApp(String appId, String path) async {
    fmError = '';
    try {
      await fs_api.openWithApp(appId: appId, path: path);
      closeOpenWithDialog();
    } catch (e) {
      fmError = e.toString();
      notifyListeners();
    }
  }

  void openTabCtxMenu(String tabId, double x, double y) {
    tabCtxMenu = TabCtxMenu(id: tabId, x: x, y: y);
    notifyListeners();
  }

  void closeTabCtxMenu() {
    tabCtxMenu = null;
    notifyListeners();
  }

  void duplicateLocalTab(String id) {
    final tab = localTabs.where((t) => t.id == id).firstOrNull;
    if (tab == null) return;
    final newId = 'tab_${DateTime.now().millisecondsSinceEpoch}';
    localTabs = [...localTabs, LocalTab(id: newId, label: tab.label, path: tab.path)];
    activeLocalTabId = newId;
    openLocalTab(localTabs.last);
    notifyListeners();
  }

  void closeOtherLocalTabs(String id) {
    if (localTabs.length <= 1) return;
    final keep = localTabs.where((t) => t.id == id).toList();
    closedLocalTabs = [
      ...closedLocalTabs,
      ...localTabs.where((t) => t.id != id),
    ].take(20).toList();
    localTabs = keep;
    activeLocalTabId = id;
    openLocalTab(keep.first);
    notifyListeners();
  }

  void closeTabsToRight(String id) {
    final idx = localTabs.indexWhere((t) => t.id == id);
    if (idx < 0 || idx >= localTabs.length - 1) return;
    closedLocalTabs = [
      ...closedLocalTabs,
      ...localTabs.sublist(idx + 1),
    ].take(20).toList();
    localTabs = localTabs.sublist(0, idx + 1);
    activeLocalTabId = id;
    notifyListeners();
  }

  void reopenClosedLocalTab() {
    if (closedLocalTabs.isEmpty) return;
    final tab = closedLocalTabs.first;
    closedLocalTabs = closedLocalTabs.sublist(1);
    localTabs = [...localTabs, tab];
    activeLocalTabId = tab.id;
    openLocalTab(tab);
    notifyListeners();
  }

  Future<void> switchView(String mode) async {
    viewMode = setViewMode(mode: mode);
    if (mode == 'local') {
      _resetBrowseContext();
    }
    if (mode == 'nas') {
      if (agent == null) {
        await refreshDiscovery(autoSelect: true);
      } else if (session != null) {
        if (nasDirty) nasDirty = false;
        await refreshFileManager();
      }
      notifyListeners();
      return;
    }
    await refreshFileManager();
    notifyListeners();
  }

  String _pathLabel(String path) {
    if (path.isEmpty || path == '/') return '/';
    return path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? path;
  }

  String _labelForPath(String path) {
    for (final p in places) {
      if (p.path == path) return p.label;
    }
    for (final m in mounts) {
      if (m.path == path) return m.label;
    }
    if (trashPath == path) return 'Trash';
    return _pathLabel(path);
  }

  void _rebuildCrumbsFromPath(String path) {
    if (path.isEmpty || path == '/') {
      localBreadcrumbs = [(label: 'System', path: '/')];
      return;
    }

    final String _envHome = Platform.environment['HOME']
        ?? Platform.environment['USERPROFILE']
        ?? '';
    final homePlace = places.firstWhere(
      (p) => p.label == 'Home',
      orElse: () => PlaceDto(label: 'Home', path: _envHome),
    );
    final homePath = homePlace.path.isNotEmpty ? homePlace.path : _envHome;

    final List<({String label, String path})> crumbs = [];
    if (homePath.isNotEmpty && path.startsWith(homePath)) {
      crumbs.add((label: 'Home', path: homePath));
      final relative = path.substring(homePath.length);
      final segments = relative.split('/').where((s) => s.isNotEmpty).toList();
      var acc = homePath;
      for (final seg in segments) {
        acc = acc == '/' ? '/$seg' : '$acc/$seg';
        crumbs.add((label: _labelForPath(acc), path: acc));
      }
    } else {
      crumbs.add((label: 'System', path: '/'));
      final segments = path.split('/').where((s) => s.isNotEmpty).toList();
      var acc = '';
      for (final seg in segments) {
        acc += '/$seg';
        crumbs.add((label: _labelForPath(acc), path: acc));
      }
    }
    localBreadcrumbs = crumbs;
  }

  void _resetBrowseContext() {
    localSearchMode = 'browse';
    localSearchQuery = '';
    localSearchResults = [];
    localSearchLoading = false;
    activeTagId = null;
  }

  Future<void> _navigateLocal(String path, List<({String label, String path})> crumbs) async {
    viewMode = setViewMode(mode: 'local');
    _resetBrowseContext();
    clearSelection();
    localBreadcrumbs = crumbs;
    fmMeta = localNavigate(path: path);
    _syncActiveLocalTab(path, crumbs);
    _listenFileStream(streamLocalFiles());
    notifyListeners();
  }

  void _syncActiveLocalTab(String path, List<({String label, String path})> crumbs) {
    final label = crumbs.isNotEmpty ? crumbs.last.label : _pathLabel(path);
    localTabs = localTabs
        .map((t) => t.id == activeLocalTabId ? t.copyWith(label: label, path: path) : t)
        .toList();
  }

  Future<void> openLocalRoot(String path, String label) async {
    _rebuildCrumbsFromPath(path);
    await _navigateLocal(path, localBreadcrumbs);
  }

  Future<void> openPathInNewTab(String path, String label) async {
    final id = 'tab_${DateTime.now().millisecondsSinceEpoch}';
    final tab = LocalTab(id: id, label: label, path: path);
    localTabs = [...localTabs, tab];
    activeLocalTabId = id;
    await openLocalRoot(path, label);
  }

  String placeLabel(PlaceDto place) => placesAliases[place.path] ?? place.label;

  void hidePlace(String path) {
    hiddenPlaces = {...hiddenPlaces, path};
    saveHiddenPlaces(hiddenPlaces);
    notifyListeners();
  }

  void addToPlaces(String path, String label) {
    if (customPlaces.any((p) => p.path == path)) return;
    customPlaces = [...customPlaces, CustomPlace(label: label, path: path)];
    saveCustomPlaces(customPlaces);
    notifyListeners();
  }

  void removeCustomPlace(String path) {
    customPlaces = customPlaces.where((p) => p.path != path).toList();
    saveCustomPlaces(customPlaces);
    notifyListeners();
  }

  void savePlaceAlias(String path, String label) {
    final next = Map<String, String>.from(placesAliases);
    if (label.trim().isEmpty) {
      next.remove(path);
    } else {
      next[path] = label.trim();
    }
    placesAliases = next;
    savePlacesAliases(placesAliases);
    notifyListeners();
  }

  void startSidebarRename(SidebarCtxMenu menu) {
    fmSidebarRenameMenu = menu;
    fmRenamePath = menu.path ?? menu.key;
    fmRenameValue = menu.label;
    fmRenameBulk = false;
    fmShowRename = true;
    closeAllMenus();
    notifyListeners();
  }

  void addMountMapping() {
    final nas = mountMappingNasDraft.trim();
    final local = mountMappingLocalDraft.trim();
    if (nas.isEmpty || local.isEmpty) return;
    mountMappings = [...mountMappings, MountMapping(nasPath: nas, localPath: local)];
    saveMountMappings(mountMappings);
    mountMappingNasDraft = '';
    mountMappingLocalDraft = '';
    notifyListeners();
  }

  void deleteMountMapping(int index) {
    if (index < 0 || index >= mountMappings.length) return;
    mountMappings = [...mountMappings]..removeAt(index);
    saveMountMappings(mountMappings);
    notifyListeners();
  }

  void setMountMappingNasDraft(String v) {
    mountMappingNasDraft = v;
    notifyListeners();
  }

  void setMountMappingLocalDraft(String v) {
    mountMappingLocalDraft = v;
    notifyListeners();
  }

  Future<void> openFile(FileItemDto item) async {
    if (viewMode == 'nas') {
      if (!item.isDir) {
        if (item.path.isEmpty) {
          fmError = 'File path unavailable. Trigger a rescan to update metadata.';
          notifyListeners();
          return;
        }
        // Hand non-directory NAS files entirely to the OS (works when the NAS is mounted).
        fmSelectedPaths = {item.path};
        fmSelectedFile = item;
        notifyListeners();
        try {
          await fs_api.openFileNative(path: item.path);
        } catch (e) {
          if (Platform.isLinux) {
            openOpenWithDialog(item.path);
          } else {
            fmError = e.toString();
            notifyListeners();
          }
        }
        return;
      }
      nasSearchActive = false;
      fmSearchQuery = '';
      final id = int.tryParse(item.parentPath);
      final prevName = nasCurrentName.isEmpty ? (agent?.hostname ?? 'NAS') : nasCurrentName;
      nasBackStack = [...nasBackStack, (id: _nasCurrentParentId, name: prevName)];
      nasForwardStack = [];
      _nasCurrentParentId = id;
      nasCurrentName = item.name;
      _listenFileStream(streamNasFiles(parentId: id));
      return;
    }
    // For symlinks, `is_dir` may be false if the Rust listing couldn't follow the
    // link at directory-scan time. Re-check with a live stat() so navigating into
    // a directory symlink always works.
    final effectiveIsDir = item.isDir ||
        (item.isSymlink && Directory(item.path).existsSync());
    if (effectiveIsDir) {
      final crumbs = [
        ...localBreadcrumbs,
        (label: item.name, path: item.path),
      ];
      await _navigateLocal(item.path, crumbs);
      return;
    }
    // Non-dir local file: open with system default; fall back to "Open With" dialog.
    fmSelectedPaths = {item.path};
    fmSelectedFile = item;
    notifyListeners();
    fmError = '';
    try {
      await fs_api.openFileNative(path: item.path);
    } catch (e) {
      if (Platform.isLinux) {
        openOpenWithDialog(item.path);
      } else {
        fmError = e.toString();
        notifyListeners();
      }
    }
  }

  void selectFile(FileItemDto item, {bool additive = false}) {
    if (additive) {
      final next = Set<String>.from(fmSelectedPaths);
      if (next.contains(item.path)) {
        next.remove(item.path);
      } else {
        next.add(item.path);
      }
      fmSelectedPaths = next;
      fmSelectedFile = next.contains(item.path) ? item : null;
    } else {
      fmSelectedPaths = {item.path};
      fmSelectedFile = item;
    }
    selectionAnchorPath = item.path;
    notifyListeners();
  }

  void selectFileWithModifiers(
    FileItemDto item, {
    required bool ctrl,
    required bool shift,
  }) {
    final files = visibleFmFiles;
    if (shift && selectionAnchorPath != null) {
      final anchorIdx = files.indexWhere((f) => f.path == selectionAnchorPath);
      final clickIdx = files.indexWhere((f) => f.path == item.path);
      if (anchorIdx >= 0 && clickIdx >= 0) {
        final start = anchorIdx < clickIdx ? anchorIdx : clickIdx;
        final end = anchorIdx > clickIdx ? anchorIdx : clickIdx;
        final range = files.sublist(start, end + 1).map((f) => f.path).toSet();
        fmSelectedPaths = ctrl ? {...fmSelectedPaths, ...range} : range;
        fmSelectedFile = item;
        notifyListeners();
        return;
      }
    }
    if (ctrl) {
      selectFile(item, additive: true);
      return;
    }
    selectFile(item, additive: false);
  }

  void clearSelection() {
    fmSelectedPaths = {};
    fmSelectedFile = null;
    selectionAnchorPath = null;
    notifyListeners();
  }

  void setSelectedPaths(Set<String> paths) {
    fmSelectedPaths = paths;
    notifyListeners();
  }

  void addFileTag({String? name, String? color}) {
    final id = 'tag_${DateTime.now().millisecondsSinceEpoch}';
    final tag = FileTag(
      id: id,
      name: name?.trim().isNotEmpty == true ? name!.trim() : 'New Tag',
      color: color ?? '#64748b',
    );
    fileTags = [...fileTags, tag];
    saveFileTags(fileTags);
    notifyListeners();
  }

  void changeFileTagColor(String id, String color) {
    fileTags = fileTags
        .map((t) => t.id == id ? FileTag(id: t.id, name: t.name, color: color) : t)
        .toList();
    saveFileTags(fileTags);
    notifyListeners();
  }

  void renameFileTag(String id, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    fileTags = fileTags
        .map((t) => t.id == id ? FileTag(id: t.id, name: trimmed, color: t.color) : t)
        .toList();
    saveFileTags(fileTags);
    notifyListeners();
  }

  void removeFileTag(String id) {
    fileTags = fileTags.where((t) => t.id != id).toList();
    final next = Map<String, List<String>>.from(tagAssignments);
    next.updateAll((_, tags) => tags.where((t) => t != id).toList());
    next.removeWhere((_, tags) => tags.isEmpty);
    tagAssignments = next;
    saveFileTags(fileTags);
    saveTagAssignments(tagAssignments);
    if (activeTagId == id) {
      activeTagId = null;
      localSearchMode = 'browse';
      localSearchQuery = '';
      localSearchResults = [];
    }
    notifyListeners();
  }

  void selectAllFiles() {
    final files = visibleFmFiles;
    fmSelectedPaths = files.map((f) => f.path).toSet();
    fmSelectedFile = files.isNotEmpty ? files.first : null;
    notifyListeners();
  }

  Future<void> fmNavigateTo(String path) async {
    if (viewMode == 'nas') return;
    _resetBrowseContext();
    _rebuildCrumbsFromPath(path);
    fmMeta = localNavigate(path: path);
    _syncActiveLocalTab(path, localBreadcrumbs);
    _listenFileStream(streamLocalFiles());
    clearSelection();
    notifyListeners();
  }

  void toggleInfoPane() {
    final next = !settings.showInfoPane;
    settings = saveSettings(settings: settings.copyWith(showInfoPane: next));
    notifyListeners();
  }

  void setInfoPaneTab(String tab) {
    settings = saveSettings(settings: settings.copyWith(infoPaneTab: tab));
    notifyListeners();
  }

  void closeInfoPane() {
    settings = saveSettings(settings: settings.copyWith(showInfoPane: false));
    notifyListeners();
  }

  void openCommandPalette() {
    fmCommandQuery = '';
    fmShowCommandPalette = true;
    notifyListeners();
  }

  void closeCommandPalette() {
    fmShowCommandPalette = false;
    notifyListeners();
  }

  void requestPathEdit() {
    fmRequestPathEdit = true;
    notifyListeners();
  }

  void clearPathEditRequest() {
    fmRequestPathEdit = false;
    // no notify needed — breadcrumb clears this synchronously
  }

  void openShortcuts() {
    fmShowShortcuts = true;
    notifyListeners();
  }

  void closeShortcuts() {
    fmShowShortcuts = false;
    notifyListeners();
  }

  void openAddBookmark() {
    bookmarkDraftLabel = fmMeta.currentPath.split('/').where((s) => s.isNotEmpty).lastOrNull ?? 'Home';
    bookmarkDraftPath = fmMeta.currentPath.isEmpty ? '/' : fmMeta.currentPath;
    fmShowAddBookmark = true;
    notifyListeners();
  }

  void closeAddBookmark() {
    fmShowAddBookmark = false;
    notifyListeners();
  }

  void setBookmarkDraftLabel(String v) {
    bookmarkDraftLabel = v;
    notifyListeners();
  }

  void setBookmarkDraftPath(String v) {
    bookmarkDraftPath = v;
    notifyListeners();
  }

  void addBookmark() {
    final path = bookmarkDraftPath.trim();
    if (path.isEmpty) return;
    final label = bookmarkDraftLabel.trim().isEmpty
        ? path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? path
        : bookmarkDraftLabel.trim();
    final id = 'bm_${DateTime.now().millisecondsSinceEpoch}';
    bookmarks = [...bookmarks, Bookmark(id: id, label: label, path: path)];
    saveBookmarks(bookmarks);
    fmShowAddBookmark = false;
    notifyListeners();
  }

  void removeBookmark(String id) {
    bookmarks = bookmarks.where((b) => b.id != id).toList();
    saveBookmarks(bookmarks);
    notifyListeners();
  }

  Future<void> openBookmark(Bookmark bm) async {
    await openLocalRoot(bm.path, bm.label);
  }

  Future<void> openMount(MountEntryDto mount) async {
    await openLocalRoot(mount.path, mount.label);
  }

  List<PaletteCommand> buildPaletteCommands() {
    return [
      PaletteCommand(
        label: 'Refresh',
        detail: 'Reload the current view',
        category: 'Navigation',
        run: refreshFileManager,
      ),
      PaletteCommand(
        label: 'New Tab',
        detail: 'Open a new local tab at Home',
        category: 'Tabs',
        run: newLocalTab,
      ),
      PaletteCommand(
        label: 'Close Tab',
        detail: 'Close the current local tab',
        category: 'Tabs',
        enabled: localTabs.length > 1,
        run: () => closeLocalTab(activeLocalTabId),
      ),
      PaletteCommand(
        label: 'Navigate Home',
        detail: 'Open the local home folder',
        category: 'Navigation',
        enabled: viewMode == 'local',
        run: fmHome,
      ),
      PaletteCommand(
        label: 'Toggle Hidden Files',
        detail: 'Show or hide dotfiles',
        category: 'Show',
        enabled: viewMode == 'local',
        run: fmToggleHidden,
      ),
      PaletteCommand(
        label: 'Toggle Details Pane',
        detail: 'Show or hide the details and preview pane',
        category: 'Show',
        run: toggleInfoPane,
      ),
      PaletteCommand(
        label: 'Show Details Tab',
        detail: 'Switch the info pane to details',
        category: 'Show',
        run: () {
          settings = saveSettings(
            settings: settings.copyWith(showInfoPane: true, infoPaneTab: 'details'),
          );
          notifyListeners();
        },
      ),
      PaletteCommand(
        label: 'Show Preview Tab',
        detail: 'Switch the info pane to preview',
        category: 'Show',
        run: () {
          settings = saveSettings(
            settings: settings.copyWith(showInfoPane: true, infoPaneTab: 'preview'),
          );
          notifyListeners();
        },
      ),
      PaletteCommand(
        label: 'Select All',
        detail: 'Select all visible items',
        category: 'Selection',
        run: selectAllFiles,
      ),
      PaletteCommand(
        label: 'Clear Selection',
        detail: 'Clear selected items',
        category: 'Selection',
        enabled: fmSelectedPaths.isNotEmpty,
        run: clearSelection,
      ),
      PaletteCommand(
        label: 'List View',
        detail: 'Use detailed rows',
        category: 'Layout',
        enabled: viewMode == 'local',
        run: () {
          settings = saveSettings(settings: settings.copyWith(localViewStyle: 'list'));
          notifyListeners();
        },
      ),
      PaletteCommand(
        label: 'Compact View',
        detail: 'Use compact icon grid',
        category: 'Layout',
        enabled: viewMode == 'local',
        run: () {
          settings = saveSettings(settings: settings.copyWith(localViewStyle: 'compact'));
          notifyListeners();
        },
      ),
      PaletteCommand(
        label: 'Open Settings',
        detail: 'Open application settings',
        category: 'Open',
        run: openFmSettings,
      ),
      PaletteCommand(
        label: 'Switch Agent',
        detail: 'Return to agent selection',
        category: 'Navigation',
        run: disconnect,
      ),
    ];
  }

  Future<void> fmBack() async {
    fmMeta = localBack();
    _rebuildCrumbsFromPath(fmMeta.currentPath);
    _syncActiveLocalTab(fmMeta.currentPath, localBreadcrumbs);
    _listenFileStream(streamLocalFiles());
    notifyListeners();
  }

  Future<void> fmForward() async {
    fmMeta = localForward();
    _rebuildCrumbsFromPath(fmMeta.currentPath);
    _syncActiveLocalTab(fmMeta.currentPath, localBreadcrumbs);
    _listenFileStream(streamLocalFiles());
    notifyListeners();
  }

  Future<void> fmHome() async {
    fmMeta = localHome();
    _rebuildCrumbsFromPath(fmMeta.currentPath);
    _syncActiveLocalTab(fmMeta.currentPath, localBreadcrumbs);
    _listenFileStream(streamLocalFiles());
    notifyListeners();
  }

  Future<void> fmToggleHidden() async {
    fmMeta = localToggleHidden();
    _listenFileStream(streamLocalFiles());
    notifyListeners();
  }

  Future<void> fmOpenPlace(String path) async {
    final place = places.where((p) => p.path == path).firstOrNull;
    await openLocalRoot(path, place?.label ?? _labelForPath(path));
  }

  void togglePortInput() {
    showPortInput = !showPortInput;
    notifyListeners();
  }

  void setLoginShowCode(bool show) {
    loginShowCode = show;
    notifyListeners();
  }

  void setLoginCode(String code) {
    loginCode = code;
    notifyListeners();
  }

  void forgetStoredAccount(String code) {
    forgetAccount(code: code);
    loginAccounts.removeWhere((a) => a.code == code);
    if (loginAccounts.isEmpty) loginShowCode = true;
    notifyListeners();
  }

  void setDemoFolderPath(String path) {
    demoFolderPath = path;
    notifyListeners();
  }

  void patchSetup(SetupStateDto next) {
    setup = next;
    notifyListeners();
  }

  void closeFmSettings() {
    fmShowSettings = false;
    notifyListeners();
  }

  void openFmSettings() {
    fmShowSettings = true;
    notifyListeners();
  }

  void setFmSearchQuery(String q) {
    fmSearchQuery = q;
    if (q.trim().isEmpty) nasSearchActive = false;
    notifyListeners();
  }

  Future<void> submitNasSearch() async {
    if (viewMode != 'nas' || fmSearchQuery.trim().isEmpty) return;
    nasSearchActive = true;
    fmFiles = [];
    fmLoading = true;
    fmError = '';
    notifyListeners();
    _listenFileStream(streamNasSearch(query: fmSearchQuery.trim()));
  }

  void setTheme(String theme) {
    settings = saveTheme(theme: theme);
    notifyListeners();
  }

  void updateSettings(AppSettingsDto next) {
    settings = saveSettings(settings: next);
    notifyListeners();
  }

  void resetAllSettings() {
    settings = resetSettings();
    notifyListeners();
  }

  void zoomIn() {
    gridZoom = (gridZoom + 0.14).clamp(0.56, 2.8);
    notifyListeners();
  }

  void zoomOut() {
    gridZoom = (gridZoom - 0.14).clamp(0.56, 2.8);
    notifyListeners();
  }

  void resetZoom() {
    gridZoom = 1.4;
    notifyListeners();
  }

  void nextLocalTab() {
    if (localTabs.length <= 1) return;
    final idx = localTabs.indexWhere((t) => t.id == activeLocalTabId);
    final next = (idx + 1) % localTabs.length;
    openLocalTab(localTabs[next]);
  }

  void prevLocalTab() {
    if (localTabs.length <= 1) return;
    final idx = localTabs.indexWhere((t) => t.id == activeLocalTabId);
    final prev = (idx - 1 + localTabs.length) % localTabs.length;
    openLocalTab(localTabs[prev]);
  }

  void openFmAdmin() {
    fmShowAdmin = true;
    notifyListeners();
  }

  void closeFmAdmin() {
    fmShowAdmin = false;
    notifyListeners();
  }

  void newLocalTab() {
    final id = 'tab_${DateTime.now().millisecondsSinceEpoch}';
    final tab = LocalTab(id: id, label: 'Home', path: '/');
    localTabs = [...localTabs, tab];
    activeLocalTabId = id;
    fmHome();
    notifyListeners();
  }

  void closeLocalTab(String id) {
    if (localTabs.length <= 1) return;
    final idx = localTabs.indexWhere((t) => t.id == id);
    if (idx < 0) return;
    final closing = localTabs[idx];
    closedLocalTabs = [closing, ...closedLocalTabs].take(20).toList();
    final wasActive = activeLocalTabId == id;
    localTabs = [...localTabs]..removeAt(idx);
    if (wasActive) {
      final next = localTabs[idx.clamp(0, localTabs.length - 1)];
      activeLocalTabId = next.id;
      fmMeta = openPlace(path: next.path);
      refreshFileManager();
    }
    notifyListeners();
  }

  void openLocalTab(LocalTab tab) {
    activeLocalTabId = tab.id;
    viewMode = setViewMode(mode: 'local');
    fmMeta = openPlace(path: tab.path);
    refreshFileManager();
    notifyListeners();
  }

  void applyPort() {
    final p = int.tryParse(portDraft);
    if (p != null && p >= 1024 && p < 65536) {
      settings = saveScanPort(port: p);
      showPortInput = false;
      refreshDiscovery(autoSelect: true);
    }
  }

  void startDemoStream() {
    final gen = ++_demoStreamGeneration;
    _demoStreamSub?.cancel();
    demoFiles = [];
    demoLoading = true;
    demoError = '';
    notifyListeners();

    _demoStreamSub = streamDemoFiles().listen(
      (event) {
        if (gen != _demoStreamGeneration) return;
        switch (event.eventType) {
          case 'meta':
            if (event.meta != null) demoStatus = event.meta!.status;
          case 'item':
            if (event.item != null) demoFiles = [...demoFiles, event.item!];
          case 'done':
            demoLoading = false;
            if (event.message != null && event.message!.isNotEmpty) {
              demoStatus = event.message!;
            }
          case 'error':
            demoLoading = false;
            demoError = event.message ?? 'Unknown stream error';
        }
        notifyListeners();
      },
      onError: (Object e) {
        if (gen != _demoStreamGeneration) return;
        demoLoading = false;
        demoError = e.toString();
        notifyListeners();
      },
      onDone: () {
        if (gen != _demoStreamGeneration) return;
        demoLoading = false;
        notifyListeners();
      },
    );
  }

  Future<void> demoStart() async {
    if (demoFolderPath.trim().isEmpty) return;
    demoLoading = true;
    demoError = '';
    notifyListeners();
    try {
      await demoStartIndex(path: demoFolderPath.trim());
      startDemoStream();
    } catch (e) {
      demoError = e.toString();
      demoLoading = false;
      notifyListeners();
    }
  }

  String get localCurrentDir => getLocalCurrentPath();

  bool get isTrashView =>
      trashPath != null &&
      viewMode == 'local' &&
      localCurrentDir == trashPath;

  bool get isCompactView => settings.localViewStyle == 'compact';

  List<FileTag> tagsForPath(String path) {
    final ids = tagAssignments[normalizeTagPath(path)] ?? [];
    return ids
        .map((id) => fileTags.where((t) => t.id == id).firstOrNull)
        .whereType<FileTag>()
        .toList();
  }

  void toggleViewStyle() {
    final next = settings.localViewStyle == 'list' ? 'compact' : 'list';
    settings = saveSettings(settings: settings.copyWith(localViewStyle: next));
    notifyListeners();
  }

  Future<void> openTrash() async {
    final tp = trashPath;
    if (tp == null) return;
    viewMode = setViewMode(mode: 'local');
    fmMeta = openPlace(path: tp);
    _listenFileStream(streamLocalFiles());
    notifyListeners();
  }

  Future<void> restoreFromTrash() async {
    final paths = selectedLocalPaths;
    if (paths.isEmpty) return;
    clearSelection();
    fmError = '';
    notifyListeners();
    try {
      fs_api.fsRestoreTrash(paths: paths);
    } catch (e) {
      fmError = e.toString();
      notifyListeners();
      return;
    }
    unawaited(refreshFileManager());
  }

  Future<void> emptyTrash() async {
    clearSelection();
    fmError = '';
    notifyListeners();
    try {
      fs_api.fsEmptyTrash();
    } catch (e) {
      fmError = e.toString();
      notifyListeners();
      return;
    }
    unawaited(refreshFileManager());
  }

  void setTagOnPath(String path, String tagId, bool enabled) {
    final key = normalizeTagPath(path);
    final next = Map<String, List<String>>.from(tagAssignments);
    final current = Set<String>.from(next[key] ?? []);
    if (enabled) {
      current.add(tagId);
    } else {
      current.remove(tagId);
    }
    if (current.isEmpty) {
      next.remove(key);
    } else {
      next[key] = current.toList();
    }
    tagAssignments = next;
    saveTagAssignments(tagAssignments);
    notifyListeners();
  }

  Future<void> openTagView(String tagId) async {
    final tag = fileTags.where((t) => t.id == tagId).firstOrNull;
    if (tag == null) return;
    final paths = tagAssignments.entries
        .where((e) => e.value.contains(tagId))
        .map((e) => e.key)
        .toList();
    viewMode = setViewMode(mode: 'local');
    activeTagId = tagId;
    localSearchMode = 'tag';
    localSearchQuery = tag.name;
    localSearchLoading = true;
    localSearchResults = [];
    fmSelectedPaths = {};
    fmSelectedFile = null;
    notifyListeners();
    try {
      final entries = fs_api.fsStatPaths(paths: paths);
      localSearchResults = entries.map(searchEntryToFileItem).toList();
    } catch (_) {
      localSearchResults = [];
    }
    localSearchLoading = false;
    notifyListeners();
  }

  List<String> get selectedLocalPaths {
    if (fmSelectedPaths.isNotEmpty) return fmSelectedPaths.toList();
    if (fmSelectedFile != null) return [fmSelectedFile!.path];
    return [];
  }

  void closeAllMenus() {
    fmLocalCtxMenu = null;
    fmEmptyCtxMenu = null;
    fmSidebarCtxMenu = null;
    fmNasCtxMenu = null;
    tabCtxMenu = null;
    _emptySubMenuTimer?.cancel();
    _itemSubMenuTimer?.cancel();
    fmEmptySubMenu = '';
    fmEmptySubMenuAnchor = null;
    fmItemSubMenu = '';
    fmItemSubMenuAnchor = null;
    notifyListeners();
  }

  void setItemSubMenu(String id, [Offset? anchor]) {
    _itemSubMenuTimer?.cancel();
    fmItemSubMenu = id;
    if (anchor != null) fmItemSubMenuAnchor = anchor;
    if (id.isEmpty) fmItemSubMenuAnchor = null;
    notifyListeners();
  }

  void delayCloseItemSubMenu() {
    _itemSubMenuTimer = Timer(const Duration(milliseconds: 120), () {
      fmItemSubMenu = '';
      fmItemSubMenuAnchor = null;
      notifyListeners();
    });
  }

  void cancelCloseItemSubMenu() => _itemSubMenuTimer?.cancel();

  void openDeviceManager() {
    fmShowDeviceManager = true;
    notifyListeners();
  }

  void closeDeviceManager() {
    fmShowDeviceManager = false;
    notifyListeners();
  }

  void hideDevice(String path) {
    hiddenDevices = {...hiddenDevices, path};
    saveHiddenDevices(hiddenDevices);
    notifyListeners();
  }

  void showDevice(String path) {
    final next = Set<String>.from(hiddenDevices)..remove(path);
    hiddenDevices = next;
    saveHiddenDevices(hiddenDevices);
    notifyListeners();
  }

  void toggleNasExpanded() {
    nasExpanded = !nasExpanded;
    notifyListeners();
  }

  Future<void> openSidebarPath(String? path, String label) async {
    if (path == null || path.isEmpty) return;
    closeAllMenus();
    await openLocalRoot(path, label);
  }

  Future<void> openSidebarPathInNewTab(String path, String label) async {
    closeAllMenus();
    final id = 'tab_${DateTime.now().millisecondsSinceEpoch}';
    final tab = LocalTab(id: id, label: label, path: path);
    localTabs = [...localTabs, tab];
    activeLocalTabId = id;
    await openLocalRoot(path, label);
  }

  Future<void> copySidebarPath(String? path) async {
    if (path == null || path.isEmpty) return;
    closeAllMenus();
    await Clipboard.setData(ClipboardData(text: path));
  }

  Future<void> openSidebarTerminal(String? path) async {
    if (path == null || path.isEmpty) return;
    closeAllMenus();
    await openTerminalAt(path);
  }

  void openNasCtxMenu(FileItemDto file, double x, double y) {
    if (!fmSelectedPaths.contains(file.path)) {
      fmSelectedPaths = {file.path};
      fmSelectedFile = file;
    }
    fmLocalCtxMenu = null;
    fmEmptyCtxMenu = null;
    fmNasCtxMenu = NasCtxMenu(
      file: file,
      type: file.isDir ? 'folder' : 'file',
      x: x,
      y: y,
    );
    notifyListeners();
  }

  void openProperties(FileItemDto file) {
    fmPropertiesFile = file;
    closeAllMenus();
    notifyListeners();
  }

  void closeProperties() {
    fmPropertiesFile = null;
    notifyListeners();
  }

  void openLocalCtxMenu(FileItemDto file, double x, double y) {
    if (!fmSelectedPaths.contains(file.path)) {
      fmSelectedPaths = {file.path};
      fmSelectedFile = file;
    }
    fmEmptyCtxMenu = null;
    fmSidebarCtxMenu = null;
    fmNasCtxMenu = null;
    fmEmptySubMenu = '';
    fmItemSubMenu = '';
    fmLocalCtxMenu = LocalCtxMenu(file: file, x: x, y: y);
    notifyListeners();
  }

  void openEmptyCtxMenu(double x, double y) {
    fmLocalCtxMenu = null;
    fmSidebarCtxMenu = null;
    fmNasCtxMenu = null;
    fmEmptySubMenu = '';
    fmEmptyCtxMenu = EmptyCtxMenu(x: x, y: y);
    notifyListeners();
  }

  void openSidebarCtxMenu(SidebarCtxMenu menu) {
    fmLocalCtxMenu = null;
    fmEmptyCtxMenu = null;
    fmSidebarCtxMenu = menu;
    notifyListeners();
  }

  void setEmptySubMenu(String id, [Offset? anchor]) {
    _emptySubMenuTimer?.cancel();
    fmEmptySubMenu = id;
    if (anchor != null) fmEmptySubMenuAnchor = anchor;
    if (id.isEmpty) fmEmptySubMenuAnchor = null;
    notifyListeners();
  }

  void delayCloseEmptySubMenu() {
    _emptySubMenuTimer = Timer(const Duration(milliseconds: 120), () {
      fmEmptySubMenu = '';
      fmEmptySubMenuAnchor = null;
      notifyListeners();
    });
  }

  void cancelCloseEmptySubMenu() => _emptySubMenuTimer?.cancel();

  void invertSelection() {
    final all = fmFiles.map((f) => f.path).toSet();
    fmSelectedPaths = all.difference(fmSelectedPaths);
    fmSelectedFile = fmSelectedPaths.isEmpty
        ? null
        : fmFiles.firstWhere(
            (f) => fmSelectedPaths.contains(f.path),
            orElse: () => fmFiles.first,
          );
    notifyListeners();
  }

  void cutSelected() {
    final paths = selectedLocalPaths;
    if (paths.isEmpty) return;
    fmClipboard = FmClipboard(
      op: 'cut',
      paths: paths,
      scope: viewMode == 'nas' ? 'nas' : 'local',
    );
    notifyListeners();
  }

  void copySelected() {
    final paths = selectedLocalPaths;
    if (paths.isEmpty) return;
    fmClipboard = FmClipboard(
      op: 'copy',
      paths: paths,
      scope: viewMode == 'nas' ? 'nas' : 'local',
    );
    notifyListeners();
  }

  void clearClipboard() {
    fmClipboard = null;
    notifyListeners();
  }

  Future<void> pasteClipboard({String? collision}) async {
    final cb = fmClipboard;
    if (cb == null || viewMode != 'local') return;
    final dest = localCurrentDir;
    if (dest.isEmpty) return;

    // Pre-flight conflict check (skip if collision mode already chosen)
    if (collision == null) {
      final srcNames = cb.paths.map((p) => p.split('/').last).toSet();
      final existingNames = fmFiles.map((f) => f.name).toSet();
      final conflicts = srcNames.intersection(existingNames).toList()..sort();
      if (conflicts.isNotEmpty) {
        fmPendingPaste = cb;
        fmPendingPasteDestDir = dest;
        fmPasteConflictNames = conflicts;
        fmShowPasteConflict = true;
        notifyListeners();
        return;
      }
    }

    unawaited(_executePaste(cb, dest, collision));
  }

  void cancelPasteConflict() {
    fmShowPasteConflict = false;
    fmPendingPaste = null;
    fmPendingPasteDestDir = '';
    fmPasteConflictNames = [];
    // No-op if this paste didn't originate from a drag; clears the drag
    // ghost/overlay if it did.
    finishDragging();
  }

  void confirmPasteWithCollision(String collision) {
    fmShowPasteConflict = false;
    final cb = fmPendingPaste;
    final dest = fmPendingPasteDestDir;
    fmPendingPaste = null;
    fmPendingPasteDestDir = '';
    fmPasteConflictNames = [];
    notifyListeners();
    if (cb == null || dest.isEmpty) return;
    if (cb.scope == 'nas') {
      unawaited(nasPasteClipboard(destDir: dest, collision: collision));
    } else {
      unawaited(_executePaste(cb, dest, collision));
    }
  }

  Future<void> _executePaste(FmClipboard cb, String dest, String? collision) async {
    final cardId = addOperationCard(
      cb.op,
      'Paste ${cb.paths.length} item${cb.paths.length == 1 ? '' : 's'}',
    );
    clearSelection();
    fmError = '';
    notifyListeners();
    try {
      final fs_api.FsBatchResult result;
      if (cb.op == 'copy') {
        result = await fs_api.fsCopy(srcPaths: cb.paths, destDir: dest, collision: collision);
        if (result.succeeded.isNotEmpty) {
          undoStack.add(FmUndoItem.copy(
            names: result.succeeded.map((p) => p.split('/').last).toList(),
            destDir: dest,
          ));
        }
      } else {
        result = await fs_api.fsMovePaths(srcPaths: cb.paths, destDir: dest, collision: collision);
        if (result.failed.isEmpty) fmClipboard = null;
        if (result.succeeded.isNotEmpty) {
          final srcDir = cb.paths.isNotEmpty
              ? cb.paths.first.substring(0, cb.paths.first.lastIndexOf('/'))
              : '';
          undoStack.add(FmUndoItem.move(
            names: result.succeeded.map((p) => p.split('/').last).toList(),
            srcDir: srcDir,
            destDir: dest,
          ));
        }
      }
      _applyBatchResult(cardId, result, 'Pasted');
      // No-op if this paste didn't originate from a drag; clears the drag
      // ghost/overlay if it did.
      finishDragging();
    } catch (e) {
      finishOperationCard(cardId, 'failed', e.toString());
      fmError = e.toString();
      notifyListeners();
      return;
    }
    unawaited(refreshFileManager());
  }

  Future<void> pasteIntoFolder(String destDir, {String? collision}) async {
    final cb = fmClipboard;
    if (cb == null) return;

    // Pre-flight collision check using actual filesystem stat.
    if (collision == null && cb.scope != 'nas') {
      final candidatePaths =
          cb.paths.map((p) => '$destDir/${p.split('/').last}').toList();
      try {
        final existing = fs_api.fsStatPaths(paths: candidatePaths);
        if (existing.isNotEmpty) {
          final conflictNames = existing.map((e) => e.name).toList()..sort();
          fmPendingPaste = cb;
          fmPendingPasteDestDir = destDir;
          fmPasteConflictNames = conflictNames;
          fmShowPasteConflict = true;
          notifyListeners();
          return;
        }
      } catch (_) {
        // stat failure is non-fatal; proceed without pre-flight check.
      }
    }

    final cardId = addOperationCard(
      cb.op,
      'Paste ${cb.paths.length} into folder',
    );
    clearSelection();
    fmError = '';
    notifyListeners();
    try {
      final fs_api.FsBatchResult result;
      if (cb.op == 'copy') {
        result = await fs_api.fsCopy(
          srcPaths: cb.paths,
          destDir: destDir,
          collision: collision,
        );
        if (result.succeeded.isNotEmpty) {
          undoStack.add(FmUndoItem.copy(
            names: result.succeeded.map((p) => p.split('/').last).toList(),
            destDir: destDir,
          ));
        }
      } else {
        result = await fs_api.fsMovePaths(
          srcPaths: cb.paths,
          destDir: destDir,
          collision: collision,
        );
        if (result.failed.isEmpty) fmClipboard = null;
        if (result.succeeded.isNotEmpty) {
          final srcDir = cb.paths.isNotEmpty
              ? cb.paths.first.substring(0, cb.paths.first.lastIndexOf('/'))
              : '';
          undoStack.add(FmUndoItem.move(
            names: result.succeeded.map((p) => p.split('/').last).toList(),
            srcDir: srcDir,
            destDir: destDir,
          ));
        }
      }
      _applyBatchResult(cardId, result, 'Pasted');
    } catch (e) {
      finishOperationCard(cardId, 'failed', e.toString());
      fmError = e.toString();
      notifyListeners();
      return;
    }
    unawaited(refreshFileManager());
  }

  Future<void> copyPathToClipboard({bool quoted = false}) async {
    final paths = selectedLocalPaths;
    if (paths.isEmpty) return;
    final text = quoted
        ? paths.map((p) => '"$p"').join(' ')
        : paths.join('\n');
    await Clipboard.setData(ClipboardData(text: text));
  }

  Future<void> copyNamesToClipboard() async {
    final names = fmFiles
        .where((f) => fmSelectedPaths.contains(f.path))
        .map((f) => f.name)
        .toList();
    if (names.isEmpty && fmSelectedFile != null) {
      names.add(fmSelectedFile!.name);
    }
    if (names.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: names.join('\n')));
  }

  void startRename(FileItemDto file) {
    fmRenamePath = file.path;
    fmRenameValue = file.name;
    fmRenameBulk = false;
    fmShowRename = true;
    closeAllMenus();
    notifyListeners();
  }

  void startBulkRename() {
    if (fmSelectedPaths.length < 2) return;
    fmRenamePath = '';
    fmRenameValue = 'Item';
    fmRenameBulk = true;
    fmShowRename = true;
    closeAllMenus();
    notifyListeners();
  }

  void setRenameValue(String v) {
    fmRenameValue = v;
    notifyListeners();
  }

  void closeRename() {
    fmShowRename = false;
    notifyListeners();
  }

  String _extensionOf(String pathOrName) {
    final name = pathOrName.split('/').last;
    final dot = name.lastIndexOf('.');
    if (dot <= 0) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  Future<void> submitRename() async {
    final name = fmRenameValue.trim();
    if (name.isEmpty) return;
    if (fmSidebarRenameMenu != null) {
      final menu = fmSidebarRenameMenu!;
      if (menu.type == 'tag') {
        renameFileTag(menu.key, name);
      } else {
        savePlaceAlias(fmRenamePath, name);
      }
      fmShowRename = false;
      fmSidebarRenameMenu = null;
      return;
    }
    if (viewMode == 'nas') {
      if (fmRenameBulk) {
        await nasBulkRename(selectedLocalPaths, name);
      } else {
        await nasRename(fmRenamePath, name);
      }
      return;
    }
    // Warn if the file extension is changing.
    if (!fmRenameBulk) {
      final oldExt = _extensionOf(fmRenamePath);
      final newExt = _extensionOf(name);
      if (oldExt.isNotEmpty && newExt != oldExt) {
        fmExtWarnPendingName = name;
        fmShowExtWarn = true;
        notifyListeners();
        return;
      }
    }
    await _doLocalRename(name);
  }

  Future<void> cancelExtWarn() async {
    fmShowExtWarn = false;
    fmExtWarnPendingName = '';
    notifyListeners();
  }

  Future<void> confirmExtWarn() async {
    fmShowExtWarn = false;
    final name = fmExtWarnPendingName;
    fmExtWarnPendingName = '';
    notifyListeners();
    if (name.isNotEmpty) await _doLocalRename(name);
  }

  Future<void> _doLocalRename(String name) async {
    final cardId = addOperationCard(
      'rename',
      fmRenameBulk ? 'Bulk rename ${selectedLocalPaths.length} items' : 'Rename item',
    );
    fmError = '';
    try {
      if (fmRenameBulk) {
        fs_api.fsBulkRename(paths: selectedLocalPaths, baseName: name);
      } else {
        final oldPath = fmRenamePath;
        final oldName = oldPath.split('/').last;
        final parent = oldPath.contains('/') ? oldPath.substring(0, oldPath.lastIndexOf('/')) : '';
        fs_api.fsRename(oldPath: oldPath, newName: name);
        // Push rename to undo stack so Ctrl+Z can revert it.
        if (parent.isNotEmpty) {
          undoStack.add(FmUndoItem.rename(
            newPath: '$parent/$name',
            oldName: oldName,
          ));
        }
      }
      finishOperationCard(cardId, 'done', 'Renamed');
      fmShowRename = false;
      clearSelection();
    } catch (e) {
      finishOperationCard(cardId, 'failed', e.toString());
      fmError = e.toString();
      notifyListeners();
      return;
    }
    unawaited(refreshFileManager());
  }

  Future<void> undoLast() async {
    if (undoStack.isEmpty) return;
    final item = undoStack.removeLast();
    notifyListeners();
    if (item.type == 'rename' && item.newPath != null && item.oldName != null) {
      final cardId = addOperationCard('rename', 'Undo rename');
      fmError = '';
      try {
        fs_api.fsRename(oldPath: item.newPath!, newName: item.oldName!);
        finishOperationCard(cardId, 'done', 'Renamed back to ${item.oldName}');
      } catch (e) {
        finishOperationCard(cardId, 'failed', e.toString());
        fmError = e.toString();
        notifyListeners();
        return;
      }
      unawaited(refreshFileManager());
    } else if (item.type == 'trash' && item.paths != null && item.paths!.isNotEmpty) {
      final cardId = addOperationCard('trash', 'Undo trash');
      fmError = '';
      try {
        fs_api.fsRestoreTrash(paths: item.paths!);
        finishOperationCard(cardId, 'done', 'Restored ${item.paths!.length} item(s) from trash');
      } catch (e) {
        finishOperationCard(cardId, 'failed', e.toString());
        fmError = e.toString();
        notifyListeners();
        return;
      }
      unawaited(refreshFileManager());
    } else if (item.type == 'move' &&
        item.paths != null &&
        item.srcDir != null &&
        item.destDir != null) {
      // Undo move: move items back from destDir to srcDir.
      final fullPaths = item.paths!.map((n) => '${item.destDir}/$n').toList();
      final cardId = addOperationCard('move', 'Undo move');
      fmError = '';
      try {
        final result = await fs_api.fsMovePaths(
          srcPaths: fullPaths,
          destDir: item.srcDir!,
          collision: 'rename',
        );
        _applyBatchResult(cardId, result, 'Moved back');
      } catch (e) {
        finishOperationCard(cardId, 'failed', e.toString());
        fmError = e.toString();
        notifyListeners();
        return;
      }
      unawaited(refreshFileManager());
    } else if (item.type == 'copy' && item.paths != null && item.destDir != null) {
      // Undo copy: delete the copies from destDir.
      final fullPaths = item.paths!.map((n) => '${item.destDir}/$n').toList();
      final cardId = addOperationCard('delete', 'Undo copy');
      fmError = '';
      try {
        final result = await fs_api.fsDeletePermanent(paths: fullPaths);
        _applyBatchResult(cardId, result, 'Deleted copies');
      } catch (e) {
        finishOperationCard(cardId, 'failed', e.toString());
        fmError = e.toString();
        notifyListeners();
        return;
      }
      unawaited(refreshFileManager());
    }
  }

  int? _indexOfFirstSelectedInVisible() {
    if (fmSelectedPaths.isEmpty) return null;
    final files = visibleFmFiles;
    for (var i = 0; i < files.length; i++) {
      if (fmSelectedPaths.contains(files[i].path)) return i;
    }
    return null;
  }

  Future<void> trashSelected() async {
    final paths = selectedLocalPaths;
    if (paths.isEmpty) return;
    _pendingSelectAfterDelete = _indexOfFirstSelectedInVisible();
    final cardId = addOperationCard(
      'trash',
      'Move ${paths.length} item${paths.length == 1 ? '' : 's'} to trash',
    );
    clearSelection();
    fmError = '';
    notifyListeners();
    try {
      final result = await fs_api.fsTrash(paths: paths);
      _applyBatchResult(cardId, result, 'Moved to trash');
      if (result.succeeded.isNotEmpty) {
        undoStack.add(FmUndoItem.trash(paths: result.succeeded));
      }
    } catch (e) {
      finishOperationCard(cardId, 'failed', e.toString());
      fmError = e.toString();
      notifyListeners();
      return;
    }
    unawaited(refreshFileManager());
  }

  void deleteSelectedPermanently() {
    final paths = selectedLocalPaths;
    if (paths.isEmpty) return;
    if (!settings.confirmPermanentDelete) {
      // Skip dialog — directly delete.
      fmDeleteConfirmPaths = paths;
      fmDeleteConfirmIsNas = false;
      confirmDeletePermanently();
      return;
    }
    fmDeleteConfirmPaths = paths;
    fmDeleteConfirmIsNas = false;
    fmShowDeleteConfirm = true;
    notifyListeners();
  }

  Future<void> cancelDeleteConfirm() async {
    fmShowDeleteConfirm = false;
    fmDeleteConfirmPaths = [];
    notifyListeners();
  }

  Future<void> confirmDeletePermanently() async {
    fmShowDeleteConfirm = false;
    final paths = List<String>.from(fmDeleteConfirmPaths);
    fmDeleteConfirmPaths = [];
    if (paths.isEmpty) { notifyListeners(); return; }
    if (fmDeleteConfirmIsNas) {
      final cardId = addOperationCard('delete', 'Delete ${paths.length} item${paths.length == 1 ? '' : 's'}');
      clearSelection();
      fmError = '';
      notifyListeners();
      unawaited(() async {
        try {
          final result = await nasFsRequest('delete', {'paths': paths});
          _applyNasBatchResult(cardId, result, 'Deleted');
          unawaited(refreshFileManager());
        } catch (e) {
          finishOperationCard(cardId, 'failed', e.toString());
          fmError = e.toString();
          notifyListeners();
        }
      }());
    } else {
      final cardId = addOperationCard('delete', 'Delete ${paths.length} item${paths.length == 1 ? '' : 's'}');
      clearSelection();
      fmError = '';
      notifyListeners();
      try {
        final result = await fs_api.fsDeletePermanent(paths: paths);
        _applyBatchResult(cardId, result, 'Deleted');
      } catch (e) {
        finishOperationCard(cardId, 'failed', e.toString());
        fmError = e.toString();
        notifyListeners();
        return;
      }
      unawaited(refreshFileManager());
    }
  }

  Future<void> duplicateSelected([String? fallback]) async {
    final paths = fallback != null ? [fallback] : selectedLocalPaths;
    if (paths.isEmpty) return;
    final cardId = addOperationCard(
      'duplicate',
      'Duplicate ${paths.length} item${paths.length == 1 ? '' : 's'}',
    );
    fmError = '';
    notifyListeners();
    try {
      await fs_api.fsDuplicate(paths: paths);
      finishOperationCard(cardId, 'done', 'Duplicated');
    } catch (e) {
      finishOperationCard(cardId, 'failed', e.toString());
      fmError = e.toString();
      notifyListeners();
      return;
    }
    unawaited(refreshFileManager());
  }

  Future<void> createNewFolder([String? name]) async {
    final dir = localCurrentDir;
    if (dir.isEmpty) return;
    final folderName = name ?? 'New Folder';
    fmError = '';
    try {
      fs_api.fsCreateDir(path: '$dir/$folderName');
    } catch (e) {
      fmError = e.toString();
      notifyListeners();
      return;
    }
    unawaited(refreshFileManager());
  }

  Future<void> createNewFile([String? name]) async {
    final dir = localCurrentDir;
    if (dir.isEmpty) return;
    fmError = '';
    try {
      fs_api.fsCreateFile(dir: dir, name: name ?? 'New File');
    } catch (e) {
      fmError = e.toString();
      notifyListeners();
      return;
    }
    unawaited(refreshFileManager());
  }

  Future<void> createTextTemplate(String base, String ext, String content) async {
    final dir = localCurrentDir;
    if (dir.isEmpty) return;
    fmError = '';
    try {
      fs_api.fsCreateTextFile(dir: dir, name: '$base.$ext', content: content);
    } catch (e) {
      fmError = e.toString();
      notifyListeners();
      return;
    }
    unawaited(refreshFileManager());
  }

  void createSymlink({required String target, required String linkName}) {
    final dir = localCurrentDir;
    if (dir.isEmpty) return;
    fmError = '';

    // Resolve a non-conflicting name. Common case: right-clicking a file/folder
    // that is already IN the current directory → same name conflicts with itself.
    final existing = fmFiles.map((f) => f.name).toSet();
    String name = linkName;
    if (existing.contains(name)) {
      final dot = name.lastIndexOf('.');
      final stem = dot > 0 ? name.substring(0, dot) : name;
      final ext = dot > 0 ? name.substring(dot) : '';
      name = '$stem (link)$ext';
      var i = 2;
      while (existing.contains(name)) {
        name = '$stem (link $i)$ext';
        i++;
      }
    }

    try {
      fs_api.fsCreateSymlink(linkPath: '$dir/$name', target: target);
    } catch (e) {
      fmError = e.toString();
      notifyListeners();
      return;
    }
    unawaited(refreshFileManager());
  }

  Future<void> openNativeFile(String path) async {
    fmError = '';
    try {
      await fs_api.openFileNative(path: path);
    } catch (e) {
      fmError = e.toString();
      notifyListeners();
    }
  }

  Future<void> openTerminalAt(String path) async {
    fmError = '';
    try {
      await fs_api.openInTerminal(
        path: path,
        terminalOverride: settings.defaultTerminal.isEmpty
            ? null
            : settings.defaultTerminal,
      );
    } catch (e) {
      fmError = e.toString();
      notifyListeners();
    }
  }

  Future<void> compressSelected(String format) async {
    var paths = selectedLocalPaths;
    if (paths.isEmpty && fmSelectedFile != null) {
      paths = [fmSelectedFile!.path];
    }
    if (paths.isEmpty) return;
    final cardId = addOperationCard('compress', 'Compress to .$format');
    fmError = '';
    notifyListeners();
    unawaited(() async {
      try {
        await fs_api.fsCompress(
          paths: paths,
          destDir: localCurrentDir,
          format: format,
        );
        finishOperationCard(cardId, 'done', 'Compressed');
        unawaited(refreshFileManager());
      } catch (e) {
        finishOperationCard(cardId, 'failed', e.toString());
        fmError = e.toString();
        notifyListeners();
      }
    }());
  }

  Future<void> extractHere(String path) async {
    final cardId = addOperationCard('extract', 'Extract archive');
    fmError = '';
    notifyListeners();
    unawaited(() async {
      try {
        await fs_api.fsExtractHere(path: path);
        finishOperationCard(cardId, 'done', 'Extracted');
        unawaited(refreshFileManager());
      } catch (e) {
        finishOperationCard(cardId, 'failed', e.toString());
        fmError = e.toString();
        notifyListeners();
      }
    }());
  }

  void addBookmarkFromPath(String label, String path) {
    final id = 'bm_${DateTime.now().millisecondsSinceEpoch}';
    bookmarks = [
      ...bookmarks,
      Bookmark(id: id, label: label, path: path),
    ];
    saveBookmarks(bookmarks);
    notifyListeners();
  }

  Future<dynamic> nasFsRequest(
    String endpoint,
    Map<String, dynamic> body,
  ) async {
    final auth = getSessionAuth();
    final agentIp = agent?.ip;
    if (auth == null || agentIp == null) {
      throw Exception('Not authenticated.');
    }
    final res = await agentSecureFetch(
      url: 'https://$agentIp/api/fs/$endpoint',
      method: 'POST',
      body: jsonEncode(body),
      token: auth.token,
      macKey: auth.macKey,
    );
    if (res.status == 401) {
      session = null;
      notifyListeners();
      throw Exception('Session expired.');
    }
    if (res.status < 200 || res.status >= 300) {
      throw Exception(res.body.isNotEmpty ? res.body : 'NAS operation failed (${res.status})');
    }
    if (res.body.isEmpty) return null;
    return jsonDecode(res.body);
  }

  Future<void> copyNasDetails(FileItemDto file) async {
    final text = '${file.name}\n${file.path}\n${file.detail}';
    await Clipboard.setData(ClipboardData(text: text));
  }

  Future<void> nasTrashSelected() async {
    final paths = selectedLocalPaths;
    if (paths.isEmpty) return;
    _pendingSelectAfterDelete = _indexOfFirstSelectedInVisible();
    final cardId = addOperationCard('trash', 'Move ${paths.length} item${paths.length == 1 ? '' : 's'} to trash');
    clearSelection();
    fmError = '';
    notifyListeners();
    unawaited(() async {
      try {
        final result = await nasFsRequest('trash', {'paths': paths});
        _applyNasBatchResult(cardId, result, 'Moved to trash');
        unawaited(refreshFileManager());
      } catch (e) {
        finishOperationCard(cardId, 'failed', e.toString());
        fmError = e.toString();
        notifyListeners();
      }
    }());
  }

  void nasDeleteSelected() {
    final paths = selectedLocalPaths;
    if (paths.isEmpty) return;
    if (!settings.confirmPermanentDelete) {
      fmDeleteConfirmPaths = paths;
      fmDeleteConfirmIsNas = true;
      confirmDeletePermanently();
      return;
    }
    fmDeleteConfirmPaths = paths;
    fmDeleteConfirmIsNas = true;
    fmShowDeleteConfirm = true;
    notifyListeners();
  }

  Future<void> nasDuplicateSelected([String? fallback]) async {
    final paths = fallback != null ? [fallback] : selectedLocalPaths;
    if (paths.isEmpty) return;
    final cardId = addOperationCard('duplicate', 'Duplicate ${paths.length} item${paths.length == 1 ? '' : 's'}');
    fmError = '';
    notifyListeners();
    unawaited(() async {
      try {
        await nasFsRequest('duplicate', {'paths': paths});
        finishOperationCard(cardId, 'done', 'Duplicated');
        unawaited(refreshFileManager());
      } catch (e) {
        finishOperationCard(cardId, 'failed', e.toString());
        fmError = e.toString();
        notifyListeners();
      }
    }());
  }

  Future<void> nasRename(String path, String newName) async {
    final cardId = addOperationCard('rename', 'Rename item');
    fmShowRename = false;
    clearSelection();
    fmError = '';
    notifyListeners();
    unawaited(() async {
      try {
        await nasFsRequest('rename', {'path': path, 'new_name': newName});
        finishOperationCard(cardId, 'done', 'Renamed to $newName');
        unawaited(refreshFileManager());
      } catch (e) {
        finishOperationCard(cardId, 'failed', e.toString());
        fmError = e.toString();
        notifyListeners();
      }
    }());
  }

  Future<void> nasBulkRename(List<String> paths, String baseName) async {
    final cardId = addOperationCard('rename', 'Bulk rename ${paths.length} items');
    fmShowRename = false;
    clearSelection();
    fmError = '';
    notifyListeners();
    unawaited(() async {
      try {
        await nasFsRequest('bulk-rename', {'paths': paths, 'base_name': baseName});
        finishOperationCard(cardId, 'done', 'Renamed ${paths.length} items');
        unawaited(refreshFileManager());
      } catch (e) {
        finishOperationCard(cardId, 'failed', e.toString());
        fmError = e.toString();
        notifyListeners();
      }
    }());
  }

  Future<void> nasPasteClipboard({String? destDir, String? collision}) async {
    final cb = fmClipboard;
    if (cb == null || cb.scope != 'nas') return;
    final dest = destDir ?? (fmMeta.currentPath.isNotEmpty ? fmMeta.currentPath : null);
    if (dest == null || dest.isEmpty) {
      fmError = 'Cannot paste: navigate into a NAS folder first.';
      notifyListeners();
      return;
    }
    // Pre-flight conflict check (skip if collision mode already chosen).
    if (collision == null) {
      final srcNames = cb.paths.map((p) => p.split('/').last).toSet();
      final existingNames = fmFiles.map((f) => f.name).toSet();
      final conflicts = srcNames.intersection(existingNames).toList()..sort();
      if (conflicts.isNotEmpty) {
        fmPendingPaste = cb;
        fmPendingPasteDestDir = dest;
        fmPasteConflictNames = conflicts;
        fmShowPasteConflict = true;
        notifyListeners();
        return;
      }
    }
    final endpoint = cb.op == 'copy' ? 'copy' : 'move';
    final cardId = addOperationCard(cb.op, 'Paste ${cb.paths.length} items');
    clearSelection();
    fmError = '';
    notifyListeners();
    unawaited(() async {
      try {
        final result = await nasFsRequest(endpoint, {
          'src_paths': cb.paths,
          'dest_dir': dest,
          if (collision != null) 'collision': collision,
        });
        _applyNasBatchResult(cardId, result, 'Pasted');
        final failed = (result?['failed'] as List?) ?? [];
        if (cb.op == 'cut' && failed.isEmpty) fmClipboard = null;
        unawaited(refreshFileManager());
      } catch (e) {
        finishOperationCard(cardId, 'failed', e.toString());
        fmError = e.toString();
        notifyListeners();
      }
    }());
  }

  Future<void> nasCompress(List<String> paths, String format) async {
    final cardId = addOperationCard('compress', 'Compress to .$format');
    fmError = '';
    notifyListeners();
    unawaited(() async {
      try {
        await nasFsRequest('compress', {
          'paths': paths,
          'dest_dir': fmMeta.currentPath,
          'format': format,
        });
        finishOperationCard(cardId, 'done', 'Compressed');
        unawaited(refreshFileManager());
      } catch (e) {
        finishOperationCard(cardId, 'failed', e.toString());
        fmError = e.toString();
        notifyListeners();
      }
    }());
  }

  Future<void> nasExtractHere(String path) async {
    final cardId = addOperationCard('extract', 'Extract archive');
    fmError = '';
    notifyListeners();
    unawaited(() async {
      try {
        await nasFsRequest('extract-here', {'path': path});
        finishOperationCard(cardId, 'done', 'Extracted');
        unawaited(refreshFileManager());
      } catch (e) {
        finishOperationCard(cardId, 'failed', e.toString());
        fmError = e.toString();
        notifyListeners();
      }
    }());
  }

  Future<void> nasExtractToSubfolder(String path) async {
    final cardId = addOperationCard('extract', 'Extract to subfolder');
    fmError = '';
    notifyListeners();
    unawaited(() async {
      try {
        await nasFsRequest('extract-to-subfolder', {'path': path});
        finishOperationCard(cardId, 'done', 'Extracted');
        unawaited(refreshFileManager());
      } catch (e) {
        finishOperationCard(cardId, 'failed', e.toString());
        fmError = e.toString();
        notifyListeners();
      }
    }());
  }

  Future<void> nasRotateImage(String path, String direction) async {
    fmError = '';
    unawaited(() async {
      try {
        await nasFsRequest('rotate-image', {'path': path, 'direction': direction});
        unawaited(refreshFileManager());
      } catch (e) {
        fmError = e.toString();
        notifyListeners();
      }
    }());
  }

  Future<void> nasCreateNewFolder([String? name]) async {
    final dir = fmMeta.currentPath;
    if (dir.isEmpty) return;
    final folderName = name ?? 'New Folder';
    final cardId = addOperationCard('new_folder', 'Create folder "$folderName"');
    fmError = '';
    notifyListeners();
    unawaited(() async {
      try {
        await nasFsRequest('mkdir', {'path': '$dir/$folderName'});
        finishOperationCard(cardId, 'done', 'Created "$folderName"');
        unawaited(refreshFileManager());
      } catch (e) {
        finishOperationCard(cardId, 'failed', e.toString());
        fmError = e.toString();
        notifyListeners();
      }
    }());
  }

  Future<void> nasCreateNewFile([String? name]) async {
    final dir = fmMeta.currentPath;
    if (dir.isEmpty) return;
    final fileName = name ?? 'New File';
    final cardId = addOperationCard('new_file', 'Create file "$fileName"');
    fmError = '';
    notifyListeners();
    unawaited(() async {
      try {
        await nasFsRequest('create-file', {'dir': dir, 'name': fileName});
        finishOperationCard(cardId, 'done', 'Created "$fileName"');
        unawaited(refreshFileManager());
      } catch (e) {
        finishOperationCard(cardId, 'failed', e.toString());
        fmError = e.toString();
        notifyListeners();
      }
    }());
  }

  Future<bool> verifyManagementCode(String password) async {
    try {
      await adminRequest('management/verify', method: 'POST', body: {'password': password});
      managementUnlocked = true;
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<dynamic> adminRequest(
    String endpoint, {
    String method = 'GET',
    Object? body,
  }) async {
    final auth = getSessionAuth();
    final agentIp = agent?.ip;
    if (auth == null || agentIp == null) {
      throw Exception('Not authenticated.');
    }
    final res = await agentSecureFetch(
      url: 'https://$agentIp/api/admin/$endpoint',
      method: method,
      body: body == null ? null : jsonEncode(body),
      token: auth.token,
      macKey: auth.macKey,
    );
    if (res.status < 200 || res.status >= 300) {
      String message;
      try {
        final parsed = jsonDecode(res.body);
        message = parsed['message']?.toString() ??
            parsed['error']?.toString() ??
            res.body;
      } catch (_) {
        message = res.body.isNotEmpty ? res.body : 'Request failed (${res.status})';
      }
      throw Exception(message);
    }
    if (res.body.isEmpty) return null;
    return jsonDecode(res.body);
  }
}