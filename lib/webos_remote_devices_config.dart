// Copyright (c) 2023 LG Electronics, Inc. All rights reserved.
// Copyright 2021 Sony Group Corporation. All rights reserved.
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// ignore_for_file: unused_element, unused_field
// fork residue from upstream flutter_tools/lib/src/custom_devices/custom_devices_config.dart; see 28 / 34.2 (decision pending)

import 'package:flutter_tools/src/base/config.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/cache.dart';

import 'webos_remote_device_config.dart';

/// See: `CustomDevicesConfig` in `custom_devices_config.dart`
class WebosRemoteDevicesConfig {
  WebosRemoteDevicesConfig({
    required Platform platform,
    required FileSystem fileSystem,
    required Logger logger,
  })  : _fileSystem = fileSystem,
        _logger = logger,
        _config = Config(_kCustomDevicesConfigName,
            fileSystem: fileSystem, logger: logger, platform: platform) {
    ensureFileExists();
  }

  static const _kCustomDevicesConfigName = 'custom_devices.json';
  static const _kCustomDevicesConfigKey = 'custom-devices';
  static const _kSchema = r'$schema';
  static const _kCustomDevices = 'custom-devices';

  final FileSystem _fileSystem;
  final Logger _logger;
  final Config _config;

  String get _defaultSchema {
    final Uri uri = _fileSystem
        .directory(Cache.flutterRoot)
        .childDirectory('packages')
        .childDirectory('flutter_tools')
        .childDirectory('static')
        .childFile('custom-devices.schema.json')
        .uri;
    assert(uri.isAbsolute);
    return uri.toString();
  }

  void ensureFileExists() {
    if (!_fileSystem.file(_config.configPath).existsSync()) {
      _config.setValue(_kCustomDevices, <dynamic>[]);
    }
  }

  List<dynamic>? _getDevicesJsonValue() {
    final dynamic json = _config.getValue(_kCustomDevicesConfigKey);
    if (json == null) {
      return null;
    } else if (json is! List) {
      const msg =
          "Could not load custom devices config. config['$_kCustomDevicesConfigKey'] is not a JSON array.";
      _logger.printError(msg);
      throw const WebosRemoteDeviceRevivalException(msg);
    }

    return json;
  }

  bool hasDeviceById(String id) {
    final List<dynamic>? typedListNullable = _getDevicesJsonValue();
    if (typedListNullable == null) {
      return false;
    }

    final List<dynamic> typedList = typedListNullable;
    for (final MapEntry<int, dynamic> entry in typedList.asMap().entries) {
      try {
        final device = WebosRemoteDeviceConfig.fromJson(entry.value);

        if (device.id == id.trim()) {
          _logger.printTrace('Found Same ID device : $id');
          return true;
        }
      } on WebosRemoteDeviceRevivalException catch (e) {
        final msg = 'Could not load custom device from config index ${entry.key}: $e';
        _logger.printError(msg);
      }
    }

    return false;
  }

  List<WebosRemoteDeviceConfig> get devices {
    final List<dynamic>? typedListNullable = _getDevicesJsonValue();
    if (typedListNullable == null) {
      return <WebosRemoteDeviceConfig>[];
    }

    final List<dynamic> typedList = typedListNullable;
    final revived = <WebosRemoteDeviceConfig>[];
    for (final MapEntry<int, dynamic> entry in typedList.asMap().entries) {
      try {
        revived.add(WebosRemoteDeviceConfig.fromJson(entry.value));
      } on WebosRemoteDeviceRevivalException catch (e) {
        // TODO(hidenori): Corresponds to the format difference
        // from the default schema and uncomment here.
        //
        final msg = 'Could not load custom device from config index ${entry.key}: $e';
        _logger.printError(msg);
        //throw WebosRemoteDeviceRevivalException(msg);
      }
    }

    return revived;
  }

  List<WebosRemoteDeviceConfig> tryGetDevices() {
    try {
      return devices;
    } on Exception {
      return <WebosRemoteDeviceConfig>[];
    }
  }

  // ignore: avoid_setters_without_getters  // write-through to Config; read via `devices` getter above
  set devices(List<WebosRemoteDeviceConfig> configs) {
    _config.setValue(_kCustomDevicesConfigKey,
        configs.map<dynamic>((WebosRemoteDeviceConfig c) => c.toJson()).toList());
  }

  // ignore: avoid_setters_without_getters  // write-through to Config; abbreviated form for export
  set abbrDevices(List<WebosRemoteDeviceConfig> configs) {
    _config.setValue(_kCustomDevicesConfigKey,
        configs.map<dynamic>((WebosRemoteDeviceConfig c) => c.toSimpleJson()).toList());
  }

  void add(WebosRemoteDeviceConfig config) {
    _config
        .setValue(_kCustomDevicesConfigKey, <dynamic>[...?_getDevicesJsonValue(), config.toJson()]);
  }

  bool contains(String deviceId) {
    return devices.any((WebosRemoteDeviceConfig device) => device.id == deviceId);
  }

  bool remove(String deviceId) {
    final List<WebosRemoteDeviceConfig> modifiedDevices = devices;
    final WebosRemoteDeviceConfig? device = modifiedDevices
        .cast<WebosRemoteDeviceConfig?>()
        .firstWhere((WebosRemoteDeviceConfig? d) => d!.id == deviceId, orElse: () => null);

    if (device == null) {
      return false;
    }

    modifiedDevices.remove(device);
    abbrDevices = modifiedDevices;
    return true;
  }

  bool updateDeviceConfig(String deviceId, String sshIdentityFile, String passPhrase) {
    var isUpdated = false;
    if (deviceId.isEmpty || sshIdentityFile.isEmpty || passPhrase.isEmpty) {
      _logger.printError('Invalid deviceId, sshIdentityFile or passPhrase');
      return isUpdated;
    }

    final List<dynamic>? typedListNullable = _getDevicesJsonValue();
    if (typedListNullable == null) {
      return isUpdated;
    }

    final List<dynamic> typedList = typedListNullable;
    final revived = <WebosRemoteDeviceConfig>[];
    for (final MapEntry<int, dynamic> entry in typedList.asMap().entries) {
      try {
        if (entry.value is Map<String, dynamic>) {
          final updatedEntry = Map<String, dynamic>.from(entry.value as Map<String, dynamic>);
          if (updatedEntry['id'] != null && updatedEntry['id'] == deviceId) {
            updatedEntry['sshIdentityFile'] = sshIdentityFile;
            updatedEntry['sshPassPhrase'] = passPhrase;
            isUpdated = true;
          }
          revived.add(WebosRemoteDeviceConfig.fromJson(updatedEntry));
        }
      } on WebosRemoteDeviceRevivalException catch (e) {
        _logger.printError('Error updating device at index ${entry.key} with ID $deviceId: $e');
      }
    }

    if (isUpdated) {
      abbrDevices = revived;
    }
    return isUpdated;
  }

  String get configPath => _config.configPath;

  void forEach(Null Function(int value) param0, void add) {}
}
