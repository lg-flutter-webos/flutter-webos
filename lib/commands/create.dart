// Copyright (c) 2023 LG Electronics, Inc. All rights reserved.
// Copyright 2023 Sony Group Corporation. All rights reserved.
// Copyright 2020 Samsung Electronics Co., Ltd. All rights reserved.
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:io';

import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/commands/create.dart';
import 'package:flutter_tools/src/flutter_project_metadata.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/runner/flutter_command.dart';
import 'package:flutter_tools/src/template.dart';

import '../webos_template.dart';

const _kAvailablePlatforms = <String>[
  'webos',
  'ios',
  'android',
  'windows',
  'linux',
  'macos',
  'web',
];

class WebosCreateCommand extends CreateCommand {
  WebosCreateCommand({super.verboseHelp});

  @override
  void addPlatformsOptions({String? customHelp}) {
    argParser.addMultiOption(
      'platforms',
      help: customHelp,
      defaultsTo: _kAvailablePlatforms,
      allowed: _kAvailablePlatforms,
    );
  }

  @override
  Future<int> renderTemplate(
    String templateName,
    Directory directory,
    Map<String, Object?> context, {
    bool overwrite = false,
    bool printStatusWhenWriting = true,
  }) async {
    // Disables https://github.com/flutter/flutter/pull/59706 by setting
    // templateManifest to null.
    final WebosTemplate template = await WebosTemplate.fromName(
      templateName,
      fileSystem: globals.fs,
      logger: globals.logger,
      templateRenderer: globals.templateRenderer,
      templateManifest: null,
    );

    // A Flutter project name may contain underscores, but a webOS app ID
    // disallows them (allowed: a-z, 0-9, '+', '-', '.'). Derive a policy-valid
    // app ID for appinfo.json's `id` by mapping '_' to '-'. Set unconditionally
    // so the value is present whenever the webOS app template renders —
    // including the default case where '--platforms' is not explicitly parsed
    // (the platforms option defaults to a list that already includes webos).
    context['webosAppId'] =
        (context['projectName'] as String? ?? '').replaceAll('_', '-');
    if (argResults!.wasParsed('platforms')) {
      if (_webOSContains()) {
        context['webos'] = true;
        context['no_platforms'] = false;
      }
    }
    return template.render(
      directory,
      context,
      overwriteExisting: overwrite,
      printStatusWhenWriting: printStatusWhenWriting,
    );
  }

  @override
  Future<int> renderMerged(
    List<String> names,
    Directory directory,
    Map<String, Object?> context, {
    bool overwrite = false,
    bool printStatusWhenWriting = true,
  }) async {
    // Disables https://github.com/flutter/flutter/pull/59706 by setting
    // templateManifest to null.
    final WebosTemplate template = await WebosTemplate.merged(
      names,
      directory,
      fileSystem: globals.fs,
      logger: globals.logger,
      templateRenderer: globals.templateRenderer,
      templateManifest: <Uri>{},
    );

    // A Flutter project name may contain underscores, but a webOS app ID
    // disallows them (allowed: a-z, 0-9, '+', '-', '.'). Derive a policy-valid
    // app ID for appinfo.json's `id` by mapping '_' to '-'. Set unconditionally
    // so the value is present whenever the webOS app template renders —
    // including the default case where '--platforms' is not explicitly parsed
    // (the platforms option defaults to a list that already includes webos).
    context['webosAppId'] =
        (context['projectName'] as String? ?? '').replaceAll('_', '-');
    if (argResults!.wasParsed('platforms')) {
      if (_webOSContains()) {
        context['webos'] = true;
        context['no_platforms'] = false;
      }
    }
    return template.render(
      directory,
      context,
      overwriteExisting: overwrite,
      printStatusWhenWriting: printStatusWhenWriting,
    );
  }

  /// See: [CreateCommand._getProjectType] in `create.dart`
  bool get _shouldGeneratePlugin {
    if (argResults!['template'] != null) {
      return stringArg('template') == 'plugin';
    } else if (projectDir.existsSync() && projectDir.listSync().isNotEmpty) {
      return determineTemplateType() == FlutterTemplateType.plugin;
    }
    return false;
  }

  bool get _shouldGenerateFfiPlugin {
    if (argResults!['template'] != null) {
      return stringArg('template') == 'plugin_ffi';
    } else if (projectDir.existsSync() && projectDir.listSync().isNotEmpty) {
      return determineTemplateType() == FlutterTemplateType.pluginFfi;
    }
    return false;
  }

  /// See:
  /// - [CreateCommand.runCommand] in `create.dart`
  /// - `CreateCommand._generatePlugin` in `create.dart`
  /// - [Template.render] in `template.dart`
  @override
  Future<FlutterCommandResult> runCommand() async {
    if (argResults!.rest.isEmpty) {
      return super.runCommand();
    }

    bool shouldRenderWebosTemplate = _webOSContains();
    if ((_shouldGeneratePlugin || _shouldGenerateFfiPlugin) &&
        !argResults!.wasParsed('platforms')) {
      shouldRenderWebosTemplate = false;
    }
    if (!shouldRenderWebosTemplate) {
      return super.runCommand();
    }

    // The template directory that the flutter tools search for available
    // templates cannot be overridden because the implementation is private.
    // So we have to copy webOS templates into the directory manually.
    final Directory webosTemplates =
        globals.fs.directory(Cache.flutterRoot).parent.childDirectory('templates');
    if (!webosTemplates.existsSync()) {
      throwToolExit('Could not locate webos templates.');
    }
    final Directory templates = globals.fs
        .directory(Cache.flutterRoot)
        .childDirectory('packages')
        .childDirectory('flutter_tools')
        .childDirectory('templates');
    _runGitClean(templates);

    try {
      for (final File sharedFile in webosTemplates.listSync().whereType<File>()) {
        final File destFile =
            templates.childDirectory('plugin_shared').childFile(sharedFile.basename);
        globals.printTrace('Copy file ${sharedFile.path} to ${destFile.path}');
        sharedFile.copySync(destFile.path);
      }

      for (final FlutterTemplateType type in FlutterTemplateType.values) {
        final String projectTypeName = type.cliName;

        final Directory projectType = webosTemplates.childDirectory(projectTypeName);
        if (!projectType.existsSync()) {
          continue;
        }

        final Directory dest =
            templates.childDirectory(projectType.basename).childDirectory('webos.tmpl');
        if (dest.existsSync()) {
          dest.deleteSync(recursive: true);
        }

        globals.printTrace('copy ${projectType.path} to ${dest.path}');
        copyDirectory(projectType, dest);
      }

      return await super.runCommand();
    } finally {
      _runGitClean(templates);
    }
  }

  bool _webOSContains() {
    final List<String> platforms = stringsArg('platforms');
    return platforms.contains('webos');
  }

  void _runGitClean(Directory directory) {
    ProcessResult result = globals.processManager.runSync(
      <String>['git', 'restore', '.'],
      workingDirectory: directory.path,
    );
    if (result.exitCode != 0) {
      throwToolExit('Failed to run git restore: ${result.stderr}');
    }
    result = globals.processManager.runSync(
      <String>['git', 'clean', '-df', '.'],
      workingDirectory: directory.path,
    );
    if (result.exitCode != 0) {
      throwToolExit('Failed to run git clean: ${result.stderr}');
    }
  }
}
