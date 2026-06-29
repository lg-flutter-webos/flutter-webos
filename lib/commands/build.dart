// Copyright (c) 2023 LG Electronics, Inc. All rights reserved.
// Copyright 2023 Sony Group Corporation. All rights reserved.
// Copyright 2020 Samsung Electronics Co., Ltd. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/android/build_validation.dart' as android;
import 'package:flutter_tools/src/base/analyze_size.dart';
import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/os.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/commands/build.dart';
import 'package:flutter_tools/src/commands/build_apk.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/project.dart';
import 'package:flutter_tools/src/runner/flutter_command.dart';

import '../webos_builder.dart';
import '../webos_cache.dart';
import '../webos_plugins.dart';
import '../webos_sdk.dart';

class WebosBuildCommand extends BuildCommand {
  WebosBuildCommand({bool verboseHelp = false})
      : super(
          fileSystem: globals.fs,
          buildSystem: globals.buildSystem,
          osUtils: globals.os,
          verboseHelp: verboseHelp,
          androidSdk: globals.androidSdk,
          logger: globals.logger,
        ) {
    addSubcommand(BuildPackageCommand(verboseHelp: verboseHelp));
  }
}

class BuildPackageCommand extends BuildSubCommand with WebosExtension, WebosRequiredArtifacts {
  /// See: [BuildApkCommand] in `build_apk.dart`
  BuildPackageCommand({bool verboseHelp = false})
      : super(
          verboseHelp: verboseHelp,
          logger: globals.logger,
        ) {
    addCommonDesktopBuildOptions(verboseHelp: verboseHelp);
    usesFlavorOption();

    argParser.addOption(
      'target-arch',
      defaultsTo: webosSdk!.targetArch,
      allowed: <String>['arm', 'arm64'],
      help: 'Target architecture for which the app is compiled',
    );
    argParser.addOption(
      'target-backend-type',
      defaultsTo: 'wayland',
      allowed: <String>['wayland', 'gbm', 'eglstream', 'x11'],
      help: 'Target backend type that the app will run on devices.',
    );
    argParser.addOption(
      'target-compiler-triple',
      defaultsTo: webosSdk!.targetCompilerTriple,
      help: 'Target compiler triple for which the app is compiled. '
          'e.g. aarch64-linux-gnu',
    );
    argParser.addOption(
      'target-sysroot',
      defaultsTo: webosSdk!.targetSysRoot,
      help: 'The root filesystem path of target platform for which '
          'the app is compiled. This option is valid only '
          'if the current host and target architectures are different.',
    );
    argParser.addOption(
      'target-toolchain',
      help: 'The toolchain path for Clang.',
    );
    argParser.addOption(
      'system-include-directories',
      help: 'The additional system include paths to cross-compile for target platform. '
          'This option is valid only '
          'if the current host and target architectures are different.',
    );
    argParser.addOption(
      'target-compiler-flags',
      help: 'The extra compile flags to be applied to C and C++ compiler',
    );
    argParser.addOption(
      'parallel',
      abbr: 'j',
      defaultsTo: '1',
      help: 'The maximum number of concurrent processes to build native bundle. '
          'This is only valid for building the native bundle.',
    );
  }

  @override
  final name = 'webos';

  @override
  Future<Set<DevelopmentArtifact>> get requiredArtifacts async => <DevelopmentArtifact>{
        // Use gensnapshot for Arm64 Linux when the host is arm64 because
        // the artifacts for arm64 host don't support self-building now.
        if (_getCurrentHostPlatformArchName() == 'arm64') DevelopmentArtifact.linux,
        WebosDevelopmentArtifact.webos,
      };

  @override
  final description = 'Build a webOS package from your app.';

  /// See: [android.validateBuild] in `build_validation.dart`
  void validateBuild(WebosBuildInfo webosBuildInfo) {
    if (webosBuildInfo.buildInfo.mode.isPrecompiled && webosBuildInfo.targetArch == 'x86') {
      throwToolExit('x86 ABI does not support AOT compilation.');
    }
  }

  /// See: [BuildApkCommand.runCommand] in `build_apk.dart`
  @override
  Future<FlutterCommandResult> runCommand() async {
    // Not supported cross-building for x64 on arm64.
    final String? targetArch = stringArg('target-arch');
    final String hostArch = _getCurrentHostPlatformArchName();
    if (hostArch != targetArch && hostArch == 'arm64') {
      globals.logger.printError('Not supported cross-building for x64 on arm64.');
      return FlutterCommandResult.fail();
    }

    var nParallel = 1;
    try {
      nParallel = int.parse(stringArg('parallel') ?? '1');
    } on FormatException {
      globals.logger
          .printWarning('Invalid number parallel jobs is given : ${stringArg("parallel") ?? "1"}');
    }

    final BuildInfo buildInfo = await getBuildInfo();
    final webosBuildInfo = WebosBuildInfo(
      buildInfo,
      targetArch: targetArch!,
      targetBackendType: stringArg('target-backend-type')!,
      targetCompilerTriple: stringArg('target-compiler-triple'),
      targetSysroot: stringArg('target-sysroot')!,
      targetCompilerFlags: stringArg('target-compiler-flags'),
      targetToolchain: stringArg('target-toolchain'),
      systemIncludeDirectories: stringArg('system-include-directories'),
      parallelJobs: nParallel,
    );
    validateBuild(webosBuildInfo);

    await WebosBuilder.buildPackage(
      project: FlutterProject.current(),
      targetFile: targetFile,
      webosBuildInfo: webosBuildInfo,
      sizeAnalyzer: SizeAnalyzer(
        analytics: globals.analytics,
        fileSystem: globals.fs,
        logger: globals.logger,
      ),
    );

    return FlutterCommandResult.success();
  }

  String _getCurrentHostPlatformArchName() {
    final HostPlatform hostPlatform = getCurrentHostPlatform();
    return hostPlatform.platformName;
  }
}
