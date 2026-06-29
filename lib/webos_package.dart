// Copyright (c) 2023 LG Electronics, Inc. All rights reserved.
// Copyright 2023 Sony Group Corporation. All rights reserved.
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:file/file.dart';
import 'package:flutter_tools/src/application_package.dart';
import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/cmake.dart';
import 'package:flutter_tools/src/flutter_application_package.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/project.dart';

import 'webos_cmake_project.dart';
import 'webos_sdk.dart';

class WebosApplicationPackageFactory extends FlutterApplicationPackageFactory {
  WebosApplicationPackageFactory()
      : super(
          androidSdk: globals.androidSdk,
          processManager: globals.processManager,
          logger: globals.logger,
          userMessages: globals.userMessages,
          fileSystem: globals.fs,
        );

  @override
  Future<ApplicationPackage?> getPackageForPlatform(
    TargetPlatform platform, {
    BuildInfo? buildInfo,
    File? applicationBinary,
  }) async {
    if (platform == TargetPlatform.tester) {
      return applicationBinary == null
          ? WebosApp.fromWebosProject(FlutterProject.current())
          : WebosApp.fromPrebuiltApp(applicationBinary);
    }
    return super.getPackageForPlatform(platform,
        buildInfo: buildInfo, applicationBinary: applicationBinary);
  }
}

abstract class WebosApp extends ApplicationPackage {
  WebosApp({required String projectBundleId}) : super(id: projectBundleId);

  factory WebosApp.fromWebosProject(FlutterProject project) {
    return BuildableWebosApp(
      project: WebosProject.fromFlutter(project),
    );
  }

  /// Reads the app metadata out of a prebuilt IPK so that
  /// `--use-application-binary` installs and launches like a built project.
  factory WebosApp.fromPrebuiltApp(FileSystemEntity applicationBinary) {
    final File ipkFile = globals.fs.file(applicationBinary.path);
    if (!ipkFile.existsSync()) {
      throwToolExit('IPK file not found: ${ipkFile.path}');
    }

    final List<int>? dataTarGz = _arMember(ipkFile.readAsBytesSync(), 'data.tar.gz');
    if (dataTarGz == null) {
      throwToolExit('Not a valid webOS IPK (no data.tar.gz): ${ipkFile.path}');
    }
    final Archive dataArchive;
    try {
      dataArchive = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(dataTarGz));
    } on Exception catch (e) {
      throwToolExit('Failed to read ${ipkFile.path}: $e');
    }

    // Extract the app's metadata files into a temp dir so the regular
    // webosSdk parsers work on them. The packaged appinfo.json already has
    // the merged requiredACG that webosSdk.package() produced.
    final Directory metaDir =
        globals.fs.systemTempDirectory.createTempSync('flutter_webos_ipk.');
    final appFileExp =
        RegExp(r'usr/palm/applications/[^/]+/(appinfo\.json|flutter-conf\.json)$');
    for (final ArchiveFile file in dataArchive.files) {
      final Match? match = appFileExp.firstMatch(file.name);
      if (file.isFile && match != null) {
        metaDir.childFile(match.group(1)!).writeAsBytesSync(file.content as List<int>);
      }
    }

    final File appInfoFile = metaDir.childFile('appinfo.json');
    final String appId =
        appInfoFile.existsSync() ? webosSdk!.getPackageId(appInfoFile) : '';
    if (appId.isEmpty) {
      throwToolExit('Not a valid webOS IPK (missing appinfo.json): ${ipkFile.path}');
    }
    final File appConfigFile = metaDir.childFile('flutter-conf.json');
    return PrebuiltWebosApp(
      ipkFilePath: ipkFile.path,
      appId: appId,
      requiredPermissions: webosSdk!.getRequiredPermissions(appInfoFile),
      type: webosSdk!.getType(appInfoFile),
      debugLogPath: webosSdk!.getDebugLogPath(appConfigFile),
      appHomePath: webosSdk!.getAppHomePath(appConfigFile),
    );
  }

  /// Returns the [memberName] member of the `ar` archive [bytes], or null.
  /// IPKs are Debian-style ar archives: a global `!<arch>\n` magic followed
  /// by 60-byte member headers (name:16 mtime:12 uid:6 gid:6 mode:8 size:10
  /// and a 2-byte end marker), with members aligned to 2 bytes.
  static List<int>? _arMember(List<int> bytes, String memberName) {
    const arMagic = '!<arch>\n';
    if (bytes.length < arMagic.length ||
        ascii.decode(bytes.sublist(0, arMagic.length), allowInvalid: true) != arMagic) {
      return null;
    }
    int offset = arMagic.length;
    while (offset + 60 <= bytes.length) {
      final String header =
          ascii.decode(bytes.sublist(offset, offset + 60), allowInvalid: true);
      final String name = header.substring(0, 16).trim();
      final int? size = int.tryParse(header.substring(48, 58).trim());
      if (size == null) {
        return null;
      }
      offset += 60;
      // GNU ar terminates member names with a '/'.
      if (name == memberName || name == '$memberName/') {
        return offset + size <= bytes.length ? bytes.sublist(offset, offset + size) : null;
      }
      offset += size + (size.isOdd ? 1 : 0);
    }
    return null;
  }

  @override
  String get displayName => id;

  String executable(BuildMode buildMode, String targetArch);

  String outputDirectory(BuildMode buildMode, String targetArch);

  String getAppId();
  String getRequiredPermissions();

  String getDebugLogPath();

  String ipkFilePath(BuildMode buildMode, String targetArch);
  String getAppHomePath();
  String getType();
}

