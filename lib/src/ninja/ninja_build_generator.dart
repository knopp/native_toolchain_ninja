// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';

import '../cbuilder/compiler_resolver.dart';
import '../cbuilder/language.dart';
import '../cbuilder/optimization_level.dart';
import '../cbuilder/output_type.dart';
import '../native_toolchain/msvc.dart';
import '../native_toolchain/tool_likeness.dart';
import '../native_toolchain/xcode.dart';
import '../tool/tool.dart';
import '../tool/tool_instance.dart';
import '../tool/tool_resolver.dart';

final class GeneratedNinjaBuild {
  final Uri buildFile;

  GeneratedNinjaBuild({required this.buildFile});
}

final class NinjaBuildGenerator {
  final HookInput input;
  final Logger? logger;
  final Uri artifact;
  final OutputType type;
  final List<Uri> sources;
  final List<Uri> includes;
  final List<Uri> forcedIncludes;
  final List<String> frameworks;
  final List<String> libraries;
  final List<Uri> libraryDirectories;
  final Uri? installName;
  final List<String> flags;
  final Map<String, String?> defines;
  final bool? pic;
  final String? std;
  final Language language;
  final String? cppLinkStdLib;
  final OptimizationLevel optimizationLevel;
  final LinkMode linkMode;

  NinjaBuildGenerator({
    required this.input,
    required this.logger,
    required this.artifact,
    required this.type,
    required this.sources,
    required this.includes,
    required this.forcedIncludes,
    required this.frameworks,
    required this.libraries,
    required this.libraryDirectories,
    required this.installName,
    required this.flags,
    required this.defines,
    required this.pic,
    required this.std,
    required this.language,
    required this.cppLinkStdLib,
    required this.optimizationLevel,
    required this.linkMode,
  }) : assert(type != OutputType.library || artifact.pathSegments.isNotEmpty);

  Uri get _outputDirectory => input.outputDirectory;
  CodeConfig get _codeConfig => input.config.code;

  late final _compilerResolver = CompilerResolver(
    codeConfig: _codeConfig,
    logger: logger,
  );

  /// Resolves the toolchain and writes the Ninja file into the build output.
  Future<GeneratedNinjaBuild> generate() async {
    // If build.ninja already exists and was generated from same configuration,
    // reuse it to avoid expensive tool resolving, especially on Windows.
    final buildFile = _outputDirectory.resolve('build.ninja');
    final fingerprintFile = _outputDirectory.resolve('build.generator.sha256');
    final fingerprint = _constructorArgumentsFingerprint();
    final existingFingerprint = await _readFingerprint(fingerprintFile);
    if (existingFingerprint == fingerprint &&
        await File.fromUri(buildFile).exists()) {
      logger?.info('Reusing ${buildFile.toFilePath()} (matching fingerprint).');
      return GeneratedNinjaBuild(buildFile: buildFile);
    }

    if (_codeConfig.targetOS == OS.windows && cppLinkStdLib != null) {
      throw ArgumentError.value(
        cppLinkStdLib,
        'cppLinkStdLib',
        'is not supported when targeting Windows',
      );
    }

    final compiler = await _compilerResolver.resolveCompiler();
    final archiver = type == OutputType.library && linkMode is StaticLinking
        ? await _compilerResolver.resolveArchiver()
        : null;
    final environment = await _compilerResolver.resolveEnvironment(compiler);
    final targetArgs = await _resolvedTargetArgs(compiler);

    final objectsDirectory = Directory.fromUri(
      _outputDirectory.resolve('.ninja/obj/'),
    );
    await objectsDirectory.create(recursive: true);
    await Directory.fromUri(_parentDirectory(artifact)).create(recursive: true);

    final objectExtension = compiler.tool == cl ? '.obj' : '.o';
    final compileSteps = <_CompileStep>[];
    for (var index = 0; index < sources.length; index++) {
      final source = sources[index];
      final object = objectsDirectory.uri.resolve(
        '${index}_${_sanitizeFileStem(source)}$objectExtension',
      );
      compileSteps.add(_CompileStep(source: source, object: object));
    }

    await File.fromUri(buildFile).writeAsString(
      _buildNinjaFile(
        compileSteps: compileSteps,
        compiler: compiler,
        archiver: archiver,
        environment: environment,
        targetArgs: targetArgs,
      ),
    );
    await File.fromUri(fingerprintFile).writeAsString(fingerprint);

    logger?.info('Generated ${buildFile.toFilePath()}.');
    return GeneratedNinjaBuild(buildFile: buildFile);
  }

