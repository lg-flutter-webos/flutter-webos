// Copyright (c) 2026 LG Electronics, Inc. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/io.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/process.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:process/process.dart';

/// Single gateway for every ares CLI invocation, mirroring the way
/// flutter_tools drives adb for Android devices.
///
/// One-shot commands run to completion and return a [RunResult]. The
/// device id is passed per call; per-device state (such as `Device`
/// lifecycles) stays in `WebosDevice`.
class AresCli {
  AresCli({
    required ProcessManager processManager,
    required Logger logger,
  })  : _processUtils = ProcessUtils(processManager: processManager, logger: logger),
        _processManager = processManager,
        _logger = logger;

  final ProcessUtils _processUtils;
  final ProcessManager _processManager;
  final Logger _logger;

  /// Device names already confirmed to exist in the ares device DB.
  final _checkedDevices = <String>{};

  static const _missingAresHint =
      'The webOS CLI (ares-*) v3.x must be available in PATH. '
      'Check the toolchain with "flutter-webos doctor -v".';

  /// Runs an ares tool to completion. Exits the tool with toolchain
  /// guidance when the binary is not available in PATH.
  Future<RunResult> run(String tool, List<String> args) async {
    try {
      return await _processUtils.run(<String>[tool, ...args]);
    } on ProcessException catch (e) {
      throwToolExit('Failed to run $tool: $e\n$_missingAresHint');
    }
  }

