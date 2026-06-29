// Copyright (c) 2023 LG Electronics, Inc. All rights reserved.
// Copyright 2023 Sony Group Corporation. All rights reserved.
// Copyright 2020 Samsung Electronics Co., Ltd. All rights reserved.
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_tools/src/artifacts.dart';
import 'package:flutter_tools/src/base/build.dart';
import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/os.dart';
import 'package:flutter_tools/src/base/process.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/build_system/build_system.dart';
import 'package:flutter_tools/src/build_system/depfile.dart';
import 'package:flutter_tools/src/build_system/exceptions.dart';
import 'package:flutter_tools/src/build_system/targets/android.dart';
import 'package:flutter_tools/src/build_system/targets/assets.dart';
import 'package:flutter_tools/src/build_system/targets/common.dart';
import 'package:flutter_tools/src/build_system/targets/icon_tree_shaker.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/cmake.dart';
import 'package:flutter_tools/src/convert.dart';
import 'package:flutter_tools/src/devfs.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/isolated/native_assets/dart_hook_result.dart';
import 'package:flutter_tools/src/project.dart';

import 'webos_build_graph.dart';
import 'webos_builder.dart';
import 'webos_cmake_project.dart';
import 'webos_sdk.dart';
import 'webos_target_platform.dart';

/// Gets the Flutter framework version from git tags or the version file.
/// Falls back to 'latest' if neither is available.
/// Resolves a flutter-webos SDK file by its repo-relative path. Single place
/// that knows the SDK layout (the SDK sits next to the vendored flutter root).
File _webosSdkFile(String relative) => globals.fs
    .file(globals.fs.path.normalize(globals.fs.path.join(Cache.flutterRoot!, '..', relative)));

String _getFlutterFrameworkVersion() {
  final String flutterRoot = Cache.flutterRoot!;

  // First, try to get version from git describe (preferred method)
  try {
    final ProcessResult result = Process.runSync(
      'git',
      ['describe', '--tags', '--abbrev=0'],
      workingDirectory: flutterRoot,
    );
    if (result.exitCode == 0) {
      final String version = (result.stdout as String).trim();
      if (version.isNotEmpty) {
        return version;
      }
    }
  } on ProcessException catch (_) {
    // Ignore git errors and try fallback
  }

  // Fallback: try to read from legacy version file
  try {
    final File versionFile = globals.fs.file(globals.fs.path.join(flutterRoot, 'version'));
    if (versionFile.existsSync()) {
      final String version = versionFile.readAsStringSync().trim();
      if (version.isNotEmpty) {
        return version;
      }
    }
  } on FileSystemException catch (_) {
    // Ignore file read errors
  }

  return 'latest';
}

/// Prepares the pre-built flutter bundle.
///
/// Source: [AndroidAssetBundle] in `android.dart`
abstract class WebosAssetBundle extends Target {
  const WebosAssetBundle(this.buildInfo);

  final WebosBuildInfo buildInfo;

  @override
  String get name => 'webos_asset_bundle';

  @override
  List<Source> get inputs => const <Source>[
        Source.pattern('{BUILD_DIR}/app.dill'),
        ...IconTreeShaker.inputs,
      ];

  @override
  List<Source> get outputs => const <Source>[];

  @override
  List<String> get depfiles => <String>[
        'flutter_assets.d',
      ];

  @override
  List<Target> get dependencies => const <Target>[
        KernelSnapshot(),
      ];

