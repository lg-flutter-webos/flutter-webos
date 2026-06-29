// Copyright (c) 2023 LG Electronics, Inc. All rights reserved.
// Copyright 2023 Sony Group Corporation. All rights reserved.
// Copyright 2020 Samsung Electronics Co., Ltd. All rights reserved.
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:flutter_tools/src/android/android_workflow.dart';
import 'package:flutter_tools/src/base/context.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/os.dart';
import 'package:flutter_tools/src/base/process.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/context_runner.dart';
import 'package:flutter_tools/src/custom_devices/custom_devices_config.dart';
import 'package:flutter_tools/src/device.dart';
import 'package:flutter_tools/src/features.dart';
import 'package:flutter_tools/src/flutter_device_manager.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/macos/macos_workflow.dart';
import 'package:flutter_tools/src/windows/windows_workflow.dart';
import 'package:process/process.dart';

import 'webos_device.dart';
import 'webos_doctor.dart';
import 'webos_remote_device_config.dart';
import 'webos_remote_devices_config.dart';

/// An extended [FlutterDeviceManager] for managing webOS devices.
class WebosDeviceManager extends FlutterDeviceManager {
  /// Source: [runInContext] in `context_runner.dart`
  WebosDeviceManager()
      : super(
          logger: globals.logger,
          processManager: globals.processManager,
          platform: globals.platform,
          androidSdk: globals.androidSdk,
          iosSimulatorUtils: globals.iosSimulatorUtils!,
          featureFlags: featureFlags,
          fileSystem: globals.fs,
          iosWorkflow: globals.iosWorkflow!,
          artifacts: globals.artifacts!,
          flutterVersion: globals.flutterVersion,
          androidWorkflow: androidWorkflow!,
          xcDevice: globals.xcdevice!,
          userMessages: globals.userMessages,
          windowsWorkflow: windowsWorkflow!,
          macOSWorkflow: context.get<MacOSWorkflow>()!,
          operatingSystemUtils: globals.os,
          customDevicesConfig: CustomDevicesConfig(
            fileSystem: globals.fs,
            logger: globals.logger,
            platform: globals.platform,
          ),
          nativeAssetsBuilder: globals.nativeAssetsBuilder,
        );

  final _webosDeviceDiscovery = WebosDeviceDiscovery(
    webosWorkflow: webosWorkflow!,
    logger: globals.logger,
    processManager: globals.processManager,
  );

  @override
  List<DeviceDiscovery> get deviceDiscoverers => <DeviceDiscovery>[
        ...super.deviceDiscoverers,
        _webosDeviceDiscovery,
      ];
}

/// Device discovery for webOS devices.
class WebosDeviceDiscovery extends PollingDeviceDiscovery {
  WebosDeviceDiscovery({
    required WebosWorkflow webosWorkflow,
    required ProcessManager processManager,
    required Logger logger,
  })  : _webosWorkflow = webosWorkflow,
        _logger = logger,
        _processManager = processManager,
        _processUtils = ProcessUtils(logger: logger, processManager: processManager),
        _webosRemoteDevicesConfig = WebosRemoteDevicesConfig(
          platform: globals.platform,
          fileSystem: globals.fs,
          logger: logger,
        ),
        super('webOS devices');

  final WebosWorkflow _webosWorkflow;
  final Logger _logger;
  final ProcessManager _processManager;
  final ProcessUtils _processUtils;
  final WebosRemoteDevicesConfig _webosRemoteDevicesConfig;

  @override
  bool get supportsPlatform => _webosWorkflow.appliesToHostPlatform;

  @override
  bool get canListAnything => _webosWorkflow.canListDevices;

  @override
  Future<List<Device>> pollingGetDevices({Duration? timeout}) async {
    if (!canListAnything) {
      return const <Device>[];
    }

    final devices = <WebosDevice>[];

    // Adds remote devices.
    for (final WebosRemoteDeviceConfig remoteDevice in _webosRemoteDevicesConfig.devices) {
      if (!remoteDevice.enabled) {
        continue;
      }

      String stdout;
      RunResult result;
      try {
        result = await _processUtils.run(remoteDevice.pingCommand, throwOnError: true);
        stdout = result.stdout.trim();
      } on ProcessException catch (ex) {
        _logger.printTrace('ping failed to list attached devices:\n$ex');
        continue;
      }

      if (result.exitCode == 0 && stdout.contains(remoteDevice.pingSuccessRegex!)) {
        final device = WebosDevice(remoteDevice.id,
            config: remoteDevice,
            desktop: false,
            targetArch: remoteDevice.platform!,
            backendType: remoteDevice.backend!,
            sdkNameAndVersion: remoteDevice.sdkNameAndVersion,
            logger: _logger,
            processManager: _processManager,
            operatingSystemUtils: OperatingSystemUtils(
              fileSystem: globals.fs,
              logger: _logger,
              platform: globals.platform,
              processManager: const LocalProcessManager(),
            ));
        devices.add(device);
      }
    }

    return devices;
  }

  @override
  Future<List<String>> getDiagnostics() async => const <String>[];

  // ignore: unused_element  // fork residue; see 28 / 34.2 (decision pending)
  String _getCurrentHostPlatformArchName() {
    final HostPlatform hostPlatform = getCurrentHostPlatform();
    return hostPlatform.platformName;
  }

  @override
  List<String> get wellKnownIds => const <String>['webOS'];
}
