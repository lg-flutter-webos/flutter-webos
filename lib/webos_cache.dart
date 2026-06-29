// Copyright (c) 2023 LG Electronics, Inc. All rights reserved.
// Copyright 2023 Sony Group Corporation. All rights reserved.
// Copyright 2020 Samsung Electronics Co., Ltd. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/os.dart' show OperatingSystemUtils;
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/base/process.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/dart/pub.dart';
import 'package:flutter_tools/src/features.dart';
import 'package:flutter_tools/src/flutter_cache.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/project.dart';
import 'package:flutter_tools/src/runner/flutter_command.dart';
import 'package:process/process.dart';

import 'webos_sdk.dart';

mixin WebosRequiredArtifacts on FlutterCommand {
  @override
  Future<Set<DevelopmentArtifact>> get requiredArtifacts async => <DevelopmentArtifact>{
        ...await super.requiredArtifacts,
        WebosDevelopmentArtifact.webos,
      };
}

/// See: [DevelopmentArtifact] in `cache.dart`
class WebosDevelopmentArtifact implements DevelopmentArtifact {
  const WebosDevelopmentArtifact._(this.name);

  @override
  final String name;

  @override
  Feature? get feature => null;

  static const DevelopmentArtifact webos = WebosDevelopmentArtifact._('webos');
}

/// A [Cache] that registers only the artifacts needed for webOS development,
/// avoiding the Android/iOS/Web/desktop artifacts pulled in by [FlutterCache].
///
/// See: [FlutterCache] in `flutter_cache.dart`
class WebosFlutterCache extends Cache {
  WebosFlutterCache({
    required Logger logger,
    required super.fileSystem,
    required Platform platform,
    required super.osUtils,
    required ProcessManager processManager,
    required FlutterProjectFactory projectFactory,
  }) : super(
          logger: logger,
          platform: platform,
          artifacts: <ArtifactSet>[],
        ) {
    registerArtifact(PubDependencies(
      logger: logger,
      // flutter root and pub must be lazily initialized to avoid accessing
      // before the version is determined.
      flutterRoot: () => Cache.flutterRoot!,
      pub: () => pub,
      projectFactory: projectFactory,
    ));
    // Provides common/flutter_patched_sdk{,_product} that frontend_server
    // hard-references for kernel compilation.
    registerArtifact(FlutterSdk(this, platform: platform));
    // Provides linux-x64/const_finder.dart.snapshot and font-subset used by
    // IconTreeShaker during release builds.
    registerArtifact(FontSubsetArtifacts(this, platform: platform));
    registerArtifact(WebosEngineArtifacts(this,
        logger: logger, platform: platform, processManager: processManager));
  }
}

class WebosEngineArtifacts extends EngineCachedArtifact {
  WebosEngineArtifacts(
    Cache cache, {
    required Logger logger,
    required Platform platform,
    required ProcessManager processManager,
  })  : _logger = logger,
        _platform = platform,
        _processUtils = ProcessUtils(processManager: processManager, logger: logger),
        super(
          'webos-sdk',
          cache,
          WebosDevelopmentArtifact.webos,
        );

  final Logger _logger;
  final Platform _platform;
  final ProcessUtils _processUtils;

  @override
  String? get version {
    final File versionFile = globals.fs
        .directory(Cache.flutterRoot)
        .parent
        .childDirectory('bin')
        .childDirectory('internal')
        .childFile('engine.version');
    return versionFile.existsSync() ? versionFile.readAsStringSync().trim() : null;
  }

  String get shortVersion {
    if (version == null) {
      throwToolExit('Failed to get the short revision of the webOS engine artifact.');
    }

    if (version!.length >= 10) {
      return version!.substring(0, 10);
    }
    return version!;
  }

  String? get artifactsVersion {
    final File mVersionFile = globals.fs
        .directory(Cache.flutterRoot)
        .parent
        .childDirectory('bin')
        .childDirectory('internal')
        .childFile('webos-artifacts.version');
    return mVersionFile.existsSync() ? mVersionFile.readAsStringSync().trim() : '0';
  }

  /// See: [Cache.storageBaseUrl] in `cache.dart`
  String get engineBaseUrl {
    final String? overrideUrl = _platform.environment['WEBOS_ENGINE_BASE_URL'];
    if (overrideUrl == null) {
      return 'https://github.com/lg-flutter-webos/artifacts/releases/download';
    }
    try {
      Uri.parse(overrideUrl);
    } on FormatException catch (err) {
      throwToolExit('"WEBOS_ENGINE_BASE_URL" contains an invalid URI:\n$err');
    }
    return overrideUrl;
  }

  List<String> artifactsDir(String platform, String runMode) {
    final String targetArch = webosSdk!.targetArch;

    final artifactsPrefix = '$platform-$targetArch-$runMode';
    return <String>[artifactsPrefix, '$artifactsPrefix.zip'];
  }

