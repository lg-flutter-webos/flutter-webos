// Copyright (c) 2023 LG Electronics, Inc. All rights reserved.
// Copyright 2021 Sony Group Corporation. All rights reserved.
// Copyright 2021 Samsung Electronics Co., Ltd. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/commands/test.dart';

import '../webos_plugins.dart';

class WebosTestCommand extends TestCommand with WebosExtension {
  WebosTestCommand({super.verboseHelp});
}