  @override
  Future<void> build(Environment environment) async {
    if (environment.defines[kBuildMode] == null) {
      throw MissingDefineException(kBuildMode, name);
    }
    final buildMode = BuildMode.fromCliName(environment.defines[kBuildMode]!);
    final Directory outputDirectory = environment.outputDir.childDirectory('flutter_assets')
      ..createSync(recursive: true);

    // Only copy the prebuilt runtimes and kernel blob in debug mode.
    if (buildMode == BuildMode.debug) {
      final String vmSnapshotData =
          environment.artifacts.getArtifactPath(Artifact.vmSnapshotData, mode: BuildMode.debug);
      final String isolateSnapshotData = environment.artifacts
          .getArtifactPath(Artifact.isolateSnapshotData, mode: BuildMode.debug);
      environment.buildDir
          .childFile('app.dill')
          .copySync(outputDirectory.childFile('kernel_blob.bin').path);
      environment.fileSystem
          .file(vmSnapshotData)
          .copySync(outputDirectory.childFile('vm_snapshot_data').path);
      environment.fileSystem
          .file(isolateSnapshotData)
          .copySync(outputDirectory.childFile('isolate_snapshot_data').path);
    }
    final TargetPlatform tp = assetTargetPlatform(buildInfo.targetArch);
    final String versionInfo = getVersionInfo(environment, buildInfo);
    final Depfile assetDepfile = await copyAssets(
      environment,
      outputDirectory,
      dartHookResult: DartHooksResult.empty(),
      targetPlatform: tp,
      buildMode: buildMode,
      additionalContent: <String, DevFSContent>{
        'version.json': DevFSStringContent(versionInfo),
      },
      flavor: environment.defines[kFlavor],
    );
    final depfileService = DepfileService(
      fileSystem: environment.fileSystem,
      logger: environment.logger,
    );
    depfileService.writeToFile(
      assetDepfile,
      environment.buildDir.childFile('flutter_assets.d'),
    );
  }

  /// Return json encoded string that contains data about version for package_info
  String getVersionInfo(Environment environment, WebosBuildInfo buildInfo) {
    final versionInfo =
        jsonDecode(FlutterProject.current().getVersionInfo()) as Map<String, dynamic>;

    final Directory metaDir =
        globals.fs.directory(environment.projectDir).childDirectory('webos').childDirectory('meta');

    if (metaDir.existsSync()) {
      final String packageName = webosSdk!.getPackageId(metaDir.childFile('appinfo.json'));
      if (packageName.isNotEmpty) {
        versionInfo['app_name'] = packageName;
        versionInfo['package_name'] = packageName;
      }

      final String version = webosSdk!.getVersion(metaDir.childFile('appinfo.json'));

      if (version.isNotEmpty) {
        versionInfo['build_number'] = version;
        versionInfo['version'] = version;
      }
    }

    if (environment.defines.containsKey(kBuildNumber)) {
      versionInfo['build_number'] = environment.defines[kBuildNumber];
    }

    if (environment.defines.containsKey(kBuildName)) {
      versionInfo['version'] = environment.defines[kBuildName];
    }

    final String frameworkVersion = _getFlutterFrameworkVersion();
    versionInfo['flutter_framework_version'] = frameworkVersion;

    if (environment.defines.containsKey(kBuildMode)) {
      versionInfo['runtime_mode'] = environment.defines[kBuildMode];
    }

    const encoder = JsonEncoder.withIndent("  ");
    return encoder.convert(versionInfo);
  }
}

/// Source: [DebugAndroidApplication] in `android.dart`
class DebugWebosApplication extends WebosAssetBundle {
  DebugWebosApplication(super.buildInfo);

  @override
  String get name => 'debug_webos_application';

  @override
  List<Source> get inputs => <Source>[
        ...super.inputs,
        const Source.artifact(Artifact.vmSnapshotData, mode: BuildMode.debug),
        const Source.artifact(Artifact.isolateSnapshotData, mode: BuildMode.debug),
      ];

  @override
  List<Source> get outputs => <Source>[
        ...super.outputs,
        const Source.pattern('{OUTPUT_DIR}/flutter_assets/vm_snapshot_data'),
        const Source.pattern('{OUTPUT_DIR}/flutter_assets/isolate_snapshot_data'),
        const Source.pattern('{OUTPUT_DIR}/flutter_assets/kernel_blob.bin'),
      ];

  @override
  List<Target> get dependencies => <Target>[
        ...super.dependencies,
        WebosPlugins(buildInfo),
      ];
}

/// See: [ReleaseAndroidApplication] in `android.dart`
class ReleaseWebosApplication extends WebosAssetBundle {
  ReleaseWebosApplication(super.buildInfo);

  @override
  String get name => 'release_webos_application';

  @override
  List<Target> get dependencies => <Target>[
        ...super.dependencies,
        WebosAotElf(genSnapshotTargetPlatformForArch(buildInfo.targetArch)),
        WebosPlugins(buildInfo),
      ];
}