  /// Creates a stable hash from constructor arguments only.
  String _constructorArgumentsFingerprint() {
    final cCompiler = _codeConfig.cCompiler;
    final targetOS = _codeConfig.targetOS;
    final sortedDefineEntries = defines.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final payload = <String, Object?>{
      'input': {
        'outputDirectory': _outputDirectory.toFilePath(),
        'targetOS': targetOS.name,
        'targetArchitecture': _codeConfig.targetArchitecture.name,
        'androidTargetNdkApi': targetOS == OS.android
            ? _codeConfig.android.targetNdkApi
            : null,
        'iosTargetSdk': targetOS == OS.iOS
            ? _codeConfig.iOS.targetSdk.toString()
            : null,
        'iosTargetVersion': targetOS == OS.iOS
            ? _codeConfig.iOS.targetVersion.toString()
            : null,
        'macOSTargetVersion': targetOS == OS.macOS
            ? _codeConfig.macOS.targetVersion.toString()
            : null,
        'cCompiler': cCompiler == null
            ? null
            : {
                'compiler': cCompiler.compiler.toFilePath(),
                'archiver': cCompiler.archiver.toFilePath(),
                'linker': cCompiler.linker.toFilePath(),
              },
      },
      'artifact': artifact.toFilePath(),
      'type': type.name,
      'sources': [for (final source in sources) source.toFilePath()],
      'includes': [for (final include in includes) include.toFilePath()],
      'forcedIncludes': [
        for (final forcedInclude in forcedIncludes) forcedInclude.toFilePath(),
      ],
      'frameworks': frameworks,
      'libraries': libraries,
      'libraryDirectories': [
        for (final directory in libraryDirectories) directory.toFilePath(),
      ],
      'installName': installName?.toFilePath(),
      'flags': flags,
      'defines': [
        for (final entry in sortedDefineEntries) [entry.key, entry.value],
      ],
      'pic': pic,
      'std': std,
      'language': language.name,
      'cppLinkStdLib': cppLinkStdLib,
      'optimizationLevel': optimizationLevel.toString(),
      'linkMode': linkMode.runtimeType.toString(),
      'version': 1,
    };
    return sha256.convert(utf8.encode(jsonEncode(payload))).toString();
  }

  /// Reads an existing fingerprint file if present.
  Future<String?> _readFingerprint(Uri fingerprintFile) async {
    final file = File.fromUri(fingerprintFile);
    if (!await file.exists()) {
      return null;
    }
    return (await file.readAsString()).trim();
  }

