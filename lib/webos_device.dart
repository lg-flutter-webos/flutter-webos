// Copyright (c) 2023 LG Electronics, Inc. All rights reserved.
// Copyright 2023 Sony Group Corporation. All rights reserved.
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// ignore_for_file: avoid_catches_without_on_clauses

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_tools/src/android/android_device.dart';
import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/os.dart';
import 'package:flutter_tools/src/base/process.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/convert.dart';
import 'package:flutter_tools/src/device.dart';
import 'package:flutter_tools/src/device_port_forwarder.dart';
import 'package:flutter_tools/src/device_vm_service_discovery_for_attach.dart';
import 'package:flutter_tools/src/project.dart';
import 'package:flutter_tools/src/protocol_discovery.dart';
import 'package:flutter_tools/src/vmservice.dart';

import 'package:process/process.dart';

import 'webos_ares.dart';
import 'webos_builder.dart';
import 'webos_package.dart';
import 'webos_remote_device_config.dart';
import 'webos_sdk.dart';

/// webOS device implementation.
///
/// See: `DesktopDevice` in `desktop_device.dart`
class WebosDevice extends Device {
  WebosDevice(
    super.id, {
    required WebosRemoteDeviceConfig config,
    required bool desktop,
    required String backendType,
    required String targetArch,
    String sdkNameAndVersion = '',
    required super.logger,
    required ProcessManager processManager,
    required OperatingSystemUtils operatingSystemUtils,
  })  : _config = config,
        _desktop = desktop,
        _backendType = backendType,
        _targetArch = targetArch,
        _sdkNameAndVersion = sdkNameAndVersion,
        _logger = logger,
        _processManager = processManager,
        _aresCli = AresCli(processManager: processManager, logger: logger),
        _operatingSystemUtils = operatingSystemUtils,
        super(
            category: desktop ? Category.desktop : Category.mobile,
            platformType: PlatformType.custom,
            ephemeral: true) {
    portForwarder = WebosCustomDevicePortForwarder(
        deviceName: _config.label, deviceId: _config.id, aresCli: _aresCli, logger: _logger);
  }

  static bool preWarmRequested = false;

  final WebosRemoteDeviceConfig _config;
  final bool _desktop;
  final String _backendType;
  final String _targetArch;
  final String _sdkNameAndVersion;
  final Logger _logger;
  final ProcessManager _processManager;
  final OperatingSystemUtils _operatingSystemUtils;
  final _runningProcesses = <Process>{};
  final _logReader = WebosLogReader();
  final AresCli _aresCli;

  int? _forwardedHostPort;
  Process? _logTailProcess;
  BuildMode _buildMode = BuildMode.debug;

  @override
  Future<bool> get isLocalEmulator async => false;

  @override
  Future<String?> get emulatorId async => null;

  @override
  Future<TargetPlatform> get targetPlatform async {
    // Use tester as a platform identifier for webOS.
    // There's currently no other choice because getNameForTargetPlatform()
    // throws an error for unknown platform types.
    return TargetPlatform.tester;
  }

  @override
  bool supportsRuntimeMode(BuildMode buildMode) {
    _buildMode = buildMode;
    return buildMode != BuildMode.jitRelease;
  }

  @override
  Future<String> get sdkNameAndVersion async =>
      _desktop ? _operatingSystemUtils.name : _sdkNameAndVersion;

  @override
  String get name => 'webOS';

  /// Registers this device in the ares device DB on first use, carrying
  /// over the connection info from the flutter custom-devices config.
  Future<void> _ensureAresDevice() {
    return _aresCli.ensureDeviceRegistered(
      _config.id,
      info: AresCli.formatDeviceInfo(
        host: _config.ipAddress ?? 'localhost',
        port: _config.sshPort,
        username: _config.sshUser,
        privateKeyName: _config.sshIdentityFile?.split(Platform.pathSeparator).last,
        passphrase: _config.sshPassPhrase,
      ),
    );
  }

  @override
  Future<bool> isAppInstalled(covariant WebosApp app, {String? userIdentifier}) async {
    await _ensureAresDevice();
    return _aresCli.isAppInstalled(_config.id, app.getAppId());
  }

  /// Device-side record of the SHA-1 of the last installed IPK, mirroring
  /// AndroidDevice's `/data/local/tmp/sky.<id>.sha1`. The devmode temp area
  /// is writable for prisoner; when the device wipes it we simply reinstall.
  static const _deviceSha1Dir = '/media/developer/temp/.flutter-webos';

