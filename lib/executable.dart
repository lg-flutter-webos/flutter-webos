// Copyright (c) 2023 LG Electronics, Inc. All rights reserved.
// Copyright 2023 Sony Group Corporation. All rights reserved.
// Copyright 2020 Samsung Electronics Co., Ltd. All rights reserved.
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:flutter_tools/executable.dart' as flutter;
import 'package:flutter_tools/runner.dart' as runner;
import 'package:flutter_tools/src/application_package.dart';
import 'package:flutter_tools/src/artifacts.dart';
import 'package:flutter_tools/src/base/context.dart';
import 'package:flutter_tools/src/base/io.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/template.dart';
import 'package:flutter_tools/src/build_system/build_targets.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/commands/config.dart';
import 'package:flutter_tools/src/commands/devices.dart';
import 'package:flutter_tools/src/commands/emulators.dart';
import 'package:flutter_tools/src/commands/generate_localizations.dart';
import 'package:flutter_tools/src/commands/logs.dart';
import 'package:flutter_tools/src/commands/screenshot.dart';
import 'package:flutter_tools/src/commands/symbolize.dart';
import 'package:flutter_tools/src/dart/pub.dart';
import 'package:flutter_tools/src/device.dart';
import 'package:flutter_tools/src/doctor.dart';
import 'package:flutter_tools/src/features.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/isolated/build_targets.dart';
import 'package:flutter_tools/src/isolated/mustache_template.dart';
import 'package:flutter_tools/src/runner/flutter_command.dart';
import 'package:flutter_tools/src/version.dart';
import 'package:path/path.dart';

import 'commands/analyze.dart';
import 'commands/attach.dart';
import 'commands/build.dart';
import 'commands/clean.dart';
import 'commands/create.dart';
import 'commands/custom_devices.dart';
import 'commands/drive.dart';
import 'commands/install.dart';
import 'commands/packages.dart';
import 'commands/precache.dart';
import 'commands/run.dart';
import 'commands/shell_completion.dart';
import 'commands/test.dart';
import 'commands/upgrade.dart';
import 'webos_artifacts.dart';
import 'webos_cache.dart';
import 'webos_device_discovery.dart';
import 'webos_doctor.dart';
import 'webos_package.dart';
import 'webos_pub.dart';
import 'webos_remote_devices_config.dart';
import 'webos_sdk.dart';
import 'webos_version.dart';

