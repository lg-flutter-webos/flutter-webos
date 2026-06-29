// Copyright (c) 2023 LG Electronics, Inc. All rights reserved.
// Copyright 2020 Samsung Electronics Co., Ltd. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:flutter_tools/src/android/android_sdk.dart';
import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/context.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/process.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:process/process.dart';

WebosSdk? get webosSdk => context.get<WebosSdk>();
File? get aresCli => globals.os.which('ares');

class WebosSdk {
  WebosSdk({
    required Logger logger,
    required ProcessManager processManager,
  }) : _processManager = ProcessUtils(logger: logger, processManager: processManager) {
    final Map<String, String> variables = globals.platform.environment;

    _targetArch = variables['OECORE_TARGET_ARCH'] ?? 'arm';
    _targetArch = (_targetArch == 'aarch64') ? 'arm64' : _targetArch;
    _targetSysroot = variables['SDKTARGETSYSROOT'] ?? '/';
    //_targetCompilerTriple = variables['CROSS_COMPILE'] ?? 'aarch64-webos-linux-';
    _targetCompilerTriple = variables['CROSS_COMPILE'] ?? 'arm-starfishmllib32-linux-gnueabi-';
    _targetCompilerTriple = _targetCompilerTriple.substring(0, _targetCompilerTriple.length - 1);

    _platformCodeName = variables['WEBOS_DISTRO_PLATFORM_CODENAME'] ?? 'queue';
    _platformVersion = variables['WEBOS_PLATFORM_VERSION'] ?? '';

    _ndkVersion = variables['WEBOS_NDK_VERSION'] ?? '';
    _sdkVersion = variables['OECORE_SDK_VERSION'] ?? '';
  }

  /// See: [AndroidSdk.locateAndroidSdk] in `android_sdk.dart`

  final ProcessUtils _processManager;

  var _sdkVersion = "";
  var _targetArch = "";
  var _targetSysroot = "";
  var _platformCodeName = "";
  var _platformVersion = "";
  var _ndkVersion = "";
  var _targetCompilerTriple = "";

  static const _platformVersionByCodeName = <String, String>{
    'queue': '26',
    'spacebuns': '27',
  };

  String get cli => 'ares';
  String get sdkVersion => _sdkVersion;
  String get targetArch => _targetArch;
  String get targetCompilerTriple => _targetCompilerTriple;
  String get targetSysRoot => _targetSysroot;
  String get platformCodeName => _platformCodeName;
  String get ndkVersion => _ndkVersion;

  /// External webOS version segment for the artifacts path (env override, else codename map).
  String get platformVersion {
    final String number =
        _platformVersion.isNotEmpty ? _platformVersion : (_platformVersionByCodeName[_platformCodeName] ?? '');
    return number.isEmpty ? _platformCodeName : 'webos$number';
  }

  String get targetCCompiler => '$targetCompilerTriple-clang';
  String get targetCXXCompiler => '$targetCompilerTriple-clang++';

  static const _defaultRequiredACG = <String>[
    'lunabus.query',
    'application.launcher',
    'settings.query',
    'systemconfig.query',
    'tts.operation',
  ];

  Future<bool> package(
    Directory workingDirectory, {
    Directory? outputDir,
    Directory? bundleDir,
  }) async {
    if (!workingDirectory.existsSync()) {
      return false;
    }

    final Directory outputIpkDir = workingDirectory.childDirectory('ipk');
    if (outputIpkDir.existsSync()) {
      outputIpkDir.deleteSync(recursive: true);
    }
    outputIpkDir.createSync(recursive: true);

    bundleDir ??= workingDirectory.childDirectory('bundle');

    final File appInfoFile = bundleDir.childFile('appinfo.json');
    if (!appInfoFile.existsSync()) {
      return false;
    }

    final String appId = getPackageId(appInfoFile);

    if (appId.isEmpty) {
      return false;
    }

    // Create IPK data part
    final Directory ipkAppDir = outputIpkDir
        .childDirectory('data')
        .childDirectory('usr')
        .childDirectory('palm')
        .childDirectory('applications')
        .childDirectory(appId);
    ipkAppDir.createSync(recursive: true);

    copyDirectory(
      bundleDir,
      ipkAppDir,
    );

    final String exeName = getMain(appInfoFile) ?? 'flutter-native';
    final File nativeRunnerFile = ipkAppDir.childFile(exeName);
    if (nativeRunnerFile.existsSync()) {
      await _processManager.run(
        <String>['chmod', '+x', exeName],
        throwOnError: true,
        workingDirectory: ipkAppDir.path,
      );
    }

    final File copiedAppInfo = ipkAppDir.childFile('appinfo.json');
    final map = jsonDecode(copiedAppInfo.readAsStringSync()) as Map<String, dynamic>;
    map.remove('requiredPermissions');
    map['requiredACG'] = _mergePermissions(map);
    copiedAppInfo.writeAsStringSync(jsonEncode(map));

    const appData = 'appdata';
    final Directory appDataFolder = ipkAppDir.childDirectory(appData);
    appDataFolder.createSync(recursive: true);
    await _processManager.run(
      <String>['chmod', '777', appData],
      throwOnError: true,
      workingDirectory: ipkAppDir.path,
    );

    // Create IPK debian-binary part
    final File debian = outputIpkDir.childFile('debian-binary');
    debian.writeAsStringSync('2.0');

    // Create IPK control part
    final Directory ipkControlDir = outputIpkDir.childDirectory('control');
    ipkControlDir.createSync(recursive: true);
    final File ipkControlFile = ipkControlDir.childFile('control');
    buildControlWithPkgInfo(appInfoFile, ipkControlFile);

    await packageByAres(appId, outputIpkDir);

    return true;
  }

