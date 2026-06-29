// Copyright (c) 2023 LG Electronics, Inc. All rights reserved.
// Copyright 2023 Sony Group Corporation. All rights reserved.
// Copyright 2020 Samsung Electronics Co., Ltd. All rights reserved.
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:file/file.dart';
import 'package:flutter_tools/src/android/android_builder.dart';
import 'package:flutter_tools/src/android/gradle.dart';
import 'package:flutter_tools/src/base/analyze_size.dart';
import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/build_system/build_system.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/commands/assemble.dart';
import 'package:flutter_tools/src/commands/build_ios_framework.dart';
import 'package:flutter_tools/src/dart/package_map.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/linux/build_linux.dart';
import 'package:flutter_tools/src/project.dart';

import 'webos_build_target.dart';
import 'webos_cmake_project.dart';
import 'webos_target_platform.dart';

/// The define to control what webos device is built for.
const kTargetBackendType = 'TargetBackendType';

/// See: [AndroidBuildInfo] in `build_info.dart`
class WebosBuildInfo {
  const WebosBuildInfo(
    this.buildInfo, {
    required this.targetArch,
    required this.targetBackendType,
    required this.targetCompilerTriple,
    required this.targetSysroot,
    required this.targetCompilerFlags,
    required this.targetToolchain,
    required this.systemIncludeDirectories,
    this.parallelJobs = 1,
  });

  final BuildInfo buildInfo;
  final String targetArch;
  final String targetBackendType;
  final String? targetCompilerTriple;
  final String targetSysroot;
  final String? targetCompilerFlags;
  final String? targetToolchain;
  final String? systemIncludeDirectories;
  final int parallelJobs;
}

// ignore: avoid_classes_with_only_static_members
/// See:
/// - [AndroidBuilder] in `android_builder.dart`
/// - [AndroidGradleBuilder.buildGradleApp] in `gradle.dart`
/// - [BuildIOSFrameworkCommand._produceAppFramework] in `build_ios_framework.dart` (build target)
/// - [AssembleCommand.runCommand] in `assemble.dart` (performance measurement)
/// - [buildLinux] in `build_linux.dart` (code size)
class WebosBuilder {
  /// The build-system defines shared by the bundle and IPK build phases.
  ///
  /// The kTargetPlatform define controls the runtime OS baked into the kernel,
  /// NOT the AOT codegen platform. webOS reports as Linux at runtime, so use
  /// [kernelTargetPlatform] (tester => no `--target-os` baked). The codegen
  /// platform is injected separately via [WebosAotElf]. See
  /// webos_target_platform.dart.
  static Map<String, String> _buildDefines(WebosBuildInfo webosBuildInfo, String targetFile) {
    return <String, String>{
      kTargetFile: targetFile,
      kBuildMode: webosBuildInfo.buildInfo.mode.cliName,
      kTargetPlatform: getNameForTargetPlatform(kernelTargetPlatform),
      ...webosBuildInfo.buildInfo.toBuildSystemEnvironment(),
      kTargetBackendType: webosBuildInfo.targetBackendType,
    };
  }

  /// The bundle and IPK phases share the same defines (and therefore the
  /// same build-id hash, keeping .last_build_id stable) but need separate
  /// physical build dirs: each BuildSystem.build call persists only its own
  /// targets' hashes to {BUILD_DIR}/.filecache, so sharing one directory
  /// would clobber the other phase's hash DB and break skip detection.
  static Environment _environment(
    FlutterProject project,
    Map<String, String> defines, {
    String buildDirName = 'flutter_build',
  }) {
    return Environment(
      projectDir: project.directory,
      outputDir: project.directory.childDirectory('build').childDirectory('webos'),
      buildDir: project.dartTool.childDirectory(buildDirName),
      cacheDir: globals.cache.getRoot(),
      flutterRootDir: globals.fs.directory(Cache.flutterRoot),
      engineVersion: globals.flutterVersion.engineRevision,
      generateDartPluginRegistry: true,
      defines: defines,
      artifacts: globals.artifacts!,
      fileSystem: globals.fs,
      logger: globals.logger,
      processManager: globals.processManager,
      platform: globals.platform,
      analytics: globals.analytics,
      packageConfigPath: findPackageConfigFileOrDefault(project.directory).path,
    );
  }

  /// Build the asset bundle and package it into an IPK in one step.
  /// Shared by `build webos` and `run` so both go through the same path.
  static Future<void> buildPackage({
    required FlutterProject project,
    required WebosBuildInfo webosBuildInfo,
    required String targetFile,
    SizeAnalyzer? sizeAnalyzer,
  }) async {
    await buildBundle(
      project: project,
      targetFile: targetFile,
      webosBuildInfo: webosBuildInfo,
      sizeAnalyzer: sizeAnalyzer,
    );
    await buildIpkFromBundle(
      project: project,
      targetFile: targetFile,
      webosBuildInfo: webosBuildInfo,
    );
  }

