// Copyright (c) 2023 LG Electronics, Inc. All rights reserved.
// Copyright 2023 Sony Group Corporation. All rights reserved.
// Copyright 2020 Samsung Electronics Co., Ltd. All rights reserved.
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';

import 'package:file/file.dart';
import 'package:flutter_tools/src/base/error_handling_io.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/build_system/targets/web.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/dart/language_version.dart';
import 'package:flutter_tools/src/dart/package_map.dart';
import 'package:flutter_tools/src/dart/pub.dart';
import 'package:flutter_tools/src/flutter_plugins.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/platform_plugins.dart';
import 'package:flutter_tools/src/plugins.dart';
import 'package:flutter_tools/src/project.dart';
import 'package:flutter_tools/src/runner/flutter_command.dart';

import 'package:package_config/package_config.dart';
import 'package:path/path.dart' as path;
import 'package:yaml/yaml.dart';

import 'webos_cmake_project.dart';

/// Source: [LinuxPlugin] in `platform_plugins.dart`
class WebosPlugin extends PluginPlatform implements NativeOrDartPlugin {
  WebosPlugin({
    required this.name,
    required this.directory,
    this.pluginClass,
    this.dartPluginClass,
    this.ffiPlugin,
    this.defaultPackage,
    this.dependencies,
  }) : assert(pluginClass != null ||
            dartPluginClass != null ||
            (ffiPlugin ?? false) ||
            defaultPackage != null);

  factory WebosPlugin.fromYaml(
      String name, Directory directory, YamlMap yaml, List<String> dependencies) {
    assert(validate(yaml));
    // Treat 'none' as not present. See https://github.com/flutter/flutter/issues/57497.
    var pluginClass = yaml[kPluginClass] as String?;
    if (pluginClass == 'none') {
      pluginClass = null;
    }
    return WebosPlugin(
        name: name,
        directory: directory,
        pluginClass: yaml[kPluginClass] as String?,
        dartPluginClass: yaml[kDartPluginClass] as String?,
        ffiPlugin: yaml[kFfiPlugin] as bool?,
        defaultPackage: yaml[kDefaultPackage] as String?,
        dependencies: dependencies);
  }

  static bool validate(YamlMap yaml) {
    return yaml[kPluginClass] is String ||
        yaml[kDartPluginClass] is String ||
        yaml[kFfiPlugin] == true ||
        yaml[kDefaultPackage] is String;
  }

  static const kConfigKey = 'webos';

  final String name;
  final Directory directory;
  final String? pluginClass;
  final String? dartPluginClass;
  final List<String>? dependencies;
  final bool? ffiPlugin;
  final String? defaultPackage;

  @override
  bool hasMethodChannel() => pluginClass != null;

  @override
  bool hasFfi() => ffiPlugin ?? false;

  @override
  bool hasDart() => dartPluginClass != null;

  @override
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'name': name,
      if (pluginClass != null) 'class': pluginClass,
      if (pluginClass != null) 'filename': _filenameForCppClass(pluginClass!),
      if (dartPluginClass != null) 'dartPluginClass': dartPluginClass,
      if (ffiPlugin ?? false) kFfiPlugin: true,
      if (defaultPackage != null) kDefaultPackage: defaultPackage,
    };
  }

  String get path => directory.parent.path;
}

/// Source: [_internalCapitalLetterRegex] in `platform_plugins.dart` (exact copy)
final _internalCapitalLetterRegex = RegExp(r'(?=(?!^)[A-Z])');
String _filenameForCppClass(String className) {
  return className.splitMapJoin(_internalCapitalLetterRegex,
      onMatch: (_) => '_', onNonMatch: (String n) => n.toLowerCase());
}

