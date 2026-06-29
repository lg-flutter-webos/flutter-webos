// Copyright (c) 2023 LG Electronics, Inc. All rights reserved.
// Copyright 2023 Sony Group Corporation. All rights reserved.
// Copyright 2020 Samsung Electronics Co., Ltd. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// ignore_for_file: unused_element, unused_field
// fork residue from upstream flutter_tools/lib/src/doctor.dart; see 28 / 34.2 (decision pending)

import 'dart:io';
import 'package:flutter_tools/src/artifacts.dart';
import 'package:flutter_tools/src/base/context.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/io.dart';
import 'package:flutter_tools/src/base/net.dart';
import 'package:flutter_tools/src/base/os.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/base/user_messages.dart';
import 'package:flutter_tools/src/base/version.dart';
import 'package:flutter_tools/src/commands/doctor.dart';
import 'package:flutter_tools/src/doctor.dart';
import 'package:flutter_tools/src/doctor_validator.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/http_host_validator.dart';
import 'package:flutter_tools/src/linux/linux_doctor.dart';
import 'package:flutter_tools/src/version.dart';
import 'package:process/process.dart';
import 'webos_sdk.dart';

WebosWorkflow? get webosWorkflow => context.get<WebosWorkflow>();
WebosValidator? get webosValidator => context.get<WebosValidator>();

/// See: `_DefaultDoctorValidatorsProvider` in `doctor.dart`
class WebosDoctorCommand extends DoctorCommand {
  WebosDoctorCommand({super.verbose}) {
    argParser.addFlag(
      'offline',
      help: 'Dummy option for update flutter tool in offline.',
    );
  }
}

class WebosDoctorValidatorsProvider implements DoctorValidatorsProvider {
  @override
  List<DoctorValidator> get validators {
    final List<DoctorValidator> validators = DoctorValidatorsProvider.defaultInstance.validators;
    final customFlutterValidator = CustomFlutterValidator(
      fileSystem: globals.fs,
      platform: globals.platform,
      flutterVersion: () =>
          globals.flutterVersion.fetchTagsAndGetVersion(clock: globals.systemClock),
      devToolsVersion: () => globals.cache.devToolsVersion,
      processManager: globals.processManager,
      userMessages: globals.userMessages,
      artifacts: globals.artifacts!,
      operatingSystemUtils: globals.os,
    );

    // Find the position of LinuxDoctorValidator in validators to remove it and replace it with CustomLinuxDoctorValidator.
    final int index = validators.indexWhere((DoctorValidator v) => v is LinuxDoctorValidator);
    final customLinuxDoctorValidator = CustomLinuxDoctorValidator(
        processManager: globals.processManager, userMessages: globals.userMessages);
    if (index != -1) {
      validators[index] = customLinuxDoctorValidator;
    }

    return <DoctorValidator>[customFlutterValidator, webosValidator!, ...validators.sublist(1)];
  }

  @override
  List<Workflow> get workflows => <Workflow>[
        ...DoctorValidatorsProvider.defaultInstance.workflows,
        webosWorkflow!,
      ];
}

/// See: [_VersionInfo] in `linux_doctor.dart`
class _VersionInfo {
  _VersionInfo(this.description) {
    final String? versionString =
        RegExp(r'[0-9]+\.[0-9]+(?:\.[0-9]+)?').firstMatch(description)?.group(0);
    number = Version.parse(versionString);
  }

  String description;
  Version? number;
}

class CustomFlutterValidator extends DoctorValidator {
  CustomFlutterValidator({
    required Platform platform,
    required FlutterVersion Function() flutterVersion,
    required String Function() devToolsVersion,
    required UserMessages userMessages,
    required FileSystem fileSystem,
    required Artifacts artifacts,
    required ProcessManager processManager,
    required OperatingSystemUtils operatingSystemUtils,
  })  : _flutterVersion = flutterVersion,
        _devToolsVersion = devToolsVersion,
        _platform = platform,
        _userMessages = userMessages,
        _fileSystem = fileSystem,
        _artifacts = artifacts,
        _processManager = processManager,
        _operatingSystemUtils = operatingSystemUtils,
        super('Flutter');