  String _deviceSha1Path(String appId) => '$_deviceSha1Dir/$appId.sha1';

  String? _sourceIpkSha1(WebosApp app) {
    final ipkFile = File(app.ipkFilePath(_buildMode, _targetArch));
    if (!ipkFile.existsSync()) {
      return null;
    }
    return sha1.convert(ipkFile.readAsBytesSync()).toString();
  }

  /// Compares the local IPK's hash against the device-side install record.
  /// webOS dev IPKs carry no signature to compare, so this relies on stable
  /// IPK bytes — packaging is skipped while the bundle is unchanged.
  ///
  /// Source: [AndroidDevice.isLatestBuildInstalled] in `android_device.dart`
  @override
  Future<bool> isLatestBuildInstalled(covariant WebosApp app) async {
    final String? sourceSha1 = _sourceIpkSha1(app);
    if (sourceSha1 == null) {
      return false;
    }
    await _ensureAresDevice();
    final RunResult result = await _aresCli.runOnDevice(
        _config.id, 'cat ${_deviceSha1Path(app.getAppId())} 2>/dev/null || true');
    if (result.exitCode != 0) {
      return false;
    }
    final String installedSha1 = result.stdout
        .split('\n')
        .map((String line) => line.trim())
        .lastWhere((String line) => line.isNotEmpty && !AresCli.isAresNoise(line),
            orElse: () => '');
    return installedSha1 == sourceSha1;
  }

  /// Best-effort: a missing record only costs a reinstall next run.
  Future<void> _writeDeviceSha1(String appId, String? sha1Hex) async {
    if (sha1Hex == null) {
      return;
    }
    final RunResult result = await _aresCli.runOnDevice(_config.id,
        'mkdir -p $_deviceSha1Dir && echo -n $sha1Hex > ${_deviceSha1Path(appId)}');
    if (result.exitCode != 0) {
      _logger.printTrace('Failed to record the installed IPK sha1: ${result.stderr}');
    }
  }

  @override
  Future<bool> installApp(covariant WebosApp app, {String? userIdentifier}) async {
    final String ipkFilePath = app.ipkFilePath(_buildMode, _targetArch);
    final String appId = app.getAppId();
    _logger.printStatus('requiredACG: ${app.getRequiredPermissions()}');

    // Create native FLUTTER_APPHOME_FOLDER folder and grant permissions.
    // Only when FLUTTER_HOME is an absolute path; relative/empty values are
    // resolved under the bundle's appdata/ at runtime and need no pre-creation.
    final String appType = app.getType();
    final String appHomePath = app.getAppHomePath();
    if (appType == 'native' && appHomePath.startsWith('/')) {
      final makeAppHomeFolderCmd =
          '/usr/bin/test -d $appHomePath || /bin/mkdir -p $appHomePath && /bin/chmod 777 $appHomePath';
      await _ensureAresDevice();
      final RunResult mkdirResult = await _aresCli.runOnDevice(_config.id, makeAppHomeFolderCmd);
      if (mkdirResult.exitCode != 0) {
        _logger.printWarning(
            "Cannot create FLUTTER_APPHOME_FOLDER at $appHomePath. It must be under the /media/developer/temp/ directory.");
      }
    }

    final String? sourceSha1 = _sourceIpkSha1(app);
    if (await isAppInstalled(app, userIdentifier: userIdentifier) &&
        await isLatestBuildInstalled(app)) {
      _logger.printStatus('Latest build already installed.');
      // Close any running instance so the subsequent launch starts the
      // installed build fresh instead of foregrounding the old process.
      await _aresCli.closeApp(_config.id, appId);
      return true;
    }

    // Install over any existing version; appinstalld updates in place, so
    // the previous unconditional uninstall is only a fallback now.
    Status installStatus = _logger.startProgress('Installing app $appId to ${_config.id}...');
    if (await tryInstall(ipkFilePath: ipkFilePath, appId: appId)) {
      installStatus.stop();
      await _writeDeviceSha1(appId, sourceSha1);
      return true;
    }
    installStatus.stop();

    _logger.printStatus('Uninstalling old version...');
    if (!await tryUninstall(appId: appId)) {
      return false;
    }
    installStatus = _logger.startProgress('Installing app $appId to ${_config.id}...');
    final bool result = await tryInstall(ipkFilePath: ipkFilePath, appId: appId);
    installStatus.stop();
    if (result) {
      await _writeDeviceSha1(appId, sourceSha1);
    }
    return result;
  }