/// See: [FlutterCommand.verifyThenRunCommand] in `flutter_command.dart`
mixin WebosExtension on FlutterCommand {
  String? _entrypoint;
  var _pubGetDone = false;

  bool get _usesTargetOption => argParser.options.containsKey('target');

  @override
  bool get shouldRunPub => !_pubGetDone && super.shouldRunPub;

  @override
  Future<FlutterCommandResult> verifyThenRunCommand(String? commandPath) async {
    if (super.shouldRunPub) {
      final FlutterProject project = FlutterProject.current();
      project.checkForDeprecation(deprecationBehavior: deprecationBehavior);
      await pub.get(
        context: PubContext.getVerifyContext(name),
        project: project,
        checkUpToDate: cachePubGet,
      );
      _pubGetDone = true;
    }
    if (_usesTargetOption) {
      _entrypoint = await _createEntrypoint(
        FlutterProject.current(),
        super.targetFile,
      );
    }
    return super.verifyThenRunCommand(commandPath);
  }

  @override
  String get targetFile => _entrypoint ?? super.targetFile;
}

/// Creates an entrypoint wrapper of [targetFile] and returns its path.
/// This effectively adds support for Dart plugins.
///
/// Source: [WebEntrypointTarget.build] in `web.dart`
Future<String> _createEntrypoint(FlutterProject project, String targetFile) async {
  final List<WebosPlugin> dartPlugins = await findWebosPlugins(project, dartOnly: true);
  if (dartPlugins.isEmpty) {
    return targetFile;
  }

  final webosProject = WebosProject.fromFlutter(project);
  if (!webosProject.existsSync()) {
    return targetFile;
  }

  final File entrypoint = webosProject.managedDirectory.childFile('main.dart')
    ..createSync(recursive: true);
  final File packagesFile =
      project.directory.childDirectory('.dart_tool').childFile('package_config.json');
  final PackageConfig packageConfig = await loadPackageConfigWithLogging(
    packagesFile,
    logger: globals.logger,
  );
  final FlutterProject flutterProject = FlutterProject.current();
  final LanguageVersion languageVersion = determineLanguageVersion(
    globals.fs.file(targetFile),
    packageConfig[flutterProject.manifest.appName],
    Cache.flutterRoot!,
  );

  final Uri mainUri = globals.fs.file(targetFile).absolute.uri;
  final String mainImport = packageConfig.toPackageUri(mainUri)?.toString() ?? mainUri.toString();

  entrypoint.writeAsStringSync('''
//
// Generated file. Do not edit.
//
// @dart=${languageVersion.major}.${languageVersion.minor}

import '$mainImport' as entrypoint;
import 'generated_plugin_registrant.dart';

Future<void> main() async {
  registerPlugins();
  entrypoint.main();
}
''');

  return entrypoint.path;
}

/// This function must be called whenever [FlutterProject.regeneratePlatformSpecificTooling]
/// or [FlutterProject.ensureReadyForPlatformSpecificTooling] is called.
///
/// See: [FlutterProject.ensureReadyForPlatformSpecificTooling] in `project.dart`
Future<void> ensureReadyForWebosTooling(FlutterProject project) async {
  if (!project.directory.existsSync() || project.hasExampleApp || project.isPlugin) {
    return;
  }
  final webosProject = WebosProject.fromFlutter(project);
  await webosProject.ensureReadyForPlatformSpecificTooling();

  await injectWebosPlugins(project);
}

/// See: [refreshPluginsList] in `flutter_plugins.dart`
Future<void> refreshWebosPluginsList(FlutterProject project) async {
  final List<WebosPlugin> plugins = await findWebosPlugins(project);
  // Sort the plugins by name to keep ordering stable in generated files.
  plugins.sort((WebosPlugin left, WebosPlugin right) => left.name.compareTo(right.name));
  // TODO(franciscojma): Remove once migration is complete.
  // Write the legacy plugin files to avoid breaking existing apps.
  final bool legacyChanged = _writeWebosFlutterPluginsListLegacy(project, plugins);

  final bool changed = await _writeWebosFlutterPluginsList(project, plugins);
  if (changed || legacyChanged) {
    createPluginSymlinks(project, force: true);
  }
}

/// See: `_writeFlutterPluginsListLegacy` in `flutter_plugins.dart`
bool _writeWebosFlutterPluginsListLegacy(FlutterProject project, List<WebosPlugin> plugins) {
  final File pluginsFile = project.directory.childFile('.flutter-plugins');
  if (plugins.isEmpty) {
    return ErrorHandlingFileSystem.deleteIfExists(pluginsFile);
  }

  const info = 'This is a generated file; do not edit or check into version control.';
  final flutterPluginsBuffer = StringBuffer('# $info\n');

  for (final plugin in plugins) {
    flutterPluginsBuffer.write('${plugin.name}=${globals.fsUtils.escapePath(plugin.path)}\n');
  }
  final String? oldPluginFileContent = _readFileContent(pluginsFile);
  final pluginFileContent = flutterPluginsBuffer.toString();
  pluginsFile.writeAsStringSync(pluginFileContent, flush: true);

  return oldPluginFileContent != _readFileContent(pluginsFile);
}

