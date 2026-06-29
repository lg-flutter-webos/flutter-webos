// Copyright (c) 2023 LG Electronics, Inc. All rights reserved.
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/time.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/version.dart';

const _unknownFrameworkVersion = '0.0.0-unknown';

String _runGit(String directory, String command) {
  return globals.processUtils
      .runSync(
        command.split(' '),
        workingDirectory: directory,
      )
      .stdout
      .trim();
}

class WebosFlutterVersion implements FlutterVersion {
  factory WebosFlutterVersion({
    required FileSystem fs,
    required String flutterRoot,
    bool fetchTags = false,
  }) {
    final version =
        FlutterVersion(fs: fs, git: globals.git, flutterRoot: flutterRoot, fetchTags: fetchTags);
    final String webOSRepositoryUrl =
        _runGit(globals.fs.directory(flutterRoot).parent.path, 'git ls-remote --get-url');

    return WebosFlutterVersion._(
      channel: version.channel,
      dartSdkVersion: version.dartSdkVersion,
      devToolsVersion: version.devToolsVersion,
      engineRevision: version.engineRevision,
      engineRevisionShort: version.engineRevisionShort,
      repositoryUrl: webOSRepositoryUrl,
      frameworkVersion: version.frameworkVersion,
      frameworkRevision: version.frameworkRevision,
      frameworkRevisionShort: version.frameworkRevisionShort,
      frameworkAge: version.frameworkAge,
      frameworkCommitDate: version.frameworkCommitDate,
      gitTagVersion: version.gitTagVersion,
      flutterRoot: flutterRoot,
      baseVersion: version,
    );
  }

  WebosFlutterVersion._({
    required this.channel,
    required this.dartSdkVersion,
    required this.devToolsVersion,
    required this.engineRevision,
    required this.engineRevisionShort,
    required this.repositoryUrl,
    required this.frameworkVersion,
    required this.frameworkRevision,
    required this.frameworkRevisionShort,
    required this.frameworkAge,
    required this.frameworkCommitDate,
    required this.gitTagVersion,
    required this.flutterRoot,
    required this.baseVersion,
  });

  String get embedderVersion {
    final File mVersionFile = globals.fs
        .directory(flutterRoot)
        .parent
        .childDirectory('bin')
        .childDirectory('internal')
        .childFile('webos-artifacts.version');
    return mVersionFile.existsSync() ? mVersionFile.readAsStringSync().trim() : '0';
  }

  String? _webosFrameworkRev;
  String get webosFrameworkRev {
    if (_webosFrameworkRev != null) {
      return _webosFrameworkRev!;
    }
    final String repoPath = globals.fs.directory(flutterRoot).parent.path;
    final String tagsOutput = _runGit(repoPath, 'git tag --points-at HEAD');
    final String webosTag = tagsOutput.split('\n').firstWhere(
          (tag) => tag.contains('webos'),
          orElse: () => '',
        );

    final String commitHash = _runGit(
      repoPath,
      'git -c log.showSignature=false log -n 1 --pretty=format:%h',
    );
    _webosFrameworkRev =
        commitHash.isEmpty ? _unknownFrameworkVersion : '$commitHash $webosTag'.trim();
    return _webosFrameworkRev!;
  }

  @override
  String toString() {
    // First line is the webOS identity; the rest is delegated to upstream.
    final webosText =
        'flutter-webos revision ($webosFrameworkRev) • webOS artifacts $embedderVersion';
    return '$webosText\n$baseVersion';
  }

////////////////////////////////////////////////////////////
  final FlutterVersion baseVersion;

  @override
  FlutterVersion fetchTagsAndGetVersion({
    SystemClock clock = const SystemClock(),
  }) {
    return this;
  }

  @override
  FileSystem get fs => throw UnimplementedError('WebosFlutterVersion .fs is not implemented');

  @override
  Future<void> checkFlutterVersionFreshness() async {
    return baseVersion.checkFlutterVersionFreshness();
  }

  @override
  void ensureVersionFile() {
    return baseVersion.ensureVersionFile();
  }

  @override
  String getVersionString({bool redactUnknownBranches = false}) {
    return baseVersion.getVersionString(redactUnknownBranches: redactUnknownBranches);
  }

  @override
  Map<String, Object> toJson() {
    return <String, Object>{
      ...baseVersion.toJson(),
      'webosArtifactsVersion': embedderVersion,
      'webosFlutterRevision': webosFrameworkRev,
    };
  }

////////////////////////////////////////////////////////////
  @override
  final String flutterRoot;

  @override
  final String devToolsVersion;

  @override
  final String channel;

  @override
  String getBranchName({bool redactUnknownBranches = false}) => channel;

  @override
  final String dartSdkVersion;

  @override
  final String engineRevision;

  @override
  final String engineRevisionShort;

  @override
  final String? repositoryUrl;

  @override
  final String frameworkVersion;

  @override
  final String frameworkRevision;

  @override
  final String frameworkRevisionShort;

  @override
  final String frameworkAge;

  @override
  final String frameworkCommitDate;

  @override
  final GitTagVersion gitTagVersion;

  @override
  String? get engineCommitDate => baseVersion.engineCommitDate;

  @override
  String? get engineBuildDate => baseVersion.engineBuildDate;

  @override
  String? get engineContentHash => baseVersion.engineContentHash;

  @override
  String get engineAge => baseVersion.engineAge;
}