/// Compiles webOS native plugins into a single shared object.
class WebosPlugins extends Target {
  WebosPlugins(this.buildInfo);

  final WebosBuildInfo buildInfo;

  @override
  String get name => 'webos_plugins';

  @override
  List<Source> get inputs => const <Source>[
        Source.pattern('{PROJECT_DIR}/.packages'),
      ];

  @override
  List<Source> get outputs => const <Source>[];

  @override
  List<String> get depfiles => <String>[
        'webos_plugins.d',
      ];

  @override
  List<Target> get dependencies => const <Target>[];

  @override
  Future<void> build(Environment environment) async {
    // TODO(hidenori): add plugin build support.
  }
}

class WebosIpkPackage extends WebosAssetBundle {
  WebosIpkPackage(super.buildInfo);

  @override
  String get name => 'webos_ipk';

  // The bundle is staged by NativeBundle outside the build system, so its
  // file list is only known after packaging — declared via the depfile.
  @override
  List<Source> get inputs => const <Source>[];

  @override
  List<Source> get outputs => const <Source>[];

  @override
  List<String> get depfiles => const <String>['webos_ipk.d'];

  @override
  List<Target> get dependencies => const <Target>[];

  @override
  Future<void> build(Environment environment) async {
    final BuildMode buildMode = buildInfo.buildInfo.mode;
    final Directory outputDir = environment.outputDir
        .childDirectory(buildInfo.targetArch)
        .childDirectory(buildMode.toString());

    await webosSdk?.package(outputDir);

    // Skipping repackaging while the bundle is unchanged also keeps the IPK
    // bytes stable, which the device-side install-skip check relies on —
    // ares-package output differs on every invocation otherwise. Symlinks in
    // the bundle point at device paths and cannot be hashed on the host;
    // their targets only change with the build mode, which already has its
    // own output directory.
    final List<File> bundleFiles = outputDir
        .childDirectory('bundle')
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .toList();
    final List<File> ipkFiles = outputDir
        .childDirectory('ipk')
        .listSync()
        .whereType<File>()
        .where((File file) => file.basename.endsWith('.ipk'))
        .toList();
    DepfileService(
      fileSystem: environment.fileSystem,
      logger: environment.logger,
    ).writeToFile(
      Depfile(bundleFiles, ipkFiles),
      environment.buildDir.childFile('webos_ipk.d'),
    );
  }
}

/// Generates an AOT snapshot (app.so) of the Dart code.
///
/// Source: [AotElfRelease] in `common.dart`
class WebosAotElf extends AotElfBase {
  const WebosAotElf(this.targetPlatform);

  @override
  String get name => 'webos_aot_elf';

  @override
  List<Source> get inputs => <Source>[
        const Source.pattern(
            '{FLUTTER_ROOT}/packages/flutter_tools/lib/src/build_system/targets/common.dart'),
        const Source.pattern('{BUILD_DIR}/app.dill'),
        const Source.artifact(Artifact.engineDartBinary),
        const Source.artifact(Artifact.skyEnginePath),
        Source.artifact(
          Artifact.genSnapshot,
          platform: targetPlatform,
          mode: BuildMode.release,
        ),
      ];

  @override
  List<Source> get outputs => const <Source>[
        Source.pattern('{BUILD_DIR}/app.so'),
      ];

  @override
  List<Target> get dependencies => const <Target>[
        KernelSnapshot(),
      ];

  final TargetPlatform targetPlatform;