  /// Renders the full `build.ninja` file for the resolved toolchain.
  String _buildNinjaFile({
    required List<_CompileStep> compileSteps,
    required ToolInstance compiler,
    required ToolInstance? archiver,
    required Map<String, String> environment,
    required List<String> targetArgs,
  }) {
    final compileRule = compiler.tool == cl ? 'compile_msvc' : 'compile';
    final linkCommand = _linkRuleCommand(
      compileSteps: compileSteps,
      compiler: compiler,
      archiver: archiver,
      environment: environment,
      targetArgs: targetArgs,
    );
    final buffer = StringBuffer()
      ..writeln('ninja_required_version = 1.10')
      ..writeln();

    if (compiler.tool == cl) {
      buffer
        ..writeln('rule compile_msvc')
        ..writeln(
          '  command = '
          '${_compileMsvcRuleCommand(compiler, environment, targetArgs)}',
        )
        ..writeln('  deps = msvc')
        ..writeln('  msvc_deps_prefix = Note: including file:')
        ..writeln(r'  description = CC $out')
        ..writeln();
    } else {
      final compileCommand = _compileRuleCommand(
        compiler,
        environment,
        targetArgs,
      );
      buffer
        ..writeln('rule compile')
        ..writeln('  command = $compileCommand')
        ..writeln(r'  depfile = $out.d')
        ..writeln('  deps = gcc')
        ..writeln(r'  description = CC $out')
        ..writeln();
    }

    buffer
      ..writeln('rule link')
      ..writeln('  command = $linkCommand')
      ..writeln(r'  description = LINK $out')
      ..writeln();

    for (final step in compileSteps) {
      buffer.write(
        'build ${_escapePath(_pathInBuildFile(step.object))}: $compileRule '
        '${_escapePath(_pathInBuildFile(step.source))}',
      );
      buffer.writeln();
    }

    final objectDependencies = compileSteps
        .map((step) => _escapePath(_pathInBuildFile(step.object)))
        .join(' ');
    final artifactPath = _escapePath(_pathInBuildFile(artifact));
    buffer.write('build $artifactPath: link $objectDependencies');
    final implicitDeps = _existingLibraryDependencies();
    if (implicitDeps.isNotEmpty) {
      final implicitDependencyPaths = implicitDeps
          .map((dep) => _escapePath(_pathInBuildFile(dep)))
          .join(' ');
      buffer.write(' | $implicitDependencyPaths');
    }
    buffer.writeln();
    buffer.writeln('default ${_escapePath(_pathInBuildFile(artifact))}');
    return buffer.toString();
  }

  /// Builds the shared compile rule for clang-like toolchains.
  String _compileRuleCommand(
    ToolInstance compiler,
    Map<String, String> environment,
    List<String> targetArgs,
  ) {
    final arguments = <_CommandToken>[
      ..._sharedCompilerArgs(compiler, targetArgs: targetArgs).map(_fixedToken),
      _fixedToken('-MMD'),
      _fixedToken('-MF'),
      _rawToken(r'$out.d'),
      _fixedToken('-c'),
      _rawToken(r'$in'),
      _fixedToken('-o'),
      _rawToken(r'$out'),
    ];
    return _commandString(
      executable: compiler.uri,
      arguments: arguments,
      environment: environment,
    );
  }

  /// Builds the shared compile rule for MSVC-style compilation.
  String _compileMsvcRuleCommand(
    ToolInstance compiler,
    Map<String, String> environment,
    List<String> targetArgs,
  ) {
    final arguments = <_CommandToken>[
      ..._sharedCompilerArgs(compiler, targetArgs: targetArgs).map(_fixedToken),
      ..._msvcIncludeArgs(environment).map(_fixedToken),
      _fixedToken('/showIncludes'),
      _fixedToken('/c'),
      _rawToken(r'$in'),
      _rawToken(r'/Fo$out'),
    ];
    return _commandString(
      executable: compiler.uri,
      arguments: arguments,
      environment: environment,
    );
  }

  /// Builds the final link or archive rule for the selected output type.
  String _linkRuleCommand({
    required List<_CompileStep> compileSteps,
    required ToolInstance compiler,
    required ToolInstance? archiver,
    required Map<String, String> environment,
    required List<String> targetArgs,
  }) {
    final executable = type == OutputType.library && linkMode is StaticLinking
        ? archiver!.uri
        : compiler.uri;
    final linkInputs = compileSteps.map(
      (step) => _fixedToken(_absolutePathForCommand(step.object)),
    );
    final linkOutput = _absolutePathForCommand(artifact);
    final arguments = switch ((compiler.tool, type, linkMode)) {
      (final tool, OutputType.library, StaticLinking _) when tool == cl => [
        _fixedToken('/out:$linkOutput'),
        ...linkInputs,
      ],
      (_, OutputType.library, StaticLinking _) => [
        _fixedToken('rcs'),
        _fixedToken(linkOutput),
        ...linkInputs,
      ],
      (final tool, _, _) when tool == cl => [
        ..._sharedCompilerArgs(
          compiler,
          forLinking: true,
          targetArgs: targetArgs,
        ).map(_fixedToken),
        ...linkInputs,
        if (type == OutputType.library) _fixedToken('/LD'),
        _fixedToken('/Fe:$linkOutput'),
        _fixedToken('/link'),
        _fixedToken(
          '/MACHINE:${_msvcMachineFlags[_codeConfig.targetArchitecture]!}',
        ),
        ..._msvcLibraryPathArgs(environment).map(_fixedToken),
        ..._windowsLibraryArgs().map(_fixedToken),
      ],
      (_, _, _) => [
        ..._sharedCompilerArgs(
          compiler,
          forLinking: true,
          targetArgs: targetArgs,
        ).map(_fixedToken),
        ...linkInputs,
        if (type == OutputType.library && linkMode is DynamicLoadingBundled)
          _fixedToken('-shared'),
        if (type != OutputType.library ||
            linkMode is DynamicLoadingBundled) ...[
          _fixedToken('-o'),
          _fixedToken(linkOutput),
        ],
        ..._posixLinkArgs().map(_fixedToken),
      ],
    };
    return _commandString(
      executable: executable,
      arguments: arguments,
      environment: environment,
    );
  }

