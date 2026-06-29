// Copyright (c) 2023 LG Electronics, Inc. All rights reserved.
// Copyright 2023 Sony Group Corporation. All rights reserved.
// Copyright 2020 Samsung Electronics Co., Ltd. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/commands/drive.dart';
import 'package:flutter_tools/src/globals.dart' as globals;

import '../webos_cache.dart';
import '../webos_plugins.dart';

class WebosDriveCommand extends DriveCommand with WebosExtension, WebosRequiredArtifacts {
  WebosDriveCommand({super.verboseHelp})
      : super(
          fileSystem: globals.fs,
          logger: globals.logger,
          platform: globals.platform,
          signals: globals.signals,
          terminal: globals.terminal,
          outputPreferences: globals.outputPreferences,
        );
}