// Key strings for the .flutter-plugins-dependencies file.
const _kFlutterPluginsPluginListKey = 'plugins';
const _kFlutterPluginsNameKey = 'name';
const _kFlutterPluginsPathKey = 'path';
const _kFlutterPluginsDependenciesKey = 'dependencies';

/// See: `_writeFlutterPluginsList` in `flutter_plugins.dart`
Future<bool> _writeWebosFlutterPluginsList(
    FlutterProject project, List<WebosPlugin> plugins) async {
  final File pluginsFile = project.flutterPluginsDependenciesFile;
  if (plugins.isEmpty) {
    return ErrorHandlingFileSystem.deleteIfExists(pluginsFile);
  }

  final String iosKey = project.ios.pluginConfigKey;
  final String androidKey = project.android.pluginConfigKey;
  final String macosKey = project.macos.pluginConfigKey;
  final String linuxKey = project.linux.pluginConfigKey;
  final String windowsKey = project.windows.pluginConfigKey;
  final String webKey = project.web.pluginConfigKey;
  final String webosKey = WebosProject.fromFlutter(project).pluginConfigKey;

  final pluginsMap = <String, Object>{};
  {
    final List<Plugin> plugins = await findPlugins(project);
    pluginsMap[iosKey] = _filterPluginsByPlatform(plugins, iosKey);
    pluginsMap[androidKey] = _filterPluginsByPlatform(plugins, androidKey);
    pluginsMap[macosKey] = _filterPluginsByPlatform(plugins, macosKey);
    pluginsMap[linuxKey] = _filterPluginsByPlatform(plugins, linuxKey);
    pluginsMap[windowsKey] = _filterPluginsByPlatform(plugins, windowsKey);
    pluginsMap[webKey] = _filterPluginsByPlatform(plugins, webKey);
  }
  pluginsMap[webosKey] = _filterWebosPluginsByPlatform(plugins, webosKey);

  final result = <String, Object>{};
  result['info'] = 'This is a generated file; do not edit or check into version control.';
  result[_kFlutterPluginsPluginListKey] = pluginsMap;

  /// The dependencyGraph object is kept for backwards compatibility, but
  /// should be removed once migration is complete.
  /// https://github.com/flutter/flutter/issues/48918
  result['dependencyGraph'] = _createPluginLegacyDependencyGraph(plugins);
  result['date_created'] = globals.systemClock.now().toString();
  result['version'] = globals.flutterVersion.frameworkVersion;

  // Only notify if the plugins list has changed. [date_created] will always be different,
  // [version] is not relevant for this check.
  const pluginsChanged = true;
  final String pluginFileContent = json.encode(result);
  pluginsFile.writeAsStringSync(pluginFileContent, flush: true);

  return pluginsChanged;
}

/// See: [_filterPluginsByPlatform] in `plugins.dart` (exact copy)
List<Map<String, Object>> _filterPluginsByPlatform(List<Plugin> plugins, String platformKey) {
  final Iterable<Plugin> platformPlugins = plugins.where((Plugin p) {
    return p.platforms.containsKey(platformKey);
  });

  final Set<String> pluginNames = platformPlugins.map((Plugin plugin) => plugin.name).toSet();
  final pluginInfo = <Map<String, Object>>[];
  for (final plugin in platformPlugins) {
    pluginInfo.add(<String, Object>{
      _kFlutterPluginsNameKey: plugin.name,
      _kFlutterPluginsPathKey: globals.fsUtils.escapePath(plugin.path),
      _kFlutterPluginsDependenciesKey: <String>[...plugin.dependencies.where(pluginNames.contains)],
    });
  }
  return pluginInfo;
}

