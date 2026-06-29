// Copyright (c) 2023 LG Electronics, Inc. All rights reserved.
// Copyright 2023 Sony Group Corporation. All rights reserved.
// Copyright 2020 Samsung Electronics Co., Ltd. All rights reserved.
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:args/args.dart';
//import 'package:flutter_tools/base/common.dart' show throwToolExit;
import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/os.dart';
import 'package:flutter_tools/src/commands/packages.dart';
import 'package:flutter_tools/src/dart/pub.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/project.dart';
import 'package:flutter_tools/src/runner/flutter_command.dart';
import 'package:yaml/yaml.dart';

import '../webos_plugins.dart';

/// This class was copied from `PackagesCommand` to substitute its
/// `PackagesGetCommand` and `PackagesInteractiveGetCommand` subcommands with
/// their webOS equivalents. We may find a better workaround in the future.
///
/// Source: [PackagesCommand] in `packages.dart`
class WebosPackagesCommand extends FlutterCommand {
  WebosPackagesCommand() {
    addSubcommand(WebosPackagesGetCommand(
        'get', "Get the current package's dependencies.", PubContext.pubGet));
    addSubcommand(WebosPackagesGetCommand('upgrade',
        "Upgrade the current package's dependencies to latest versions.", PubContext.pubUpgrade));
    addSubcommand(
        WebosPackagesGetCommand('add', 'Add a dependency to pubspec.yaml.', PubContext.pubAdd));
    addSubcommand(WebosPackagesGetCommand(
        'remove', 'Removes a dependency from the current package.', PubContext.pubRemove));
    addSubcommand(PackagesTestCommand());
    addSubcommand(PackagesValidateCommand());
    addSubcommand(PackagesForwardCommand(
        'publish', 'Publish the current package to pub.dartlang.org',
        requiresPubspec: true));
    addSubcommand(PackagesForwardCommand('downgrade', 'Downgrade packages in a Flutter project',
        requiresPubspec: true));
    addSubcommand(
        PackagesForwardCommand('deps', 'Print package dependencies', requiresPubspec: true));
    addSubcommand(
        PackagesForwardCommand('run', 'Run an executable from a package', requiresPubspec: true));
    addSubcommand(PackagesForwardCommand('cache', 'Work with the Pub system cache'));
    addSubcommand(PackagesForwardCommand('version', 'Print Pub version'));
    addSubcommand(PackagesForwardCommand('uploader', 'Manage uploaders for a package on pub.dev'));
    addSubcommand(PackagesForwardCommand('login', 'Log into pub.dev.'));
    addSubcommand(PackagesForwardCommand('logout', 'Log out of pub.dev.'));
    addSubcommand(PackagesForwardCommand('global', 'Work with Pub global packages'));
    addSubcommand(PackagesForwardCommand(
        'outdated', 'Analyze dependencies to find which ones can be upgraded',
        requiresPubspec: true));
    addSubcommand(PackagesPassthroughCommand());
  }

  @override
  final name = 'pub';

  @override
  List<String> get aliases => const <String>['packages'];

  @override
  final description = 'Commands for managing Flutter packages.';

  @override
  Future<FlutterCommandResult> runCommand() async => FlutterCommandResult.fail();
}

class WebosPackagesGetCommand extends PackagesGetCommand with _PostRunPluginInjection {
  WebosPackagesGetCommand(super.commandName, super.description, super.context);
}

mixin _PostRunPluginInjection on FlutterCommand {
  /// See: [PackagesGetCommand.runCommand] in `packages.dart`
  @override
  Future<FlutterCommandResult> runCommand() async {
    final FlutterCommandResult result = await super.runCommand();

    if (result == FlutterCommandResult.success()) {
      final String? workingDirectory = argResults!.rest.isNotEmpty ? argResults!.rest[0] : null;
      final String? target = findProjectRoot(globals.fs, workingDirectory);
      if (target == null) {
        return result;
      }
      final FlutterProject rootProject = FlutterProject.fromDirectory(globals.fs.directory(target));
      await ensureReadyForWebosTooling(rootProject);
      if (rootProject.hasExampleApp && rootProject.example.pubspecFile.existsSync()) {
        await ensureReadyForWebosTooling(rootProject.example);
      }
    }

    return result;
  }
}

