// Copyright (c) 2023 LG Electronics, Inc. All rights reserved.
// Copyright 2021 Sony Group Corporation. All rights reserved.
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:meta/meta.dart';

/// See: [_listsEqual] in `custom_device_config.dart` (exact copy)
bool _listsEqual(List<dynamic>? a, List<dynamic>? b) {
  if (a == b) {
    return true;
  }
  if (a == null || b == null) {
    return false;
  }
  if (a.length != b.length) {
    return false;
  }

  return a.asMap().entries.every((MapEntry<int, dynamic> e) => e.value == b[e.key]);
}

/// See: [_regexesEqual] in `custom_device_config.dart` (exact copy)
bool _regexesEqual(RegExp? a, RegExp? b) {
  if (a == b) {
    return true;
  }
  if (a == null || b == null) {
    return false;
  }

  return a.pattern == b.pattern &&
      a.isMultiLine == b.isMultiLine &&
      a.isCaseSensitive == b.isCaseSensitive &&
      a.isUnicode == b.isUnicode &&
      a.isDotAll == b.isDotAll;
}

/// See: `CustomDeviceRevivalException` in `custom_device_config.dart`
@immutable
class WebosRemoteDeviceRevivalException implements Exception {
  const WebosRemoteDeviceRevivalException(this.message);

  const WebosRemoteDeviceRevivalException.fromDescriptions(
      String fieldDescription, String expectedValueDescription)
      : message = 'Expected $fieldDescription to be $expectedValueDescription.';

  final String message;

  @override
  String toString() {
    return message;
  }

  @override
  bool operator ==(Object other) {
    return (other is WebosRemoteDeviceRevivalException) && (other.message == message);
  }

  @override
  int get hashCode => message.hashCode;
}

/// See: `CustomDeviceConfig` in `custom_device_config.dart`
@immutable
class WebosRemoteDeviceConfig {
  const WebosRemoteDeviceConfig(
      {required this.id,
      required this.label,
      required this.sdkNameAndVersion,
      this.platform = 'arm64',
      this.backend = 'wayland',
      this.sshUser = 'prisoner',
      this.sshPort = '9922',
      this.sshIdentityFile,
      this.sshPassPhrase,
      required this.enabled,
      required this.ipAddress,
      this.pingCommand = const <String>[],
      this.pingSuccessRegex,
      this.postBuildCommand,
      this.postRunDebugCommand = const <String>[],
      this.forwardPortCommand,
      this.forwardPortSuccessRegex,
      this.screenshotCommand})
      : assert(forwardPortCommand == null || forwardPortSuccessRegex != null);

  factory WebosRemoteDeviceConfig.fromJson(dynamic json) {
    final Map<String, dynamic> typedMap =
        _castJsonObject(json, 'device configuration', 'a JSON object');

    //-p 18014 -i dede.pem -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no"
    final sshOptions = <String>[
      '-o',
      'UserKnownHostsFile=/dev/null',
      '-o',
      'StrictHostKeyChecking=no',
      '-o',
      'HostkeyAlgorithms=+ssh-rsa',
      '-o',
      'PubkeyAcceptedAlgorithms=+ssh-rsa',
      if (typedMap[_kSshIdentityFile] != null) ...<String>[
        '-i',
        _castString(typedMap[_kSshIdentityFile], _kSshIdentityFile, 'SSH identity file')
      ],
    ];

    final String sshPort = (typedMap[_kSshPort] != null)
        ? _castString(typedMap[_kSshPort], _kSshPort, 'SSH Port')
        : '9922';

    final String sshUser = (typedMap[_kSshUser] != null)
        ? _castString(typedMap[_kSshUser], _kSshUser, 'SSH User Name')
        : 'prisoner';

    final String ipAddress = _castString(typedMap[_kIpAddress], _kIpAddress, 'IPv4');

    final forwardPortCommand = <String>[
      'ssh',
      '-p',
      sshPort,
      '-o',
      'ExitOnForwardFailure=yes',
      ...sshOptions,
      '-L',
      r'127.0.0.1:${hostPort}:127.0.0.1:${devicePort}',
      '$sshUser@$ipAddress',
      'uname -a;/bin/sh'
    ];

    final forwardPortSuccessRegex = RegExp('LGwebOS');

    final pingCommand = <String>['ping', '-w', '3', '-c', '1', ipAddress];
    final pingSuccessRegex = RegExp('ttl=');

    //r"touch /var/log/${appId}; tail -f /var/log/${appId}"
    final postRunDebugCommand = <String>[
      // 'ssh', '-p', sshPort, ...sshOptions, '$sshUser@$ipAddress',
      r'tail -F ${logPath}/${appId}'
    ];

    return WebosRemoteDeviceConfig(
        id: _castString(typedMap[_kId], _kId, 'a string'),
        label: _castString(typedMap[_kLabel], _kLabel, 'a string'),
        sdkNameAndVersion:
            _castString(typedMap[_kSdkNameAndVersion], _kSdkNameAndVersion, 'a string'),
        platform: _castString(typedMap[_kPlatform], _kPlatform, 'arm64'),
        backend: _castString(typedMap[_kBackend], _kBackend, 'wayland'),
        sshUser: sshUser,
        sshPort: sshPort,
        sshIdentityFile: (typedMap[_kSshIdentityFile] == null)
            ? null
            : _castString(typedMap[_kSshIdentityFile], _kSshIdentityFile, "SSH identity file"),
        sshPassPhrase: (typedMap[_kSshPassPhrase] == null)
            ? null
            : _castString(typedMap[_kSshPassPhrase], _kSshPassPhrase, "Pass Phrase"),
        enabled: _castBool(typedMap[_kEnabled], _kEnabled, 'a boolean'),
        ipAddress: ipAddress,
        pingCommand: pingCommand,
        pingSuccessRegex: pingSuccessRegex,
        postBuildCommand: _castStringListOrNull(
          typedMap[_kPostBuildCommand],
          _kPostBuildCommand,
          'null or array of strings with at least one element',
          minLength: 1,
        ),
        postRunDebugCommand: postRunDebugCommand,
        forwardPortCommand: forwardPortCommand,
        forwardPortSuccessRegex: forwardPortSuccessRegex,
        screenshotCommand: _castStringListOrNull(typedMap[_kScreenshotCommand], _kScreenshotCommand,
            'array of strings with at least one element',
            minLength: 1));
  }

