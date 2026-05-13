import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

const String _kAutostartAppName = 'Vocotype Flutter';
const String _kBackendConfigRelativePath = '.config/vocotype/backend.json';
const String _kBackendRuntimeEnv = 'VOCOTYPE_BACKEND_RUNTIME';
const bool _kDefaultRestoreClipboardAfterShiftInsert = true;
const Duration _kShiftInsertRestoreDelay = Duration(milliseconds: 120);
const Duration _kAudioInputRefreshInterval = Duration(seconds: 5);
const String _kDefaultToggleHotkeyConfigValue = 'f2';

class _ToggleHotkeyOption {
  const _ToggleHotkeyOption({
    required this.configValue,
    required this.label,
    required this.key,
  });

  final String configValue;
  final String label;
  final PhysicalKeyboardKey key;
}

const _ToggleHotkeyOption _kDefaultToggleHotkeyOption = _ToggleHotkeyOption(
  configValue: _kDefaultToggleHotkeyConfigValue,
  label: 'F2',
  key: PhysicalKeyboardKey.f2,
);

const List<_ToggleHotkeyOption> _kToggleHotkeyOptions = <_ToggleHotkeyOption>[
  _ToggleHotkeyOption(
    configValue: 'f1',
    label: 'F1',
    key: PhysicalKeyboardKey.f1,
  ),
  _kDefaultToggleHotkeyOption,
  _ToggleHotkeyOption(
    configValue: 'f3',
    label: 'F3',
    key: PhysicalKeyboardKey.f3,
  ),
  _ToggleHotkeyOption(
    configValue: 'f4',
    label: 'F4',
    key: PhysicalKeyboardKey.f4,
  ),
  _ToggleHotkeyOption(
    configValue: 'f5',
    label: 'F5',
    key: PhysicalKeyboardKey.f5,
  ),
  _ToggleHotkeyOption(
    configValue: 'f6',
    label: 'F6',
    key: PhysicalKeyboardKey.f6,
  ),
  _ToggleHotkeyOption(
    configValue: 'f7',
    label: 'F7',
    key: PhysicalKeyboardKey.f7,
  ),
  _ToggleHotkeyOption(
    configValue: 'f8',
    label: 'F8',
    key: PhysicalKeyboardKey.f8,
  ),
  _ToggleHotkeyOption(
    configValue: 'f9',
    label: 'F9',
    key: PhysicalKeyboardKey.f9,
  ),
  _ToggleHotkeyOption(
    configValue: 'f10',
    label: 'F10',
    key: PhysicalKeyboardKey.f10,
  ),
  _ToggleHotkeyOption(
    configValue: 'f11',
    label: 'F11',
    key: PhysicalKeyboardKey.f11,
  ),
  _ToggleHotkeyOption(
    configValue: 'f12',
    label: 'F12',
    key: PhysicalKeyboardKey.f12,
  ),
];

_ToggleHotkeyOption _toggleHotkeyOptionForConfigValue(String? rawValue) {
  final normalized = (rawValue ?? '').trim().toLowerCase();
  for (final option in _kToggleHotkeyOptions) {
    if (option.configValue == normalized) {
      return option;
    }
  }
  return _kDefaultToggleHotkeyOption;
}

int _intFromDynamic(Object? value, {int fallback = 0}) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value) ?? fallback;
  }
  return fallback;
}

bool _boolFromDynamic(Object? value, {required bool fallback}) {
  if (value is bool) {
    return value;
  }
  if (value is num) {
    return value != 0;
  }
  if (value is String) {
    switch (value.trim().toLowerCase()) {
      case '1':
      case 'true':
      case 'yes':
      case 'on':
        return true;
      case '0':
      case 'false':
      case 'no':
      case 'off':
        return false;
    }
  }
  return fallback;
}

String? _trimmedStringOrNull(Object? value) {
  if (value == null) {
    return null;
  }
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}

class AudioInputDevice {
  const AudioInputDevice({
    required this.id,
    required this.name,
    required this.maxInputChannels,
    required this.defaultSampleRate,
  });

  factory AudioInputDevice.fromJson(Map<String, dynamic> json) {
    final maxInputChannels = _intFromDynamic(
      json['max_input_channels'],
      fallback: 1,
    );
    final defaultSampleRate = _intFromDynamic(
      json['default_sample_rate'],
      fallback: 44100,
    );
    return AudioInputDevice(
      id: _intFromDynamic(json['id']),
      name: _trimmedStringOrNull(json['name']) ?? 'Unknown input',
      maxInputChannels: maxInputChannels > 0 ? maxInputChannels : 1,
      defaultSampleRate: defaultSampleRate > 0 ? defaultSampleRate : 44100,
    );
  }

  final int id;
  final String name;
  final int maxInputChannels;
  final int defaultSampleRate;

  String get label => '[$id] $name';
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  launchAtStartup.setup(
    appName: _kAutostartAppName,
    appPath: Platform.resolvedExecutable,
  );
  const WindowOptions windowOptions = WindowOptions(skipTaskbar: true);
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.hide();
  });
  await hotKeyManager.unregisterAll();
  runApp(const VoCoTypeApp());
}

class VoCoTypeApp extends StatelessWidget {
  const VoCoTypeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vocotype Flutter',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      home: const HomePage(),
    );
  }
}

class DaemonClient {
  DaemonClient({this.socketPath = '/tmp/vocotype-backend.sock'});

  final String socketPath;

  Future<Map<String, dynamic>> send(Map<String, dynamic> req) async {
    final socket = await Socket.connect(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
      timeout: const Duration(seconds: 2),
    );
    try {
      socket.write('${jsonEncode(req)}\n');
      await socket.flush();
      final body = await socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 30));
      return jsonDecode(body) as Map<String, dynamic>;
    } finally {
      socket.destroy();
    }
  }
}

class _BackendLaunchCommand {
  _BackendLaunchCommand({
    required this.pythonPath,
    required this.scriptPath,
    required this.runtimeDir,
  });

  final String pythonPath;
  final String scriptPath;
  final String runtimeDir;
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

enum TypeBackend {
  auto,
  xdotool,
  wtype,
  shiftInsertPaste;

  String get label {
    switch (this) {
      case TypeBackend.auto:
        return 'Auto';
      case TypeBackend.xdotool:
        return 'Xdotool';
      case TypeBackend.wtype:
        return 'Wtype';
      case TypeBackend.shiftInsertPaste:
        return 'Shift+Insert Paste';
    }
  }