/// Main entry point for commands.
///
/// Source: [flutter.main] in `executable.dart` (some commands and options were omitted)
Future<void> main(List<String> args) async {
  final bool veryVerbose = args.contains('-vv');
  final bool verbose = args.contains('-v') || args.contains('--verbose') || veryVerbose;

  final bool doctor = (args.isNotEmpty && args.first == 'doctor') ||
      (args.length == 2 && verbose && args.last == 'doctor');
  final bool help = args.contains('-h') ||
      args.contains('--help') ||
      (args.isNotEmpty && args.first == 'help') ||
      (args.length == 1 && verbose);
  final bool muteCommandLogging = (help || doctor) && !veryVerbose;
  final bool verboseHelp = help && verbose;

  if (args.isEmpty || args.first != 'completion') {
    args = <String>[
      '--suppress-analytics', // Suppress flutter analytics by default.
      '--no-version-check',
      ...args,
    ];
  }

  Cache.flutterRoot = join(rootPath, 'flutter');

  await runner.run(
    args,
    () => <FlutterCommand>[
      // Commands directly from flutter_tools.
      ConfigCommand(verboseHelp: verboseHelp),
      WebosDevicesCommand(featureFlags: featureFlags),
      DevicesCommand(verboseHelp: verboseHelp),
      WebosDoctorCommand(verbose: verbose),
      EmulatorsCommand(),
      GenerateLocalizationsCommand(
        fileSystem: globals.fs,
        logger: globals.logger,
        artifacts: globals.artifacts!,
        processManager: globals.processManager,
      ),
      WebosInstallCommand(verboseHelp: verboseHelp),
      LogsCommand(
        sigint: ProcessSignal.sigint,
        sigterm: ProcessSignal.sigterm,
      ),
      ScreenshotCommand(fs: globals.fs),
      SymbolizeCommand(stdio: globals.stdio, fileSystem: globals.fs),
      WebosUpgradeCommand(verboseHelp: verboseHelp),
      // Commands extended for webOS.
      WebosAnalyzeCommand(verboseHelp: verboseHelp),
      WebosAttachCommand(
        verboseHelp: verboseHelp,
        stdio: globals.stdio,
        logger: globals.logger,
        terminal: globals.terminal,
        signals: globals.signals,
        platform: globals.platform,
        processInfo: globals.processInfo,
        fileSystem: globals.fs,
      ),
      WebosBuildCommand(verboseHelp: verboseHelp),
      WebosCleanCommand(verbose: verbose),
      WebosCreateCommand(verboseHelp: verboseHelp),
      WebosDriveCommand(verboseHelp: verboseHelp),
      WebosPackagesCommand(),
      WebosPrecacheCommand(
        verboseHelp: verboseHelp,
        cache: globals.cache,
        logger: globals.logger,
        platform: globals.platform,
        featureFlags: featureFlags,
      ),
      WebosRunCommand(verboseHelp: verboseHelp),
      WebosTestCommand(verboseHelp: verboseHelp),
      WebosShellCompletionCommand(),
    ],
    verbose: verbose,
    verboseHelp: verboseHelp,
    muteCommandLogging: muteCommandLogging,
    reportCrashes: false,
    overrides: <Type, Generator>{
      Cache: () => WebosFlutterCache(
            fileSystem: globals.fs,
            logger: globals.logger,
            platform: globals.platform,
            osUtils: globals.os,
            projectFactory: globals.projectFactory,
            processManager: globals.processManager,
          ),
      TemplateRenderer: () => const MustacheTemplateRenderer(),
      ApplicationPackageFactory: () => WebosApplicationPackageFactory(),
      Artifacts: () => WebosArtifacts(
            fileSystem: globals.fs,
            cache: globals.cache,
            platform: globals.platform,
            operatingSystemUtils: globals.os,
          ),
      DeviceManager: () => WebosDeviceManager(),
      DoctorValidatorsProvider: () => WebosDoctorValidatorsProvider(),
      FlutterVersion: () => WebosFlutterVersion(
            fs: globals.fs,
            flutterRoot: Cache.flutterRoot ?? rootPath,
          ),
      WebosRemoteDevicesConfig: () => WebosRemoteDevicesConfig(
            platform: globals.platform,
            fileSystem: globals.fs,
            logger: globals.logger,
          ),
      WebosSdk: () => WebosSdk(
            logger: globals.logger,
            processManager: globals.processManager,
          ),
      Pub: () => WebosPub(
            fileSystem: globals.fs,
            logger: globals.logger,
            processManager: globals.processManager,
            platform: globals.platform,
            botDetector: globals.botDetector,
          ),
      WebosWorkflow: () => WebosWorkflow(
            operatingSystemUtils: globals.os,
          ),
      WebosValidator: () => WebosValidator(
            processManager: globals.processManager,
            userMessages: globals.userMessages,
          ),
      BuildTargets: () => const BuildTargetsImpl(),
      if (verbose && !muteCommandLogging)
        Logger: () => VerboseLogger(StdoutLogger(
              stdio: globals.stdio,
              terminal: globals.terminal,
              outputPreferences: globals.outputPreferences,
            )),
    },
    shutdownHooks: globals.shutdownHooks,
  );
}

/// See: [Cache.defaultFlutterRoot] in `cache.dart`
String get rootPath {
  final String scriptPath = Platform.script.toFilePath();
  return normalize(join(
    scriptPath,
    scriptPath.endsWith('.snapshot') ? '../../..' : '../..',
  ));
}