class PackagesValidateCommand extends FlutterCommand {
  PackagesValidateCommand() {
    requiresPubspecYaml();
  }

  @override
  var argParser = ArgParser.allowAnything();

  @override
  String get name => 'validate';

  @override
  String get description {
    return 'Run the "validate" package.\n'
        ' --allowed-url is getting ; separated url string list';
  }

  @override
  String get invocation {
    return '${runner!.executableName} pub validate';
  }

  ArgParser get _permissiveArgParser {
    final argParser = ArgParser();
    argParser.addOption('allowed-url');
    return argParser;
  }

  @override
  Future<FlutterCommandResult> runCommand() async {
    final List<String> rest = argResults!.rest;
    var allowedUrl = <String>['https://pub.dev', 'https://pub.flutter-io.cn'];

    try {
      final ArgResults results = _permissiveArgParser.parse(rest);
      final allowed = results['allowed-url'] as String?;

      if (allowed != null) {
        allowedUrl = allowed.split(';');

        //Transform url as end with '/'
        allowedUrl = allowedUrl.map((u) => u.replaceAll(RegExp(r'/+$'), r'$')).toList();
      }
    } on ArgParserException {
      // Let pub give the error message.
    }

    try {
      final String? target = findProjectRoot(globals.fs);
      if (target == null) {
        throw StateError('Failed to find project root');
      }

      final File pubLockFile = globals.fs.directory(target).childFile('pubspec.lock');

      if (!pubLockFile.existsSync()) {
        globals.printError('Failed to find "pubspec.lock" file.');
        throw StateError('Failed to find "pubspec.lock" file.');
      }

      globals.printTrace('allowed-url: $allowedUrl');
      globals.printTrace('pubLockFile: ${pubLockFile.path}');

      if (!_validate(loadYaml(pubLockFile.readAsStringSync()), allowedUrl)) {
        throw StateError('Package has invalid url source');
      }
    } catch (e) {
      throwToolExit(
        e.toString(),
        exitCode: 1,
      );
    }

    return FlutterCommandResult.success();
  }

  bool _validate(Object? publock, List<String> allowedUrl) {
    final errors = <String>[];

    if (publock == null) {
      return false;
    }

//packages:
//  after_layout:
//    dependency: "direct main"
//    description:
//      name: after_layout
//      sha256: "95a1cb2ca1464f44f14769329fbf15987d20ab6c88f8fc5d359bd362be625f29"
//      url: "https://pub.dev"
//    source: hosted
//    version: "1.2.0"
    if (publock is! YamlMap) {
      return false;
    }

    final Object? packages = publock['packages'];

    if (packages is! YamlMap) {
      errors.add('Expected YAML map');
    } else {
      for (final MapEntry<Object?, Object?> kvp in packages.entries) {
        if (kvp.key is! String) {
          errors.add('Expected YAML key to be a string, but got ${kvp.key}.');
          continue;
        }

        final key = kvp.key as String?;
        globals.printTrace('publock package: $key');

        final package = kvp.value! as YamlMap;

        if (package.containsKey('source')) {
          final String source = package['source'] as String? ?? "";
          if (source == 'sdk' || source == 'path') {
            globals.printTrace('  $key source : $source');
            continue;
          }
        } else {
          errors.add('Package: $key has no source entry');
          break;
        }

        if (package.containsKey('description')) {
          if (!_validateURL(package['description'] as YamlMap, allowedUrl)) {
            errors.add('  $key is using not allowed url');
            break;
          }
        }
      }
    }

    if (errors.isNotEmpty) {
      globals.printStatus('Error detected in pubspec.lock:', emphasis: true);
      globals.printError(errors.join('\n'));
      return false;
    }

    globals.printStatus('Success to validate pubspec.lock');
    return true;
  }

  bool _validateURL(YamlMap description, List<String> allowedUrl) {
    final url = description['url'] as String?;
    if (url == null) {
      return false;
    }

    var matched = false;
    for (final allow in allowedUrl) {
      matched |= url.startsWith(allow);

      if (matched) {
        break;
      }
    }

    if (!matched) {
      globals.printError('Found not allowed url: $url');
    }
    return matched;
  }
}
