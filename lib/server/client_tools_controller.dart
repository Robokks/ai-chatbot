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
    app.addListener(_changed);
  }
  final AppState app;
  CodingApiProxy? _api;
  PackageProxy? _packages;
  String? workspace;
  late String _identity;
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
  }

  @override
  void dispose() {
    app.removeListener(_changed);
    unawaited(stop());
    super.dispose();
  }
}