  final Platform _platform;
  final FlutterVersion Function() _flutterVersion;
  final String Function() _devToolsVersion;
  final UserMessages _userMessages;
  final FileSystem _fileSystem;
  final Artifacts _artifacts;
  final ProcessManager _processManager;
  final OperatingSystemUtils _operatingSystemUtils;

  @override
  Future<ValidationResult> validateImpl() {
    throw UnimplementedError(
      'CustomFlutterValidator.validateImpl is not implemented. '
      'Use validate() instead.',
    );
  }

  @override
  Future<ValidationResult> validate() async {
    final messages = <ValidationMessage>[];
    String? versionChannel;
    String? frameworkVersion;

    try {
      final FlutterVersion version = _flutterVersion();
      final String? gitUrl = _platform.environment['FLUTTER_GIT_URL'];
      versionChannel = version.channel;
      frameworkVersion = version.frameworkVersion;

      messages.add(_getFlutterUpstreamMessage(version));
      if (gitUrl != null) {
        messages.add(ValidationMessage(_userMessages.flutterGitUrl(gitUrl)));
      }
      messages.add(ValidationMessage(_userMessages.flutterRevision(
        version.frameworkRevisionShort,
        version.frameworkAge,
        version.frameworkCommitDate,
      )));
      messages.add(ValidationMessage(_userMessages.engineRevision(version.engineRevisionShort)));
      messages.add(ValidationMessage(_userMessages.dartRevision(version.dartSdkVersion)));
      messages.add(ValidationMessage(_userMessages.devToolsVersion(_devToolsVersion())));
      final String? pubUrl = _platform.environment[kPubDevOverride];
      if (pubUrl != null) {
        messages.add(ValidationMessage(_userMessages.pubMirrorURL(pubUrl)));
      }
      final String? storageBaseUrl = _platform.environment[kFlutterStorageBaseUrl];
      if (storageBaseUrl != null) {
        messages.add(ValidationMessage(_userMessages.flutterMirrorURL(storageBaseUrl)));
      }
    } on VersionCheckError catch (e) {
      messages.add(ValidationMessage.error(e.message));
    }

    // Check that the binaries we downloaded for this platform actually run on it.
    // If the binaries are not downloaded (because android is not enabled), then do
    // not run this check.
    final String genSnapshotPath = _artifacts.getArtifactPath(Artifact.genSnapshot);
    if (_fileSystem.file(genSnapshotPath).existsSync() && !_genSnapshotRuns(genSnapshotPath)) {
      final buffer = StringBuffer();
      buffer.writeln(_userMessages.flutterBinariesDoNotRun);
      if (_platform.isLinux) {
        buffer.writeln(_userMessages.flutterBinariesLinuxRepairCommands);
      } else if (_platform.isMacOS &&
          _operatingSystemUtils.hostPlatform == HostPlatform.darwin_arm64) {
        buffer.writeln(
            'Flutter requires the Rosetta translation environment on ARM Macs. Try running:');
        buffer.writeln('  sudo softwareupdate --install-rosetta --agree-to-license');
      }
      messages.add(ValidationMessage.error(buffer.toString()));
    }

    ValidationType valid;
    if (messages.every((ValidationMessage message) => message.isInformation)) {
      valid = ValidationType.success;
    } else {
      // The issues for this validator stem from broken git configuration of the local install;
      // in that case, make it clear that it is fine to continue, but freshness check/upgrades
      // won't be supported.
      valid = ValidationType.partial;
      messages.add(
        ValidationMessage(_userMessages.flutterValidatorErrorIntentional),
      );
    }

    return ValidationResult(
      valid,
      messages,
      statusInfo: _userMessages.flutterStatusInfo(
        versionChannel,
        frameworkVersion,
        _operatingSystemUtils.name,
        _platform.localeName,
      ),
    );
  }

