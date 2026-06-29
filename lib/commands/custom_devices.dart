// Copyright (c) 2023 LG Electronics, Inc. All rights reserved.
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:io' as io;

import 'package:async/async.dart';
import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/context.dart';
import 'package:flutter_tools/src/base/error_handling_io.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/io.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/terminal.dart';
import 'package:flutter_tools/src/commands/custom_devices.dart';
import 'package:flutter_tools/src/features.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/runner/flutter_command.dart';
import 'package:meta/meta.dart';

import '../webos_ares.dart';
import '../webos_plugins.dart';
import '../webos_remote_device_config.dart';
import '../webos_remote_devices_config.dart';
import '../webos_sdk.dart';

/// See: [CustomDevicesCommand] in custom_devices.dart
class WebosDevicesCommand extends FlutterCommand with WebosExtension {
  factory WebosDevicesCommand({
    required FeatureFlags featureFlags,
  }) {
    final WebosRemoteDevicesConfig? customDevicesConfig = context.get<WebosRemoteDevicesConfig>();

    return WebosDevicesCommand._common(
      customDevicesConfig: customDevicesConfig!,
      terminal: globals.terminal,
      fileSystem: globals.fs,
      logger: globals.logger,
      featureFlags: featureFlags,
    );
  }

  WebosDevicesCommand._common({
    required WebosRemoteDevicesConfig customDevicesConfig,
    required Terminal terminal,
    required FileSystem fileSystem,
    required Logger logger,
    required FeatureFlags featureFlags,
  })  : _customDevicesConfig = customDevicesConfig,
        _featureFlags = featureFlags {
    addSubcommand(WebosDevicesListCommand(
      customDevicesConfig: customDevicesConfig,
      featureFlags: featureFlags,
      logger: logger,
    ));
    addSubcommand(WebosDevicesResetCommand(
      customDevicesConfig: customDevicesConfig,
      featureFlags: featureFlags,
      fileSystem: fileSystem,
      logger: logger,
    ));
    addSubcommand(WebosDevicesAddCommand(
      customDevicesConfig: customDevicesConfig,
      terminal: terminal,
      featureFlags: featureFlags,
      fileSystem: fileSystem,
      logger: logger,
    ));
    addSubcommand(WebosDevicesDeleteCommand(
      customDevicesConfig: customDevicesConfig,
      featureFlags: featureFlags,
      fileSystem: fileSystem,
      logger: logger,
    ));
    addSubcommand(WebosDevicesGetKeyCommand(
      customDevicesConfig: customDevicesConfig,
      featureFlags: featureFlags,
      fileSystem: fileSystem,
      logger: logger,
    ));
  }

  final WebosRemoteDevicesConfig _customDevicesConfig;
  final FeatureFlags _featureFlags;

  @override
  String get description {
    String configFileLine;
    if (_featureFlags.areCustomDevicesEnabled) {
      configFileLine =
          '\nMakes changes to the config file at "${_customDevicesConfig.configPath}".\n';
    } else {
      configFileLine = '';
    }

    return '''
List, reset, add, delete and get-key custom devices.
$configFileLine
This is just a collection of commonly used shorthands for things like adding
ssh devices, resetting (with backup) and checking the config file. For advanced
configuration or more complete documentation, edit the config file with an
editor that supports JSON schemas like VS Code.

Requires the custom devices feature to be enabled. You can enable it using "flutter config --enable-custom-devices".
''';
  }

  @override
  String get name => 'custom-devices';

  @override
  String get category => FlutterCommandCategory.tools;

  @override
  Future<FlutterCommandResult> runCommand() async {
    return FlutterCommandResult.success();
  }
}

/// This class is meant to provide some commonly used utility functions
/// to the subcommands, like backing up the config file & checking if the
/// feature is enabled.
abstract class WebosDevicesCommandBase extends FlutterCommand {
  WebosDevicesCommandBase({
    required this.customDevicesConfig,
    required this.featureFlags,
    required this.fileSystem,
    required this.logger,
  });

  @protected
  final WebosRemoteDevicesConfig customDevicesConfig;
  @protected
  final FeatureFlags featureFlags;
  @protected
  final FileSystem? fileSystem;
  @protected
  final Logger logger;

  /// The path to the (potentially non-existing) backup of the config file.
  @protected
  String get configBackupPath => '${customDevicesConfig.configPath}.bak';