  /// Runs an ares tool best-effort: returns false instead of failing the
  /// command when ares is unavailable or the invocation fails.
  Future<bool> tryRun(String tool, List<String> args) async {
    try {
      final RunResult result = await _processUtils.run(<String>[tool, ...args]);
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  /// Builds an `ares-setup-device --info` value. ares resolves a bare
  /// [privateKeyName] file name under ~/.ssh, which is where
  /// `custom-devices get-key` stores it.
  static String formatDeviceInfo({
    required String host,
    required String port,
    required String username,
    String? privateKeyName,
    String? passphrase,
  }) {
    final info = StringBuffer("{'host':'$host', 'port':'$port', 'username':'$username'");
    if (privateKeyName != null) {
      info.write(", 'privatekey':'$privateKeyName'");
      if (passphrase != null) {
        info.write(", 'passphrase':'$passphrase'");
      }
    }
    info.write('}');
    return info.toString();
  }

  Future<bool> isDeviceRegistered(String name) async {
    final RunResult result = await run('ares-setup-device', <String>['--listfull']);
    return RegExp('"name"\\s*:\\s*"${RegExp.escape(name)}"').hasMatch(result.stdout);
  }

  /// Devices registered before the ares-cli transition only exist in the
  /// flutter custom-devices config, so register them in the ares device DB
  /// on first use. Checked at most once per [name] for this tool run.
  Future<void> ensureDeviceRegistered(String name, {required String info}) async {
    if (!_checkedDevices.add(name)) {
      return;
    }
    if (await isDeviceRegistered(name)) {
      return;
    }
    _logger.printStatus('Device $name is not registered in ares-cli. Registering...');
    final RunResult addResult =
        await run('ares-setup-device', <String>['--add', name, '--info', info]);
    if (addResult.exitCode != 0) {
      _logger.printError('Failed to register device $name in ares-cli: ${addResult.stderr}\n'
          '  Run manually: ares-setup-device --add $name --info "$info"');
    }
  }

  Future<bool> isAppInstalled(String device, String appId) async {
    final RunResult result = await run('ares-install', <String>['--list', '-d', device]);
    if (result.exitCode != 0) {
      _logger.printTrace('isAppInstalled: ares-install --list failed: ${result.stderr}');
      return false;
    }
    return result.stdout.split('\n').any((String line) => line.trim() == appId);
  }

  /// ares-install handles file transfer + installation in one step.
  Future<bool> installApp(String device, String ipkFilePath) async {
    final RunResult result = await run('ares-install', <String>[ipkFilePath, '-d', device]);
    if (result.exitCode != 0) {
      _logger.printError('ares-install failed: ${result.stderr}');
      return false;
    }
    return true;
  }

  /// Best-effort removal; missing apps are not an error.
  Future<void> removeApp(String device, String appId) async {
    final RunResult result =
        await run('ares-install', <String>['--remove', appId, '-d', device]);
    if (result.exitCode != 0) {
      _logger.printTrace('ares-install --remove failed: ${result.stderr}');
    }
  }

  /// Closes a running app on the device, best-effort: closing an app
  /// that is not running is not an error worth failing a stop for.
  Future<bool> closeApp(String device, String appId) =>
      tryRun('ares-launch', <String>['--close', appId, '-d', device]);

  /// Fetches the devmode SSH key served by the Developer Mode app on the
  /// device (port 9991) and registers it together with [passphrase] in the
  /// ares device DB. ares stores the key as `~/.ssh/<device>_webos`.
  Future<bool> getKey(String device, String passphrase) async {
    final RunResult result = await run(
        'ares-novacom', <String>['--getkey', '--passphrase', passphrase, '-d', device]);
    if (result.exitCode != 0) {
      _logger.printError('ares-novacom --getkey failed: ${result.stderr}');
      return false;
    }
    return true;
  }

  /// Runs [command] in the device shell via `ares-novacom --run`.
  /// stdout carries an ares status preamble before the remote output;
  /// callers interested in output should filter with [isAresNoise].
  Future<RunResult> runOnDevice(String device, String command) =>
      run('ares-novacom', <String>['--run', command, '-d', device]);

  /// True for ares status lines (e.g. `[Info] Set target device : tv`)
  /// that are not part of the remote command's own output.
  static bool isAresNoise(String line) => line.startsWith('[Info]');

  /// Live long-lived ares child processes (log tails, forward tunnels)
  /// across all [AresCli] instances. These survive tool exit as orphans
  /// unless killed — and the detach/attach exit paths don't reliably
  /// reach dispose()/unforward — so they are reaped by a tool shutdown
  /// hook.
  static final _liveProcesses = <Process>{};
  static var _shutdownHookRegistered = false;

  /// Starts a long-lived ares process, reaped at tool exit at the latest.
  /// Exits the tool with toolchain guidance when the binary is not
  /// available in PATH.
  Future<Process> _start(List<String> command) async {
    _logger.printTrace(command.join(' '));
    try {
      final Process process = await _processManager.start(command);
      _liveProcesses.add(process);
      unawaited(process.exitCode.then((int _) => _liveProcesses.remove(process)));
      if (!_shutdownHookRegistered) {
        _shutdownHookRegistered = true;
        globals.shutdownHooks.addShutdownHook(() {
          for (final process in Set<Process>.of(_liveProcesses)) {
            process.kill();
          }
        });
      }
      return process;
    } on ProcessException catch (e) {
      throwToolExit('Failed to run ${command.first}: $e\n$_missingAresHint');
    }
  }

  /// Starts [command] in the device shell via `ares-novacom --run` and
  /// returns the live process for streaming its output (e.g. a log tail).
  /// Kill the process to stop the remote command. stdout begins with an
  /// ares status preamble; filter lines with [isAresNoise].
  Future<Process> startOnDevice(String device, String command) =>
      _start(<String>['ares-novacom', '--run', command, '-d', device]);

  /// Starts forwarding [devicePort] on the device to [hostPort] on the host
  /// via `ares-novacom --forward`. Completes with the running tunnel process
  /// once ares reports the tunnel is up, or null when setup fails (e.g. the
  /// host port is already in use). Kill the returned process to unforward.
  Future<Process?> startForward(String device, int devicePort, int hostPort) async {
    final Process process = await _start(<String>[
      'ares-novacom', '--forward', '--port', '$devicePort:$hostPort', '-d', device,
    ]);
    final ready = Completer<bool>();
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
      (String line) {
        _logger.printTrace('ares-novacom forward: $line');
        // ares prints "forward running..." once the local server is bound.
        if (!ready.isCompleted && line.contains('running')) {
          ready.complete(true);
        }
      },
      onError: (Object _) {},
    );
    process.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(
      (String line) => _logger.printTrace('ares-novacom forward stderr: $line'),
      onError: (Object _) {},
    );
    unawaited(process.exitCode.then((int code) {
      if (!ready.isCompleted) {
        ready.complete(false);
      }
    }));
    if (await ready.future) {
      return process;
    }
    return null;
  }

  Future<bool> launchApp(String device, String appId, {String? params}) async {
    final RunResult result = await run('ares-launch', <String>[
      appId,
      '-d',
      device,
      if (params != null) ...<String>['-p', params],
    ]);
    if (result.exitCode != 0) {
      _logger.printError('ares-launch failed: ${result.stderr}');
      return false;
    }
    return true;
  }
}