  ValidationMessage _getFlutterVersionMessage(
      String frameworkVersion, String versionChannel, String flutterRoot) {
    String flutterVersionMessage =
        _userMessages.flutterVersion(frameworkVersion, versionChannel, flutterRoot);

    // The tool sets the channel as kUserBranch, if the current branch is on a
    // "detached HEAD" state, doesn't have an upstream, or is on a user branch,
    // and sets the frameworkVersion as "0.0.0-unknown" if "git describe" on
    // HEAD doesn't produce an expected format to be parsed for the frameworkVersion.
    if (versionChannel != kUserBranch && frameworkVersion != '0.0.0-unknown') {
      return ValidationMessage(flutterVersionMessage);
    }
    if (versionChannel == kUserBranch) {
      flutterVersionMessage = '$flutterVersionMessage\n${_userMessages.flutterUnknownChannel}';
    }
    if (frameworkVersion == '0.0.0-unknown') {
      flutterVersionMessage = '$flutterVersionMessage\n${_userMessages.flutterUnknownVersion}';
    }
    return ValidationMessage.hint(flutterVersionMessage);
  }

  List<ValidationMessage> _validateRequiredBinaries(String flutterRoot) {
    final ValidationMessage? flutterWarning = _validateSdkBinary('flutter', flutterRoot);
    final ValidationMessage? dartWarning = _validateSdkBinary('dart', flutterRoot);
    return <ValidationMessage>[
      if (flutterWarning != null) flutterWarning,
      if (dartWarning != null) dartWarning,
    ];
  }

  /// Return a warning if the provided [binary] on the user's path does not
  /// resolve within the Flutter SDK.
  ValidationMessage? _validateSdkBinary(String binary, String flutterRoot) {
    final String flutterBinDir = _fileSystem.path.join(flutterRoot, 'bin');

    final File? flutterBin = _operatingSystemUtils.which(binary);
    if (flutterBin == null) {
      return ValidationMessage.hint(
        'The $binary binary is not on your path. Consider adding '
        '$flutterBinDir to your path.',
      );
    }
    final String resolvedFlutterPath = flutterBin.resolveSymbolicLinksSync();
    if (!_filePathContainsDirPath(flutterRoot, resolvedFlutterPath)) {
      final hint = 'Warning: `$binary` on your path resolves to '
          '$resolvedFlutterPath, which is not inside your current Flutter '
          'SDK checkout at $flutterRoot. Consider adding $flutterBinDir to '
          'the front of your path.';
      return ValidationMessage.hint(hint);
    }
    return null;
  }

  bool _filePathContainsDirPath(String directory, String file) {
    // calling .canonicalize() will normalize for alphabetic case and path
    // separators
    return _fileSystem.path
        .canonicalize(file)
        .startsWith(_fileSystem.path.canonicalize(directory) + _fileSystem.path.separator);
  }

  ValidationMessage _getFlutterUpstreamMessage(FlutterVersion version) {
    final String? repositoryUrl = version.repositoryUrl;
    final VersionCheckError? upstreamValidationError =
        VersionUpstreamValidator(version: version, platform: _platform).run();

    // VersionUpstreamValidator can produce an error if repositoryUrl is null
    if (upstreamValidationError != null) {
      final String errorMessage = upstreamValidationError.message;
      if (errorMessage.contains('could not determine the remote upstream which is being tracked')) {
        return ValidationMessage.hint(_userMessages.flutterUpstreamRepositoryUnknown);
      }
      if (errorMessage
          .contains('Either remove "FLUTTER_GIT_URL" from the environment or set it to')) {
        return ValidationMessage.hint(
            _userMessages.flutterUpstreamRepositoryUrlEnvMismatch(repositoryUrl!));
      }
    }
    return ValidationMessage(_userMessages.flutterUpstreamRepositoryUrl(repositoryUrl!));
  }

  bool _genSnapshotRuns(String genSnapshotPath) {
    const kExpectedExitCode = 255;
    try {
      return _processManager.runSync(<String>[genSnapshotPath]).exitCode == kExpectedExitCode;
    } on Exception {
      return false;
    }
  }
}

