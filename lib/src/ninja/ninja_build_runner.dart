// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:logging/logging.dart';

import '../utils/run_process.dart';

/// Runs a generated Ninja file in its output directory.
final class NinjaBuildRunner {
  final Uri buildFile;
  final Uri ninjaExecutable;
  final Uri packageRoot;
  final Logger? logger;

  NinjaBuildRunner({
    required this.buildFile,
    required this.ninjaExecutable,
    required this.packageRoot,
    required this.logger,
  });

  /// Invokes `ninja` and returns the dependencies it recorded for the build.
  Future<Set<Uri>> run() async {
    await runProcess(
      executable: ninjaExecutable,
      arguments: ['-f', File.fromUri(buildFile).uri.pathSegments.last, '-v'],
      workingDirectory: _workingDirectory,
      logger: logger,
      captureOutput: false,
      throwOnUnexpectedExitCode: true,
    );
    await _writeCompileCommandsIfLocalPackage();
    return _readDependencies();
  }

  Uri get _workingDirectory => File.fromUri(buildFile).parent.uri;

  /// Reads the dependency graph persisted by Ninja after the build completes.
  Future<Set<Uri>> _readDependencies() async {
    final result = await runProcess(
      executable: ninjaExecutable,
      arguments: [
        '-f',
        File.fromUri(buildFile).uri.pathSegments.last,
        '-t',
        'deps',
      ],
      workingDirectory: _workingDirectory,
      logger: logger,
      captureOutput: true,
      throwOnUnexpectedExitCode: true,
    );
    return _parseDependencies(result.stdout);
  }

  /// Writes `compile_commands.json` for local package builds.
  Future<void> _writeCompileCommandsIfLocalPackage() async {
    if (!_isWithinPackageRoot(_workingDirectory, packageRoot)) {
      return;
    }
    final result = await runProcess(
      executable: ninjaExecutable,
      arguments: [
        '-f',
        File.fromUri(buildFile).uri.pathSegments.last,
        '-t',
        'compdb',
      ],
      workingDirectory: _workingDirectory,
      logger: logger,
      captureOutput: true,
      throwOnUnexpectedExitCode: true,
    );
    await File.fromUri(
      packageRoot.resolve('compile_commands.json'),
    ).writeAsString(result.stdout);
  }

  /// Extracts dependency paths from `ninja -t deps` output.
  Set<Uri> _parseDependencies(String stdout) {
    final dependencies = <Uri>{};
    for (final line in stdout.split('\n')) {
      if (line.isEmpty || !_isDependencyLine(line)) {
        continue;
      }
      dependencies.add(_dependencyUri(line.trim()));
    }
    return dependencies;
  }

  bool _isDependencyLine(String line) =>
      line.isNotEmpty &&
      (line.codeUnitAt(0) == 0x20 || line.codeUnitAt(0) == 0x09);

  Uri _dependencyUri(String path) {
    if (_isAbsolutePath(path)) {
      return Uri.file(path);
    }
    return _workingDirectory.resolveUri(Uri(path: path.replaceAll('\\', '/')));
  }

  bool _isAbsolutePath(String path) =>
      path.startsWith('/') ||
      path.startsWith('\\') ||
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);

  bool _isWithinPackageRoot(Uri child, Uri parent) {
    final childPath = _normalizedDirectoryPath(child);
    final parentPath = _normalizedDirectoryPath(parent);
    return childPath.startsWith(parentPath);
  }

  String _normalizedDirectoryPath(Uri uri) {
    var path = Directory.fromUri(uri).absolute.path;
    if (!path.endsWith(Platform.pathSeparator)) {
      path = '$path${Platform.pathSeparator}';
    }
    if (Platform.isWindows) {
      path = path.toLowerCase();
    }
    return path;
  }
}