/// See: [_filterPluginsByPlatform] in `plugins.dart`
List<Map<String, Object>> _filterWebosPluginsByPlatform(
    List<WebosPlugin> plugins, String platformKey) {
  final Set<String> pluginNames = plugins.map((WebosPlugin plugin) => plugin.name).toSet();
  final pluginInfo = <Map<String, Object>>[];
  for (final plugin in plugins) {
    pluginInfo.add(<String, Object>{
      _kFlutterPluginsNameKey: plugin.name,
      _kFlutterPluginsPathKey: globals.fsUtils.escapePath(plugin.path),
      _kFlutterPluginsDependenciesKey: <String>[
        ...plugin.dependencies!.where(pluginNames.contains)
      ],
    });
  }
  return pluginInfo;
}

/// See: [_createPluginLegacyDependencyGraph] in `flutter_plugins.dart`
List<Object> _createPluginLegacyDependencyGraph(List<WebosPlugin> plugins) {
  final directAppDependencies = <Object>[];
  final Set<String> pluginNames = plugins.map((WebosPlugin plugin) => plugin.name).toSet();

  for (final plugin in plugins) {
    directAppDependencies.add(<String, Object>{
      'name': plugin.name,
      // Extract the plugin dependencies which happen to be plugins.
      'dependencies': <String>[...plugin.dependencies!.where(pluginNames.contains)],
    });
  }
  return directAppDependencies;
}

/// See: [injectPlugins] in `plugins.dart`
Future<void> injectWebosPlugins(FlutterProject project) async {
  final webosProject = WebosProject.fromFlutter(project);
  if (webosProject.existsSync()) {
    final List<WebosPlugin> dartPlugins = await findWebosPlugins(project, dartOnly: true);
    final List<WebosPlugin> nativePlugins = await findWebosPlugins(project, nativeOnly: true);
    _writeDartPluginRegistrant(webosProject.managedDirectory, dartPlugins);
    _writePluginCmakefileTemplate(webosProject, webosProject.managedDirectory, nativePlugins);
  }
}

/// Source: [findPlugins] in `plugins.dart`
Future<List<WebosPlugin>> findWebosPlugins(
  FlutterProject project, {
  bool dartOnly = false,
  bool nativeOnly = false,
  bool throwOnError = true,
}) async {
  final plugins = <WebosPlugin>[];
  final File packagesFile =
      project.directory.childDirectory('.dart_tool').childFile('package_config.json');
  final PackageConfig packageConfig = await loadPackageConfigWithLogging(
    packagesFile,
    logger: globals.logger,
    throwOnError: throwOnError,
  );

  for (final Package package in packageConfig.packages) {
    final Uri packageRoot = package.packageUriRoot.resolve('..');
    final WebosPlugin? plugin = _pluginFromPackage(package.name, packageRoot);
    if (plugin == null) {
      continue;
    } else if (nativeOnly &&
        !plugin.hasFfi() &&
        (plugin.pluginClass == null || plugin.pluginClass == 'none')) {
      continue;
    } else if (dartOnly && plugin.dartPluginClass == null) {
      continue;
    }
    plugins.add(plugin);
  }
  return plugins;
}

/// Source: [_pluginFromPackage] in `plugins.dart`
WebosPlugin? _pluginFromPackage(String name, Uri packageRoot) {
  final String pubspecPath = globals.fs.path.fromUri(packageRoot.resolve('pubspec.yaml'));
  if (!globals.fs.isFileSync(pubspecPath)) {
    return null;
  }

  YamlMap? pubspec;
  try {
    pubspec = loadYaml(globals.fs.file(pubspecPath).readAsStringSync()) as YamlMap?;
  } on YamlException catch (err) {
    globals.printTrace('Failed to parse plugin manifest for $name: $err');
  }
  if (pubspec == null) {
    return null;
  }
  final flutterConfig = pubspec['flutter'] as YamlMap?;
  if (flutterConfig == null || !flutterConfig.containsKey('plugin')) {
    return null;
  }

  final Directory packageDir = globals.fs.directory(packageRoot);
  globals.printTrace('Found plugin $name at ${packageDir.path}');

  final pluginYaml = flutterConfig['plugin'] as YamlMap;
  if (pluginYaml['platforms'] == null) {
    return null;
  }
  final platformsYaml = pluginYaml['platforms'] as YamlMap;
  if (platformsYaml[WebosPlugin.kConfigKey] == null) {
    return null;
  }
  final dependencies = pubspec['dependencies'] as YamlMap;
  return WebosPlugin.fromYaml(
    name,
    packageDir.childDirectory('webos'),
    platformsYaml[WebosPlugin.kConfigKey] as YamlMap,
    <String>[...dependencies.keys.cast<String>()],
  );
}

