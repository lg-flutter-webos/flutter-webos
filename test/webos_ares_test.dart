// Copyright (c) 2026 LG Electronics, Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_webos/webos_ares.dart';
import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/process.dart';
import 'package:process/process.dart';
import 'package:test/test.dart';

/// Minimal ProcessManager fake: routes every run() through [handler] and
/// records the issued commands.
class _FakeProcessManager implements ProcessManager {
  _FakeProcessManager(this.handler);

  final ProcessResult Function(List<String> command) handler;
  final commands = <List<String>>[];

  @override
  Future<ProcessResult> run(
    List<Object> command, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding? stdoutEncoding = systemEncoding,
    Encoding? stderrEncoding = systemEncoding,
  }) async {
    final List<String> cmd = command.map((Object e) => e.toString()).toList();
    commands.add(cmd);
    return handler(cmd);
  }

  @override
  ProcessResult runSync(
    List<Object> command, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding? stdoutEncoding = systemEncoding,
    Encoding? stderrEncoding = systemEncoding,
  }) =>
      throw UnimplementedError();

  @override
  Future<Process> start(
    List<Object> command, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) =>
      throw UnimplementedError();

  @override
  bool canRun(dynamic executable, {String? workingDirectory}) => true;

  @override
  bool killPid(int pid, [ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

ProcessResult _ok([String stdout = '']) => ProcessResult(1, 0, stdout, '');
ProcessResult _fail([String stderr = 'boom']) => ProcessResult(1, 1, '', stderr);

AresCli _cli(_FakeProcessManager pm) =>
    AresCli(processManager: pm, logger: BufferLogger.test());

void main() {
  group('run/tryRun', () {
    test('run returns the result on success', () async {
      final pm = _FakeProcessManager((_) => _ok('hello'));
      final RunResult result = await _cli(pm).run('ares-install', <String>['--list']);
      expect(result.exitCode, 0);
      expect(pm.commands.single, <String>['ares-install', '--list']);
    });

    test('run exits the tool with toolchain guidance when ares is missing', () async {
      final pm = _FakeProcessManager(
          (List<String> cmd) => throw ProcessException(cmd.first, cmd.sublist(1)));
      expect(
        () => _cli(pm).run('ares-install', <String>['--list']),
        throwsA(isA<ToolExit>().having(
            (ToolExit e) => e.message, 'message', contains('flutter-webos doctor'))),
      );
    });

    test('tryRun swallows a missing binary and a nonzero exit', () async {
      final missing = _FakeProcessManager(
          (List<String> cmd) => throw ProcessException(cmd.first, cmd.sublist(1)));
      expect(await _cli(missing).tryRun('ares-setup-device', <String>['--remove', 'tv']),
          isFalse);

      final failing = _FakeProcessManager((_) => _fail());
      expect(await _cli(failing).tryRun('ares-setup-device', <String>['--remove', 'tv']),
          isFalse);

      final succeeding = _FakeProcessManager((_) => _ok());
      expect(await _cli(succeeding).tryRun('ares-setup-device', <String>['--remove', 'tv']),
          isTrue);
    });
  });

  group('formatDeviceInfo', () {
    test('without key', () {
      expect(
        AresCli.formatDeviceInfo(host: '10.0.0.2', port: '9922', username: 'prisoner'),
        "{'host':'10.0.0.2', 'port':'9922', 'username':'prisoner'}",
      );
    });

    test('with key and passphrase', () {
      expect(
        AresCli.formatDeviceInfo(
            host: '10.0.0.2',
            port: '9922',
            username: 'prisoner',
            privateKeyName: 'tv_webos',
            passphrase: 'AB12CD'),
        "{'host':'10.0.0.2', 'port':'9922', 'username':'prisoner', "
        "'privatekey':'tv_webos', 'passphrase':'AB12CD'}",
      );
    });
  });

  group('isAppInstalled', () {
    test('matches whole lines only', () async {
      final pm = _FakeProcessManager((_) => _ok('com.example.app2\ncom.example.app\n'));
      expect(await _cli(pm).isAppInstalled('tv', 'com.example.app'), isTrue);
      expect(await _cli(pm).isAppInstalled('tv', 'com.example.ap'), isFalse);
    });

    test('returns false when the listing fails', () async {
      final pm = _FakeProcessManager((_) => _fail());
      expect(await _cli(pm).isAppInstalled('tv', 'com.example.app'), isFalse);
    });
  });

  group('ensureDeviceRegistered', () {
    test('does not add an already-registered device', () async {
      final pm = _FakeProcessManager((_) => _ok('[{"name": "tv", "default": true}]'));
      await _cli(pm).ensureDeviceRegistered('tv', info: 'unused');
      expect(pm.commands.single.take(2), <String>['ares-setup-device', '--listfull']);
    });

    test('adds an unregistered device with the given info', () async {
      final pm = _FakeProcessManager((_) => _ok('[]'));
      const info = "{'host':'10.0.0.2', 'port':'9922', 'username':'prisoner'}";
      await _cli(pm).ensureDeviceRegistered('tv', info: info);
      expect(pm.commands, hasLength(2));
      expect(pm.commands[1], <String>['ares-setup-device', '--add', 'tv', '--info', info]);
    });

    test('checks each device at most once', () async {
      final pm = _FakeProcessManager((_) => _ok('[{"name": "tv"}]'));
      final AresCli cli = _cli(pm);
      await cli.ensureDeviceRegistered('tv', info: 'unused');
      await cli.ensureDeviceRegistered('tv', info: 'unused');
      expect(pm.commands, hasLength(1));
    });
  });

  group('app lifecycle', () {
    test('launchApp passes params through -p', () async {
      final pm = _FakeProcessManager((_) => _ok());
      expect(await _cli(pm).launchApp('tv', 'com.example.app', params: '{"a":1}'),
          isTrue);
      expect(pm.commands.single,
          <String>['ares-launch', 'com.example.app', '-d', 'tv', '-p', '{"a":1}']);
    });

    test('installApp surfaces failure as false', () async {
      final pm = _FakeProcessManager((_) => _fail());
      expect(await _cli(pm).installApp('tv', '/tmp/app.ipk'), isFalse);
    });

    test('removeApp is best-effort', () async {
      final pm = _FakeProcessManager((_) => _fail());
      await _cli(pm).removeApp('tv', 'com.example.app');
      expect(pm.commands.single,
          <String>['ares-install', '--remove', 'com.example.app', '-d', 'tv']);
    });

    test('closeApp goes through ares-launch --close, best-effort', () async {
      final pm = _FakeProcessManager((_) => _fail());
      expect(await _cli(pm).closeApp('tv', 'com.example.app'), isFalse);
      expect(pm.commands.single,
          <String>['ares-launch', '--close', 'com.example.app', '-d', 'tv']);
    });
  });

  group('ares-novacom', () {
    test('runOnDevice wraps the command in --run', () async {
      final pm = _FakeProcessManager((_) => _ok());
      await _cli(pm).runOnDevice('tv', 'rm -rf /tmp/x');
      expect(pm.commands.single,
          <String>['ares-novacom', '--run', 'rm -rf /tmp/x', '-d', 'tv']);
    });

    test('getKey passes the passphrase non-interactively', () async {
      final pm = _FakeProcessManager((_) => _ok());
      expect(await _cli(pm).getKey('tv', 'AB12CD'), isTrue);
      expect(pm.commands.single,
          <String>['ares-novacom', '--getkey', '--passphrase', 'AB12CD', '-d', 'tv']);
    });

    test('isAresNoise matches the status preamble only', () {
      expect(AresCli.isAresNoise('[Info] Set target device : tv'), isTrue);
      expect(AresCli.isAresNoise('flutter: Observatory listening on ...'), isFalse);
    });
  });
}