  static const _kId = 'id';
  static const _kLabel = 'label';
  static const _kSdkNameAndVersion = 'sdkNameAndVersion';
  static const _kPlatform = 'platform';
  static const _kEnabled = 'enabled';
  static const _kBackend = 'backend';
  static const _kIpAddress = 'ipAddress';
  static const _kPingCommand = 'ping';
  static const _kPingSuccessRegex = 'pingSuccessRegex';
  static const _kPostBuildCommand = 'postBuild';
  static const _kPostRunDebugCommand = 'postRunDebug';
  static const _kForwardPortCommand = 'forwardPort';
  static const _kForwardPortSuccessRegex = 'forwardPortSuccessRegex';
  static const _kScreenshotCommand = 'screenshot';

  static const _kSshUser = 'sshUser';
  static const _kSshPassPhrase = 'sshPassPhrase';
  static const _kSshPort = 'sshPort';
  static const _kSshIdentityFile = 'sshIdentityFile';

  final String id;
  final String label;
  final String sdkNameAndVersion;
  final String sshUser;
  final String? sshPassPhrase;
  final String sshPort;
  final String? sshIdentityFile;
  final String? platform;
  final String? backend;
  final bool enabled;
  final String? ipAddress;
  final List<String> pingCommand;
  final RegExp? pingSuccessRegex;
  final List<String>? postBuildCommand;
  final List<String> postRunDebugCommand;
  final List<String>? forwardPortCommand;
  final RegExp? forwardPortSuccessRegex;
  final List<String>? screenshotCommand;

  bool get usesPortForwarding => forwardPortCommand != null;

  bool get supportsScreenshotting => screenshotCommand != null;

  static T _maybeRethrowAsRevivalException<T>(
      T Function() closure, String fieldDescription, String expectedValueDescription) {
    try {
      return closure();
    } on Object {
      throw WebosRemoteDeviceRevivalException.fromDescriptions(
          fieldDescription, expectedValueDescription);
    }
  }

  static Map<String, dynamic> _castJsonObject(
      dynamic value, String fieldDescription, String expectedValueDescription) {
    if (value == null) {
      throw WebosRemoteDeviceRevivalException.fromDescriptions(
          fieldDescription, expectedValueDescription);
    }

    return _maybeRethrowAsRevivalException(
      () => Map<String, dynamic>.from(value as Map<dynamic, dynamic>),
      fieldDescription,
      expectedValueDescription,
    );
  }

  static bool _castBool(dynamic value, String fieldDescription, String expectedValueDescription) {
    if (value == null) {
      throw WebosRemoteDeviceRevivalException.fromDescriptions(
          fieldDescription, expectedValueDescription);
    }

    return _maybeRethrowAsRevivalException(
      () => value as bool,
      fieldDescription,
      expectedValueDescription,
    );
  }

  static String _castString(
      dynamic value, String fieldDescription, String expectedValueDescription) {
    if (value == null) {
      throw WebosRemoteDeviceRevivalException.fromDescriptions(
          fieldDescription, expectedValueDescription);
    }

    return _maybeRethrowAsRevivalException(
      () => value as String,
      fieldDescription,
      expectedValueDescription,
    );
  }

