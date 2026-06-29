// Copyright (c) 2023 LG Electronics, Inc. All rights reserved.
// Copyright 2023 Sony Group Corporation. All rights reserved.
// Copyright 2021 Samsung Electronics Co., Ltd. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/commands/precache.dart';
import 'package:flutter_tools/src/runner/flutter_command.dart';

import '../webos_cache.dart';

class WebosPrecacheCommand extends PrecacheCommand {
  WebosPrecacheCommand({
    super.verboseHelp,
    required super.cache,
    required super.platform,
    required super.logger,
    required super.featureFlags,
  })  : _cache = cache,
        _platform = platform {
    argParser.addFlag(
      'webos',
      help: 'Precache artifacts for webOS development.',
    );
    argParser.addFlag(
      'force-webos',
      help: 'Force re-downloading of webOS artifacts.',
    );
  }

  final Cache _cache;
  final Platform _platform;

  bool get _includeOtherPlatforms =>
      boolArg('android') ||
      DevelopmentArtifact.values.any((DevelopmentArtifact artifact) =>
          boolArg(artifact.name) && argResults!.wasParsed(artifact.name));

  @override
  Future<FlutterCommandResult> runCommand() async {
    final bool includeAllPlatforms = boolArg('all-platforms');
    final bool includeWebos = boolArg('webos');
    final bool includeDefaults = !includeWebos && !_includeOtherPlatforms;

    const webosStampName = 'webos-sdk';

    // Re-lock the cache.
    if (_platform.environment['FLUTTER_ALREADY_LOCKED'] != 'true') {
      await _cache.lock();
    }

    if (includeAllPlatforms || includeDefaults || includeWebos) {
      if (boolArg('force') || boolArg('force-webos')) {
        _cache.setStampFor(webosStampName, '');
      }
      await _cache.updateAll(<DevelopmentArtifact>{
        WebosDevelopmentArtifact.webos,
      });
    }

    if (includeAllPlatforms || includeDefaults || _includeOtherPlatforms) {
      // If the '--force' option is used, the super.runCommand() will delete
      // the webos's stamp file. It should be restored.
      final String? webosStamp = _cache.getStampFor(webosStampName);
      final FlutterCommandResult result = await super.runCommand();
      if (webosStamp != null) {
        _cache.setStampFor(webosStampName, webosStamp);
      }
      return result;
    }

    return FlutterCommandResult.success();
  }
}