  /// Copies the current config file to [configBackupPath], overwriting it
  /// if necessary. Returns false and does nothing if the current config file
  /// doesn't exist. (True otherwise)
  @protected
  bool backup() {
    final File configFile = fileSystem!.file(customDevicesConfig.configPath);
    if (configFile.existsSync()) {
      configFile.copySync(configBackupPath);
      return true;
    }
    return false;
  }

  /// Gateway for the ares CLI calls made by the custom-devices subcommands.
  @protected
  late final ares = AresCli(processManager: globals.processManager, logger: logger);

  /// Runs ares-setup-device with [args], best-effort. Returns false when the
  /// invocation fails or ares-cli is not available in PATH.
  @protected
  Future<bool> runAresSetupDevice(List<String> args) =>
      ares.tryRun('ares-setup-device', args);

  /// Checks if the custom devices feature is enabled and returns true/false
  /// accordingly. Additionally, logs an error if it's not enabled with a hint
  /// on how to enable it.
  @protected
  void checkFeatureEnabled() {
    if (!featureFlags.areCustomDevicesEnabled) {
      throwToolExit('Custom devices feature must be enabled. '
          'Enable using `flutter config --enable-custom-devices`.');
    }
  }
}

class WebosDevicesListCommand extends WebosDevicesCommandBase {
  WebosDevicesListCommand({
    required super.customDevicesConfig,
    required super.featureFlags,
    required super.logger,
  }) : super(fileSystem: null);

  @override
  String get description => '''
List the currently configured custom devices, both enabled and disabled, reachable or not.
''';

  @override
  String get name => 'list';

  @override
  Future<FlutterCommandResult> runCommand() async {
    checkFeatureEnabled();

    late List<WebosRemoteDeviceConfig> devices;
    try {
      devices = customDevicesConfig.devices;
    } on Exception {
      throwToolExit('Could not list custom devices.');
    }

    if (devices.isEmpty) {
      logger.printStatus('No custom devices found in "${customDevicesConfig.configPath}"');
    } else {
      logger.printStatus('List of custom devices in "${customDevicesConfig.configPath}":');
      for (final device in devices) {
        logger.printStatus('id: ${device.id}, label: ${device.label}, enabled: ${device.enabled}',
            indent: 2, hangingIndent: 2);
      }
    }

    return FlutterCommandResult.success();
  }
}

class WebosDevicesResetCommand extends WebosDevicesCommandBase {
  WebosDevicesResetCommand({
    required super.customDevicesConfig,
    required super.featureFlags,
    required FileSystem super.fileSystem,
    required super.logger,
  });

  @override
  String get description => '''
Reset the config file to the default.

The current config file will be backed up to the same path, but with a `.bak` appended.
If a file already exists at the backup location, it will be overwritten.
''';

  @override
  String get name => 'reset';

  @override
  Future<FlutterCommandResult> runCommand() async {
    checkFeatureEnabled();

    // Keep the ares device DB in sync with the devices being cleared. A
    // malformed config is a valid reason to reset, so skip the sync then.
    var devices = <WebosRemoteDeviceConfig>[];
    try {
      devices = customDevicesConfig.devices;
    } on Exception {
      // Unreadable config — nothing to sync.
    }
    for (final device in devices) {
      if (!await runAresSetupDevice(<String>['--remove', device.id])) {
        logger.printStatus('Note: could not remove "${device.id}" from the '
            'ares-cli device DB (it may not be registered there).');
      }
    }

    final bool wasBackedUp = backup();

    ErrorHandlingFileSystem.deleteIfExists(fileSystem!.file(customDevicesConfig.configPath));
    customDevicesConfig.ensureFileExists();

    logger.printStatus(wasBackedUp
        ? 'Successfully reset the custom devices config file and created a '
            'backup at "$configBackupPath".'
        : 'Successfully reset the custom devices config file.');
    return FlutterCommandResult.success();
  }
}

class WebosDevicesAddCommand extends WebosDevicesCommandBase {
  WebosDevicesAddCommand({
    required super.customDevicesConfig,
    required Terminal terminal,
    required super.featureFlags,
    required FileSystem super.fileSystem,
    required super.logger,
  }) : _terminal = terminal;