  @override
  Future<bool> uninstallApp(covariant WebosApp app, {String? userIdentifier}) async {
    final String appId = app.getAppId();

    // Drop the install record so a stale hash can never claim this appId
    // is still installed.
    await _ensureAresDevice();
    await _aresCli.runOnDevice(_config.id, 'rm -f ${_deviceSha1Path(appId)}');

    return tryUninstall(appId: appId);
  }

  /// Source: [AndroidDevice.startApp] in `android_device.dart`
  @override
  Future<LaunchResult> startApp(
    WebosApp package, {
    String? mainPath,
    String? route,
    DebuggingOptions? debuggingOptions,
    Map<String, Object?> platformArgs = const <String, Object>{},
    bool prebuiltApplication = false,
    bool ipv6 = false,
    String? userIdentifier,
  }) async {
    if (!_desktop) {
      if (!prebuiltApplication) {
        _logger.printTrace('Building app');
        await buildForDevice(
          package,
          buildInfo: debuggingOptions!.buildInfo,
          mainPath: mainPath ?? 'lib/main.dart',
          buildIpk: true,
          userIdentifier: userIdentifier,
        );
      }
      if (!await installApp(package, userIdentifier: userIdentifier)) {
        return LaunchResult.failed();
      }

      ProcessSignal.sigint.watch().listen((ProcessSignal signal) {
        _maybeUnforwardPort();
        _stopLogTail();
      });

      final String appId = package.getAppId();

      // Best-effort cleanup of the previous run's log file.
      await _aresCli.runOnDevice(_config.id, 'rm -rf ${_logFilePathFor(package)}');

      final String launchParams = _buildLaunchParams(
          debuggingOptions, platformArgs['trace-startup'] as bool? ?? false, route);

      if (!await _aresCli.launchApp(_config.id, appId, params: launchParams)) {
        return LaunchResult.failed();
      }

      if (_buildMode == BuildMode.release) {
        _logger.printStatus('Launch succeeded ${package.name} on ${_config.id}');
        return LaunchResult.succeeded();
      }

      await _startLogTail(package);

      final discovery = ProtocolDiscovery.vmService(
        _logReader,
        portForwarder: _config.usesPortForwarding ? portForwarder : null,
        hostPort: debuggingOptions?.hostVmServicePort,
        devicePort: debuggingOptions?.deviceVmServicePort,
        logger: _logger,
        ipv6: ipv6,
      );
      final Uri? observatoryUri = await discovery.uri;
      await discovery.cancel();

      if (_config.usesPortForwarding) {
        _forwardedHostPort = observatoryUri!.port;
      }

      _logger.printStatus('Launch succeeded ${package.name} on ${_config.id}');
      return LaunchResult.succeeded(vmServiceUri: observatoryUri);
    }

    // Target is desktop hosts from here.
    if (!prebuiltApplication) {
      _logger.printTrace('Building app');
      await buildForDevice(
        package,
        buildInfo: debuggingOptions!.buildInfo,
        mainPath: mainPath,
      );
    }

    // Ensure that the executable is locatable.
    final BuildMode buildMode = debuggingOptions!.buildInfo.mode;
    final bool traceStartup = platformArgs['trace-startup'] as bool? ?? false;
    final String executable = executablePathForDevice(package, buildMode);
    const executableOptions = '--bundle=./';

    final Process process = await _processManager.start(
      <String>[
        executable,
        executableOptions,
        if (_desktop && _backendType == 'wayland') '-d',
        ...debuggingOptions.dartEntrypointArgs,
      ],
      environment: _computeEnvironment(debuggingOptions, traceStartup, route),
    );
    _runningProcesses.add(process);
    unawaited(process.exitCode.then((_) => _runningProcesses.remove(process)));

    _logReader.initializeProcess(process);
    if (debuggingOptions.buildInfo.isRelease) {
      return LaunchResult.succeeded();
    }
    final observatoryDiscovery = ProtocolDiscovery.vmService(
      _logReader,
      devicePort: debuggingOptions.deviceVmServicePort,
      hostPort: debuggingOptions.hostVmServicePort,
      ipv6: ipv6,
      logger: _logger,
    );
    try {
      final Uri? observatoryUri = await observatoryDiscovery.uri;
      if (observatoryUri != null) {
        onAttached(package, buildMode, process);
        return LaunchResult.succeeded(vmServiceUri: observatoryUri);
      }
      _logger.printError(
        'Error waiting for a debug connection: '
        'The log reader stopped unexpectedly.',
      );
    } on Exception catch (error) {
      _logger.printError('Error waiting for a debug connection: $error');
    } finally {
      await observatoryDiscovery.cancel();
    }
    return LaunchResult.failed();
  }

