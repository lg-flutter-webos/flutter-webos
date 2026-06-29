// Copyright (c) 2023 LG Electronics, Inc. All rights reserved.
// Copyright 2023 Sony Group Corporation. All rights reserved.
// Copyright 2020 Samsung Electronics Co., Ltd. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/commands/attach.dart';

import '../webos_plugins.dart';

class WebosAttachCommand extends AttachCommand with WebosExtension {
  WebosAttachCommand({
    super.verboseHelp,
    super.hotRunnerFactory,
    required super.stdio,
    required super.logger,
    required super.terminal,
    required super.signals,
    required super.platform,
    required super.processInfo,
    required super.fileSystem,
  });
}
