import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A credential boundary for local coding clients: the Main key never enters
/// their settings, process arguments or environment.
class CodingApiProxy {
  HttpServer? _server;
  final HttpClient _client = HttpClient();
  final Set<HttpClientRequest> _active = {};
  final Set<Socket> _sockets = {};
  Uri? get url =>
      _server == null ? null : Uri.parse('http://127.0.0.1:${_server!.port}');

  Future<Uri> start({
    required Uri upstream,
    required Future<String> Function() readKey,
  }) async {
    if (!['http', 'https'].contains(upstream.scheme) ||
        upstream.userInfo.isNotEmpty ||
        upstream.host.isEmpty) {
      throw ArgumentError('Invalid Main URL');
    }
    if (_server != null) return url!;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((request) async {
      HttpClientRequest? remote;
      Socket? downstream;
      StreamSubscription<List<int>>? body;
      Completer<void>? forwarded;
      var disconnected = false;
      var finished = false;
      void cancel() {
        if (finished || disconnected) return;
        disconnected = true;
        remote?.abort();
        downstream?.destroy();
        unawaited(body?.cancel());
        if (forwarded != null && !forwarded.isCompleted) forwarded.complete();
      }

      try {
        if (request.uri.path == '/v1/messages/count_tokens' &&
            request.method == 'POST' &&
            (request.headers.value('authorization') == 'Bearer lab-local' ||
                request.headers.value('x-api-key') == 'lab-local')) {
          request.response.statusCode = HttpStatus.notImplemented;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'type': 'error',
              'error': {
                'type': 'api_error',
                'message': 'Exact token counting is unavailable for routed models. No estimated count is returned.',
              },
            }),
          );
          await request.response.close();
          return;
        }
        final allowed =
            (request.method == 'POST' &&
                [
                  '/v1/messages',
                  '/v1/responses',
                  '/v1/chat/completions',
                ].contains(request.uri.path)) ||
            (request.method == 'GET' && request.uri.path == '/v1/models');
        if (!allowed ||
            request.uri.hasAuthority ||
            request.headers.value(HttpHeaders.authorizationHeader) !=
                    'Bearer lab-local' &&
                request.headers.value('x-api-key') != 'lab-local') {
          request.response.statusCode = HttpStatus.forbidden;
          await request.response.close();
          return;
        }
        final key = await readKey();
        if (key.isEmpty) throw StateError('Connect to Main first');
        final base = upstream.path.replaceFirst(RegExp(r'/+$'), '');
        final path = base.endsWith('/v1')
            ? '$base${request.uri.path.substring(3)}'
            : '$base${request.uri.path}';
        remote = await _client.openUrl(
          request.method,
          upstream.replace(path: path, query: request.uri.query),
        );
        if (disconnected) {
          remote.abort();
          return;
        }
        remote.followRedirects = false;
        _active.add(remote);
        remote.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
        for (final name in [
          'content-type',
          'accept',
          'anthropic-version',
          'anthropic-beta',
        ]) {
          final value = request.headers.value(name);
          if (value != null) remote.headers.set(name, value);
        }
        await remote.addStream(request);
        // Own the loopback socket so a FIN is observable even while Main is
        // stalled. HttpResponse.done alone waits for the next write to fail.
        downstream = await request.response.detachSocket(writeHeaders: false);
        _sockets.add(downstream);
        downstream.listen(
          (_) {},
          onDone: cancel,
          onError: (Object _) => cancel(),
        );
        final response = await remote.close();
        if (disconnected) return;
        downstream.write(
          'HTTP/1.1 ${response.statusCode} ${response.reasonPhrase}\r\nConnection: close\r\n',
        );
        for (final name in ['content-type', 'retry-after', 'cache-control']) {
          final value = response.headers.value(name);
          if (value != null) downstream.write('$name: $value\r\n');
        }
        downstream.write('\r\n');
        forwarded = Completer<void>();
        body = response.listen(
          (bytes) {
            if (disconnected) return;
            body?.pause();
            try {
              downstream!.add(bytes);
            } catch (_) {
              cancel();
              return;
            }
            unawaited(
              downstream.flush().then((_) {
                if (!disconnected) body?.resume();
              }, onError: (Object _) => cancel()),
            );
          },
          onError: (Object error, StackTrace stack) {
            if (!forwarded!.isCompleted) forwarded.completeError(error, stack);
          },
          onDone: () {
            if (!forwarded!.isCompleted) forwarded.complete();
          },
          cancelOnError: true,
        );
        await forwarded.future;
        if (disconnected) return;
        finished = true;
        await downstream.flush();
        await downstream.close();
      } catch (_) {
        if (disconnected || downstream != null) return;
        try {
          request.response.statusCode = HttpStatus.badGateway;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'error': {'message': 'Main connection unavailable'},
            }),
          );
          await request.response.close();
        } catch (_) {
          /* Client already disconnected. */
        }
      } finally {
        finished = true;
        if (remote != null) _active.remove(remote);
        if (downstream != null) {
          _sockets.remove(downstream);
          downstream.destroy();
        }
        await body?.cancel();
      }
    });
    return url!;
  }

  Future<void> close() async {
    for (final request in _active) {
      request.abort();
    }
    _active.clear();
    for (final socket in _sockets) {
      socket.destroy();
    }
    _sockets.clear();
    await _server?.close(force: true);
    _server = null;
    _client.close(force: true);
  }
}