class PrebuiltWebosApp extends WebosApp {
  PrebuiltWebosApp({
    required String ipkFilePath,
    required String appId,
    required String requiredPermissions,
    required String type,
    required String debugLogPath,
    required String appHomePath,
  })  : _ipkFilePath = ipkFilePath,
        _appId = appId,
        _requiredPermissions = requiredPermissions,
        _type = type,
        _debugLogPath = debugLogPath,
        _appHomePath = appHomePath,
        super(projectBundleId: appId);

  final String _ipkFilePath;
  final String _appId;
  final String _requiredPermissions;
  final String _type;
  final String _debugLogPath;
  final String _appHomePath;

  @override
  String executable(BuildMode buildMode, String targetArch) => _ipkFilePath;

  @override
  String outputDirectory(BuildMode buildMode, String targetArch) =>
      globals.fs.file(_ipkFilePath).parent.path;

  @override
  String getAppId() => _appId;

  @override
  String getRequiredPermissions() => _requiredPermissions;

  @override
  String getDebugLogPath() => _debugLogPath;

  @override
  String getAppHomePath() => _appHomePath;

  @override
  String getType() => _type;

  @override
  String ipkFilePath(BuildMode buildMode, String targetArch) => _ipkFilePath;

  @override
  String get name => _appId;
}

class BuildableWebosApp extends WebosApp {
  BuildableWebosApp({required this.project})
      : super(projectBundleId: project.parent.manifest.appName);

  final WebosProject project;

  @override
  String executable(BuildMode buildMode, String targetArch) {
    final String? binaryName = getCmakeExecutableName(project);
    final Directory bundleDir = _getBaseDir(buildMode, targetArch).childDirectory('bundle');
    return bundleDir.childFile(binaryName!).path;
  }

  @override
  String outputDirectory(BuildMode buildMode, String targetArch) {
    final Directory bundleDir = _getBaseDir(buildMode, targetArch).childDirectory('bundle');
    return bundleDir.path;
  }

  @override
  String getAppId() {
    final Directory metaDir =
        project.parent.directory.childDirectory('webos').childDirectory('meta');

    final File metaFile = metaDir.childFile('appinfo.json');
    if (!metaFile.existsSync()) {
      return "";
    }

    return webosSdk!.getPackageId(metaFile);
  }

  @override
  String getDebugLogPath() {
    final Directory metaDir =
        project.parent.directory.childDirectory('webos').childDirectory('meta');

    final File metaFile = metaDir.childFile('flutter-conf.json');
    return webosSdk!.getDebugLogPath(metaFile);
  }

  @override
  String getAppHomePath() {
    final Directory metaDir =
        project.parent.directory.childDirectory('webos').childDirectory('meta');

    final File metaFile = metaDir.childFile('flutter-conf.json');
    return webosSdk!.getAppHomePath(metaFile);
  }

  @override
  String getType() {
    final Directory metaDir =
        project.parent.directory.childDirectory('webos').childDirectory('meta');

    final File metaFile = metaDir.childFile('appinfo.json');
    return webosSdk!.getType(metaFile);
  }

  @override
  String getRequiredPermissions() {
    final Directory metaDir =
        project.parent.directory.childDirectory('webos').childDirectory('meta');

    final File metaFile = metaDir.childFile('appinfo.json');
    if (!metaFile.existsSync()) {
      return '"public"';
    }

    return webosSdk!.getRequiredPermissions(metaFile);
  }

  @override
  String ipkFilePath(BuildMode buildMode, String targetArch) {
    final String appId = getAppId();
    final Directory ipkDir = _getBaseDir(buildMode, targetArch).childDirectory('ipk');

    // ares-package names the IPK "<id>_<version>_<arch>.ipk"; find the newest
    // app-id-prefixed .ipk instead of assuming "<appId>.ipk".
    if (ipkDir.existsSync()) {
      final List<File> ipks = ipkDir
          .listSync()
          .whereType<File>()
          .where((File f) =>
              f.basename.startsWith(appId) && f.basename.endsWith('.ipk'))
          .toList();
      if (ipks.isNotEmpty) {
        ipks.sort((File a, File b) =>
            b.lastModifiedSync().compareTo(a.lastModifiedSync()));
        return ipks.first.path;
      }
    }

    // Fallback before the IPK is built.
    return ipkDir.childFile('$appId.ipk').path;
  }

  Directory _getBaseDir(BuildMode buildMode, String targetArch) {
    final Directory baseDir = project.parent.directory
        .childDirectory('build')
        .childDirectory('webos')
        .childDirectory(targetArch)
        .childDirectory(buildMode.cliName);

    return baseDir;
  }

  @override
  String get name => project.parent.manifest.appName;
}