  String get configValue {
    switch (this) {
      case TypeBackend.auto:
        return 'auto';
      case TypeBackend.xdotool:
        return 'xdotool';
      case TypeBackend.wtype:
        return 'wtype';
      case TypeBackend.shiftInsertPaste:
        return 'shift_insert_paste';
    }
  }

  static TypeBackend fromConfigValue(String? raw) {
    switch ((raw ?? '').trim().toLowerCase()) {
      case 'xdotool':
        return TypeBackend.xdotool;
      case 'wtype':
        return TypeBackend.wtype;
      case 'shift+insert':
      case 'shift_insert':
      case 'shift-insert':
      case 'shiftinsert':
      case 'shift_insert_paste':
        return TypeBackend.shiftInsertPaste;
      case 'auto':
      default:
        return TypeBackend.auto;
    }
  }
}

class _ClipboardSnapshot {
  const _ClipboardSnapshot({required this.text});

  final String? text;
}

class _HomePageState extends State<HomePage> with TrayListener, WindowListener {
  final DaemonClient _client = DaemonClient();
  final List<String> _logs = <String>[];

  bool _recording = false;
  bool _busy = false;
  bool _autostartEnabled = false;
  bool _autostartBusy = true;
  bool _removePeriod = false;
  bool _restoreClipboardAfterShiftInsert =
      _kDefaultRestoreClipboardAfterShiftInsert;
  bool _settingsBusy = true;
  bool _audioInputBusy = true;
  bool _isQuitting = false;
  TypeBackend _typeBackend = _typeBackendFromEnv();
  String _toggleHotkeyConfigValue = _kDefaultToggleHotkeyConfigValue;
  String _lastText = '';
  List<AudioInputDevice> _audioInputDevices = const <AudioInputDevice>[];
  String? _selectedAudioDeviceName;
  String? _resolvedAudioDeviceName;
  int _selectedAudioInputChannel = 0;
  int _selectedAudioSampleRate = 44100;
  HotKey? _hotKey;
  Process? _managedBackendProcess;
  bool _backendStartedByApp = false;
  Future<void>? _ensureBackendFuture;
  Timer? _audioInputRefreshTimer;

  _ToggleHotkeyOption get _toggleHotkeyOption {
    return _toggleHotkeyOptionForConfigValue(_toggleHotkeyConfigValue);
  }

  String get _toggleHotkeyLabel => _toggleHotkeyOption.label;

  static TypeBackend _typeBackendFromEnv() {
    return TypeBackend.fromConfigValue(
      Platform.environment['VOCOTYPE_TYPE_BACKEND'],
    );
  }

  @override
  void initState() {
    super.initState();
    trayManager.addListener(this);
    windowManager.addListener(this);
    unawaited(_initDesktopBehaviors());
    unawaited(_bootstrapRuntime());
    _audioInputRefreshTimer = Timer.periodic(
      _kAudioInputRefreshInterval,
      (_) {
        if (!mounted || _audioInputBusy) {
          return;
        }
        unawaited(_loadAudioInputSettings(showBusy: false));
      },
    );
    _addLog(
      'Input backend: ${_typeBackend.label} '
      '(effective: ${_effectiveBackendForCurrentSession().label})',
    );
  }

  @override
  void dispose() {
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    _audioInputRefreshTimer?.cancel();
    _audioInputRefreshTimer = null;
    unawaited(_unbindHotkey());
    _managedBackendProcess = null;
    super.dispose();
  }

  Future<void> _initDesktopBehaviors() async {
    await _safeDesktopInit(windowManager.setPreventClose(true), 'Window setup');
    await _safeDesktopInit(
      trayManager.setIcon('assets/tray_icon.png'),
      'Tray icon setup',
    );
    if (!Platform.isLinux) {
      await _safeDesktopInit(
        trayManager.setToolTip('Vocotype Flutter'),
        'Tray tooltip setup',
      );
    }
    await _safeDesktopInit(_updateTrayMenu(), 'Tray menu setup');
    _addLog('Tray initialized');
    await _loadAutostartState();
    await _hideToTray(log: false);
    _addLog('App started minimized to tray');
  }

  Future<void> _safeDesktopInit(Future<void> future, String label) async {
    try {
      await future;
    } catch (e) {
      _addLog('$label failed: $e');
    }
  }

  Future<void> _updateTrayMenu() async {
    final Menu menu = Menu(
      items: <MenuItem>[
        MenuItem(key: 'show_window', label: '显示窗口'),
        MenuItem.separator(),
        MenuItem(key: 'exit_app', label: '退出'),
      ],
    );
    await trayManager.setContextMenu(menu);
  }

