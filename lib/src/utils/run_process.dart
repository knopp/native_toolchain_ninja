// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';

/// Runs a [Process].
///
/// If [logger] is provided, stream stdout and stderr to it.
///
/// If [captureOutput], captures stdout and stderr.
Future<RunProcessResult> runProcess({
  required Uri executable,
  List<String> arguments = const [],
  Uri? workingDirectory,
  Map<String, String>? environment,
  required Logger? logger,
  bool captureOutput = true,
  Level stdoutLogLevel = .FINE,
  int expectedExitCode = 0,
  bool throwOnUnexpectedExitCode = false,
}) async {
  final printWorkingDir =
      workingDirectory != null && workingDirectory != Directory.current.uri;
  final commandString = [
    if (printWorkingDir) '(cd ${workingDirectory.toFilePath()};',
    ...?environment?.entries.map((entry) => '${entry.key}=${entry.value}'),
    executable.toFilePath(),
    ...arguments.map((a) => a.contains(' ') ? "'$a'" : a),
    if (printWorkingDir) ')',
  ].join(' ');
  logger?.info('Running `$commandString`.');

  final stdoutBuffer = StringBuffer();
  final stderrBuffer = StringBuffer();
  final process = await Process.start(
    executable.toFilePath(),
    arguments,
    workingDirectory: workingDirectory?.toFilePath(),
    environment: environment,
    runInShell: Platform.isWindows && workingDirectory != null,
  );

  final stdoutSub = _splitLines(process.stdout).listen((String line) {
    logger?.log(stdoutLogLevel, line);
    if (captureOutput) {
      stdoutBuffer.write(line);
      stdoutBuffer.write('\n');
    }
  });
  final stderrSub = _splitLines(process.stderr).listen((String line) {
    logger?.severe(line);
    if (captureOutput) {
      stderrBuffer.write(line);
      stderrBuffer.write('\n');
    }
  });

  final (exitCode, _, _) = await (
    process.exitCode,
    stdoutSub.asFuture<void>(),
    stderrSub.asFuture<void>(),
  ).wait;
  final result = RunProcessResult(
    pid: process.pid,
    command: commandString,
    exitCode: exitCode,
    stdout: stdoutBuffer.toString(),
    stderr: stderrBuffer.toString(),
  );
  if (throwOnUnexpectedExitCode && expectedExitCode != exitCode) {
    throw ProcessException(
      executable.toFilePath(),
      arguments,
      "Full command string: '$commandString'.\n"
      "Exit code: '$exitCode'.\n"
      'For the output of the process check the logger output.',
    );
  }
  return result;
}

// The chunk may be shorter than a line, however this still assumes that new
// line triggers new chunk.
Stream<String> _splitLines(Stream<List<int>> data) async* {
  final buffer = StringBuffer();
  await for (final chunk in data) {
    try {
      final decoded = systemEncoding.decode(chunk);
      if (decoded.endsWith('\n')) {
        if (buffer.isNotEmpty) {
          buffer.write(decoded);
          yield buffer.toString();
          buffer.clear();
        } else {
          yield decoded;
        }
      } else {
        buffer.write(decoded);
      }
    } catch (e) {
      yield 'Failed to decode chunk: $e';
      continue;
    }
  }
  if (buffer.isNotEmpty) {
    yield buffer.toString();
  }
}

/// Drop in replacement of [ProcessResult].
class RunProcessResult {
  final int pid;

  final String command;

  final int exitCode;

  final String stderr;

  final String stdout;

  RunProcessResult({
    required this.pid,
    required this.command,
    required this.exitCode,
    required this.stderr,
    required this.stdout,
  });

  @override
  String toString() =>
      '''command: $command
exitCode: $exitCode
stdout: $stdout
stderr: $stderr''';
}