  /// The device-side log file the embedder writes for [app].
  String _logFilePathFor(WebosApp app) {
    final String appId = app.getAppId();
    String logPath = app.getDebugLogPath();
    // A relative FLUTTER_APP_LOG_PATH resolves under the app bundle's
    // appdata/ on the device, mirroring the embedder's runtime resolution.
    if (!logPath.startsWith('/')) {
      logPath = '/media/developer/apps/usr/palm/applications/$appId/appdata/$logPath';
    }
    return '$logPath/$appId';
  }

  /// Streams the device log file for [app] into [_logReader].
  ///
  /// Waits device-side for the log file to appear, then tails it from the
  /// first line so that a VM Service URI logged before we attached is still
  /// discovered. tail -F keeps retrying if the file still isn't there when
  /// the wait runs out.
  Future<void> _startLogTail(WebosApp app) async {
    final String logFile = _logFilePathFor(app);
    final tailCmd = 'i=0; while [ ! -f "$logFile" ] && [ \$i -lt 25 ]; do '
        'sleep 0.2; i=\$((i+1)); done; tail -n +1 -F "$logFile"';
    await _ensureAresDevice();
    final Process tailProcess = await _aresCli.startOnDevice(_config.id, tailCmd);
    _logTailProcess = tailProcess;
    tailProcess.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .where((String line) => !AresCli.isAresNoise(line))
        .listen((String line) => _logReader._inputController.add(utf8.encode('$line\n')));
    tailProcess.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String line) {
      _logReader._inputController.add(utf8.encode('$line\n'));
      if (line.contains("can't open")) {
        _logReader._inputController.add(
            utf8.encode('Please wait a moment while the log file is being created. \n'));
      }
    });
  }

  /// Stops streaming the device log file by killing the ares tail process.
  /// The remote tail exits with its SSH session.
  void _stopLogTail() {
    _logTailProcess?.kill();
    _logTailProcess = null;
  }

  @override
  Future<bool> stopApp(covariant WebosApp? app, {String? userIdentifier}) async {
    _maybeUnforwardPort();
    _stopLogTail();

    // Close the app on the device; local desktop processes are killed below.
    if (!_desktop && app != null) {
      await _aresCli.closeApp(_config.id, app.getAppId());
    }

    var succeeded = true;
    // Walk a copy of _runningProcesses, since the exit handler removes from the
    // set.
    for (final process in Set<Process>.of(_runningProcesses)) {
      succeeded &= _processManager.killPid(process.pid);
    }
    return succeeded;
  }

  @override
  void clearLogs() {}

  @override
  Future<DeviceLogReader> getLogReader({
    covariant WebosApp? app,
    bool includePastLogs = false,
  }) async {
    // flutter attach connects to an app launched by an earlier run whose
    // log tail died with that run's process — start one lazily here.
    if (!_desktop && app != null && _logTailProcess == null) {
      await _startLogTail(app);
    }
    return _logReader;
  }

  @override
  VMServiceDiscoveryForAttach getVMServiceDiscoveryForAttach({
    String? appId,
    String? fuchsiaModule,
    int? filterDevicePort,
    int? expectedHostPort,
    required bool ipv6,
    required Logger logger,
  }) {
    // The base implementation requests the log reader without an app, which
    // would never start the lazy log tail attach depends on. Resolve the app
    // from the current project, like the application package factory does.
    final WebosApp? app = _desktop ? null : WebosApp.fromWebosProject(FlutterProject.current());
    return LogScanningVMServiceDiscoveryForAttach(
      getLogReader(app: app),
      portForwarder: portForwarder,
      devicePort: filterDevicePort,
      hostPort: expectedHostPort,
      ipv6: ipv6,
      logger: logger,
    );
  }

  @override
  late final DevicePortForwarder portForwarder;

  @override
  Future<bool> isSupported() async => true;

  @override
  bool get supportsScreenshot => false;

  @override
  bool isSupportedForProject(FlutterProject flutterProject) {
    return flutterProject.isModule && flutterProject.directory.childDirectory('webos').existsSync();
  }

  @override
  Future<void> dispose() async {
    // The ares tail is a child process: it survives tool exit (e.g. after
    // detach) unless killed here.
    _stopLogTail();
  }

  Future<void> buildForDevice(
    WebosApp package, {
    String? mainPath,
    BuildInfo? buildInfo,
    bool buildIpk = false,
    String? userIdentifier,
  }) async {
    final FlutterProject project = FlutterProject.current();
    // Cross-compile with the NDK toolchain, same as the `build webos` command.
    final webosBuildInfo = WebosBuildInfo(
      buildInfo!,
      targetArch: _targetArch,
      targetBackendType: _backendType,
      targetCompilerTriple: webosSdk!.targetCompilerTriple,
      targetSysroot: webosSdk!.targetSysRoot,
      targetCompilerFlags: null,
      targetToolchain: null,
      systemIncludeDirectories: null,
    );
    if (buildIpk) {
      await WebosBuilder.buildPackage(
        project: project,
        targetFile: mainPath!,
        webosBuildInfo: webosBuildInfo,
      );
    } else {
      await WebosBuilder.buildBundle(
        project: project,
        targetFile: mainPath!,
        webosBuildInfo: webosBuildInfo,
      );
    }
  }

  String executablePathForDevice(WebosApp package, BuildMode buildMode) {
    return package.executable(buildMode, _targetArch);
  }

  void onAttached(WebosApp package, BuildMode buildMode, Process process) {}

  /// Builds a JSON string of engine switches from [DebuggingOptions] to be
  /// passed as launch parameters to remote devices via luna-send.
  /// Mirrors the same flags as [_computeEnvironment] but as a JSON object.
  String _buildLaunchParams(DebuggingOptions? debuggingOptions, bool traceStartup, String? route) {
    final engineSwitches = <String, Object>{};

    if (debuggingOptions == null) {
      final launchParams = <String, Object>{'engine-switches': engineSwitches};
      if (preWarmRequested) {
        launchParams['background'] = true;
      }
      return jsonEncode(launchParams);
    }

    engineSwitches['enable-dart-profiling'] = true;

    if (traceStartup) {
      engineSwitches['trace-startup'] = true;
    }
    if (route != null) {
      engineSwitches['route'] = route;
    }
    if (debuggingOptions.enableSoftwareRendering) {
      engineSwitches['enable-software-rendering'] = true;
    }
    if (debuggingOptions.skiaDeterministicRendering) {
      engineSwitches['skia-deterministic-rendering'] = true;
    }
    if (debuggingOptions.traceSkia) {
      engineSwitches['trace-skia'] = true;
    }
    if (debuggingOptions.traceAllowlist != null) {
      engineSwitches['trace-allowlist'] = debuggingOptions.traceAllowlist!;
    }
    if (debuggingOptions.traceSkiaAllowlist != null) {
      engineSwitches['trace-skia-allowlist'] = debuggingOptions.traceSkiaAllowlist!;
    }
    if (debuggingOptions.traceSystrace) {
      engineSwitches['trace-systrace'] = true;
    }
    if (debuggingOptions.endlessTraceBuffer) {
      engineSwitches['endless-trace-buffer'] = true;
    }
    if (debuggingOptions.purgePersistentCache) {
      engineSwitches['purge-persistent-cache'] = true;
    }
    if (debuggingOptions.debuggingEnabled) {
      if (debuggingOptions.deviceVmServicePort != null) {
        engineSwitches['vm-service-port'] = debuggingOptions.deviceVmServicePort.toString();
      }
      if (debuggingOptions.buildInfo.isDebug) {
        engineSwitches['enable-checked-mode'] = true;
        engineSwitches['verify-entry-points'] = true;
      }
      if (debuggingOptions.startPaused) {
        engineSwitches['start-paused'] = true;
      }
      if (debuggingOptions.disableServiceAuthCodes) {
        engineSwitches['disable-service-auth-codes'] = true;
      }
      final String dartVmFlags = debuggingOptions.dartFlags;
      if (dartVmFlags.isNotEmpty) {
        engineSwitches['dart-flags'] = dartVmFlags;
      }
      if (debuggingOptions.useTestFonts) {
        engineSwitches['use-test-fonts'] = true;
      }
      if (debuggingOptions.verboseSystemLogs) {
        engineSwitches['verbose-logging'] = true;
      }
    }
    switch (debuggingOptions.enableImpeller) {
      case ImpellerStatus.enabled:
        engineSwitches['enable-impeller'] = true;
      case ImpellerStatus.disabled:
        engineSwitches['enable-impeller'] = false;
      case ImpellerStatus.platformDefault:
        break;
    }
    if (debuggingOptions.enableFlutterGpu) {
      engineSwitches['enable-flutter-gpu'] = true;
    }

    final launchParams = <String, Object>{'engine-switches': engineSwitches};
    if (preWarmRequested) {
      launchParams['background'] = true;
    }
    return jsonEncode(launchParams);
  }

  /// Source: `DesktopDevice._computeEnvironment` in `desktop_device.dart`
  Map<String, String> _computeEnvironment(
      DebuggingOptions debuggingOptions, bool traceStartup, String? route) {
    var flags = 0;
    final environment = <String, String>{};

    void addFlag(String value) {
      flags += 1;
      environment['FLUTTER_ENGINE_SWITCH_$flags'] = value;
    }

    void finish() {
      environment['FLUTTER_ENGINE_SWITCHES'] = flags.toString();
    }

    addFlag('enable-dart-profiling=true');

    if (traceStartup) {
      addFlag('trace-startup=true');
    }
    if (route != null) {
      addFlag('route=$route');
    }
    if (debuggingOptions.enableSoftwareRendering) {
      addFlag('enable-software-rendering=true');
    }
    if (debuggingOptions.skiaDeterministicRendering) {
      addFlag('skia-deterministic-rendering=true');
    }
    if (debuggingOptions.traceSkia) {
      addFlag('trace-skia=true');
    }
    if (debuggingOptions.traceAllowlist != null) {
      addFlag('trace-allowlist=${debuggingOptions.traceAllowlist}');
    }
    if (debuggingOptions.traceSkiaAllowlist != null) {
      addFlag('trace-skia-allowlist=${debuggingOptions.traceSkiaAllowlist}');
    }
    if (debuggingOptions.traceSystrace) {
      addFlag('trace-systrace=true');
    }
    if (debuggingOptions.endlessTraceBuffer) {
      addFlag('endless-trace-buffer=true');
    }
    if (debuggingOptions.purgePersistentCache) {
      addFlag('purge-persistent-cache=true');
    }
    // Options only supported when there is a VM Service connection between the
    // tool and the device, usually in debug or profile mode.
    if (debuggingOptions.debuggingEnabled) {
      if (debuggingOptions.deviceVmServicePort != null) {
        addFlag('vm-service-port=${debuggingOptions.deviceVmServicePort}');
      }
      if (debuggingOptions.buildInfo.isDebug) {
        addFlag('enable-checked-mode=true');
        addFlag('verify-entry-points=true');
      }
      if (debuggingOptions.startPaused) {
        addFlag('start-paused=true');
      }
      if (debuggingOptions.disableServiceAuthCodes) {
        addFlag('disable-service-auth-codes=true');
      }
      final String dartVmFlags = debuggingOptions.dartFlags;
      if (dartVmFlags.isNotEmpty) {
        addFlag('dart-flags=$dartVmFlags');
      }
      if (debuggingOptions.useTestFonts) {
        addFlag('use-test-fonts=true');
      }
      if (debuggingOptions.verboseSystemLogs) {
        addFlag('verbose-logging=true');
      }
    }
    switch (debuggingOptions.enableImpeller) {
      case ImpellerStatus.enabled:
        addFlag('enable-impeller=true');
      case ImpellerStatus.disabled:
        addFlag('enable-impeller=false');
      case ImpellerStatus.platformDefault:
        break;
    }
    if (debuggingOptions.enableFlutterGpu) {
      addFlag('enable-flutter-gpu=true');
    }
    finish();
    return environment;
  }

  /// Source: [tryUninstall] in `custom_device.dart`
  Future<bool> tryUninstall(
      {required String appId,
      Duration? timeout,
      Map<String, String> additionalReplacementValues = const <String, String>{}}) async {
    await _ensureAresDevice();
    await _aresCli.removeApp(_config.id, appId);
    return true;
  }

  /// Source: [tryInstall] in `custom_device.dart`
  Future<bool> tryInstall(
      {required String ipkFilePath,
      required String appId,
      Duration? timeout,
      Map<String, String> additionalReplacementValues = const <String, String>{}}) async {
    await _ensureAresDevice();
    if (!await _aresCli.installApp(_config.id, ipkFilePath)) {
      return false;
    }
    _logger.printTrace("Installed app $appId on remote device ${_config.id}");

    return true;
  }

  /// Source: [_maybeUnforwardPort] in `custom_device.dart`
  void _maybeUnforwardPort() {
    if (_forwardedHostPort != null) {
      final ForwardedPort forwardedPort =
          portForwarder.forwardedPorts.singleWhere((ForwardedPort forwardedPort) {
        return forwardedPort.hostPort == _forwardedHostPort;
      });

      _forwardedHostPort = null;
      portForwarder.unforward(forwardedPort);
    }
  }
}

