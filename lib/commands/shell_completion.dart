// Copyright (c) 2023 LG Electronics, Inc. All rights reserved.
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:completion/completion.dart';

import 'package:flutter_tools/src/base/common.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/commands/shell_completion.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/runner/flutter_command.dart';

class WebosShellCompletionCommand extends ShellCompletionCommand {
  WebosShellCompletionCommand() : super();

  @override
  Future<FlutterCommandResult> runCommand() async {
    final List<String> rest = argResults?.rest ?? <String>[];
    if (rest.length > 1) {
      throwToolExit('Too many arguments given to bash-completion command.', exitCode: 1);
    }

    if (rest.isEmpty || rest.first == '-') {
      final String script = generateCompletionScript(<String>['flutter-webos']);
      globals.stdio.stdoutWrite(script);
      return FlutterCommandResult.warning();
    }

    final File outputFile = globals.fs.file(rest.first);
    if (outputFile.existsSync() && !boolArg('overwrite')) {
      throwToolExit(
        'Output file ${outputFile.path} already exists, will not overwrite. '
        'Use --overwrite to force overwriting existing output file.',
        exitCode: 1,
      );
    }
    try {
      outputFile.writeAsStringSync(generateCompletionScript(<String>['flutter-webos']));
    } on FileSystemException catch (error) {
      throwToolExit('Unable to write shell completion setup script.\n$error', exitCode: 1);
    }

    return FlutterCommandResult.success();
  }
}