  /// Formats a command line for the current host shell.
  String _commandString({
    required Uri executable,
    required List<_CommandToken> arguments,
    required Map<String, String> environment,
  }) {
    if (Platform.isWindows) {
      return _windowsCommand(
        executable: executable,
        arguments: arguments,
        environment: environment,
      );
    }
    return _posixCommand(
      executable: executable,
      arguments: arguments,
      environment: environment,
    );
  }

  /// Formats a command line for POSIX shells.
  String _posixCommand({
    required Uri executable,
    required List<_CommandToken> arguments,
    required Map<String, String> environment,
  }) {
    final command = <String>[
      if (environment.isNotEmpty) 'env',
      for (final entry in environment.entries)
        '${entry.key}=${_quotePosix(entry.value)}',
      _quotePosix(_pathForCommand(executable)),
      ...arguments.map(_quotePosixToken),
    ];
    return command.join(' ');
  }

  /// Formats a command line for direct Windows process invocation.
  String _windowsCommand({
    required Uri executable,
    required List<_CommandToken> arguments,
    required Map<String, String> environment,
  }) =>
      '"${_pathForCommand(executable)}" '
      '${arguments.map(_quoteWindowsToken).join(' ')}';

  /// Computes compiler-driver flags shared by all compile or link edges.
  Iterable<String> _sharedCompilerArgs(
    ToolInstance compiler, {
    bool forLinking = false,
    required List<String> targetArgs,
  }) sync* {
    if (compiler.tool == cl) {
      if (!forLinking && optimizationLevel != OptimizationLevel.unspecified) {
        yield optimizationLevel.msvcFlag();
      }
      if (std != null) {
        yield '/std:$std';
      }
      if (language == Language.cpp && !forLinking) {
        yield '/TP';
      }
      yield* flags;
      for (final MapEntry(:key, :value) in defines.entries) {
        yield value == null ? '/D$key' : '/D$key=$value';
      }
      for (final include in includes) {
        yield '/I${_pathForCommand(include)}';
      }
      for (final forcedInclude in forcedIncludes) {
        yield '/FI${_pathForCommand(forcedInclude)}';
      }
    } else {
      yield* targetArgs;
      if (installName != null) {
        yield '-install_name';
        yield _pathForCommand(installName!);
      }
      yield* _picArgs(compiler.tool, forLinking: forLinking);
      if (std != null) {
        yield '-std=$std';
      }
      if (language == Language.cpp) {
        if (!forLinking) {
          yield '-x';
          yield 'c++';
        }
        final stdLib =
            cppLinkStdLib ?? _defaultCppLibraries[_codeConfig.targetOS];
        if (stdLib != null) {
          if (forLinking) {
            yield '-l$stdLib';
          } else {
            yield '-stdlib=lib$stdLib';
          }
        }
      }
      if (!forLinking && optimizationLevel != OptimizationLevel.unspecified) {
        yield optimizationLevel.clangFlag();
      }
      if (_codeConfig.targetOS == OS.android) {
        yield '-Wl,-z,max-page-size=16384';
      }
      if (forLinking &&
          (_codeConfig.targetOS == OS.iOS ||
              _codeConfig.targetOS == OS.macOS)) {
        yield '-Wl,-encryptable';
      }
      yield* flags;
      for (final MapEntry(:key, :value) in defines.entries) {
        yield value == null ? '-D$key' : '-D$key=$value';
      }
      for (final include in includes) {
        yield '-I${_pathForCommand(include)}';
      }
      for (final forcedInclude in forcedIncludes) {
        yield '-include';
        yield _pathForCommand(forcedInclude);
      }
      if (forLinking && language == Language.objectiveC) {
        for (final framework in frameworks) {
          yield '-framework';
          yield framework;
        }
      }
    }
  }

