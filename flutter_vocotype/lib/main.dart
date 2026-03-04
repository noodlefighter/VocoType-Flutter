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
const String _kLegacyAutostartAppName = 'VoCoType Fcitx5';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await _migrateLegacyAutostartEntry();
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

Future<void> _migrateLegacyAutostartEntry() async {
  if (!Platform.isLinux) {
    return;
  }
  final home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) {
    return;
  }

  final autostartDir = Directory('$home/.config/autostart');
  final legacyFile =
      File('${autostartDir.path}/$_kLegacyAutostartAppName.desktop');
  if (!await legacyFile.exists()) {
    return;
  }

  final newFile = File('${autostartDir.path}/$_kAutostartAppName.desktop');
  if (await newFile.exists()) {
    return;
  }

  try {
    var content = await legacyFile.readAsString();
    content = content
        .replaceAll(
          'Name=$_kLegacyAutostartAppName',
          'Name=$_kAutostartAppName',
        )
        .replaceAll(
          'Comment=$_kLegacyAutostartAppName startup script',
          'Comment=$_kAutostartAppName startup script',
        );
    await newFile.writeAsString(content);
    await legacyFile.delete();
  } catch (_) {
    // Ignore migration failures.
  }
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
  DaemonClient({this.socketPath = '/tmp/vocotype-fcitx5.sock'});

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
}

class _HomePageState extends State<HomePage> with TrayListener, WindowListener {
  final DaemonClient _client = DaemonClient();
  final List<String> _logs = <String>[];

  bool _recording = false;
  bool _busy = false;
  bool _autostartEnabled = false;
  bool _autostartBusy = true;
  bool _isQuitting = false;
  TypeBackend _typeBackend = _typeBackendFromEnv();
  String _lastText = '';
  HotKey? _hotKey;

  static TypeBackend _typeBackendFromEnv() {
    final raw = (Platform.environment['VOCOTYPE_TYPE_BACKEND'] ?? '')
        .trim()
        .toLowerCase();
    switch (raw) {
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

  @override
  void initState() {
    super.initState();
    trayManager.addListener(this);
    windowManager.addListener(this);
    unawaited(_initDesktopBehaviors());
    unawaited(_bindHotkey());
    unawaited(_ping());
    _addLog(
      'Input backend: ${_typeBackend.label} '
      '(effective: ${_effectiveBackendForCurrentSession().label})',
    );
  }

  @override
  void dispose() {
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    unawaited(_unbindHotkey());
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
        MenuItem(
          key: 'show_window',
          label: '显示窗口',
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'exit_app',
          label: '退出',
        ),
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
    final hotKey = HotKey(
      key: PhysicalKeyboardKey.f2,
      scope: HotKeyScope.system,
    );
    _hotKey = hotKey;

    await hotKeyManager.register(
      hotKey,
      keyDownHandler: (_) => _onF2Down(),
      keyUpHandler: (_) => _onF2Up(),
    );

    _addLog('Hotkey registered: F2 (system scope, hold-to-talk mode)');
  }

  Future<void> _unbindHotkey() async {
    final hotKey = _hotKey;
    if (hotKey != null) {
      await hotKeyManager.unregister(hotKey);
    }
  }

  Future<void> _ping() async {
    try {
      final resp = await _client.send(<String, dynamic>{'cmd': 'ping'});
      _addLog('Daemon ping: ${resp['ok'] == true ? 'OK' : 'FAILED'}');
    } catch (e) {
      _addLog('Daemon ping failed: $e');
    }
  }

  Future<void> _onF2Down() async {
    await _startRecording();
  }

  Future<void> _onF2Up() async {
    await _stopAndTranscribe();
  }

  Future<void> _startRecording() async {
    if (_recording || _busy) {
      return;
    }
    setState(() {
      _recording = true;
    });
    _addLog('F2 down -> start recording');

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
    _addLog('F2 up -> stop and transcribe');

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
        result = await Process.run(
          'xdotool',
          <String>['type', '--clearmodifiers', '--delay', '0', '--', text],
        );
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
      final sequenceResult = await Process.run(
        'xdotool',
        <String>['keydown', 'Shift_L', 'key', 'Insert', 'keyup', 'Shift_L'],
      );
      if (sequenceResult.exitCode == 0) {
        _addLog('Pasted ASR text via Shift+Insert');
        return true;
      }

      final chordResult = await Process.run(
        'xdotool',
        <String>['key', '--clearmodifiers', 'Shift_L+Insert'],
      );
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
      if (clipboardProvider != null) {
        unawaited(_cleanupSelectionProvider(clipboardProvider));
      }
      if (primaryProvider != null) {
        unawaited(_cleanupSelectionProvider(primaryProvider));
      }
    }
  }

  Future<bool> _setClipboardText(String text) async {
    Future<String?> readText() async {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      return data?.text;
    }

    for (var i = 0; i < 3; i++) {
      await Clipboard.setData(ClipboardData(text: text));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (await readText() == text) {
        return true;
      }
    }

    return false;
  }

  Future<Process?> _startSelectionProvider(
      String selection, String text) async {
    try {
      final process = await Process.start(
        'xclip',
        <String>['-selection', selection, '-in', '-loops', '64'],
      );
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());
      process.stdin.write(text);
      await process.stdin.close();
      return process;
    } catch (_) {
      return null;
    }
  }

  Future<void> _cleanupSelectionProvider(Process process) async {
    try {
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
            ? 'Recording (release F2 to stop)'
            : 'Idle (hold F2 to talk)');

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
                  onChanged: (TypeBackend? value) {
                    if (value == null) {
                      return;
                    }
                    setState(() {
                      _typeBackend = value;
                    });
                    _addLog(
                      'Input backend set to ${value.label} '
                      '(effective: ${_effectiveBackendForCurrentSession().label})',
                    );
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
            const Text('Logs'),
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
                      child: Text(
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