/// See: `_writeWebPluginRegistrant` in `plugins.dart`
void _writeDartPluginRegistrant(
  Directory registryDirectory,
  List<WebosPlugin> plugins,
) {
  final List<Map<String, dynamic>> pluginConfigs =
      plugins.where((p) => p.hasDart()).map((WebosPlugin plugin) => plugin.toMap()).toList();

  final context = <String, dynamic>{
    'plugins': pluginConfigs,
  };
  _renderTemplateToFile(
    '''
//
// Generated file. Do not edit.
//

// ignore_for_file: lines_longer_than_80_chars

{{#plugins}}
import 'package:{{name}}/{{name}}.dart';
{{/plugins}}

// ignore: public_member_api_docs
void registerPlugins() {
{{#plugins}}
  {{dartPluginClass}}.registerWith();
{{/plugins}}
}
''',
    context,
    registryDirectory.childFile('generated_plugin_registrant.dart').path,
  );
}

/// See: `_writeWindowsPluginFiles` in `plugins.dart`
void _writePluginCmakefileTemplate(
  WebosProject webosProject,
  Directory registryDirectory,
  List<WebosPlugin> plugins,
) {
  final List<Map<String, dynamic>> pluginConfigs =
      plugins.where((p) => !p.hasFfi()).map((WebosPlugin plugin) => plugin.toMap()).toList();
  final List<Map<String, dynamic>> ffiConfigs =
      plugins.where((p) => p.hasFfi()).map((WebosPlugin plugin) => plugin.toMap()).toList();

  final context = <String, dynamic>{
    'plugins': pluginConfigs,
    'ffiPlugins': ffiConfigs,
    'pluginsDir': _cmakeRelativePluginSymlinkDirectoryPath(webosProject),
  };
  _renderTemplateToFile(
    '''
//
// Generated file. Do not edit.
//

#ifndef GENERATED_PLUGIN_REGISTRANT_
#define GENERATED_PLUGIN_REGISTRANT_

#include <flutter/plugin_registry.h>

// Registers Flutter plugins.
extern "C" void RegisterPlugins(flutter::PluginRegistry* registry);

#endif  // GENERATED_PLUGIN_REGISTRANT_
''',
    context,
    registryDirectory.childFile('generated_plugin_registrant.h').path,
  );
  _renderTemplateToFile(
    '''
//
// Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

{{#plugins}}
#include <{{name}}/{{filename}}.h>
{{/plugins}}

void RegisterPlugins(flutter::PluginRegistry* registry) {
{{#plugins}}
  {{class}}RegisterWithRegistrar(
      registry->GetRegistrarForPlugin("{{class}}"));
{{/plugins}}
}
''',
    context,
    registryDirectory.childFile('generated_plugin_registrant.cc').path,
  );
  _renderTemplateToFile(
    r'''
#
# Generated file, do not edit.
#

list(APPEND FLUTTER_PLUGIN_LIST
{{#plugins}}
  {{name}}
{{/plugins}}
)

list(APPEND FLUTTER_FFI_PLUGIN_LIST
{{#ffiPlugins}}
  {{name}}
{{/ffiPlugins}}
)

set(PLUGIN_BUNDLED_LIBRARIES)
add_definitions(-D_FLUTTER_RUN_MODE=\"${FLUTTER_RUN_MODE}\")
add_definitions(-D_FLUTTER_FRAMEWORK_VERSION=\"${FLUTTER_FRAMEWORK_VERSION}\")

foreach(plugin ${FLUTTER_PLUGIN_LIST})
  add_subdirectory({{pluginsDir}}/${plugin}/webos plugins/${plugin})
  target_link_libraries(${WEBOS_PLUGIN_INTERFACE_LIBRARY} PRIVATE ${plugin}_plugin)
  list(APPEND PLUGIN_BUNDLED_LIBRARIES $<TARGET_FILE:${plugin}_plugin>)
  list(APPEND PLUGIN_BUNDLED_LIBRARIES ${${plugin}_bundled_libraries})
endforeach(plugin)

foreach(ffi_plugin ${FLUTTER_FFI_PLUGIN_LIST})
  add_subdirectory({{pluginsDir}}/${ffi_plugin}/webos plugins/${ffi_plugin})
  list(APPEND PLUGIN_BUNDLED_LIBRARIES ${${ffi_plugin}_bundled_libraries})
endforeach(ffi_plugin)
''',
    context,
    registryDirectory.childFile('generated_plugins.cmake').path,
  );
}