  static List<String> _castStringList(
    dynamic value,
    String fieldDescription,
    String expectedValueDescription, {
    int minLength = 0,
  }) {
    if (value == null) {
      throw WebosRemoteDeviceRevivalException.fromDescriptions(
          fieldDescription, expectedValueDescription);
    }

    final List<String> list = _maybeRethrowAsRevivalException(
      () => List<String>.from(value as Iterable<dynamic>),
      fieldDescription,
      expectedValueDescription,
    );

    if (list.length < minLength) {
      throw WebosRemoteDeviceRevivalException.fromDescriptions(
          fieldDescription, expectedValueDescription);
    }

    return list;
  }

  static List<String>? _castStringListOrNull(
    dynamic value,
    String fieldDescription,
    String expectedValueDescription, {
    int minLength = 0,
  }) {
    if (value == null) {
      return null;
    }

    return _castStringList(value, fieldDescription, expectedValueDescription, minLength: minLength);
  }

  Object toJson() {
    return <String, Object?>{
      _kId: id,
      _kLabel: label,
      _kSdkNameAndVersion: sdkNameAndVersion,
      _kPlatform: platform,
      _kEnabled: enabled,
      _kBackend: backend,
      _kIpAddress: ipAddress,
      _kSshUser: sshUser,
      if (sshPassPhrase != null) ...{
        _kSshPassPhrase: sshPassPhrase,
      },
      _kSshPort: sshPort,
      if (sshIdentityFile != null) ...<String, Object?>{
        _kSshIdentityFile: sshIdentityFile,
      },
      if (pingCommand.isNotEmpty) ...<String, Object?>{
        _kPingCommand: pingCommand,
        _kPingSuccessRegex: pingSuccessRegex?.pattern,
      },
      if (postBuildCommand != null) ...<String, Object?>{
        _kPostBuildCommand: postBuildCommand,
      },
      if (postRunDebugCommand.isNotEmpty) ...<String, Object?>{
        _kPostRunDebugCommand: postRunDebugCommand,
      },
      if (forwardPortCommand != null) ...<String, Object?>{
        _kForwardPortCommand: forwardPortCommand,
        _kForwardPortSuccessRegex: forwardPortSuccessRegex?.pattern,
      },
      if (screenshotCommand != null) ...<String, Object?>{
        _kScreenshotCommand: screenshotCommand,
      },
    };
  }

  Object toSimpleJson() {
    return <String, Object?>{
      _kId: id,
      _kLabel: label,
      _kSdkNameAndVersion: sdkNameAndVersion,
      _kPlatform: platform,
      _kEnabled: enabled,
      _kBackend: backend,
      _kIpAddress: ipAddress,
      _kSshUser: sshUser,
      if (sshPassPhrase != null) ...{
        _kSshPassPhrase: sshPassPhrase,
      },
      _kSshPort: sshPort,
      if (sshIdentityFile != null) ...<String, Object?>{
        _kSshIdentityFile: sshIdentityFile,
      },
    };
  }

  @override
  bool operator ==(Object other) {
    return other is WebosRemoteDeviceConfig &&
        other.id == id &&
        other.label == label &&
        other.sdkNameAndVersion == sdkNameAndVersion &&
        other.platform == platform &&
        other.enabled == enabled &&
        other.backend == backend &&
        other.ipAddress == ipAddress &&
        _listsEqual(other.pingCommand, pingCommand) &&
        _regexesEqual(other.pingSuccessRegex, pingSuccessRegex) &&
        _listsEqual(other.postBuildCommand, postBuildCommand) &&
        _listsEqual(other.postRunDebugCommand, postRunDebugCommand) &&
        _listsEqual(other.forwardPortCommand, forwardPortCommand) &&
        _regexesEqual(other.forwardPortSuccessRegex, forwardPortSuccessRegex) &&
        _listsEqual(other.screenshotCommand, screenshotCommand);
  }

  @override
  int get hashCode {
    return id.hashCode ^
        label.hashCode ^
        sdkNameAndVersion.hashCode ^
        platform.hashCode ^
        enabled.hashCode ^
        backend.hashCode ^
        ipAddress.hashCode ^
        pingCommand.hashCode ^
        (pingSuccessRegex?.pattern).hashCode ^
        postBuildCommand.hashCode ^
        postRunDebugCommand.hashCode ^
        forwardPortCommand.hashCode ^
        (forwardPortSuccessRegex?.pattern).hashCode ^
        screenshotCommand.hashCode;
  }

  @override
  String toString() {
    return 'WebosRemoteDeviceConfig('
        'id: $id, '
        'label: $label, '
        'sdkNameAndVersion: $sdkNameAndVersion, '
        'platform: $platform, '
        'enabled: $enabled, '
        'backend: $backend, '
        'ipAddress: $ipAddress, '
        'pingCommand: $pingCommand, '
        'pingSuccessRegex: $pingSuccessRegex, '
        'postBuildCommand: $postBuildCommand, '
        'postRunDebugCommand: $postRunDebugCommand, '
        'forwardPortCommand: $forwardPortCommand, '
        'forwardPortSuccessRegex: $forwardPortSuccessRegex, '
        'screenshotCommand: $screenshotCommand)';
  }
}