  /// Mirrors [AotElfBase.build], but takes the AOT codegen platform from
  /// [targetPlatform] instead of the kTargetPlatform define.
  ///
  /// webOS sets the kTargetPlatform define to a Linux/tester value so the
  /// kernel bakes `operatingSystem == 'linux'` (see [kernelTargetPlatform]).
  /// gen_snapshot, however, needs the arch/host-aware platform (`android_*`
  /// for the cross-compiled snapshotter and the 32-bit ARM codegen flags), so
  /// we cannot reuse the define here.
  @override
  Future<void> build(Environment environment) async {
    final snapshotter = AOTSnapshotter(
      fileSystem: environment.fileSystem,
      logger: environment.logger,
      xcode: globals.xcode!,
      processManager: environment.processManager,
      artifacts: environment.artifacts,
    );
    final String? buildModeEnvironment = environment.defines[kBuildMode];
    if (buildModeEnvironment == null) {
      throw MissingDefineException(kBuildMode, 'webos_aot_elf');
    }
    final buildMode = BuildMode.fromCliName(buildModeEnvironment);
    final List<String> extraGenSnapshotOptions =
        decodeCommaSeparated(environment.defines, kExtraGenSnapshotOptions);
    final String? splitDebugInfo = environment.defines[kSplitDebugInfo];
    final dartObfuscation = environment.defines[kDartObfuscation] == 'true';
    final String? codeSizeDirectory = environment.defines[kCodeSizeDirectory];

    if (codeSizeDirectory != null) {
      // Name by the codegen platform (not the kTargetPlatform define, which is
      // 'flutter-tester') so the files match WebosBuilder's size analysis.
      final String platformName = getNameForTargetPlatform(targetPlatform);
      final File codeSizeFile = environment.fileSystem
          .directory(codeSizeDirectory)
          .childFile('snapshot.$platformName.json');
      final File precompilerTraceFile = environment.fileSystem
          .directory(codeSizeDirectory)
          .childFile('trace.$platformName.json');
      extraGenSnapshotOptions.add('--write-v8-snapshot-profile-to=${codeSizeFile.path}');
      extraGenSnapshotOptions.add('--trace-precompiler-to=${precompilerTraceFile.path}');
    }

    final int snapshotExitCode = await snapshotter.build(
      platform: targetPlatform,
      buildMode: buildMode,
      mainPath: environment.buildDir.childFile('app.dill').path,
      outputPath: environment.buildDir.path,
      extraGenSnapshotOptions: extraGenSnapshotOptions,
      splitDebugInfo: splitDebugInfo,
      dartObfuscation: dartObfuscation,
    );
    if (snapshotExitCode != 0) {
      throw Exception('AOT snapshotter exited with code $snapshotExitCode');
    }
  }
}

class NativeBundle {
  NativeBundle(this.buildInfo, this.targetFile);

  final WebosBuildInfo? buildInfo;
  final String? targetFile;

  final _processUtils =
      ProcessUtils(logger: globals.logger, processManager: globals.processManager);

  /// Removes everything from the preserved cmake build tree except the bundle
  /// staging area and packaged IPKs, forcing the next configure to start clean.
  void _deleteCmakeTree(Directory outputDir) {
    for (final FileSystemEntity entity in outputDir.listSync()) {
      if (entity.basename == 'bundle' || entity.basename == 'ipk') {
        continue;
      }
      entity.deleteSync(recursive: true);
    }
  }

  static bool _sameContent(File a, File b) {
    if (a.lengthSync() != b.lengthSync()) {
      return false;
    }
    final Uint8List aBytes = a.readAsBytesSync();
    final Uint8List bBytes = b.readAsBytesSync();
    for (var i = 0; i < aBytes.length; i++) {
      if (aBytes[i] != bBytes[i]) {
        return false;
      }
    }
    return true;
  }

  /// Copies [source] to [target] only when the content differs: unchanged
  /// compile inputs keep their mtimes, so make/ninja sees them as up to date.
  static void _copyFileIfChanged(File source, File target) {
    if (target.existsSync() && _sameContent(source, target)) {
      return;
    }
    target.parent.createSync(recursive: true);
    source.copySync(target.path);
  }