  static Future<void> buildIpkFromBundle({
    required FlutterProject project,
    required WebosBuildInfo webosBuildInfo,
    required String targetFile,
  }) async {
    final webosProject = WebosProject.fromFlutter(project);
    if (!webosProject.existsSync()) {
      throwToolExit(
        'This project is not configured for webos.\n'
        'To fix this problem, create a new project by running `flutter-webos create <app-dir>`.',
      );
    }

    // Same defines as the bundle phase, own build dir (see _environment).
    final Environment environment = _environment(
        project, _buildDefines(webosBuildInfo, targetFile),
        buildDirName: 'flutter_build_ipk');

    final Target target = WebosIpkPackage(webosBuildInfo);

    final Status status =
        globals.logger.startProgress('Creating an IPK package for webOS test development...');

    try {
      final BuildResult result = await globals.buildSystem.build(target, environment);
      if (!result.success) {
        for (final ExceptionMeasurement measurement in result.exceptions.values) {
          globals.printError(measurement.exception.toString());
        }
        throwToolExit('The build failed.');
      }
    } finally {
      status.stop();
    }
  }

  static Future<void> buildBundle({
    required FlutterProject project,
    required WebosBuildInfo webosBuildInfo,
    required String targetFile,
    SizeAnalyzer? sizeAnalyzer,
  }) async {
    final webosProject = WebosProject.fromFlutter(project);
    if (!webosProject.existsSync()) {
      throwToolExit(
        'This project is not configured for webos.\n'
        'To fix this problem, create a new project by running `flutter-webos create <app-dir>`.',
      );
    }

    final BuildInfo buildInfo = webosBuildInfo.buildInfo;
    final String buildModeName = buildInfo.mode.cliName;
    final Environment environment =
        _environment(project, _buildDefines(webosBuildInfo, targetFile));
    final Directory outputDir = environment.outputDir;

    final Target target = buildInfo.isDebug
        ? DebugWebosApplication(webosBuildInfo)
        : ReleaseWebosApplication(webosBuildInfo);

    final Status status = globals.logger.startProgress(
        'Building a webOS application in $buildModeName mode for ${webosBuildInfo.targetArch} target...');
    try {
      final BuildResult result = await globals.buildSystem.build(target, environment);
      if (!result.success) {
        for (final ExceptionMeasurement measurement in result.exceptions.values) {
          globals.printError(measurement.exception.toString());
        }
        throwToolExit('The build failed.');
      }

      // These pseudo targets cannot be skipped and should be invoked whenever
      // the build is run.
      await NativeBundle(webosBuildInfo, targetFile).build(environment);

      if (buildInfo.performanceMeasurementFile != null) {
        final File outFile = globals.fs.file(buildInfo.performanceMeasurementFile);
        // ignore: invalid_use_of_visible_for_testing_member
        writePerformanceData(result.performance.values, outFile);
      }
    } finally {
      status.stop();
    }

    if (buildInfo.codeSizeDirectory != null && sizeAnalyzer != null) {
      final String arch = webosBuildInfo.targetArch;
      final String genSnapshotPlatform =
          getNameForTargetPlatform(genSnapshotTargetPlatformForArch(webosBuildInfo.targetArch));
      final File codeSizeFile = globals.fs
          .directory(buildInfo.codeSizeDirectory)
          .childFile('snapshot.$genSnapshotPlatform.json');
      final File precompilerTrace = globals.fs
          .directory(buildInfo.codeSizeDirectory)
          .childFile('trace.$genSnapshotPlatform.json');
      final Map<String, Object?> output = await sizeAnalyzer.analyzeAotSnapshot(
        aotSnapshot: codeSizeFile,
        // This analysis is only supported for release builds.
        outputDirectory: globals.fs.directory(
          globals.fs.path.join(outputDir.path, arch, 'release', 'bundle'),
        ),
        precompilerTrace: precompilerTrace,
        type: 'linux',
      );
      final File outputFile = globals.fsUtils.getUniqueFile(
        globals.fs.directory(globals.fsUtils.homeDirPath).childDirectory('.flutter-devtools'),
        'webos-code-size-analysis',
        'json',
      )..writeAsStringSync(jsonEncode(output));
      // This message is used as a sentinel in analyze_apk_size_test.dart
      globals.printStatus(
        'A summary of your Linux bundle analysis can be found at: ${outputFile.path}',
      );

      // DevTools expects a file path relative to the .flutter-devtools/ dir.
      final String relativeAppSizePath = outputFile.path.split('.flutter-devtools/').last.trim();
      globals
          .printStatus('\nTo analyze your app size in Dart DevTools, run the following command:\n'
              'flutter pub global activate devtools; flutter pub global run devtools '
              '--appSizeBase=$relativeAppSizePath');
    }
  }
}

// arch <-> TargetPlatform mappings live in webos_target_platform.dart so the
// gen_snapshot (codegen), asset-bundle, and kernel (runtime-OS) concerns each
// get their own value instead of sharing one overloaded mapping.
