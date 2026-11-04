import 'dart:convert';
import 'dart:io';

import 'package:ai_chatbot/server/coding_client_setup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'launcher data is encoded, uses dummy credentials and can be stopped',
    () async {
      final directory = await Directory.systemTemp.createTemp('launchers_');
      addTearDown(() => directory.delete(recursive: true));
      final workspace = Directory('${directory.path}/project & value');
      final env = CodingClientSetup.claude(
        localUrl: Uri.parse('http://127.0.0.1:1234'),
        model: 'model with "quotes"',
      );
      final launcher = await CodingClientSetup.writeLauncher(
        directory: directory,
        name: 'claude',
        workspace: workspace,
        environment: env,
      );
      final contents = await File('${directory.path}/lab-claude.ps1')
          .readAsString();
      expect(contents, contains('FromBase64String'));
      expect(contents, contains('Set-Location -LiteralPath'));
      expect(contents, isNot(contains(workspace.path)));
      final encoded = RegExp("FromBase64String\\('([^']+)'\\)")
          .firstMatch(contents)!
          .group(1)!;
      final data = jsonDecode(utf8.decode(base64Decode(encoded))) as Map;
      expect(data['workspace'], workspace.absolute.path);
      expect((data['environment'] as Map)['ANTHROPIC_AUTH_TOKEN'], 'lab-local');
      expect(await launcher.exists(), isTrue);
      await expectLater(
        CodingClientSetup.writeLauncher(
          directory: directory,
          name: 'codex',
          workspace: workspace,
          environment: {'OPENAI_API_KEY': 'real-secret'},
        ),
        throwsArgumentError,
      );
      await CodingClientSetup.invalidateLaunchers(directory);
      expect(
        await File('${directory.path}/lab-claude.ps1').readAsString(),
        contains('Session stopped'),
      );
      expect(
        await File('${directory.path}/lab-claude.ps1').readAsString(),
        isNot(contains('FromBase64String')),
      );
    },
  );
  test(
    'tool detection checks injected PATH without running any executables',
    () async {
      final directory = await Directory.systemTemp.createTemp('detection_');
      addTearDown(() => directory.delete(recursive: true));
      await File('${directory.path}/claude.cmd')
          .writeAsString('must never run');
      await File('${directory.path}/git.exe').writeAsString('must never run');
      final found = await CodingClientSetup.detectTools(
        environment: {'PATH': directory.path, 'PATHEXT': '.EXE;.CMD'},
        windows: true,
      );
      expect(found['claude'], endsWith('claude.cmd'));
      expect(found['git'], endsWith('git.exe'));
      expect(found['codex'], isNull);
      expect(found['python'], isNull);
    },
  );
}