/// See: [LinuxDoctorValidator] in `linux_doctor.dart`
class WebosValidator extends DoctorValidator {
  WebosValidator({
    required ProcessManager processManager,
    required UserMessages userMessages,
  })  : _processManager = processManager,
        _userMessages = userMessages,
        super('webOS toolchain - develop for webOS devices') {
    _requiredBinaryVersions = <String, Version>{
      kClangBinary: Version(12, 0, 0),
      kCmakeBinary: Version(3, 10, 0),
      kPkgConfigBinary: Version(0, 29, 0),
      kAresBinary: Version(3, 2, 4),
    };
  }

  final ProcessManager _processManager;
  final UserMessages _userMessages;

  final String kClangBinary = webosSdk!.targetCCompiler;
  static const kCmakeBinary = 'cmake';
  static const kPkgConfigBinary = 'pkg-config';
  static const kAresBinary = 'ares';

  late Map<String, Version> _requiredBinaryVersions;

  @override
  Future<ValidationResult> validateImpl() async {
    ValidationType validationType = ValidationType.success;
    final messages = <ValidationMessage>[];

    final installedVersions = <String, _VersionInfo?>{
      // Sort the check to make the call order predictable for unit tests.
      for (final String binary in _requiredBinaryVersions.keys.toList()..sort())
        binary: await _getBinaryVersion(binary)
    };

    // Determine overall validation level.
    if (installedVersions.values.any((_VersionInfo? versionInfo) => versionInfo?.number == null)) {
      validationType = ValidationType.missing;
    } else if (installedVersions.keys.any(
        (String binary) => installedVersions[binary]!.number! < _requiredBinaryVersions[binary]!)) {
      validationType = ValidationType.partial;
    }

    if (webosSdk!.sdkVersion == '') {
      validationType = ValidationType.missing;
      messages.add(const ValidationMessage.error('webOS NDK environment is not set properly.'));
    }

    // Message for webOS NDK version.
    if (webosSdk!.ndkVersion.isNotEmpty) {
      messages.add(ValidationMessage('webOS NDK version ${webosSdk!.ndkVersion}'));
    }

    // Message for ares (webOS CLI). Required to package, install, and run apps.
    {
      final _VersionInfo? version = installedVersions[kAresBinary];
      if (version == null || version.number == null) {
        messages.add(const ValidationMessage.error(
          'Unable to find the webOS CLI (ares). '
          'Install it with "npm install -g @webos-tools/cli" and make sure it is on your PATH.',
        ));
      } else {
        assert(_requiredBinaryVersions.containsKey(kAresBinary));
        messages.add(ValidationMessage('webOS CLI (ares) version ${version.number}'));
        final Version requiredVersion = _requiredBinaryVersions[kAresBinary]!;
        if (version.number! < requiredVersion) {
          messages.add(ValidationMessage.error(
            'The webOS CLI (ares) is too old; version $requiredVersion or later is required. '
            'Upgrade it with "npm install -g @webos-tools/cli".',
          ));
        }
      }
    }

    // Message for Clang.
    {
      final _VersionInfo? version = installedVersions[kClangBinary];
      if (version == null || version.number == null) {
        messages.add(const ValidationMessage.error('Unable to find webOS NDK toolchain.'));
      } else {
        assert(_requiredBinaryVersions.containsKey(kClangBinary));
        messages.add(ValidationMessage(version.description));
        final Version requiredVersion = _requiredBinaryVersions[kClangBinary]!;
        if (version.number! < requiredVersion) {
          messages
              .add(ValidationMessage.error(_userMessages.clangTooOld(requiredVersion.toString())));
        }
      }
    }

    // Message for CMake.
    {
      final _VersionInfo? version = installedVersions[kCmakeBinary];
      if (version == null || version.number == null) {
        messages.add(ValidationMessage.error(_userMessages.cmakeMissing));
      } else {
        assert(_requiredBinaryVersions.containsKey(kCmakeBinary));
        messages.add(ValidationMessage(version.description));
        final Version requiredVersion = _requiredBinaryVersions[kCmakeBinary]!;
        if (version.number! < requiredVersion) {
          messages
              .add(ValidationMessage.error(_userMessages.cmakeTooOld(requiredVersion.toString())));
        }
      }
    }

    // Message for pkg-config.
    {
      final _VersionInfo? version = installedVersions[kPkgConfigBinary];
      if (version == null || version.number == null) {
        messages.add(ValidationMessage.error(_userMessages.pkgConfigMissing));
      } else {
        assert(_requiredBinaryVersions.containsKey(kPkgConfigBinary));
        // The full version description is just the number, so add context.
        messages.add(ValidationMessage(_userMessages.pkgConfigVersion(version.description)));
        final Version requiredVersion = _requiredBinaryVersions[kPkgConfigBinary]!;
        if (version.number! < requiredVersion) {
          messages.add(
              ValidationMessage.error(_userMessages.pkgConfigTooOld(requiredVersion.toString())));
        }
      }
    }

    return ValidationResult(validationType, messages);
  }