  /// Build the app IPK with the webOS CLI (ares-package).
  Future<void> packageByAres(String appId, Directory outputIpkDir) async {
    final Directory appDir = outputIpkDir
        .childDirectory('data')
        .childDirectory('usr')
        .childDirectory('palm')
        .childDirectory('applications')
        .childDirectory(appId);

    if (!appDir.existsSync()) {
      throwToolExit('App directory not found: ${appDir.path}');
    }

    final RunResult result = await _processManager.run(
      <String>[
        'ares-package',
        '--no-minify',
        appDir.path,
        '-o',
        outputIpkDir.path,
      ],
      workingDirectory: outputIpkDir.path,
    );
    if (result.exitCode != 0) {
      throwToolExit('Failed to run ares-package: ${result.stderr}');
    }

    // Keep the ares-generated name; ipkFilePath() discovers it.
    final bool produced = outputIpkDir
        .listSync()
        .whereType<File>()
        .any((File f) => f.basename.endsWith('.ipk'));
    if (!produced) {
      throwToolExit('ares-package produced no .ipk in ${outputIpkDir.path}');
    }
  }

  String getPackageId(File pkgInfo) {
    if (!pkgInfo.existsSync()) {
      return "";
    }

    final String strPkgInfo = pkgInfo.readAsStringSync();
    final map = jsonDecode(strPkgInfo) as Map<String, dynamic>;

    return map['id'] as String;
  }

  String getDebugLogPath(File pkgInfo) {
    if (!pkgInfo.existsSync()) {
      return '/var/log';
    }

    final String strPkgInfo = pkgInfo.readAsStringSync();
    final map = jsonDecode(strPkgInfo) as Map<String, dynamic>;

    return (map['FLUTTER_APP_LOG_PATH'] as String?) ?? '/var/log';
  }

  String? getMain(File pkgInfo) {
    if (!pkgInfo.existsSync()) {
      return null;
    }

    final String strPkgInfo = pkgInfo.readAsStringSync();
    final map = jsonDecode(strPkgInfo) as Map<String, dynamic>;

    return map['main'] as String?;
  }

  List<String> _mergePermissions(Map<String, dynamic> map) {
    return <String>{
      ...((map['requiredACG'] as List?)?.cast<String>() ?? <String>[]),
      ..._defaultRequiredACG,
    }.toList();
  }

  String getRequiredPermissions(File pkgInfo) {
    final map = pkgInfo.existsSync()
        ? jsonDecode(pkgInfo.readAsStringSync()) as Map<String, dynamic>
        : <String, dynamic>{};

    return _mergePermissions(map).map((p) => '"$p"').join(',');
  }

  String getVersion(File pkgInfo) {
    if (!pkgInfo.existsSync()) {
      return "";
    }

    final String strPkgInfo = pkgInfo.readAsStringSync();
    final map = jsonDecode(strPkgInfo) as Map<String, dynamic>;

    return map['version'] as String;
  }

  String getType(File pkgInfo) {
    if (!pkgInfo.existsSync()) {
      return "flutter";
    }

    final String strPkgInfo = pkgInfo.readAsStringSync();
    final map = jsonDecode(strPkgInfo) as Map<String, dynamic>;

    return map['type'] as String? ?? 'flutter';
  }

  /// Returns FLUTTER_HOME from [appConfig], or '' when unset.
  /// The runner resolves '' and relative values against `<bundle>/appdata/`.
  String getAppHomePath(File appConfig) {
    if (!appConfig.existsSync()) {
      return '';
    }
    final String strAppConfig = appConfig.readAsStringSync();
    final map = jsonDecode(strAppConfig) as Map<String, dynamic>;

    return map['FLUTTER_HOME'] as String? ?? '';
  }

  void buildControlWithPkgInfo(File pkgInfo, File control) {
    if (!pkgInfo.existsSync()) {
      return;
    }

    final String strPkgInfo = pkgInfo.readAsStringSync();
    final map = jsonDecode(strPkgInfo) as Map<String, dynamic>;

    control.writeAsStringSync('''
Package: ${map['id']}
Version: ${map['version']}
Description: ${map['title']}
Section: webos/apps
Priority: optional
Maintainer: N/A <nobody@example.com>
License: Apache-2.0
Architecture: all
''');
  }
}