  /// Resolves target-specific flags that depend on the selected compiler.
  Future<List<String>> _resolvedTargetArgs(ToolInstance compiler) async {
    final args = <String>[];
    final architecture = _codeConfig.targetArchitecture;

    if (_codeConfig.targetOS == OS.android) {
      final minimumApi = architecture == Architecture.riscv64 ? 35 : 21;
      final targetApi = _codeConfig.android.targetNdkApi < minimumApi
          ? minimumApi
          : _codeConfig.android.targetNdkApi;
      args.add('--target=${_androidTargets[architecture]!}$targetApi');
      args.add('--sysroot=${compiler.uri.resolve('../sysroot/').toFilePath()}');
    }
    if (_codeConfig.targetOS == OS.windows) {
      args.add('--target=${_clangWindowsTargets[architecture]!}');
    }
    if (_codeConfig.targetOS == OS.macOS) {
      args.add('--target=${_appleMacTargets[architecture]!}');
      args.add('-mmacos-version-min=${_codeConfig.macOS.targetVersion}');
    }
    if (_codeConfig.targetOS == OS.iOS) {
      final appleTarget =
          _appleIosTargets[architecture]![_codeConfig.iOS.targetSdk]!;
      args.add('--target=$appleTarget');
      args.add('-mios-version-min=${_codeConfig.iOS.targetVersion}');
      args.add('-isysroot');
      args.add(
        (await _resolveAppleSdk(
          _codeConfig.iOS.targetSdk == IOSSdk.iPhoneOS
              ? iPhoneOSSdk
              : iPhoneSimulatorSdk,
        )).toFilePath(),
      );
    }
    if (_codeConfig.targetOS == OS.macOS) {
      args.add('-isysroot');
      args.add((await _resolveAppleSdk(macosxSdk)).toFilePath());
    }

    return args;
  }

  /// Emits PIC or PIE flags only when the target toolchain supports them.
  Iterable<String> _picArgs(Tool tool, {required bool forLinking}) sync* {
    if (pic == null || _codeConfig.targetOS == OS.windows) {
      return;
    }
    if (tool.isClangLike && !forLinking) {
      if (pic!) {
        yield type == OutputType.library ? '-fPIC' : '-fPIE';
      } else {
        yield '-fno-PIC';
        yield '-fno-PIE';
      }
      return;
    }
    if (!forLinking || type != OutputType.executable) {
      return;
    }
    yield pic! ? '-pie' : '-no-pie';
  }

  /// Adds linker search paths and runtime lookup behavior for non-MSVC links.
  Iterable<String> _posixLinkArgs() sync* {
    if (type != OutputType.library || linkMode is DynamicLoadingBundled) {
      if (_codeConfig.targetOS == OS.android ||
          _codeConfig.targetOS == OS.linux) {
        yield '-Wl,-rpath,\$ORIGIN';
      }
      for (final directory in libraryDirectories) {
        yield '-L${_absolutePathForCommand(directory)}';
      }
      for (final library in libraries) {
        yield '-l$library';
      }
    }
  }

  /// Adds library search paths for MSVC-style links.
  Iterable<String> _windowsLibraryArgs() sync* {
    for (final directory in libraryDirectories) {
      yield '/LIBPATH:${_absolutePathForCommand(directory)}';
    }
    for (final library in libraries) {
      yield '$library.lib';
    }
  }

