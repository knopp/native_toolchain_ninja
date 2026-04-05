// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:native_toolchain_ninja/src/ninja/ninja_build_runner.dart';
import 'package:test/test.dart';

import '../helpers.dart';

void main() {
  test(
    '_parseDependencies parses dependency entries from ninja deps output',
    () async {
      final fixture = await File.fromUri(
        packageUri.resolve('test/ninja/testfiles/deps1'),
      ).readAsString();
      final runner = NinjaBuildRunner(
        buildFile: packageUri.resolve('test/ninja/testfiles/build.ninja'),
        ninjaExecutable: packageUri.resolve('test/ninja/testfiles/ninja'),
        packageRoot: packageUri,
        logger: null,
      );

      expect(
        runner.parseDependenciesForTesting(fixture),
        unorderedEquals([
          Uri.file('/Users/Matej/Projects/flutter/custom_window/src/macos.m'),
          Uri.file('/Users/Matej/Projects/flutter/custom_window/src/macos.h'),
        ]),
      );
    },
  );
}