  // A hostname consists of one or more "names", separated by a dot.
  // A name may consist of alpha-numeric characters. Hyphens are also allowed,
  // but not as the first or last character of the name.
  static final _hostnameRegex = RegExp(
      r'^(([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\-]*[a-zA-Z0-9])\.)*([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9\-]*[A-Za-z0-9])$');

  final Terminal _terminal;
  late StreamQueue<String> inputs;

  @override
  String get description => 'Add a new device the custom devices config file.';

  @override
  String get name => 'add';

  void printSuccessfullyAdded(WebosRemoteDeviceConfig config) {
    logger.printStatus(
        'Successfully added custom device to config file at "${customDevicesConfig.configPath}".');
    logger.printStatus('''
After adding your device, you'll need to get the key file from your webOS TV.
Follow these steps:
  1. Ensure that the key server button in the Developer Mode app on your TV is enabled.
  2. Run the command "flutter-webos custom-devices get-key -d ${config.id}" to retrieve the key file from your webOS TV.
  3. Enter the passphrase displayed in the Developer Mode app into the prompt.
For more details, refer to the https://webostv.developer.lge.com/develop/getting-started/developer-mode-app''');
  }

  /// Returns null if [s] is a valid, unused device id; otherwise the error
  /// message to show the user.
  String? _validateId(String s) {
    if (!RegExp(r'^\w+$').hasMatch(s)) {
      return 'Invalid id. Use only alphanumeric or underscore characters:';
    }
    if (customDevicesConfig.hasDeviceById(s)) {
      return 'Device id "$s" already exists. Please enter a different id:';
    }
    return null;
  }

  // ignore: unused_element  // fork residue; see 28 / 34.2 (decision pending)
  bool _isValidHostname(String s) => _hostnameRegex.hasMatch(s);

  bool _isValidIpAddr(String s) => InternetAddress.tryParse(s) != null;

  /// Ask the user to input a string.
  Future<String?> askForString(
    String name, {
    String? description,
    String? example,
    String? defaultsTo,
    Future<String?> Function(String)? validator,
  }) async {
    String msg = description ?? name;

    final String exampleOrDefault = <String>[
      if (example != null) 'example: $example',
      if (defaultsTo != null) 'empty for $defaultsTo',
    ].join(', ');

    if (exampleOrDefault.isNotEmpty) {
      msg += '\n($exampleOrDefault)';
    }

    logger.printStatus(msg);
    while (true) {
      if (!await inputs.hasNext) {
        return null;
      }

      final String input = await inputs.next;

      final String? error = validator == null ? null : await validator(input);
      if (error != null) {
        logger.printStatus(error);
      } else {
        if (input.isEmpty && defaultsTo != null) {
          return defaultsTo;
        }

        return input;
      }
    }
  }

  /// Ask the user for a y(es) / n(o) or empty input.
  Future<bool> askForBool(
    String name, {
    String? description,
    bool defaultsTo = true,
  }) async {
    final defaultsToStr = defaultsTo ? '[Y/n]' : '[y/N]';
    logger.printStatus('$description $defaultsToStr (empty for default)');
    while (true) {
      final String input = await inputs.next;

      if (input.isEmpty) {
        return defaultsTo;
      } else if (input.toLowerCase() == 'y') {
        return true;
      } else if (input.toLowerCase() == 'n') {
        return false;
      } else {
        logger.printStatus(
            'Invalid input. Expected is either y, n or empty for default. $name? $defaultsToStr');
      }
    }
  }

  /// Ask the user if he wants to apply the config.
  /// Shows a different prompt if errors or warnings exist in the config.
  Future<bool> askApplyConfig({bool hasErrorsOrWarnings = false}) {
    return askForBool('apply',
        description: hasErrorsOrWarnings
            ? 'Warnings or errors exist in custom device. '
                'Would you like to add the custom device to the config anyway?'
            : 'Would you like to add the custom device to the config now?',
        defaultsTo: !hasErrorsOrWarnings);
  }