  /// Turns MSVC include-related environment variables into compiler flags.
  Iterable<String> _msvcIncludeArgs(Map<String, String> environment) sync* {
    for (final path in _splitWindowsSearchPath(environment['INCLUDE'])) {
      yield '/I$path';
    }
  }

  /// Turns MSVC library-related environment variables into linker flags.
  Iterable<String> _msvcLibraryPathArgs(Map<String, String> environment) sync* {
    for (final key in ['LIB', 'LIBPATH']) {
      for (final path in _splitWindowsSearchPath(environment[key])) {
        yield '/LIBPATH:$path';
      }
    }
  }

  /// Splits Windows path-list environment variables while dropping empties.
  Iterable<String> _splitWindowsSearchPath(String? value) sync* {
    if (value == null || value.isEmpty) {
      return;
    }
    for (final entry in value.split(';')) {
      final trimmed = entry.trim();
      if (trimmed.isNotEmpty) {
        yield trimmed;
      }
    }
  }

  /// Resolves the active Apple SDK path for SDK-backed targets.
  Future<Uri> _resolveAppleSdk(Tool sdkTool) async {
    final context = ToolResolvingContext(logger: logger);
    final resolved = await sdkTool.defaultResolver!.resolve(context);
    return resolved
        .where((ToolInstance instance) => instance.tool == sdkTool)
        .first
        .uri;
  }

  /// Tracks linked libraries that already exist under the build directory.
  List<Uri> _existingLibraryDependencies() {
    final results = <Uri>[];
    for (final directory in libraryDirectories) {
      for (final library in libraries) {
        final dynamicFile = directory.resolve(
          _codeConfig.targetOS.dylibFileName(library),
        );
        final staticFile = directory.resolve(
          _codeConfig.targetOS.staticlibFileName(library),
        );
        if (File.fromUri(dynamicFile).existsSync()) {
          results.add(dynamicFile);
        } else if (File.fromUri(staticFile).existsSync()) {
          results.add(staticFile);
        }
      }
    }
    return results;
  }

  /// Escapes paths when they are referenced from Ninja build edges.
  ///
  /// Ninja treats `$` as escape/variable syntax, `:` as the separator between
  /// outputs and rules, spaces as separators, and `#` as a comment starter.
  /// See the Ninja manual section on lexical syntax and escaping.
  String _escapePath(String value) => value
      .replaceAll(r'$', r'$$')
      .replaceAll(':', r'$:')
      .replaceAll(' ', r'$ ')
      .replaceAll('#', r'$#');