/// Isolated CODEX_HOME avoids modifying existing user settings or credentials.
/// Launch the executable directly with these environment values and a selected
/// workingDirectory; never put a prompt or script into command arguments.
class CodingClientSetup {
  /// Apply to launched terminal/process only: git, pip and npm honor these.
  /// Existing global package settings remain intact after the session closes.
  static Map<String, String> packageEnvironment(Uri localProxy) {
    if (localProxy.scheme != 'http' ||
        localProxy.host != '127.0.0.1' ||
        localProxy.userInfo.isNotEmpty ||
        !localProxy.hasPort) {
      throw ArgumentError(
        'Package proxy must be a credential-free loopback URL',
      );
    }
    final url = localProxy.toString();
    return {
      'HTTP_PROXY': url,
      'HTTPS_PROXY': url,
      'http_proxy': url,
      'https_proxy': url,
      'npm_config_proxy': url,
      'npm_config_https_proxy': url,
      'NO_PROXY': '127.0.0.1,localhost,::1',
      'no_proxy': '127.0.0.1,localhost,::1',
    };
  }

  /// Fixed terminal commands only. Prompts/scripts are never shell arguments.
  static Future<void> openWindowsTerminal({
    required bool codex,
    required Directory workingDirectory,
    required Map<String, String> environment,
  }) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('Windows terminal required');
    }
    if (!await workingDirectory.exists()) {
      throw ArgumentError('Working folder does not exist');
    }
    await Process.start(
      'cmd.exe',
      [
        '/d',
        '/c',
        'start',
        '""',
        'cmd.exe',
        '/d',
        '/k',
        codex ? 'codex' : 'claude',
      ],
      workingDirectory: workingDirectory.path,
      environment: environment,
      mode: ProcessStartMode.detached,
    );
  }

  /// Check executable presence without running installers or shell commands.
  static Future<Map<String, String?>> detectTools({
    Map<String, String>? environment,
    bool? windows,
  }) async {
    final env = environment ?? Platform.environment;
    final win = windows ?? Platform.isWindows;
    final paths = (env['PATH'] ?? env['Path'] ?? '').split(win ? ';' : ':');
    final extensions = win
        ? ['', ...(env['PATHEXT'] ?? '.COM;.EXE;.BAT;.CMD').split(';')]
        : [''];
    final found = <String, String?>{};
    for (final tool in [
      'claude',
      'codex',
      'python',
      'node',
      'npm',
      'git',
      'dynasbrain',
    ]) {
      String? location;
      for (final directory in paths.where((p) => p.isNotEmpty)) {
        for (final extension in extensions) {
          final path =
              '${directory.replaceAll('"', '')}${Platform.pathSeparator}$tool${win ? extension.toLowerCase() : extension}';
          if (await File(path).exists()) {
            location = path;
            break;
          }
        }
        if (location != null) break;
      }
      found[tool] = location;
    }
    return found;
  }

  static const launcherNames = ['claude', 'codex', 'packages', 'labview'];
  static Future<File> writeLauncher({
    required Directory directory,
    required String name,
    required Directory workspace,
    required Map<String, String> environment,
  }) async {
    if (!launcherNames.contains(name)) throw ArgumentError('Unknown launcher');
    // Allow only settings produced by this helper, never arbitrary credentials.
    const allowed = {
      'CODEX_HOME',
      'OPENAI_API_KEY',
      'OPENAI_BASE_URL',
      'ANTHROPIC_BASE_URL',
      'ANTHROPIC_AUTH_TOKEN',
      'ANTHROPIC_API_KEY',
      'ANTHROPIC_MODEL',
      'ANTHROPIC_DEFAULT_SONNET_MODEL',
      'ANTHROPIC_DEFAULT_OPUS_MODEL',
      'ANTHROPIC_DEFAULT_HAIKU_MODEL',
      'HTTP_PROXY',
      'HTTPS_PROXY',
      'http_proxy',
      'https_proxy',
      'npm_config_proxy',
      'npm_config_https_proxy',
      'NO_PROXY',
      'no_proxy',
    };
    if (environment.keys.any((key) => !allowed.contains(key)) ||
        ['OPENAI_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_API_KEY'].any(
          (key) =>
              environment[key] != null &&
              environment[key] != '' &&
              environment[key] != 'lab-local',
        )) {
      throw ArgumentError('Launchers may contain only dummy credentials');
    }
    await directory.create(recursive: true);
    final encoded = base64Encode(
      utf8.encode(
        jsonEncode({
          'workspace': workspace.absolute.path,
          'environment': environment,
        }),
      ),
    );
    final script = File(
      '${directory.path}${Platform.pathSeparator}lab-$name.ps1',
    );
    final command = name == 'claude'
        ? '& claude'
        : name == 'codex'
        ? '& codex'
        : '& cmd.exe /d /k';
    await script.writeAsString(
      "\$session = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$encoded')) | ConvertFrom-Json\r\n"
      "foreach (\$entry in \$session.environment.PSObject.Properties) { [Environment]::SetEnvironmentVariable(\$entry.Name, [string]\$entry.Value, 'Process') }\r\n"
      "Set-Location -LiteralPath \$session.workspace\r\nWrite-Host 'Keep the Lab app open. Main access rules still apply.'\r\n$command\r\n",
      flush: true,
    );
    final launcher = File(
      '${directory.path}${Platform.pathSeparator}lab-$name.cmd',
    );
    await launcher.writeAsString(
      '@echo off\r\npowershell.exe -NoProfile -NoExit -ExecutionPolicy Bypass -File "%~dp0lab-$name.ps1"\r\n',
      flush: true,
    );
    return launcher;
  }

  static Future<void> invalidateLaunchers(Directory directory) async {
    if (!await directory.exists()) return;
    for (final name in launcherNames) {
      final script = File(
        '${directory.path}${Platform.pathSeparator}lab-$name.ps1',
      );
      if (await script.exists()) {
        await script.writeAsString(
          "Write-Host 'Session stopped. Open the Lab app and set up this tool again.'\r\n",
          flush: true,
        );
      }
    }
  }

  static String _toml(String text) => jsonEncode(text);
  static Future<Map<String, String>> codex({
    required Directory home,
    required Uri localUrl,
    required String model,
  }) async {
    await home.create(recursive: true);
    final file = File('${home.path}${Platform.pathSeparator}config.toml');
    final contents =
        'model = ${_toml(model)}\nmodel_provider = "lab_main"\nweb_search = "disabled"\nmodel_reasoning_effort = "none"\nmodel_reasoning_summary = "none"\n'
        '[model_providers.lab_main]\nname = "Lab Main"\nbase_url = ${_toml('${localUrl.toString().replaceFirst(RegExp(r'/+$'), '')}/v1')}\n'
        'wire_api = "responses"\nrequires_openai_auth = false\nsupports_websockets = false\nexperimental_bearer_token = "lab-local"\n';
    // The app owns this dedicated home. Refuse to overwrite unrelated settings.
    if (await file.exists() &&
        !(await file.readAsString()).contains('model_provider = "lab_main"')) {
      throw StateError('Choose an empty dedicated Codex home');
    }
    await file.writeAsString(contents, flush: true);
    return {
      'CODEX_HOME': home.absolute.path,
      'OPENAI_API_KEY': 'lab-local',
      'OPENAI_BASE_URL':
          '${localUrl.toString().replaceFirst(RegExp(r'/+$'), '')}/v1',
    };
  }

  static Map<String, String> claude({
    required Uri localUrl,
    required String model,
  }) => {
    'ANTHROPIC_BASE_URL': localUrl.toString(),
    'ANTHROPIC_AUTH_TOKEN': 'lab-local',
    'ANTHROPIC_API_KEY': '',
    'ANTHROPIC_DEFAULT_SONNET_MODEL': model,
    'ANTHROPIC_DEFAULT_OPUS_MODEL': model,
    'ANTHROPIC_DEFAULT_HAIKU_MODEL': model,
    'ANTHROPIC_MODEL': model,
  };
}
