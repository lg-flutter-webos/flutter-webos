// Copyright (c) 2023 LG Electronics, Inc. All rights reserved.
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/application_package.dart';
import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/commands/install.dart';
import 'package:flutter_tools/src/device.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/runner/flutter_command.dart';

/// See: [InstallCommand] in install.dart
class WebosInstallCommand extends InstallCommand {
  WebosInstallCommand({super.verboseHelp = false});

  @override
  Future<FlutterCommandResult> runCommand() async {
    final Device targetDevice = device!;
    final ApplicationPackage? package = await applicationPackages?.getPackageForPlatform(
      await targetDevice.targetPlatform,
    );
    if (package == null) {
      throwToolExit('Could not find or build package');
    }

    final BuildMode buildMode = getBuildMode();
    if (targetDevice.supportsRuntimeMode(buildMode) == false) {
      throwToolExit('Unsupported $buildMode to $device');
    }

    globals.printStatus('Working for the [$buildMode] mode...');

    if (uninstallOnly) {
      await _uninstallApp(package, targetDevice);
    } else {
      await _installApp(package, targetDevice);
    }
    return FlutterCommandResult.success();
  }

  /// See: [_uninstallApp] in install.dart
  /// There is no way to call parent private function from child class.
  Future<void> _uninstallApp(ApplicationPackage package, Device device) async {
    if (await device.isAppInstalled(package, userIdentifier: userIdentifier)) {
      globals.printStatus('Uninstalling $package from $device...');

      if (!await device.uninstallApp(package, userIdentifier: userIdentifier)) {
        globals.printError('Uninstalling old version failed - $userIdentifier');
      }
    } else {
      globals.printStatus('$package not found on $device, skipping uninstall');
    }
  }

  /// See: [_installApp] in install.dart
  /// There is no way to call parent private function from child class.
  Future<void> _installApp(ApplicationPackage package, Device device) async {
    globals.printStatus('Installing $package to $device...');

    if (!await installApp(device, package, userIdentifier: userIdentifier)) {
      globals.printError('Installing webos app old version failed - $userIdentifier');
      throwToolExit('Install failed');
    }
  }
}