  /// Mirrors [source] into [target], copying only changed files. Any extra
  /// file in [target] (e.g. removed by an artifact update) triggers a clean
  /// re-copy so the tree cannot go stale.
  static void _copyDirectoryIfChanged(Directory source, Directory target) {
    if (target.existsSync()) {
      final sourcePaths = <String>{
        for (final FileSystemEntity entity
            in source.listSync(recursive: true, followLinks: false))
          globals.fs.path.relative(entity.path, from: source.path),
      };
      final bool hasStale = target
          .listSync(recursive: true, followLinks: false)
          .any((FileSystemEntity entity) =>
              !sourcePaths.contains(globals.fs.path.relative(entity.path, from: target.path)));
      if (hasStale) {
        target.deleteSync(recursive: true);
      }
    }
    target.createSync(recursive: true);
    for (final FileSystemEntity entity
        in source.listSync(recursive: true, followLinks: false)) {
      final String relative = globals.fs.path.relative(entity.path, from: source.path);
      if (entity is File) {
        _copyFileIfChanged(
            entity, globals.fs.file(globals.fs.path.join(target.path, relative)));
      } else if (entity is Directory) {
        globals.fs.directory(globals.fs.path.join(target.path, relative))
            .createSync(recursive: true);
      }
    }
  }