class WebosLogReader extends DeviceLogReader {
  final _inputController = StreamController<List<int>>.broadcast();

  void initializeProcess(Process process) {
    process.stdout.listen(_inputController.add);
    process.stderr.listen(_inputController.add);
    process.exitCode.whenComplete(_inputController.close);
  }

  @override
  Stream<String> get logLines {
    return _inputController.stream.transform(utf8.decoder).transform(const LineSplitter());
  }

  @override
  String get name => 'webOS';

  @override
  void dispose() {}

  @override
  Future<void> provideVmService(FlutterVmService connectedVmService) async {}
}

class WebosCustomDevicePortForwarder extends DevicePortForwarder {
  WebosCustomDevicePortForwarder({
    required String deviceName,
    required String deviceId,
    required AresCli aresCli,
    this.numTries,
    required Logger logger,
  })  : _deviceName = deviceName,
        _deviceId = deviceId,
        _aresCli = aresCli,
        _logger = logger;

  final String _deviceName;
  final String _deviceId;
  final AresCli _aresCli;
  final int? numTries;
  final Logger _logger;
  final _forwardedPorts = <ForwardedPort>[];

  /// One `ares-novacom --forward` tunnel process per forwarded host port.
  final _tunnelProcesses = <int, Process>{};

  @override
  Future<void> dispose() async {
    // Copy: unforward() mutates _forwardedPorts.
    await Future.wait(List<ForwardedPort>.of(_forwardedPorts).map(unforward));
  }

