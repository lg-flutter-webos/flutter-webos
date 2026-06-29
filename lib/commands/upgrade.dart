// Copyright (c) 2023 LG Electronics, Inc. All rights reserved.
// Copyright 2023 Sony Group Corporation. All rights reserved.
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:core';

import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/io.dart';
import 'package:flutter_tools/src/base/os.dart';
import 'package:flutter_tools/src/base/process.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/commands/upgrade.dart';
import 'package:flutter_tools/src/dart/pub.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/project.dart';
import 'package:flutter_tools/src/runner/flutter_command.dart';

import 'package:meta/meta.dart';

/// Source: [UpgradeCommand] in `upgrade.dart`
class WebosUpgradeCommand extends UpgradeCommand {
  WebosUpgradeCommand({
    required super.verboseHelp,
  });

  @override
  Future<FlutterCommandResult> runCommand() {
    final commandRunner = WebosUpgradeCommandRunner();
    commandRunner.workingDirectory =
        stringArg('working-directory') ?? globals.fs.directory(Cache.flutterRoot).parent.path;
    return commandRunner.runCommand(
      force: boolArg('force'),
      continueFlow: boolArg('continue'),
      testFlow: stringArg('working-directory') != null,
      verifyOnly: boolArg('verify-only'),
    );
  }
}

class WebosGitTagVersion {
  WebosGitTagVersion(
    this.hash,
    this.hashShort,
    this.gitTag,
  );

  /// The git hash (or an abbreviation thereof) for this commit.
  final String? hash;

  /// The git short hash (or an abbreviation thereof) for this commit.
  final String hashShort;

  /// The git tag that is this version's closest ancestor.
  final String? gitTag;
}

/// Source: [UpgradeCommandRunner] in `upgrade.dart`
@visibleForTesting
class WebosUpgradeCommandRunner {
  String? workingDirectory;

  Future<FlutterCommandResult> runCommand({
    required bool force,
    required bool continueFlow,
    required bool testFlow,
    required bool verifyOnly,
  }) async {
    if (!continueFlow) {
      await runCommandFirstHalf(
        force: force,
        testFlow: testFlow,
        verifyOnly: verifyOnly,
      );
    } else {
      await runCommandSecondHalf();
    }
    return FlutterCommandResult.success();
  }

  Future<void> runCommandFirstHalf({
    required bool force,
    required bool testFlow,
    required bool verifyOnly,
  }) async {
    WebosGitTagVersion upstreamVersion = await fetchTaggedLatestVersion();
    final WebosGitTagVersion currentVersion = await fetchCurrentVersion();

    // Gets the latest version of the current branch,
    // if the current dir does not have any tags.
    if (currentVersion.gitTag == null) {
      upstreamVersion = await fetchCurrentBranchLatestVersion();
    }

    if (currentVersion.hash == upstreamVersion.hash) {
      globals.printStatus('flutter-webos is already up to date');
      return;
    }

    globals.printStatus('A new version of flutter-webos is available\n');
    if (currentVersion.gitTag != null) {
      globals.printStatus(
          'The latest version: ${upstreamVersion.gitTag} (revision ${upstreamVersion.hashShort})',
          emphasis: true);
      globals.printStatus(
          'Your current version: ${currentVersion.gitTag} (revision ${currentVersion.hashShort})\n');
    } else {
      globals.printStatus('The latest revision: ${upstreamVersion.hashShort}', emphasis: true);
      globals.printStatus('Your current revision: ${currentVersion.hashShort}\n');
    }
    if (verifyOnly) {
      globals.printStatus('To upgrade now, run "flutter-webos upgrade".');
      return;
    }

    if (!force && await hasUncommittedChanges()) {
      throwToolExit('Your flutter-webos checkout has local changes that would be erased by '
          'upgrading. If you want to keep these changes, it is recommended that '
          'you stash them via "git stash" or else commit the changes to a local '
          'branch. If it is okay to remove local changes, then re-run this '
          'command with "--force".');
    }

    if (currentVersion.gitTag != null) {
      globals.printStatus(
          'Upgrading flutter-webos to ${upstreamVersion.gitTag} from ${currentVersion.gitTag} in $workingDirectory...');
    } else {
      globals.printStatus(
          'Upgrading flutter-webos to ${upstreamVersion.hashShort} from ${currentVersion.hashShort} in $workingDirectory...');
    }
    await attemptReset(upstreamVersion.hash);
    if (!testFlow) {
      await flutterUpgradeContinue();
    }
  }