  Future<void> _loadAutostartState() async {
    try {
      final enabled = await launchAtStartup.isEnabled();
      if (!mounted) {
        return;
      }
      setState(() {
        _autostartEnabled = enabled;
        _autostartBusy = false;
      });
      _addLog('Autostart ${enabled ? 'enabled' : 'disabled'}');
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _autostartBusy = false;
      });
      _addLog('Autostart status check failed: $e');
    }
  }

  Future<void> _setAutostartEnabled(bool enabled) async {
    if (_autostartBusy) {
      return;
    }
    setState(() {
      _autostartBusy = true;
    });
    try {
      if (enabled) {
        await launchAtStartup.enable();
      } else {
        await launchAtStartup.disable();
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _autostartEnabled = enabled;
        _autostartBusy = false;
      });
      _addLog('Autostart ${enabled ? 'enabled' : 'disabled'}');
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _autostartBusy = false;
      });
      _addLog('Autostart update failed: $e');
    }
  }

  Future<void> _bootstrapRuntime() async {
    await _loadSavedSettings();
    try {
      await _bindHotkey();
    } catch (e) {
      _addLog('Failed to register hotkey: $e');
    }
    await _ensureBackendRunning();
    await _loadAudioInputSettings();
    await _ping();
  }

  File _backendConfigFile() {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      throw StateError('HOME is not set');
    }
    return File('$home/$_kBackendConfigRelativePath');
  }

  String? _resolveVenvPython(Iterable<String> runtimeDirs) {
    for (final runtimeDir in runtimeDirs) {
      final pythonPath = '$runtimeDir/.venv/bin/python';
      if (File(pythonPath).existsSync()) {
        return pythonPath;
      }
    }
    return null;
  }

  _BackendLaunchCommand? _resolveDevBackendLaunchCommand() {
    final cwd = Directory.current.path;
    final fallbackScripts = <String>[
      '$cwd/backend/backend_server.py',
      '$cwd/../backend/backend_server.py',
    ];

    for (final scriptPath in fallbackScripts) {
      if (!File(scriptPath).existsSync()) {
        continue;
      }
      final normalizedScriptPath = File(
        scriptPath,
      ).absolute.resolveSymbolicLinksSync();
      final scriptDir = File(normalizedScriptPath).parent.path;
      final projectDir = Directory(scriptDir).parent.path;
      final pythonPath = _resolveVenvPython(<String>[
        projectDir,
        cwd,
        '$cwd/..',
      ]);
      if (pythonPath == null) {
        continue;
      }
      return _BackendLaunchCommand(
        pythonPath: pythonPath,
        scriptPath: normalizedScriptPath,
        runtimeDir: projectDir,
      );
    }
    return null;
  }

  _BackendLaunchCommand? _resolveBackendLaunchCommand() {
    final devCommand = _resolveDevBackendLaunchCommand();
    if (devCommand != null) {
      return devCommand;
    }

    final runtimeDirs = <String>{};
    final envRuntime = Platform.environment[_kBackendRuntimeEnv];
    if (envRuntime != null && envRuntime.isNotEmpty) {
      runtimeDirs.add(envRuntime);
    }

    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      runtimeDirs.add(
        '$home/.local/share/vocotype-flutter_vocotype/backend_runtime',
      );
    }

    final executable = File(Platform.resolvedExecutable);
    runtimeDirs.add('${executable.parent.parent.path}/backend_runtime');

    for (final runtimeDir in runtimeDirs) {
      final pythonPath = _resolveVenvPython(<String>[runtimeDir]);
      if (pythonPath == null) {
        continue;
      }
      final scriptPath = '$runtimeDir/backend/backend_server.py';
      if (File(pythonPath).existsSync() && File(scriptPath).existsSync()) {
        return _BackendLaunchCommand(
          pythonPath: pythonPath,
          scriptPath: scriptPath,
          runtimeDir: runtimeDir,
        );
      }
    }
    return null;
  }

  Future<bool> _daemonPing() async {
    try {
      final resp = await _client.send(<String, dynamic>{'cmd': 'ping'});
      return resp['ok'] == true ||
          resp['pong'] == true ||
          resp['type'] == 'pong';
    } catch (_) {
      return false;
    }
  }

  Future<void> _ensureBackendRunning() {
    final pending = _ensureBackendFuture;
    if (pending != null) {
      return pending;
    }
    final future = _ensureBackendRunningImpl();
    _ensureBackendFuture = future;
    return future.whenComplete(() {
      if (identical(_ensureBackendFuture, future)) {
        _ensureBackendFuture = null;
      }
    });
  }

  Future<void> _ensureBackendRunningImpl() async {
    if (await _daemonPing()) {
      _addLog('Backend reachable');
      return;
    }

    final started = await _startManagedBackend();
    if (!started) {
      return;
    }

    final ready = await _waitForBackendReady();
    if (ready) {
      _addLog('Backend started by app');
      return;
    }

    _addLog('Backend startup timed out');
    await _stopManagedBackendIfNeeded(forceKill: true);
  }

  Future<bool> _waitForBackendReady({
    Duration timeout = const Duration(seconds: 10),
    Duration interval = const Duration(milliseconds: 250),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await _daemonPing()) {
        return true;
      }
      await Future<void>.delayed(interval);
    }
    return false;
  }

  Future<bool> _startManagedBackend() async {
    if (_managedBackendProcess != null) {
      return true;
    }
    final command = _resolveBackendLaunchCommand();
    if (command == null) {
      _addLog(
        'Backend launch command not found: missing backend script or .venv/bin/python',
      );
      return false;
    }

    try {
      final process = await Process.start(
        command.pythonPath,
        <String>[command.scriptPath],
        workingDirectory: command.runtimeDir,
        environment: <String, String>{_kBackendRuntimeEnv: command.runtimeDir},
      );
      _managedBackendProcess = process;
      _backendStartedByApp = true;
      _attachManagedBackendLogging(process);
      _addLog('Starting backend: ${command.scriptPath}');
      return true;
    } catch (e) {
      _addLog('Failed to start backend: $e');
      _managedBackendProcess = null;
      _backendStartedByApp = false;
      return false;
    }
  }

  void _attachManagedBackendLogging(Process process) {
    unawaited(
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((String line) => _addLog('[backend] $line'), onError: (_) {})
          .asFuture<void>(),
    );
    unawaited(
      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((String line) => _addLog('[backend] $line'), onError: (_) {})
          .asFuture<void>(),
    );
    unawaited(
      process.exitCode.then((int code) {
        if (identical(_managedBackendProcess, process)) {
          _managedBackendProcess = null;
          _backendStartedByApp = false;
        }
        _addLog('Backend process exited: $code');
      }),
    );
  }

  Future<void> _stopManagedBackendIfNeeded({bool forceKill = false}) async {
    final process = _managedBackendProcess;
    if (process == null || !_backendStartedByApp) {
      return;
    }

    if (!forceKill) {
      try {
        await _client.send(<String, dynamic>{'cmd': 'shutdown'}).timeout(
            const Duration(seconds: 2));
      } catch (_) {
        // Ignore shutdown command failures and fallback to process signal.
      }
    }

    try {
      await process.exitCode.timeout(const Duration(seconds: 2));
      _addLog('Managed backend stopped');
    } on TimeoutException {
      process.kill(ProcessSignal.sigterm);
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
        _addLog('Managed backend stopped with SIGTERM');
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        _addLog('Managed backend killed with SIGKILL');
      }
    } finally {
      if (identical(_managedBackendProcess, process)) {
        _managedBackendProcess = null;
        _backendStartedByApp = false;
      }
    }
  }

  Future<void> _loadSavedSettings() async {
    try {
      final config = await _readBackendConfigMap();
      final output = _stringDynamicMap(config['output']);
      final frontend = _stringDynamicMap(config['frontend']);
      final hotkeys = _stringDynamicMap(config['hotkeys']);
      final removePeriodEnabled = output['remove_period'] == true;
      final restoreClipboardEnabled = _boolFromDynamic(
        frontend['restore_clipboard_after_shift_insert'],
        fallback: _kDefaultRestoreClipboardAfterShiftInsert,
      );
      final toggleHotkeyConfigValue = _toggleHotkeyOptionForConfigValue(
        _trimmedStringOrNull(hotkeys['toggle']),
      ).configValue;
      final configuredMethod = _trimmedStringOrNull(output['method']);
      final backend = configuredMethod == null
          ? _typeBackend
          : TypeBackend.fromConfigValue(configuredMethod);
      if (!mounted) {
        return;
      }
      setState(() {
        _removePeriod = removePeriodEnabled;
        _restoreClipboardAfterShiftInsert = restoreClipboardEnabled;
        _toggleHotkeyConfigValue = toggleHotkeyConfigValue;
        _typeBackend = backend;
        _settingsBusy = false;
      });
      _addLog(
        'Settings loaded: remove_period=$removePeriodEnabled, '
        'restore_clipboard_after_shift_insert=$restoreClipboardEnabled, '
        'toggle_hotkey=${_toggleHotkeyOption.label}, '
        'input_backend=${backend.label}',
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _settingsBusy = false;
      });
      _addLog('Failed to load settings: $e');
    }
  }

  Future<void> _setRemovePeriodEnabled(bool enabled) async {
    if (_settingsBusy) {
      return;
    }
    final previous = _removePeriod;
    setState(() {
      _removePeriod = enabled;
      _settingsBusy = true;
    });

    try {
      final config = await _readBackendConfigMap();
      final merged = _mergeConfigWithRemovePeriod(config, enabled);
      await _writeBackendConfigAtomically(merged);
      if (!mounted) {
        return;
      }
      setState(() {
        _settingsBusy = false;
      });
      _addLog('Remove period setting updated: $enabled');
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _removePeriod = previous;
        _settingsBusy = false;
      });
      _addLog('Failed to update remove period setting: $e');
    }
  }

  Future<void> _setShiftInsertRestoreClipboardEnabled(bool enabled) async {
    if (_settingsBusy) {
      return;
    }
    final previous = _restoreClipboardAfterShiftInsert;
    setState(() {
      _restoreClipboardAfterShiftInsert = enabled;
      _settingsBusy = true;
    });

    try {
      final config = await _readBackendConfigMap();
      final merged = _mergeConfigWithShiftInsertRestoreClipboard(
        config,
        enabled,
      );
      await _writeBackendConfigAtomically(merged);
      if (!mounted) {
        return;
      }
      setState(() {
        _settingsBusy = false;
      });
      _addLog('Shift+Insert clipboard restore setting updated: $enabled');
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _restoreClipboardAfterShiftInsert = previous;
        _settingsBusy = false;
      });
      _addLog('Failed to update Shift+Insert clipboard restore setting: $e');
    }
  }

  Future<Map<String, dynamic>> _readBackendConfigMap() async {
    final file = _backendConfigFile();
    if (!await file.exists()) {
      return <String, dynamic>{};
    }
    final raw = await file.readAsString();
    if (raw.trim().isEmpty) {
      return <String, dynamic>{};
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('backend config must be a JSON object');
    }
    return _stringDynamicMap(decoded);
  }

  Map<String, dynamic> _mergeConfigWithRemovePeriod(
    Map<String, dynamic> config,
    bool enabled,
  ) {
    final merged = Map<String, dynamic>.from(config);
    final output = _stringDynamicMap(merged['output']);
    output['remove_period'] = enabled;
    merged['output'] = output;
    return merged;
  }

  Map<String, dynamic> _mergeConfigWithShiftInsertRestoreClipboard(
    Map<String, dynamic> config,
    bool enabled,
  ) {
    final merged = Map<String, dynamic>.from(config);
    final frontend = _stringDynamicMap(merged['frontend']);
    frontend['restore_clipboard_after_shift_insert'] = enabled;
    merged['frontend'] = frontend;
    return merged;
  }

  Map<String, dynamic> _mergeConfigWithTypeBackend(
    Map<String, dynamic> config,
    TypeBackend backend,
  ) {
    final merged = Map<String, dynamic>.from(config);
    final output = _stringDynamicMap(merged['output']);
    output['method'] = backend.configValue;
    merged['output'] = output;
    return merged;
  }

  Map<String, dynamic> _mergeConfigWithToggleHotkey(
    Map<String, dynamic> config,
    String toggleHotkeyConfigValue,
  ) {
    final merged = Map<String, dynamic>.from(config);
    final hotkeys = _stringDynamicMap(merged['hotkeys']);
    hotkeys['toggle'] = toggleHotkeyConfigValue;
    merged['hotkeys'] = hotkeys;
    return merged;
  }

  Future<void> _setTypeBackend(TypeBackend backend) async {
    if (_settingsBusy || backend == _typeBackend) {
      return;
    }

    final previous = _typeBackend;
    setState(() {
      _typeBackend = backend;
      _settingsBusy = true;
    });

    try {
      final config = await _readBackendConfigMap();
      final merged = _mergeConfigWithTypeBackend(config, backend);
      await _writeBackendConfigAtomically(merged);
      if (!mounted) {
        return;
      }
      setState(() {
        _settingsBusy = false;
      });
      _addLog(
        'Input backend updated: ${backend.label} '
        '(effective: ${_effectiveBackendForCurrentSession().label})',
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _typeBackend = previous;
        _settingsBusy = false;
      });
      _addLog('Failed to update input backend: $e');
    }
  }

  Future<void> _setToggleHotkey(String configValue) async {
    final nextConfigValue = _toggleHotkeyOptionForConfigValue(
      configValue,
    ).configValue;
    if (_settingsBusy || nextConfigValue == _toggleHotkeyConfigValue) {
      return;
    }

    final previousConfigValue = _toggleHotkeyConfigValue;
    setState(() {
      _toggleHotkeyConfigValue = nextConfigValue;
      _settingsBusy = true;
    });

    Map<String, dynamic>? previousConfig;
    try {
      previousConfig = await _readBackendConfigMap();
      final merged = _mergeConfigWithToggleHotkey(
        previousConfig,
        nextConfigValue,
      );
      await _writeBackendConfigAtomically(merged);
      await _bindHotkey();
      if (!mounted) {
        return;
      }
      setState(() {
        _settingsBusy = false;
      });
      _addLog('Start-recognition hotkey updated: $_toggleHotkeyLabel');
    } catch (e) {
      if (previousConfig != null) {
        try {
          await _writeBackendConfigAtomically(previousConfig);
        } catch (_) {
          // Ignore rollback failures and continue restoring runtime state.
        }
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _toggleHotkeyConfigValue = previousConfigValue;
        _settingsBusy = false;
      });

      try {
        await _bindHotkey();
      } catch (restoreError) {
        _addLog('Failed to restore previous hotkey: $restoreError');
      }
      _addLog('Failed to update start-recognition hotkey: $e');
    }
  }

  Map<String, dynamic> _mergeConfigWithAudioInput(
    Map<String, dynamic> config, {
    required String deviceName,
    required int sampleRate,
    required int inputChannel,
  }) {
    final merged = Map<String, dynamic>.from(config);
    final audio = _stringDynamicMap(merged['audio']);
    audio['device'] = deviceName;
    audio['sample_rate'] = sampleRate;
    audio['input_channel'] = inputChannel;
    merged['audio'] = audio;
    return merged;
  }

  Future<void> _writeBackendConfigAtomically(
    Map<String, dynamic> config,
  ) async {
    final file = _backendConfigFile();
    await file.parent.create(recursive: true);
    final tempName =
        '.${file.uri.pathSegments.last}.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}';
    final tempFile = File('${file.parent.path}/$tempName');
    final payload = '${const JsonEncoder.withIndent('  ').convert(config)}\n';
    await tempFile.writeAsString(payload, flush: true);
    await tempFile.rename(file.path);
  }

  Map<String, dynamic> _stringDynamicMap(Object? value) {
    if (value is Map<String, dynamic>) {
      return Map<String, dynamic>.from(value);
    }
    if (value is Map) {
      final normalized = <String, dynamic>{};
      for (final entry in value.entries) {
        normalized[entry.key.toString()] = entry.value;
      }
      return normalized;
    }
    return <String, dynamic>{};
  }

  AudioInputDevice? _audioInputDeviceFromList(
    List<AudioInputDevice> devices,
    String? name,
  ) {
    if (name == null || name.isEmpty) {
      return null;
    }
    for (final device in devices) {
      if (device.name == name) {
        return device;
      }
    }
    return null;
  }

  AudioInputDevice? _audioInputDeviceByName(String? name) {
    return _audioInputDeviceFromList(_audioInputDevices, name);
  }

  AudioInputDevice? get _selectedAudioInputDevice {
    return _audioInputDeviceByName(_selectedAudioDeviceName);
  }

  int _clampAudioInputChannel(AudioInputDevice? device, int channel) {
    if (device == null) {
      return 0;
    }
    if (channel < 0) {
      return 0;
    }
    if (channel >= device.maxInputChannels) {
      return device.maxInputChannels - 1;
    }
    return channel;
  }

  List<int> _availableAudioInputChannels(AudioInputDevice? device) {
    if (device == null) {
      return const <int>[];
    }
    return List<int>.generate(device.maxInputChannels, (int index) => index);
  }

  String? _resolveAudioDeviceName(
    List<AudioInputDevice> devices,
    Map<String, dynamic> current,
  ) {
    final configuredName = _trimmedStringOrNull(current['device']);
    final configuredMatch = _audioInputDeviceFromList(devices, configuredName);
    if (configuredMatch != null) {
      return configuredMatch.name;
    }

    final resolvedName = _trimmedStringOrNull(current['resolved_device_name']);
    final resolvedMatch = _audioInputDeviceFromList(devices, resolvedName);
    if (resolvedMatch != null) {
      return resolvedMatch.name;
    }

    if (devices.isNotEmpty) {
      return devices.first.name;
    }
    return configuredName ?? resolvedName;
  }

  String _audioInputSummary() {
    if (_audioInputBusy) {
      return '正在读取音频输入设置...';
    }

    final device = _selectedAudioInputDevice;
    if (device == null) {
      return _audioInputDevices.isEmpty ? '未检测到可用的音频输入设备' : '当前音频源不可用，请刷新后重试';
    }

    final resolvedName = _resolvedAudioDeviceName;
    final sourceLabel = resolvedName == null || resolvedName == device.name
        ? device.label
        : '$resolvedName (${device.label})';
    final applyBehavior = _recording ? '录音中切换将在下一次录音时生效' : '切换后无需重启';
    return '$sourceLabel · 通道 ${_selectedAudioInputChannel + 1}/${device.maxInputChannels} · '
        '${_selectedAudioSampleRate}Hz · $applyBehavior';
  }

  Future<void> _loadAudioInputSettings({bool showBusy = true}) async {
    if (showBusy && mounted) {
      setState(() {
        _audioInputBusy = true;
      });
    }

    try {
      await _ensureBackendRunning();
      final resp = await _client.send(<String, dynamic>{
        'cmd': 'list_audio_inputs',
      });
      if (resp['ok'] != true) {
        throw StateError(
          resp['error']?.toString() ?? 'list_audio_inputs_failed',
        );
      }

      final devices = <AudioInputDevice>[];
      final rawDevices = resp['devices'];
      if (rawDevices is List) {
        for (final entry in rawDevices) {
          if (entry is Map) {
            devices.add(AudioInputDevice.fromJson(_stringDynamicMap(entry)));
          }
        }
      }

      final current = _stringDynamicMap(resp['current']);
      final selectedDeviceName = _resolveAudioDeviceName(devices, current);
      final selectedDevice = _audioInputDeviceFromList(
        devices,
        selectedDeviceName,
      );
      final selectedChannel = _clampAudioInputChannel(
        selectedDevice,
        _intFromDynamic(current['input_channel']),
      );
      final fallbackSampleRate = selectedDevice?.defaultSampleRate ?? 44100;
      final sampleRate = _intFromDynamic(
        current['sample_rate'],
        fallback: fallbackSampleRate,
      );

      if (!mounted) {
        return;
      }
      setState(() {
        _audioInputDevices = devices;
        _selectedAudioDeviceName = selectedDeviceName;
        _resolvedAudioDeviceName = _trimmedStringOrNull(
          current['resolved_device_name'],
        );
        _selectedAudioInputChannel = selectedChannel;
        _selectedAudioSampleRate =
            sampleRate > 0 ? sampleRate : fallbackSampleRate;
        _audioInputBusy = false;
      });
      _addLog('Audio inputs loaded: ${devices.length}');
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _audioInputBusy = false;
      });
      _addLog('Failed to load audio inputs: $e');
    }
  }

  Future<void> _applyAudioInputSelection({
    String? deviceName,
    int? inputChannel,
  }) async {
    if (_audioInputBusy) {
      return;
    }

    final previousDeviceName = _selectedAudioDeviceName;
    final previousChannel = _selectedAudioInputChannel;
    final previousSampleRate = _selectedAudioSampleRate;
    final nextDevice = _audioInputDeviceByName(
      deviceName ?? _selectedAudioDeviceName,
    );
    if (nextDevice == null) {
      _addLog('Audio input update skipped: no device selected');
      return;
    }

    final nextChannel = _clampAudioInputChannel(
      nextDevice,
      inputChannel ?? _selectedAudioInputChannel,
    );
    final nextSampleRate = nextDevice.defaultSampleRate > 0
        ? nextDevice.defaultSampleRate
        : previousSampleRate;
    if (nextDevice.name == previousDeviceName &&
        nextChannel == previousChannel &&
        nextSampleRate == previousSampleRate) {
      return;
    }

    setState(() {
      _audioInputBusy = true;
      _selectedAudioDeviceName = nextDevice.name;
      _selectedAudioInputChannel = nextChannel;
      _selectedAudioSampleRate = nextSampleRate;
    });

    Map<String, dynamic>? originalConfig;
    try {
      originalConfig = await _readBackendConfigMap();
      final merged = _mergeConfigWithAudioInput(
        originalConfig,
        deviceName: nextDevice.name,
        sampleRate: nextSampleRate,
        inputChannel: nextChannel,
      );
      await _writeBackendConfigAtomically(merged);
      await _ensureBackendRunning();
      final resp = await _client.send(<String, dynamic>{
        'cmd': 'set_audio_input',
        'device': nextDevice.name,
        'sample_rate': nextSampleRate,
        'input_channel': nextChannel,
      });
      if (resp['ok'] != true) {
        throw StateError(resp['error']?.toString() ?? 'set_audio_input_failed');
      }

      await _loadAudioInputSettings(showBusy: false);
      final appliedNow = resp['applied_now'] == true;
      _addLog(
        'Audio input set: ${nextDevice.label}, channel ${nextChannel + 1}'
        '${appliedNow ? '' : ' (next recording)'}',
      );
      if (!appliedNow && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('录音中的切换会在下一次开始录音时生效')));
      }
    } catch (e) {
      if (originalConfig != null) {
        try {
          await _writeBackendConfigAtomically(originalConfig);
        } catch (_) {
          // Ignore rollback failures and keep UI state consistent.
        }
      } else {
        // Ignore rollback failures and keep UI state consistent.
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _selectedAudioDeviceName = previousDeviceName;
        _selectedAudioInputChannel = previousChannel;
        _selectedAudioSampleRate = previousSampleRate;
        _audioInputBusy = false;
      });
      _addLog('Failed to update audio input: $e');
    }
  }

  Future<void> _showWindowFromTray() async {
    try {
      await windowManager.setSkipTaskbar(false);
      await windowManager.show();
      await windowManager.focus();
    } catch (e) {
      _addLog('Show window failed: $e');
    }
  }

  Future<void> _hideToTray({bool log = true}) async {
    try {
      await windowManager.setSkipTaskbar(true);
      await windowManager.hide();
      if (log) {
        _addLog('Window hidden to tray');
      }
    } catch (e) {
      _addLog('Hide to tray failed: $e');
    }
  }

  Future<void> _popUpTrayMenu() async {
    try {
      await trayManager.popUpContextMenu();
    } catch (e) {
      _addLog('Tray menu popup failed: $e');
    }
  }

  Future<void> _exitApp() async {
    if (_isQuitting) {
      return;
    }
    _isQuitting = true;
    await _stopManagedBackendIfNeeded();
    try {
      await trayManager.destroy();
    } catch (_) {
      // Ignore tray cleanup failures.
    }
    await windowManager.destroy();
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(_showWindowFromTray());
  }

  @override
  void onTrayIconRightMouseDown() {
    if (!Platform.isLinux) {
      unawaited(_popUpTrayMenu());
    }
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show_window':
        unawaited(_showWindowFromTray());
        break;
      case 'exit_app':
        unawaited(_exitApp());
        break;
    }
  }

  @override
  void onWindowClose() {
    if (_isQuitting) {
      return;
    }
    unawaited(_hideToTray());
  }

  Future<void> _bindHotkey() async {
    final option = _toggleHotkeyOption;
    final hotKey = HotKey(key: option.key, scope: HotKeyScope.system);

    await _unbindHotkey();

    await hotKeyManager.register(
      hotKey,
      keyDownHandler: (_) => _onHotkeyDown(),
      keyUpHandler: (_) => _onHotkeyUp(),
    );
    _hotKey = hotKey;

    _addLog(
      'Hotkey registered: ${option.label} (system scope, hold-to-talk mode)',
    );
  }

  Future<void> _unbindHotkey() async {
    final hotKey = _hotKey;
    _hotKey = null;
    if (hotKey != null) {
      await hotKeyManager.unregister(hotKey);
    }
  }

  Future<void> _ping() async {
    final ok = await _daemonPing();
    _addLog('Daemon ping: ${ok ? 'OK' : 'FAILED'}');
  }

  Future<void> _onHotkeyDown() async {
    await _startRecording();
  }

  Future<void> _onHotkeyUp() async {
    await _stopAndTranscribe();
  }

  Future<void> _startRecording() async {
    if (_recording || _busy) {
      return;
    }
    await _ensureBackendRunning();
    if (!await _daemonPing()) {
      _addLog('Start aborted: backend unavailable');
      return;
    }
    setState(() {
      _recording = true;
    });
    _addLog('$_toggleHotkeyLabel down -> start recording');

    try {
      final resp = await _client.send(<String, dynamic>{'cmd': 'start'});
      if (resp['ok'] != true) {
        _addLog('Start failed: ${resp['error']}');
      }
    } catch (e) {
      _addLog('Start failed: $e');
    }
  }

  Future<void> _stopAndTranscribe() async {
    if (!_recording || _busy) {
      return;
    }

    setState(() {
      _recording = false;
      _busy = true;
    });
    _addLog('$_toggleHotkeyLabel up -> stop and transcribe');

    try {
      final resp = await _client.send(<String, dynamic>{
        'cmd': 'stop_and_wait',
        'timeout_ms': 20000,
      });

      if (resp['ok'] == true) {
        final result = resp['result'] as Map<String, dynamic>?;
        final text = (result?['text'] as String? ?? '').trim();
        setState(() {
          _lastText = text;
        });
        _addLog('ASR: ${text.isEmpty ? '(empty)' : text}');
        await _typeToFocusedWindow(text);
      } else {
        _addLog('Stop/ASR failed: ${resp['error']}');
      }
    } catch (e) {
      _addLog('Stop/ASR failed: $e');
    } finally {
      setState(() {
        _busy = false;
      });
    }
  }

  void _addLog(String line) {
    if (!mounted) {
      return;
    }
    final ts = DateTime.now().toIso8601String().substring(11, 19);
    setState(() {
      _logs.insert(0, '[$ts] $line');
      if (_logs.length > 120) {
        _logs.removeRange(120, _logs.length);
      }
    });
  }

  Future<void> _copyLogs() async {
    final text = _logs.join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text.isEmpty ? '没有可复制的日志' : '日志已复制到剪贴板')),
    );
  }

  Future<void> _typeToFocusedWindow(String text) async {
    if (text.isEmpty) {
      return;
    }

    final preferredBackend = _effectiveBackendForCurrentSession();
    final preferredOk = await _typeWithBackend(preferredBackend, text);
    if (preferredOk) {
      return;
    }

    if (_typeBackend == TypeBackend.auto) {
      for (final fallbackBackend in _autoFallbackBackends()) {
        _addLog(
          'Primary backend ${preferredBackend.label} failed, '
          'trying ${fallbackBackend.label}',
        );
        final ok = await _typeWithBackend(fallbackBackend, text);
        if (ok) {
          return;
        }
      }
    }
  }

  TypeBackend _effectiveBackendForCurrentSession() {
    if (_typeBackend != TypeBackend.auto) {
      return _typeBackend;
    }
    return TypeBackend.shiftInsertPaste;
  }

  List<TypeBackend> _autoFallbackBackends() {
    final sessionType = Platform.environment['XDG_SESSION_TYPE']?.toLowerCase();
    if (sessionType == 'wayland') {
      return <TypeBackend>[TypeBackend.wtype, TypeBackend.xdotool];
    }
    return <TypeBackend>[TypeBackend.xdotool, TypeBackend.wtype];
  }

  Future<bool> _typeWithBackend(TypeBackend backend, String text) async {
    if (backend == TypeBackend.shiftInsertPaste) {
      return _pasteWithShiftInsert(text);
    }

    try {
      final ProcessResult result;
      if (backend == TypeBackend.wtype) {
        result = await Process.run('wtype', <String>[text]);
      } else {
        result = await Process.run('xdotool', <String>[
          'type',
          '--clearmodifiers',
          '--delay',
          '0',
          '--',
          text,
        ]);
      }

      if (result.exitCode == 0) {
        _addLog('Typed ASR text via ${backend.label}');
        return true;
      }

      final stderr = (result.stderr ?? '').toString().trim();
      _addLog(
        stderr.isEmpty
            ? '${backend.label} failed with exit code ${result.exitCode}'
            : '${backend.label} failed: $stderr',
      );
      return false;
    } on ProcessException catch (e) {
      _addLog('${backend.label} not available: ${e.message}');
      return false;
    } catch (e) {
      _addLog('${backend.label} failed: $e');
      return false;
    }
  }

  Future<bool> _pasteWithShiftInsert(String text) async {
    final clipboardSnapshot = await _captureClipboardSnapshot();
    Process? clipboardProvider;
    Process? primaryProvider;
    if (Platform.isLinux) {
      clipboardProvider = await _startSelectionProvider('clipboard', text);
      primaryProvider = await _startSelectionProvider('primary', text);
      if (clipboardProvider != null || primaryProvider != null) {
        _addLog(
          'Shift+Insert providers: '
          'clipboard=${clipboardProvider != null}, '
          'primary=${primaryProvider != null}',
        );
      }
      if (clipboardProvider == null) {
        final clipboardOk = await _setClipboardText(text);
        if (!clipboardOk) {
          _addLog('Shift+Insert clipboard update not confirmed');
        }
      }
      if (primaryProvider == null) {
        _addLog('Shift+Insert primary selection provider unavailable');
      }
    } else {
      final clipboardOk = await _setClipboardText(text);
      if (!clipboardOk) {
        _addLog('Shift+Insert clipboard update not confirmed');
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 35));

    try {
      // Send explicit key down/up sequence first to avoid chord parsing issues.
      final sequenceResult = await Process.run('xdotool', <String>[
        'keydown',
        'Shift_L',
        'key',
        'Insert',
        'keyup',
        'Shift_L',
      ]);
      if (sequenceResult.exitCode == 0) {
        _addLog('Pasted ASR text via Shift+Insert');
        return true;
      }

      final chordResult = await Process.run('xdotool', <String>[
        'key',
        '--clearmodifiers',
        'Shift_L+Insert',
      ]);
      if (chordResult.exitCode == 0) {
        _addLog('Pasted ASR text via Shift+Insert (chord fallback)');
        return true;
      }

      final sequenceErr = (sequenceResult.stderr ?? '').toString().trim();
      final chordErr = (chordResult.stderr ?? '').toString().trim();
      _addLog(
        'Shift+Insert failed'
        '${sequenceErr.isEmpty ? '' : ' [sequence: $sequenceErr]'}'
        '${chordErr.isEmpty ? '' : ' [chord: $chordErr]'}',
      );
      return false;
    } on ProcessException catch (e) {
      _addLog('Shift+Insert not available: ${e.message}');
      return false;
    } catch (e) {
      _addLog('Shift+Insert failed: $e');
      return false;
    } finally {
      if (clipboardSnapshot != null ||
          clipboardProvider != null ||
          primaryProvider != null) {
        await Future<void>.delayed(_kShiftInsertRestoreDelay);
      }
      if (clipboardProvider != null) {
        await _cleanupSelectionProvider(clipboardProvider, terminate: true);
      }
      if (primaryProvider != null) {
        await _cleanupSelectionProvider(primaryProvider, terminate: true);
      }
      await _restoreClipboardSnapshot(clipboardSnapshot);
    }
  }

  Future<_ClipboardSnapshot?> _captureClipboardSnapshot() async {
    if (!_restoreClipboardAfterShiftInsert) {
      return null;
    }

    try {
      final text = await _readClipboardText();
      _addLog(
        text == null
            ? 'Shift+Insert clipboard backup unavailable'
            : 'Shift+Insert clipboard backed up',
      );
      return _ClipboardSnapshot(text: text);
    } catch (e) {
      _addLog('Shift+Insert clipboard backup failed: $e');
      return null;
    }
  }

  Future<void> _restoreClipboardSnapshot(_ClipboardSnapshot? snapshot) async {
    if (snapshot == null) {
      return;
    }
    if (snapshot.text == null) {
      _addLog('Shift+Insert clipboard restore skipped: no text to restore');
      return;
    }

    try {
      final restored = await _setClipboardText(snapshot.text!);
      _addLog(
        restored
            ? 'Shift+Insert clipboard restored'
            : 'Shift+Insert clipboard restore not confirmed',
      );
    } catch (e) {
      _addLog('Shift+Insert clipboard restore failed: $e');
    }
  }

  Future<String?> _readClipboardText() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return data?.text;
  }

  Future<bool> _setClipboardText(String text) async {
    for (var i = 0; i < 3; i++) {
      await Clipboard.setData(ClipboardData(text: text));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (await _readClipboardText() == text) {
        return true;
      }
    }

    return false;
  }

  Future<Process?> _startSelectionProvider(
    String selection,
    String text,
  ) async {
    try {
      final process = await Process.start('xclip', <String>[
        '-selection',
        selection,
        '-in',
        '-loops',
        '64',
      ]);
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());
      process.stdin.write(text);
      await process.stdin.close();
      return process;
    } catch (_) {
      return null;
    }
  }

  Future<void> _cleanupSelectionProvider(
    Process process, {
    bool terminate = false,
  }) async {
    try {
      if (terminate) {
        process.kill(ProcessSignal.sigterm);
        await process.exitCode.timeout(const Duration(milliseconds: 500));
        return;
      }
      await process.exitCode.timeout(const Duration(milliseconds: 2500));
    } on TimeoutException {
      process.kill(ProcessSignal.sigterm);
    } catch (_) {
      // Ignore cleanup failures.
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _busy
        ? 'Recognizing'
        : (_recording
            ? 'Recording (release $_toggleHotkeyLabel to stop)'
            : 'Idle (hold $_toggleHotkeyLabel to talk)');

    return Scaffold(
      appBar: AppBar(title: const Text('Vocotype Flutter')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Status: $status',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Text('Last Result: ${_lastText.isEmpty ? '-' : _lastText}'),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                const Text('Input Backend'),
                const SizedBox(width: 12),
                DropdownButton<TypeBackend>(
                  value: _typeBackend,
                  onChanged: _settingsBusy
                      ? null
                      : (TypeBackend? value) {
                          if (value == null) {
                            return;
                          }
                          unawaited(_setTypeBackend(value));
                        },
                  items: TypeBackend.values
                      .map(
                        (TypeBackend backend) => DropdownMenuItem<TypeBackend>(
                          value: backend,
                          child: Text(backend.label),
                        ),
                      )
                      .toList(),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Effective backend: ${_effectiveBackendForCurrentSession().label}',
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                const Expanded(child: Text('开始语音识别快捷键')),
                const SizedBox(width: 12),
                DropdownButton<String>(
                  value: _toggleHotkeyConfigValue,
                  onChanged: _settingsBusy
                      ? null
                      : (String? value) {
                          if (value == null) {
                            return;
                          }
                          unawaited(_setToggleHotkey(value));
                        },
                  items: _kToggleHotkeyOptions
                      .map(
                        (option) => DropdownMenuItem<String>(
                          value: option.configValue,
                          child: Text(option.label),
                        ),
                      )
                      .toList(),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text('按住 $_toggleHotkeyLabel 开始录音，松开后停止并识别'),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '音频输入',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                TextButton.icon(
                  onPressed: _audioInputBusy
                      ? null
                      : () {
                          unawaited(_loadAudioInputSettings());
                        },
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('刷新音频源'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _selectedAudioInputDevice?.name,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: '音频源',
                border: OutlineInputBorder(),
              ),
              items: _audioInputDevices
                  .map(
                    (AudioInputDevice device) => DropdownMenuItem<String>(
                      value: device.name,
                      child: Text(device.label),
                    ),
                  )
                  .toList(),
              onChanged: (_audioInputBusy || _audioInputDevices.isEmpty)
                  ? null
                  : (String? value) {
                      if (value == null) {
                        return;
                      }
                      unawaited(
                        _applyAudioInputSelection(
                          deviceName: value,
                          inputChannel: 0,
                        ),
                      );
                    },
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<int>(
              initialValue: _selectedAudioInputDevice == null
                  ? null
                  : _selectedAudioInputChannel,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: '输入通道',
                border: OutlineInputBorder(),
              ),
              items: _availableAudioInputChannels(_selectedAudioInputDevice)
                  .map(
                    (int channel) => DropdownMenuItem<int>(
                      value: channel,
                      child: Text('通道 ${channel + 1}'),
                    ),
                  )
                  .toList(),
              onChanged: (_audioInputBusy || _selectedAudioInputDevice == null)
                  ? null
                  : (int? value) {
                      if (value == null) {
                        return;
                      }
                      unawaited(_applyAudioInputSelection(inputChannel: value));
                    },
            ),
            const SizedBox(height: 4),
            Text(_audioInputSummary()),
            const SizedBox(height: 12),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('开机启动'),
              subtitle: Text(
                _autostartBusy ? '读取中...' : (_autostartEnabled ? '已启用' : '已关闭'),
              ),
              value: _autostartEnabled,
              onChanged: _autostartBusy
                  ? null
                  : (bool? value) {
                      unawaited(_setAutostartEnabled(value ?? false));
                    },
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('去除句号'),
              subtitle: Text(
                _settingsBusy ? '读写中...' : (_removePeriod ? '已启用' : '已关闭'),
              ),
              value: _removePeriod,
              onChanged: _settingsBusy
                  ? null
                  : (bool value) {
                      unawaited(_setRemovePeriodEnabled(value));
                    },
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Shift+Insert 后恢复剪贴板'),
              subtitle: Text(
                _settingsBusy
                    ? '读写中...'
                    : (_restoreClipboardAfterShiftInsert
                        ? '已启用，粘贴后恢复原剪贴板文本'
                        : '已关闭，Shift+Insert 会覆盖当前剪贴板文本'),
              ),
              value: _restoreClipboardAfterShiftInsert,
              onChanged: _settingsBusy
                  ? null
                  : (bool value) {
                      unawaited(_setShiftInsertRestoreClipboardEnabled(value));
                    },
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: <Widget>[
                ElevatedButton(
                  onPressed: _busy ? null : _startRecording,
                  child: const Text('Start'),
                ),
                ElevatedButton(
                  onPressed: (_busy || !_recording) ? null : _stopAndTranscribe,
                  child: const Text('Stop + Transcribe'),
                ),
                OutlinedButton(
                  onPressed: _ping,
                  child: const Text('Ping Daemon'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                const Expanded(child: Text('Logs')),
                TextButton.icon(
                  onPressed: _copyLogs,
                  icon: const Icon(Icons.copy_all, size: 18),
                  label: const Text('复制日志'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.black26),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  reverse: false,
                  itemCount: _logs.length,
                  itemBuilder: (BuildContext context, int index) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      child: SelectableText(
                        _logs[index],
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
