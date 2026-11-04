import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import 'client_connection.dart';
import 'coding_client_setup.dart';
import 'package_proxy.dart';

/// Owned by HostController, not a screen: terminals survive navigation.
class ClientToolsController extends ChangeNotifier {
  ClientToolsController(this.app) {
    _identity = _connectionIdentity;
    workspace = app.storage.getSetting('clientTools.workspace');
    _launcherDirectory = app.storage.getSetting('clientTools.launchers');
    _cleanup = _launcherDirectory == null
        ? Future.value()
        : CodingClientSetup.invalidateLaunchers(Directory(_launcherDirectory!));
    app.addListener(_changed);
  }
  final AppState app;
  CodingApiProxy? _api;
  PackageProxy? _packages;
  String? workspace;
  late String _identity;
  String? _launcherDirectory;
  late Future<void> _cleanup;
  final Map<String, String> launchers = {};
  Map<String, String?> installedTools = {};
  bool get apiRunning => _api?.url != null;
  bool get packageRunning => _packages?.port != null;
  Future<void> checkTools() async {
    installedTools = await CodingClientSetup.detectTools();
    notifyListeners();
  }

  Future<void> _saveLauncher(
    String name,
    Directory directory,
    Map<String, String> environment,
  ) async {
    await _cleanup;
    final support = await getApplicationSupportDirectory();
    _launcherDirectory =
        '${support.path}${Platform.pathSeparator}lab-launchers';
    final file = await CodingClientSetup.writeLauncher(
      directory: Directory(_launcherDirectory!),
      name: name,
      workspace: directory,
      environment: environment,
    );
    launchers[name] = file.path;
    await app.storage.setSetting('clientTools.launchers', _launcherDirectory);
    notifyListeners();
  }

  String get _connectionIdentity =>
      '${app.providers[ProviderKind.network]?.baseUrl}|${app.keyFor(ProviderKind.network)}';
  List<String> get models =>
      app.providers[ProviderKind.network]?.models ?? const [];
  void _changed() {
    if (_identity != _connectionIdentity) {
      _identity = _connectionIdentity;
      unawaited(stop());
    }
    notifyListeners();
  }

  Future<void> chooseWorkspace() async {
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: 'Coding project folder',
    );
    if (path != null) {
      workspace = path;
      await app.storage.setSetting('clientTools.workspace', path);
      notifyListeners();
    }
  }

  Directory _workspace() {
    if (workspace == null) throw StateError('Choose a project folder first');
    return Directory(workspace!);
  }

  Uri _upstream() {
    if (!app.hasKey(ProviderKind.network)) {
      throw StateError('Connect to Main first');
    }
    return Uri.parse(app.providers[ProviderKind.network]!.baseUrl);
  }

  Future<Uri> _apiUrl() async {
    final upstream = _upstream();
    final proxy = _api ??= CodingApiProxy();
    return proxy.start(
      upstream: upstream,
      readKey: () async => app.keyFor(ProviderKind.network),
    );
  }

  Future<Map<String, String>> _packageEnvironment() async {
    if (_packages == null) {
      final upstream = _upstream();
      final connection = ClientConnection(
        upstream.toString(),
        app.keyFor(ProviderKind.network),
      );
      try {
        final access = await connection.access();
        final port = access['proxyPort'];
        if (port is! int) {
          throw StateError('Package sharing is unavailable on Main');
        }
        final proxy = PackageProxy(
          upstream: ProxyUpstream(
            host: upstream.host,
            port: port,
            token: app.keyFor(ProviderKind.network),
          ),
        );
        await proxy.start(address: InternetAddress.loopbackIPv4, port: 0);
        _packages = proxy;
      } finally {
        connection.close();
      }
    }
    return CodingClientSetup.packageEnvironment(
      Uri.parse('http://127.0.0.1:${_packages!.port}'),
    );
  }

  Future<void> openCoding({required bool codex, required String model}) async {
    if (!models.contains(model)) {
      throw StateError('Select a currently approved model');
    }
    final directory = _workspace();
    final local = await _apiUrl();
    final env = <String, String>{};
    if (codex) {
      final support = await getApplicationSupportDirectory();
      env.addAll(
        await CodingClientSetup.codex(
          home: Directory('${support.path}${Platform.pathSeparator}lab-codex'),
          localUrl: local,
          model: model,
        ),
      );
    } else {
      env.addAll(CodingClientSetup.claude(localUrl: local, model: model));
    }
    // Package access is optional; opening a coding tool doesn't require it.
    if (_packages != null) env.addAll(await _packageEnvironment());
    await _saveLauncher(codex ? 'codex' : 'claude', directory, env);
    await CodingClientSetup.openWindowsTerminal(
      codex: codex,
      workingDirectory: directory,
      environment: env,
    );
  }

  Future<void> openLabview(String model) async {
    if (!models.contains(model)) {
      throw StateError('Select a currently approved model');
    }
    final directory = _workspace();
    if (!Platform.isWindows) {
      throw UnsupportedError('Windows terminal required');
    }
    final local = await _apiUrl();
    final support = await getApplicationSupportDirectory();
    final env = CodingClientSetup.claude(localUrl: local, model: model);
    env.addAll(
      await CodingClientSetup.codex(
        home: Directory('${support.path}${Platform.pathSeparator}lab-codex'),
        localUrl: local,
        model: model,
      ),
    );
    if (_packages != null) env.addAll(await _packageEnvironment());
    await _saveLauncher('labview', directory, env);
    await Process.start(
      'cmd.exe',
      ['/d', '/c', 'start', '""', 'cmd.exe', '/d', '/k'],
      workingDirectory: directory.path,
      environment: env,
      mode: ProcessStartMode.detached,
    );
  }

  Future<void> openPackageTerminal() async {
    final directory = _workspace();
    if (!Platform.isWindows) {
      throw UnsupportedError('Windows terminal required');
    }
    final env = await _packageEnvironment();
    await _saveLauncher('packages', directory, env);
    await Process.start(
      'cmd.exe',
      ['/d', '/c', 'start', '""', 'cmd.exe', '/d', '/k'],
      workingDirectory: directory.path,
      environment: env,
      mode: ProcessStartMode.detached,
    );
  }

  Future<void> stop() async {
    final api = _api;
    final packages = _packages;
    _api = null;
    _packages = null;
    await api?.close();
    await packages?.stop();
    await _cleanup;
    if (_launcherDirectory != null) {
      await CodingClientSetup.invalidateLaunchers(
        Directory(_launcherDirectory!),
      );
    }
    launchers.clear();
    if (!_disposed) notifyListeners();
  }

  bool _disposed = false;
  @override
  void dispose() {
    _disposed = true;
    app.removeListener(_changed);
    unawaited(stop());
    super.dispose();
  }
}