  Future<ForwardedPort?> tryForward(int devicePort, int hostPort) async {
    final Process? tunnel = await _aresCli.startForward(_deviceId, devicePort, hostPort);
    if (tunnel == null) {
      return null;
    }
    _tunnelProcesses[hostPort] = tunnel;
    _logger.printTrace('Forwarding device port $devicePort to host port $hostPort');
    return ForwardedPort(hostPort, devicePort);
  }

  @override
  Future<int> forward(int devicePort, {int? hostPort}) async {
    int actualHostPort = (hostPort == 0 || hostPort == null) ? devicePort : hostPort;
    var tries = 0;

    _logger.printTrace("Forwarding device port $devicePort");

    while ((numTries == null) || (tries < numTries!)) {
      while (_forwardedPorts.any((port) => port.hostPort == actualHostPort)) {
        actualHostPort += 1;
      }

      final ForwardedPort? port = await tryForward(devicePort, actualHostPort);
      if (port != null) {
        _forwardedPorts.add(port);
        return actualHostPort;
      } else {
        actualHostPort += 1;
        tries += 1;
      }
    }
    throwToolExit('Forwarding port for custom device $_deviceName failed after $tries tries.');
  }

  @override
  List<ForwardedPort> get forwardedPorts => List<ForwardedPort>.unmodifiable(_forwardedPorts);

  @override
  Future<void> unforward(ForwardedPort forwardedPort) async {
    assert(_forwardedPorts.contains(forwardedPort));
    _forwardedPorts.remove(forwardedPort);
    final Process? tunnel = _tunnelProcesses.remove(forwardedPort.hostPort);
    if (tunnel != null) {
      tunnel.kill();
      await tunnel.exitCode;
    }
  }
}