  /// Quotes a literal token for POSIX shells.
  String _quotePosix(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";

  /// Leaves Ninja variables intact while quoting literal POSIX tokens.
  String _quotePosixToken(_CommandToken token) => token.raw
      ? token.value
      : _quotePosix(_escapeNinjaInterpolation(token.value));

  /// Quotes a literal token for `cmd.exe`.
  String _quoteWindows(String value) {
    final mustQuote = RegExp(r'[\s"&()<>^|]').hasMatch(value);
    final escaped = value.replaceAll('"', r'\"');
    return mustQuote ? '"$escaped"' : escaped;
  }

  /// Leaves Ninja variables intact while quoting literal Windows tokens.
  String _quoteWindowsToken(_CommandToken token) => token.raw
      ? token.value
      : _quoteWindows(_escapeNinjaInterpolation(token.value));

  /// Prevents literal dollar signs from being treated as Ninja interpolation.
  String _escapeNinjaInterpolation(String value) =>
      value.replaceAll(r'$', r'$$');

  /// Generates stable object file stems from source file names.
  String _sanitizeFileStem(Uri source) {
    final segments = source.pathSegments.where((segment) => segment.isNotEmpty);
    final stem = segments.isEmpty ? 'source' : segments.last.split('.').first;
    return stem.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  }

  /// Returns the containing directory for an output file.
  Uri _parentDirectory(Uri fileUri) => File.fromUri(fileUri).parent.uri;

  /// Formats a path as it should appear in Ninja build statements.
  String _pathInBuildFile(Uri uri) => _displayPath(uri);

  /// Formats a path as it should appear inside shell commands.
  String _pathForCommand(Uri uri) => _displayPath(uri);

  /// Uses absolute file-system paths for link commands.
  String _absolutePathForCommand(Uri uri) => uri.toFilePath();

  /// Uses relative paths for files inside the build directory when possible.
  String _displayPath(Uri uri) {
    if (!_isInsideOutputDirectory(uri)) {
      return uri.toFilePath();
    }

    final outputDirectoryPath = _normalizedOutputDirectoryPath();
    final comparableOutputPath = _comparablePath(outputDirectoryPath);
    final comparablePath = _comparablePath(uri.toFilePath());
    if (comparablePath == comparableOutputPath) {
      return '.';
    }
    final relativePath = comparablePath.substring(outputDirectoryPath.length);
    return relativePath.isEmpty ? '.' : relativePath;
  }

  /// Checks whether a path is contained by the current build output directory.
  bool _isInsideOutputDirectory(Uri uri) {
    final outputDirectoryPath = _normalizedOutputDirectoryPath();
    final comparableOutputPath = _comparablePath(outputDirectoryPath);
    final comparablePath = _comparablePath(uri.toFilePath());
    return comparablePath == comparableOutputPath ||
        comparablePath.startsWith(outputDirectoryPath);
  }

  /// Normalizes the build output directory to always end with a separator.
  String _normalizedOutputDirectoryPath() {
    final path = _outputDirectory.toFilePath();
    if (path.endsWith(Platform.pathSeparator)) {
      return path;
    }
    return '$path${Platform.pathSeparator}';
  }

  /// Normalizes paths before comparing directory identity.
  String _comparablePath(String path) {
    if (path.endsWith(Platform.pathSeparator)) {
      return path.substring(0, path.length - Platform.pathSeparator.length);
    }
    return path;
  }

  /// Marks a command token as a literal shell argument.
  _CommandToken _fixedToken(String value) => _CommandToken(value, raw: false);

  /// Marks a command token as a Ninja variable expansion.
  _CommandToken _rawToken(String value) => _CommandToken(value, raw: true);
}

final class _CompileStep {
  final Uri source;
  final Uri object;

  _CompileStep({required this.source, required this.object});
}

/// A single command-line token that is either a literal argument or a raw
/// Ninja variable such as `$in` or `$out`.
final class _CommandToken {
  final String value;
  final bool raw;

  const _CommandToken(this.value, {required this.raw});
}

const _androidTargets = {
  Architecture.arm: 'armv7a-linux-androideabi',
  Architecture.arm64: 'aarch64-linux-android',
  Architecture.ia32: 'i686-linux-android',
  Architecture.x64: 'x86_64-linux-android',
  Architecture.riscv64: 'riscv64-linux-android',
};

const _appleMacTargets = {
  Architecture.arm64: 'arm64-apple-darwin',
  Architecture.x64: 'x86_64-apple-darwin',
};

const _appleIosTargets = {
  Architecture.arm64: {
    IOSSdk.iPhoneOS: 'arm64-apple-ios',
    IOSSdk.iPhoneSimulator: 'arm64-apple-ios-simulator',
  },
  Architecture.x64: {IOSSdk.iPhoneSimulator: 'x86_64-apple-ios-simulator'},
};

const _clangWindowsTargets = {
  Architecture.arm64: 'arm64-pc-windows-msvc',
  Architecture.ia32: 'i386-pc-windows-msvc',
  Architecture.x64: 'x86_64-pc-windows-msvc',
};

const _msvcMachineFlags = {
  Architecture.arm64: 'ARM64',
  Architecture.ia32: 'X86',
  Architecture.x64: 'X64',
};

const _defaultCppLibraries = {
  OS.android: 'c++_shared',
  OS.fuchsia: 'c++',
  OS.iOS: 'c++',
  OS.linux: 'stdc++',
  OS.macOS: 'c++',
};