  /// Run interactively (with user prompts), the target device should be
  /// connected to via ssh.
  Future<FlutterCommandResult> runInteractivelySsh() async {
    // Listen to the keystrokes stream as late as possible, since it's a
    // single-subscription stream apparently.
    // Also, _terminal.keystrokes can be closed unexpectedly, which will result
    // in StreamQueue.next throwing a StateError when make the StreamQueue listen
    // to that directly.
    // This caused errors when using Ctrl+C to terminate while the
    // custom-devices add command is waiting for user input.
    // So instead, we add the keystrokes stream events to a new single-subscription
    // stream and listen to that instead.
    final nonClosingKeystrokes = StreamController<String>();
    final StreamSubscription<String> keystrokesSubscription = _terminal.keystrokes
        .listen((String s) => nonClosingKeystrokes.add(s.trim()), cancelOnError: true);

    inputs = StreamQueue<String>(nonClosingKeystrokes.stream);

    // Using predefined strings for easy setup.
    const label = 'webOS remote device';
    final String? sdkNameAndVersion = webosSdk?.sdkVersion;
    final String? platform = webosSdk?.targetArch;

    const enabled = true;

    final String id = (await askForString('id',
        description: 'Please enter the unique id you want to device to have. Must contain only '
            'alphanumeric or underscore characters.',
        example: 'webos',
        validator: (String s) async => _validateId(s)))!;

    final String targetStr = (await askForString('target',
        description: 'Please enter the hostname or IPv4 address of the device.',
        example: '192.168.0.100',
        validator: (String s) async =>
            _isValidIpAddr(s) ? null : 'Invalid input. Please enter target:'))!;

    final InternetAddress? targetIp = InternetAddress.tryParse(targetStr);

    final String port = (await askForString(
      'port',
      description: 'Please enter the port number for ssh connection.',
      example: '9922',
      defaultsTo: '9922',
    ))!;

    final config = WebosRemoteDeviceConfig(
      id: id,
      label: label,
      sdkNameAndVersion: sdkNameAndVersion ?? "N/A",
      enabled: enabled,
      ipAddress: (targetIp != null) ? targetIp.address : "localhost",
      platform: platform ?? 'arm',
      sshPort: port,
    );

    final bool apply = await askApplyConfig();

    unawaited(keystrokesSubscription.cancel());
    unawaited(nonClosingKeystrokes.close());

    if (apply) {
      customDevicesConfig.add(config);
      printSuccessfullyAdded(config);

      // Register device in ares-cli for ares-install/ares-launch support.
      // A device with the same name may already exist in the ares DB, in
      // which case --add fails; update it with --modify instead.
      final String aresInfo = AresCli.formatDeviceInfo(
          host: config.ipAddress!, port: config.sshPort, username: config.sshUser);
      if (!await runAresSetupDevice(<String>['--add', config.id, '--info', aresInfo]) &&
          !await runAresSetupDevice(<String>['--modify', config.id, '--info', aresInfo])) {
        logger.printError('Failed to register device in ares-cli. Please run manually:\n'
            '  ares-setup-device --add ${config.id} --info "$aresInfo"');
      }
    }

    return FlutterCommandResult.success();
  }

  @override
  Future<FlutterCommandResult> runCommand() async {
    checkFeatureEnabled();

    return runInteractivelySsh();
  }
}

class WebosDevicesDeleteCommand extends WebosDevicesCommandBase {
  WebosDevicesDeleteCommand({
    required super.customDevicesConfig,
    required super.featureFlags,
    required FileSystem super.fileSystem,
    required super.logger,
  });

  @override
  String get description => '''
Delete a device from the config file.
''';

  @override
  String get name => 'delete';

  @override
  Future<FlutterCommandResult> runCommand() async {
    checkFeatureEnabled();

    final id = globalResults!['device-id'] as String;
    if (!customDevicesConfig.contains(id)) {
      throwToolExit(
          'Couldn\'t find device with id "$id" in config at "${customDevicesConfig.configPath}"');
    }

    backup();
    customDevicesConfig.remove(id);
    logger.printStatus(
        'Successfully removed device with id "$id" from config at "${customDevicesConfig.configPath}"');

    // Keep the ares device DB in sync. Devices registered before the
    // ares-cli transition may not exist there, so stay quiet about it.
    if (!await runAresSetupDevice(<String>['--remove', id])) {
      logger.printStatus('Note: could not remove "$id" from the ares-cli device DB '
          '(it may not be registered there).');
    }
    return FlutterCommandResult.success();
  }
}

class WebosDevicesGetKeyCommand extends WebosDevicesCommandBase {
  WebosDevicesGetKeyCommand({
    required super.customDevicesConfig,
    required super.featureFlags,
    required FileSystem super.fileSystem,
    required super.logger,
  });