  Future<void> build(Environment environment) async {
    final FlutterProject project = FlutterProject.fromDirectory(environment.projectDir);
    final webosProject = WebosProject.fromFlutter(project);

    // Keep the cmake build tree (cache and objects) so the native build is
    // incremental across runs; only the bundle staging area is rebuilt from
    // scratch so stale files cannot leak into the IPK.
    final Directory webosDir = webosProject.editableDirectory;
    final BuildMode buildMode = buildInfo!.buildInfo.mode;
    final Directory outputDir = environment.outputDir
        .childDirectory(buildInfo!.targetArch)
        .childDirectory(buildMode.toString());
    outputDir.createSync(recursive: true);

    final Directory outputBundleDir = outputDir.childDirectory('bundle');
    if (outputBundleDir.existsSync()) {
      outputBundleDir.deleteSync(recursive: true);
    }
    outputBundleDir.createSync(recursive: true);
    outputBundleDir.childDirectory('lib').createSync();
    final Directory outputBundleDataDir = outputBundleDir.childDirectory('data')..createSync();

    final Directory metaDir =
        webosProject.parent.directory.childDirectory('webos').childDirectory('meta');
    final String appType = webosSdk!.getType(metaDir.childFile('appinfo.json'));

    // Copy necessary files
    final Directory engineDir = _getEngineArtifactsDirectory(buildInfo!.targetArch, buildMode);
    final Directory commonDir = engineDir.parent.childDirectory('webos-common');
    final File engineBinary = engineDir.childFile('libflutter_engine.so');
    // libflutter_webos_*.so in profile mode is under the debug mode's directory.
    final embedderBuildMode = buildMode.isRelease ? buildMode : BuildMode.fromCliName('debug');

    final File embedderCommon = engineDir.childFile('libflutter_common.so');
    final Directory clientIncludeDir = commonDir.childDirectory('include');

    final Directory flutterDir = webosDir.childDirectory('flutter');
    final Directory flutterEphemeralDir = flutterDir.childDirectory('ephemeral');

    final String frameworkVersion = _getFlutterFrameworkVersion();

    // Copy necessary files. Copies are content-conditional so unchanged
    // sources, headers, and libraries keep their mtimes and the cmake build
    // stays incremental.
    {
      flutterEphemeralDir.createSync(recursive: true);

      _copyDirectoryIfChanged(
        clientIncludeDir,
        flutterEphemeralDir.childDirectory('include'),
      );

      final Directory runnerBaseSrcDir = commonDir.childDirectory('runner_base');
      if (!runnerBaseSrcDir.existsSync()) {
        throwToolExit('runner_base sources missing in webos-common artifact: '
            '${runnerBaseSrcDir.path}');
      }
      _copyDirectoryIfChanged(
        runnerBaseSrcDir,
        flutterEphemeralDir.childDirectory('runner_base'),
      );

      _copyFileIfChanged(engineBinary, flutterEphemeralDir.childFile(engineBinary.basename));
      _copyFileIfChanged(embedderCommon, flutterEphemeralDir.childFile(embedderCommon.basename));

      const embedderFileName = 'libflutter_webos_media.so';

      var embedderAsLink = true;
      if (appType == "native") {
        final File embedderBinary = engineDir.childFile(embedderFileName);
        if (embedderBinary.existsSync()) {
          _copyFileIfChanged(
              embedderBinary, flutterEphemeralDir.childFile(embedderBinary.basename));
          embedderAsLink = false;
        }
      }
      if (embedderAsLink) {
        final Link embedder = flutterEphemeralDir.childLink(embedderFileName);
        final linkTarget = '/usr/lib/flutter/$frameworkVersion/'
            '$embedderBuildMode/${embedder.basename}';
        if (!embedder.existsSync() || embedder.targetSync() != linkTarget) {
          if (embedder.existsSync()) {
            embedder.deleteSync();
          }
          embedder.createSync(linkTarget);
        }
      }

      final File icuData = commonDir.childDirectory('icu').childFile('icudtl.dat');
      _copyFileIfChanged(icuData, flutterEphemeralDir.childFile(icuData.basename));

      if (buildMode.isPrecompiled) {
        final File aotSharedLib = environment.buildDir.childFile('app.so');
        _copyFileIfChanged(aotSharedLib, flutterEphemeralDir.childFile('libapp.so'));
      }

      final String? binaryName = webosSdk!.getMain(metaDir.childFile('appinfo.json'));
      if (binaryName == null) {
        throwToolExit('appinfo.json has no "main": BINARY_NAME would not match the '
            'ipk/launcher app id.');
      }
      WebosBuildGraph(
        webosProject,
        WebosBuildInputs(
          binaryName: binaryName,
          engineLibrary: engineBinary.basename,
          embedderLibrary: embedderFileName,
          commonLibrary: embedderCommon.basename,
          icuDataFile: icuData.basename,
          aotLibrary: 'libapp.so',
          projectBuildDir: environment.outputDir.path,
        ),
      ).emit();

      // Ship the static compile-settings fragment into ephemeral. Provides
      // SYSTEM include + APPLY_STANDARD_SETTINGS function to user templates.
      final File compileSettingsSrc = _webosSdkFile('lib/cmake/webos_compile_settings.cmake');
      if (!compileSettingsSrc.existsSync()) {
        throwToolExit('flutter-webos install is corrupt: ${compileSettingsSrc.path} '
            'not found.');
      }
      compileSettingsSrc.copySync(webosProject.webosCompileSettingsFile.path);
    }

    // Build the environment that needs to be set for the re-entrant flutter build
    // step.
    {
      final Map<String, String> environmentConfig = buildInfo!.buildInfo.toEnvironmentConfig();
      environmentConfig['FLUTTER_TARGET'] = targetFile!;
      final LocalEngineInfo? localEngineInfo = globals.artifacts?.localEngineInfo;
      if (localEngineInfo != null) {
        final String targetOutPath = localEngineInfo.targetOutPath;
        environmentConfig['FLUTTER_ENGINE'] =
            globals.fs.path.dirname(globals.fs.path.dirname(targetOutPath));
        environmentConfig['LOCAL_ENGINE'] = localEngineInfo.localTargetName;
        environmentConfig['LOCAL_ENGINE_HOST'] = localEngineInfo.localHostName;
      }
      writeGeneratedCmakeConfig(Cache.flutterRoot!, webosProject, buildInfo!.buildInfo,
          environmentConfig, globals.logger);
    }

    // Run the native build.
    final cmakeBuildType = buildMode.isPrecompiled ? 'Release' : 'Debug';
    final targetArch = buildInfo!.targetArch == 'arm64' ? 'aarch64' : 'arm';
    final String hostArch = _getCurrentHostPlatformArchName();
    final String? targetCompilerTriple = buildInfo!.targetCompilerTriple;
    final String targetSysroot = buildInfo!.targetSysroot;
    final String? targetCompilerFlags = buildInfo!.targetCompilerFlags;
    final String? targetToolchain = buildInfo!.targetToolchain;
    final String? systemIncludeDirectories = buildInfo!.systemIncludeDirectories;
    final configureCommand = <String>[
      'cmake',
      '-DCMAKE_BUILD_TYPE=$cmakeBuildType',
      '-DFLUTTER_TARGET_BACKEND_TYPE=${buildInfo!.targetBackendType}',
      '-DFLUTTER_TARGET_PLATFORM=webos-${buildInfo!.targetArch}',
      if (targetSysroot != '/') '-DCMAKE_SYSROOT=$targetSysroot',
      if (buildInfo!.targetArch != hostArch) '-DCMAKE_SYSTEM_PROCESSOR=$targetArch',
      if (systemIncludeDirectories != null)
        '-DFLUTTER_SYSTEM_INCLUDE_DIRECTORIES=$systemIncludeDirectories',
      if (targetCompilerTriple != null) '-DCMAKE_C_COMPILER_TARGET=$targetCompilerTriple',
      if (targetCompilerTriple != null) '-DCMAKE_CXX_COMPILER_TARGET=$targetCompilerTriple',
      if (targetCompilerFlags != null) '-DCMAKE_C_FLAGS=$targetCompilerFlags',
      if (targetCompilerFlags != null) '-DCMAKE_CXX_FLAGS=$targetCompilerFlags',
      webosDir.path,
    ];
    final compilerEnvironment = (targetToolchain == null)
        ? <String, String>{'CC': 'clang', 'CXX': 'clang++'}
        : <String, String>{
            'CC': '$targetToolchain/bin/clang',
            'CXX': '$targetToolchain/bin/clang++'
          };

    Future<RunResult> runNativeBuild() async {
      RunResult result = await _processUtils.run(
        configureCommand,
        workingDirectory: outputDir.path,
        environment: compilerEnvironment,
      );
      if (result.exitCode != 0) {
        return result;
      }
      result = await _processUtils.run(
        <String>['cmake', '--build', '.', '--parallel', '${buildInfo!.parallelJobs}'],
        workingDirectory: outputDir.path,
      );
      if (result.exitCode != 0) {
        return result;
      }
      // Create flutter app's bundle.
      return _processUtils.run(
        <String>['cmake', '--install', '.'],
        workingDirectory: outputDir.path,
      );
    }

    final bool hadCachedTree = outputDir.childFile('CMakeCache.txt').existsSync();
    RunResult result = await runNativeBuild();
    if (result.exitCode != 0 && hadCachedTree) {
      // A preserved tree can go stale (e.g. a toolchain or sysroot change
      // invalidating CMakeCache); retry once from a clean tree before
      // surfacing the failure.
      globals.printStatus('Native build failed with the cached cmake tree; '
          'retrying from a clean tree...');
      _deleteCmakeTree(outputDir);
      result = await runNativeBuild();
    }
    if (result.exitCode != 0) {
      throwToolExit('Failed to build the native bundle:\n$result');
    }
    {
      final Directory flutterAssetsDir = outputBundleDataDir.childDirectory('flutter_assets');
      copyDirectory(
        environment.outputDir.childDirectory('flutter_assets'),
        flutterAssetsDir,
      );
    }

    final Directory webosMetaDir = webosDir.childDirectory('meta');
    if (webosMetaDir.existsSync()) {
      webosMetaDir
          .listSync()
          .whereType<File>()
          .forEach((File info) => info.copySync(outputBundleDir.childFile(info.basename).path));
    }
  }
}

String _getCurrentHostPlatformArchName() {
  final HostPlatform hostPlatform = getCurrentHostPlatform();
  return hostPlatform.platformName;
}

/// On non-Windows, returns [path] unchanged.
///
/// On Windows, converts Windows-style [path] (e.g. 'C:\x\y') into Unix path
/// ('/c/x/y') and returns.
String getUnixPath(String path) {
  if (Platform.isWindows) {
    path = path.replaceAll(r'\', '/');
    if (path.startsWith(':', 1)) {
      path = '/${path[0].toLowerCase()}${path.substring(2)}';
    }
  }
  return path;
}

/// On non-Windows, returns the PATH environment variable.
///
/// On Windows, appends the msys2 executables directory to PATH and returns.
String getDefaultPathVariable() {
  final Map<String, String> variables = globals.platform.environment;
  return variables.containsKey('PATH') ? variables['PATH']! : '';
}

/// See: [CachedArtifacts._getEngineArtifactsPath]
Directory _getEngineArtifactsDirectory(String arch, BuildMode? mode) {
  assert(mode != null, 'Need to specify a build mode.');

  return globals.cache.getArtifactDirectory('engine').childDirectory('webos-$arch-${mode!.name}');
}