  @override
  List<List<String>> getBinaryDirs() => <List<String>>[
        artifactsDir('webos', 'release'),
        artifactsDir('webos', 'debug'),
        artifactsDir('webos', 'profile'),
      ];

  List<List<String>> getBaseBinaryDirs() => <List<String>>[
        <String>['webos', 'common'],
      ];

  @override
  List<String> getLicenseDirs() => const <String>[];

  @override
  List<String> getPackageDirs() => const <String>[];

  @override
  Future<void> updateInner(
    ArtifactUpdater artifactUpdater,
    FileSystem fileSystem,
    OperatingSystemUtils operatingSystemUtils,
  ) async {
    final String? localEnginePath = _platform.environment['WEBOS_ENGINE_LOCAL_PATH'];
    final String platformVersion = webosSdk!.platformVersion;
    // GitHub releases expose assets under a single tag, not nested folders.
    final releaseTag = '$shortVersion-$platformVersion-$artifactsVersion';
    final downloadUrl = '$engineBaseUrl/$releaseTag';

    cleanWebosCache();

    var successCount = 0;
    if (localEnginePath != null) {
      successCount = await _downloadArtifactsFromLocal(operatingSystemUtils, localEnginePath);
    }

    _logger.printTrace('Download Local ARTIFACTS :$successCount');
    // Success downloading all the requires file
    if (successCount == 2) {
      return;
    }

    for (final List<String> toolsDir in getBaseBinaryDirs()) {
      final String cacheDirPrefix = toolsDir[0];
      final String cacheDirPostfix = toolsDir[1];

      final cacheDir = '$cacheDirPrefix-$cacheDirPostfix';
      final urlPath = '$cacheDir.zip';

      await artifactUpdater.downloadZipArchive(
        'Downloading $cacheDir tools...',
        Uri.parse('$downloadUrl/$urlPath'),
        location.childDirectory(cacheDir),
      );
    }

    // webos-common file is missing in local path
    // and got file from remote
    if (successCount == 1) {
      return;
    }

    for (final List<String> toolsDir in getBinaryDirs()) {
      final String cacheDir = toolsDir[0];
      final String urlPath = toolsDir[1];

      await artifactUpdater.downloadZipArchive(
        'Downloading $cacheDir tools...',
        Uri.parse('$downloadUrl/$urlPath'),
        location.childDirectory(cacheDir),
      );
    }
  }

  Future<int> _downloadArtifactsFromLocal(
    OperatingSystemUtils operatingSystemUtils,
    String localEnginePath,
  ) async {
    _logger.printStatus('Unpack webOS artifacts from local path...');
    var success = 0;

    // lib32-flutter-wayland-client-sdk-dev/webos-arm-release.zip
    final exp = RegExp(r'(.*)/([\w-]+)\.zip');
    final RegExpMatch? match = exp.firstMatch(localEnginePath);

    if (match == null || match.groupCount != 2) {
      return success;
    }

    await _unzipArtifacts(operatingSystemUtils, '${match[2]}', localEnginePath);
    success++;

    final File localCommonFile = globals.fs.directory(match[1]).childFile('webos-common.zip');
    if (!localCommonFile.existsSync()) {
      return success;
    }

    await _unzipArtifacts(operatingSystemUtils, 'webos-common', localCommonFile.path);
    success++;

    return success;
  }

  Future<void> _unzipArtifacts(
    OperatingSystemUtils operatingSystemUtils,
    String cacheDir,
    String filePath,
  ) async {
    final Directory artifactDir = location.childDirectory(cacheDir);
    final Status status = _logger.startProgress('Copying $cacheDir tools...');

    try {
      if (artifactDir.existsSync()) {
        artifactDir.deleteSync(recursive: true);
      }
      artifactDir.createSync(recursive: true);
      final RunResult result = await _processUtils.run(<String>[
        'unzip',
        filePath,
        '-d',
        artifactDir.path,
      ]);
      if (result.exitCode != 0) {
        throwToolExit(
          'Failed to copy webOS artifact from local.\n\n'
          '$result',
        );
      }
    } finally {
      status.stop();
    }
    _makeFilesExecutable(artifactDir, operatingSystemUtils);
  }

  /// Source: [EngineCachedArtifact._makeFilesExecutable] in `cache.dart`
  void _makeFilesExecutable(
    Directory dir,
    OperatingSystemUtils operatingSystemUtils,
  ) {
    operatingSystemUtils.chmod(dir, 'a+r,a+x');
    for (final File file in dir.listSync(recursive: true).whereType<File>()) {
      if (file.basename == 'gen_snapshot') {
        operatingSystemUtils.chmod(file, 'a+r,a+x');
      }
    }
  }

  void cleanWebosCache() {
    location.listSync().forEach((d) {
      if (d is Directory) {
        final Directory dir = d;

        if (dir.basename.indexOf('webos') == 0) {
          _logger.printTrace('Cleanup webOS artifacts ${d.path}...');
          dir.deleteSync(recursive: true);
        }
      }
    });
  }
}