  late StreamQueue<String> inputs;

  @override
  String get description => '''
Get rsa key from the device, download and set path to the config file.
''';

  @override
  String get name => 'get-key';

  @override
  Future<FlutterCommandResult> runCommand() async {
    final String passPhrase = (await askForString('passPhrase',
        description: 'Please enter the passphrase', example: 'ABC123', isPassPhrase: true))!;

    final id = globalResults!['device-id'] as String?;
    if (id == null || id.isEmpty) {
      logger.printError('Device ID is missing or empty.');
      return FlutterCommandResult.fail();
    }

    late List<WebosRemoteDeviceConfig> devices;
    late WebosRemoteDeviceConfig device;
    try {
      devices = customDevicesConfig.devices;
      device = devices.firstWhere((WebosRemoteDeviceConfig data) => data.id == id);
    } on StateError {
      logger.printError('Device with ID "$id" not found in the configuration.');
      return FlutterCommandResult.fail();
    } on Exception catch (e) {
      logger.printError('An unexpected error occurred: $e');
      return FlutterCommandResult.fail();
    }

    // ares-novacom --getkey resolves the device from the ares DB, so carry
    // over devices registered before the ares transition first.
    await ares.ensureDeviceRegistered(
      id,
      info: AresCli.formatDeviceInfo(
        host: device.ipAddress ?? 'localhost',
        port: device.sshPort,
        username: device.sshUser,
      ),
    );

    final String? sshDirectory = getSshDirectory();
    if (sshDirectory == null) {
      logger.printError('Could not resolve the ~/.ssh directory.');
      return FlutterCommandResult.fail();
    }

    // ares downloads the key from the device's key server and registers
    // privatekey/passphrase in the ares device DB in one step.
    if (!await ares.getKey(id, passPhrase)) {
      logger.printError('Could not fetch the SSH key from device "$id". Ensure the '
          'Developer Mode app is running on the TV and its key server is enabled.');
      return FlutterCommandResult.fail();
    }

    final sshFilePath = '$sshDirectory/${id}_webos';
    if (!io.File(sshFilePath).existsSync()) {
      logger.printError('get-key succeeded but no key file was found at "$sshFilePath".');
      return FlutterCommandResult.fail();
    }

    final bool isUpdated = customDevicesConfig.updateDeviceConfig(id, sshFilePath, passPhrase);
    if (isUpdated) {
      logger.printStatus(
          'Successfully get-key for device $id and updated the config file at "${customDevicesConfig.configPath}".');
    } else {
      return FlutterCommandResult.fail();
    }

    return FlutterCommandResult.success();
  }

  String? getSshDirectory() {
    try {
      final String? homeDirectory = io.Platform.environment['HOME'];
      if (homeDirectory == null) {
        return null;
      }
      final sshDirectory = '$homeDirectory/.ssh';
      final sshDir = io.Directory(sshDirectory);
      if (!sshDir.existsSync()) {
        sshDir.createSync(recursive: true);
      }
      return sshDirectory;
    } on Exception catch (e) {
      logger.printError('getSshDirectory error : $e');
      return null;
    }
  }

  Future<String?> askForString(
    String name, {
    String? description,
    String? example,
    String? defaultsTo,
    Future<bool> Function(String)? validator,
    bool isPassPhrase = false,
  }) async {
    String msg = description ?? name;

    final String exampleOrDefault = <String>[
      if (example != null) 'example: $example',
      if (defaultsTo != null) 'empty for $defaultsTo',
    ].join(', ');

    if (exampleOrDefault.isNotEmpty) {
      msg += '\n($exampleOrDefault)';
    }

    logger.printStatus(msg);
    while (true) {
      final String? input =
          isPassPhrase ? await getPassPhrase() : (await inputs.hasNext ? await inputs.next : null);

      if (input == null || input.isEmpty) {
        if (defaultsTo != null) {
          return defaultsTo;
        }
      } else if (validator != null && !await validator(input)) {
        logger.printStatus('Invalid input. Please enter $name:');
        continue;
      }

      return input;
    }
  }

  Future<String?> getPassPhrase() async {
    io.stdin.echoMode = true;
    final String? input = io.stdin.readLineSync();
    io.stdout.write('\n');
    return input;
  }
}