/// Source: [_cmakeRelativePluginSymlinkDirectoryPath] in `flutter_plugins.dart`
String _cmakeRelativePluginSymlinkDirectoryPath(CmakeBasedProject project) {
  final FileSystem fileSystem = project.pluginSymlinkDirectory.fileSystem;
  final String makefileDirPath = project.cmakeFile.parent.absolute.path;
  // CMake always uses posix-style path separators, regardless of the platform.
  final cmakePathContext = path.Context(style: path.Style.posix);
  final List<String> relativePathComponents = fileSystem.path.split(fileSystem.path.relative(
    project.pluginSymlinkDirectory.absolute.path,
    from: makefileDirPath,
  ));
  return cmakePathContext.joinAll(relativePathComponents);
}

/// Source: [_renderTemplateToFile] in `plugins.dart` (exact copy)
void _renderTemplateToFile(String template, dynamic context, String filePath) {
  final String renderedTemplate = globals.templateRenderer.renderString(template, context);
  final File file = globals.fs.file(filePath);
  file.createSync(recursive: true);
  file.writeAsStringSync(renderedTemplate);
}

/// Source: [createPluginSymlinks] in `flutter_plugins.dart`
void createPluginSymlinks(FlutterProject project, {bool force = false}) {
  Map<String, Object?>? platformPlugins;
  final String? pluginFileContent = _readFileContent(project.flutterPluginsDependenciesFile);
  if (pluginFileContent != null) {
    final pluginInfo = json.decode(pluginFileContent) as Map<String, Object?>?;
    platformPlugins = pluginInfo?[_kFlutterPluginsPluginListKey] as Map<String, Object?>?;
  }
  platformPlugins ??= <String, Object?>{};

  final webosProject = WebosProject.fromFlutter(project);
  if (webosProject.existsSync()) {
    _createPlatformPluginSymlinks(
      webosProject.pluginSymlinkDirectory,
      platformPlugins[webosProject.pluginConfigKey] as List<Object?>?,
      force: force,
    );
  }
}

/// Returns the contents of [file] or `null` if that file does not exist.
String? _readFileContent(File file) {
  return file.existsSync() ? file.readAsStringSync() : null;
}

/// Creates [symlinkDirectory] containing symlinks to each plugin listed in [platformPlugins].
///
/// If [force] is true, the directory will be created only if missing.
void _createPlatformPluginSymlinks(Directory symlinkDirectory, List<Object?>? platformPlugins,
    {bool force = false}) {
  if (force && symlinkDirectory.existsSync()) {
    // Start fresh to avoid stale links.
    symlinkDirectory.deleteSync(recursive: true);
  }
  symlinkDirectory.createSync(recursive: true);
  if (platformPlugins == null) {
    return;
  }
  for (final Map<String, Object?> pluginInfo in platformPlugins.cast<Map<String, Object?>>()) {
    final name = pluginInfo[_kFlutterPluginsNameKey]! as String;
    final path = pluginInfo[_kFlutterPluginsPathKey]! as String;
    final Link link = symlinkDirectory.childLink(name);
    if (link.existsSync()) {
      continue;
    }
    try {
      link.createSync(path);
    } on FileSystemException catch (e) {
      // ignore: invalid_use_of_visible_for_testing_member
      handleSymlinkException(e,
          platform: globals.platform, os: globals.os, destination: 'dest', source: 'source');
      rethrow;
    }
  }
}