  /// Source: [UpgradeCommandRunner.hasUncommittedChanges] in `upgrade.dart`
  Future<bool> hasUncommittedChanges() async {
    try {
      final RunResult result = await globals.processUtils.run(
        <String>['git', 'status', '-s'],
        throwOnError: true,
        workingDirectory: workingDirectory,
      );
      return result.stdout.trim().isNotEmpty;
    } on ProcessException catch (error) {
      throwToolExit(
          'The tool could not verify the status of the current flutter-webos checkout. '
          'This might be due to git not being installed or an internal error. '
          'If it is okay to ignore potential local changes, then re-run this '
          'command with "--force".\n'
          'Error: $error.');
    }
  }

  Future<WebosGitTagVersion> fetchTaggedLatestVersion() async {
    String latestTag;
    String latestRevision;
    try {
      // Fetch upstream branch's commits and tags
      await globals.processUtils.run(
        <String>['git', 'fetch', '--tags'],
        throwOnError: true,
        workingDirectory: workingDirectory,
      );

      RunResult result = await globals.processUtils.run(
        <String>['git', 'tag', '-l', '--sort=-v:refname'],
        throwOnError: true,
        workingDirectory: workingDirectory,
      );
      final List<String> tags = const LineSplitter().convert(result.stdout.trim());
      if (tags.isEmpty) {
        throwToolExit(
            'Unable to upgrade flutter-webos: Your flutter-webos checkout does not have any tags.\n'
            'Re-install flutter-webos.');
      }

      // Gets the hash of the latest version.
      latestTag = tags.firstWhere(
        (String tag) => tag.startsWith(RegExp(r'[0-9]')),
        orElse: () => throw StateError('No version tag found starting with a digit.'),
      );
      result = await globals.processUtils.run(
        <String>['git', 'rev-parse', latestTag],
        throwOnError: true,
        workingDirectory: workingDirectory,
      );
      latestRevision = result.stdout.trim();
    } on StateError catch (e) {
      throwToolExit('Unable to upgrade flutter-webos: ${e.message}\n'
          'Use a version format like [major].[minor].xx (e.g., 1.2.34).');
    } on Exception catch (_) {
      throwToolExit('Unable to upgrade flutter-webos: The current flutter-webos branch is '
          'not tracking any remote repository.\n'
          'Re-install flutter-webos.');
    }
    return WebosGitTagVersion(latestRevision, latestRevision.substring(0, 10), latestTag);
  }

  Future<WebosGitTagVersion> fetchCurrentBranchLatestVersion() async {
    String latestRevision;
    try {
      final RunResult result = await globals.processUtils.run(
        <String>['git', 'log', '-n', '1'],
        throwOnError: true,
        workingDirectory: workingDirectory,
      );

      // Gets the hash of the latest version.
      // e.g. commit 13d148c1980913b68f55032dc37ae6026b71a2a1 (HEAD -> main, origin/main, origin/HEAD)
      final List<String> lines = const LineSplitter().convert(result.stdout.trim());
      if (lines.isEmpty) {
        throwToolExit(
            'Unable to upgrade flutter-webos: Your flutter-webos checkout does not have any logs.\n'
            'Re-install flutter-webos.');
      }
      latestRevision = lines[0].split(' ')[1];
    } on Exception catch (_) {
      throwToolExit('Unable to upgrade flutter-webos: The current flutter-webos branch is '
          'not tracking any remote repository.\n'
          'Re-install flutter-webos.');
    }
    return WebosGitTagVersion(latestRevision, latestRevision.substring(0, 10), null);
  }