  /// See: [_getBinaryVersion] in `linux_doctor.dart`
  Future<_VersionInfo?> _getBinaryVersion(String binary) async {
    ProcessResult? result;
    try {
      result = await _processManager.run(<String>[
        binary,
        '--version',
      ]);
    } on ArgumentError {
      // ignore error.
    } on ProcessException {
      // ignore error.
    }
    if (result == null || result.exitCode != 0) {
      return null;
    }
    final String firstLine = (result.stdout as String).split('\n').first.trim();
    return _VersionInfo(firstLine);
  }
}

/// The webOS-specific implementation of a [Workflow].
///
/// See: `AndroidWorkflow` in `android_workflow.dart`
class WebosWorkflow extends Workflow {
  WebosWorkflow({
    required OperatingSystemUtils operatingSystemUtils,
  }) : _operatingSystemUtils = operatingSystemUtils;

  final OperatingSystemUtils _operatingSystemUtils;

  @override
  bool get appliesToHostPlatform =>
      (_operatingSystemUtils.hostPlatform == HostPlatform.linux_x64) ||
      (_operatingSystemUtils.hostPlatform == HostPlatform.linux_arm64);

  @override
  bool get canLaunchDevices => true;

  @override
  bool get canListDevices => true;

  @override
  bool get canListEmulators => false;
}

class CustomLinuxDoctorValidator extends DoctorValidator {
  CustomLinuxDoctorValidator({
    required ProcessManager processManager,
    required UserMessages userMessages,
  })  : _processManager = processManager,
        _userMessages = userMessages,
        super('Linux toolchain - develop for Linux desktop');

  final ProcessManager _processManager;
  final UserMessages _userMessages;

  static const kClangBinary = 'clang++';
  static const kCmakeBinary = 'cmake';
  static const kNinjaBinary = 'ninja';
  static const kPkgConfigBinary = 'pkg-config';

  final _requiredBinaryVersions = <String, Version>{
    kClangBinary: Version(3, 4, 0),
    kCmakeBinary: Version(3, 10, 0),
    kNinjaBinary: Version(1, 8, 0),
    kPkgConfigBinary: Version(0, 29, 0),
  };

  final _requiredGtkLibraries = <String>[
    'gtk+-3.0',
    'glib-2.0',
    'gio-2.0',
  ];

  @override
  Future<ValidationResult> validateImpl() {
    throw UnimplementedError(
      'CustomLinuxDoctorValidator.validateImpl is not implemented. '
      'Use validate() instead.',
    );
  }

  @override
  Future<ValidationResult> validate() async {
    ValidationType validationType = ValidationType.success;
    final messages = <ValidationMessage>[];

    final installedVersions = <String, _VersionInfo?>{
      // Sort the check to make the call order predictable for unit tests.
      for (final String binary in _requiredBinaryVersions.keys.toList()..sort())
        binary: await _getBinaryVersion(binary),
    };

    // Determine overall validation level.
    if (installedVersions.values.any((_VersionInfo? versionInfo) => versionInfo?.number == null)) {
      validationType = ValidationType.missing;
    } else if (installedVersions.keys.any(
        (String binary) => installedVersions[binary]!.number! < _requiredBinaryVersions[binary]!)) {
      validationType = ValidationType.partial;
    }

    // Message for Clang.
    {
      final _VersionInfo? version = installedVersions[kClangBinary];
      if (version == null || version.number == null) {
        messages.add(ValidationMessage.error(_userMessages.clangMissing));
      } else {
        assert(_requiredBinaryVersions.containsKey(kClangBinary));
        messages.add(ValidationMessage(version.description));
        final Version requiredVersion = _requiredBinaryVersions[kClangBinary]!;
        if (version.number! < requiredVersion) {
          messages
              .add(ValidationMessage.error(_userMessages.clangTooOld(requiredVersion.toString())));
        }
      }
    }

    // Message for CMake.
    {
      final _VersionInfo? version = installedVersions[kCmakeBinary];
      if (version == null || version.number == null) {
        messages.add(ValidationMessage.error(_userMessages.cmakeMissing));
      } else {
        assert(_requiredBinaryVersions.containsKey(kCmakeBinary));
        messages.add(ValidationMessage(version.description));
        final Version requiredVersion = _requiredBinaryVersions[kCmakeBinary]!;
        if (version.number! < requiredVersion) {
          messages
              .add(ValidationMessage.error(_userMessages.cmakeTooOld(requiredVersion.toString())));
        }
      }
    }

    // Message for ninja.
    {
      final _VersionInfo? version = installedVersions[kNinjaBinary];
      if (version == null || version.number == null) {
        messages.add(ValidationMessage.error(_userMessages.ninjaMissing));
      } else {
        assert(_requiredBinaryVersions.containsKey(kNinjaBinary));
        // The full version description is just the number, so add context.
        messages.add(ValidationMessage(_userMessages.ninjaVersion(version.description)));
        final Version requiredVersion = _requiredBinaryVersions[kNinjaBinary]!;
        if (version.number! < requiredVersion) {
          messages
              .add(ValidationMessage.error(_userMessages.ninjaTooOld(requiredVersion.toString())));
        }
      }
    }

    // Message for pkg-config.
    {
      final _VersionInfo? version = installedVersions[kPkgConfigBinary];
      if (version == null || version.number == null) {
        messages.add(ValidationMessage.error(_userMessages.pkgConfigMissing));
        // Exit early because we cannot validate libraries without pkg-config.
        return ValidationResult(validationType, messages);
      } else {
        assert(_requiredBinaryVersions.containsKey(kPkgConfigBinary));
        // The full version description is just the number, so add context.
        messages.add(ValidationMessage(_userMessages.pkgConfigVersion(version.description)));
        final Version requiredVersion = _requiredBinaryVersions[kPkgConfigBinary]!;
        if (version.number! < requiredVersion) {
          messages.add(
              ValidationMessage.error(_userMessages.pkgConfigTooOld(requiredVersion.toString())));
        }
      }
    }

    // Messages for libraries.
    {
      var libraryMissing = false;
      for (final String library in _requiredGtkLibraries) {
        if (!await _libraryIsPresent(library)) {
          libraryMissing = true;
          break;
        }
      }
      if (libraryMissing) {
        validationType = ValidationType.missing;
        messages.add(ValidationMessage.error(_userMessages.gtkLibrariesMissing));
      }
    }

    return ValidationResult(validationType, messages);
  }

  /// Returns the installed version of [binary], or null if it's not installed.
  ///
  /// Requires tha [binary] take a '--version' flag, and print a version of the
  /// form x.y.z somewhere on the first line of output.
  Future<_VersionInfo?> _getBinaryVersion(String binary) async {
    ProcessResult? result;
    try {
      result = await _processManager.run(<String>[
        binary,
        '--version',
      ]);
    } on ArgumentError {
      // ignore error.
    } on ProcessException {
      // ignore error.
    }
    if (result == null || result.exitCode != 0) {
      return null;
    }
    final String firstLine = (result.stdout as String).split('\n').first.trim();
    return _VersionInfo(firstLine);
  }

  /// Checks that [library] is available via pkg-config.
  Future<bool> _libraryIsPresent(String library) async {
    ProcessResult? result;
    try {
      result = await _processManager.run(<String>[
        'bash',
        '-c',
        'export PATH=/usr/bin:\$PATH && pkg-config --exists $library',
      ]);
    } on ArgumentError {
      // ignore error.
    }
    return (result?.exitCode ?? 1) == 0;
  }
}