  Future<WebosGitTagVersion> fetchCurrentVersion() async {
    String? tag;
    String? latestRevision;
    try {
      RunResult result = await globals.processUtils.run(
        <String>['git', 'rev-parse', '--verify', 'HEAD'],
        throwOnError: true,
        workingDirectory: workingDirectory,
      );
      latestRevision = result.stdout.trim();

      result = await globals.processUtils.run(
        <String>['git', 'describe', '--exact-match', 'HEAD'],
        throwOnError: true,
        workingDirectory: workingDirectory,
      );
      tag = result.stdout.trim();
    } on Exception catch (e) {
      final errorString = e.toString();
      if (errorString.contains('fatal: no tag exactly matches')) {
        tag = null;
      } else if (errorString.contains('fatal: HEAD does not point to a branch')) {
        throwToolExit(
            'Unable to upgrade flutter-webos: Your flutter-webos checkout is currently not '
            'on a release branch.\n'
            'Re-install flutter-webos.');
      } else if (errorString.contains('fatal: no upstream configured for branch')) {
        throwToolExit('Unable to upgrade flutter-webos: The current flutter-webos branch is '
            'not tracking any remote repository.\n'
            'Re-install flutter-webos.');
      } else {
        throwToolExit(errorString);
      }
    }
    return WebosGitTagVersion(latestRevision, latestRevision!.substring(0, 10), tag);
  }

  /// Source: [attemptReset] in `upgrade.dart` (exact copy)
  Future<void> attemptReset(String? newRevision) async {
    try {
      await globals.processUtils.run(
        <String>['git', 'reset', '--hard', newRevision!],
        throwOnError: true,
        workingDirectory: workingDirectory,
      );

      final File pubLockFile =
          globals.fs.file(globals.fs.path.join(workingDirectory!, 'pubspec.lock'));
      if (await pubLockFile.exists()) {
        await pubLockFile.delete();
      }
    } on ProcessException catch (e) {
      throwToolExit(e.message, exitCode: e.errorCode);
    }
  }

  /// Source: [attemptReset] in `upgrade.dart`
  Future<void> flutterUpgradeContinue() async {
    final int code = await globals.processUtils.stream(
      <String>[
        globals.fs.path.join('bin', 'flutter-webos'),
        'upgrade',
        '--continue',
        '--no-version-check',
      ],
      workingDirectory: workingDirectory,
      allowReentrantFlutter: true,
      environment: Map<String, String>.of(globals.platform.environment),
    );
    if (code != 0) {
      throwToolExit(null, exitCode: code);
    }
  }

  /// Source: [runCommandSecondHalf] in `upgrade.dart`
  Future<void> runCommandSecondHalf() async {
    // Make sure the welcome message re-display is delayed until the end.
    globals.persistentToolState?.setShouldRedisplayWelcomeMessage(false);
    await precacheArtifacts();
    await updatePackages();
    await runDoctor();
    // Force the welcome message to re-display following the upgrade.
    globals.persistentToolState?.setShouldRedisplayWelcomeMessage(true);
  }

  /// Source: [precacheArtifacts] in `upgrade.dart`
  Future<void> precacheArtifacts() async {
    globals.printStatus('');
    globals.printStatus('Upgrading engine...');
    final int code = await globals.processUtils.stream(
      <String>[
        globals.fs.path.join('bin', 'flutter-webos'),
        '--no-color',
        '--no-version-check',
        'precache',
        '--force',
        '--webos',
      ],
      workingDirectory: workingDirectory,
      allowReentrantFlutter: true,
      environment: Map<String, String>.of(globals.platform.environment),
    );
    if (code != 0) {
      throwToolExit(null, exitCode: code);
    }
  }

  /// Source: [updatePackages] in `upgrade.dart`
  Future<void> updatePackages() async {
    globals.printStatus('');
    final String? projectRoot = findProjectRoot(globals.fs);
    if (projectRoot != null) {
      globals.printStatus('');
      await pub.get(
        context: PubContext.pubUpgrade,
        project: FlutterProject.fromDirectory(globals.fs.directory(projectRoot)),
        upgrade: true,
      );
    }
  }

  /// Source: [runDoctor] in `upgrade.dart`
  Future<void> runDoctor() async {
    globals.printStatus('');
    globals.printStatus('Running flutter doctor...');
    await globals.processUtils.stream(
      <String>[
        globals.fs.path.join('bin', 'flutter-webos'),
        '--no-version-check',
        'doctor',
      ],
      workingDirectory: workingDirectory,
      allowReentrantFlutter: true,
    );
  }
}
