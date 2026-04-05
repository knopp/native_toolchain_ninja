// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import '../cbuilder/build_mode.dart';
import '../cbuilder/language.dart';
import '../cbuilder/logger.dart';
import '../cbuilder/optimization_level.dart';
import '../cbuilder/output_type.dart';
import 'ninja_build_downloader.dart';
import 'ninja_build_generator.dart';
import 'ninja_build_runner.dart';

/// Specification for generating Ninja files for a native build.
class NinjaBuilder {
  /// The dart files involved in building this artifact.
  ///
  /// Resolved against [BuildInput.packageRoot].
  ///
  /// Used to output the [BuildOutput.dependencies].
  @Deprecated(
    'Newer Dart and Flutter SDKs automatically add the Dart hook '
    'sources as dependencies.',
  )
  final List<String> dartBuildFiles;

  /// What kind of artifact to build.
  final OutputType type;

  /// Name of the library or executable to build.
  final String name;

  /// The package name to associate the asset with.
  final String? packageName;

  /// Asset identifier.
  final String? assetName;

  /// Source files to compile.
  final List<String> sources;

  /// Include directories to pass to the compiler.
  final List<String> includes;

  /// Files forced into each translation unit before compilation.
  final List<String> forcedIncludes;

  /// Frameworks to link.
  final List<String> frameworks;

  /// Libraries to link.
  final List<String> libraries;

  /// Additional search directories for [libraries].
  final List<String> libraryDirectories;

  /// The install name of the generated dynamic library.
  @visibleForTesting
  final Uri? installName;

  /// Flags to pass to the compiler driver.
  final List<String> flags;

  /// Definitions of preprocessor macros.
  final Map<String, String?> defines;

  /// Whether to define a macro for the current [BuildMode].
  final bool buildModeDefine;

  /// Whether to define `NDEBUG` outside of debug builds.
  final bool ndebugDefine;

  /// Whether position independent code should be generated.
  final bool? pic;

  /// The language standard to use.
  final String? std;

  /// The language to compile [sources] as.
  final Language language;

  /// The C++ standard library to link against.
  final String? cppLinkStdLib;

  /// The preferred link mode for libraries.
  final LinkModePreference? linkModePreference;

  /// What optimization level should be used for compiling.
  final OptimizationLevel optimizationLevel;

  /// The build mode to encode into the generated commands.
  final BuildMode buildMode;

  static const List<String> defaultFrameworks = ['Foundation'];
  static const List<String> defaultLibraryDirectories = ['.'];

  NinjaBuilder.library({
    required this.name,
    this.packageName,
    this.assetName,
    this.sources = const [],
    this.includes = const [],
    this.forcedIncludes = const [],
    this.frameworks = defaultFrameworks,
    this.libraries = const [],
    this.libraryDirectories = defaultLibraryDirectories,
    @Deprecated(
      'Newer Dart and Flutter SDKs automatically add the Dart hook '
      'sources as dependencies.',
    )
    this.dartBuildFiles = const [],
    @visibleForTesting this.installName,
    this.flags = const [],
    this.defines = const {},
    this.buildModeDefine = true,
    this.ndebugDefine = true,
    this.pic = true,
    this.std,
    this.language = Language.c,
    this.cppLinkStdLib,
    this.linkModePreference,
    this.optimizationLevel = OptimizationLevel.o3,
    this.buildMode = BuildMode.release,
  }) : type = OutputType.library;

  NinjaBuilder.executable({
    required this.name,
    this.packageName,
    this.sources = const [],
    this.includes = const [],
    this.forcedIncludes = const [],
    this.frameworks = defaultFrameworks,
    this.libraries = const [],
    this.libraryDirectories = defaultLibraryDirectories,
    @Deprecated(
      'Newer Dart and Flutter SDKs automatically add the Dart hook '
      'sources as dependencies.',
    )
    this.dartBuildFiles = const [],
    this.flags = const [],
    this.defines = const {},
    this.buildModeDefine = true,
    this.ndebugDefine = true,
    bool? pie = false,
    this.std,
    this.language = Language.c,
    this.cppLinkStdLib,
    this.optimizationLevel = OptimizationLevel.o3,
    this.buildMode = BuildMode.release,
  }) : type = OutputType.executable,
       assetName = null,
       installName = null,
       pic = pie,
       linkModePreference = null;

  /// Generates Ninja files for this build in [BuildInput.outputDirectory].
  ///
  /// The build itself is not run. If the expected artifact already exists, it
  /// is emitted as a [CodeAsset]. Otherwise only the generated Ninja metadata
  /// and dependencies are written.
  Future<void> run({
    required BuildInput input,
    required BuildOutputBuilder output,
    Logger? logger,
    List<AssetRouting> routing = const [ToAppBundle()],
  }) async {
    logger ??= createDefaultLogger();
    if (!input.config.buildCodeAssets) {
      logger.info(
        'config.buildAssetTypes did not contain CodeAssets, '
        'skipping Ninja generation for $name.',
      );
      return;
    }
    assert(
      input.config.linkingEnabled || routing.whereType<ToLinkHook>().isEmpty,
      'ToLinkHook can only be provided if input.config.linkingEnabled is true.',
    );

    final packageRoot = input.packageRoot;
    final outDir = input.outputDirectory;
    await Directory.fromUri(outDir).create(recursive: true);

    final linkMode = _resolveLinkMode(input.config.code.linkModePreference);
    final artifact = switch (type) {
      OutputType.library => outDir.resolve(
        input.config.code.targetOS.libraryFileName(name, linkMode),
      ),
      OutputType.executable => outDir.resolve(
        input.config.code.targetOS.executableFileName(name),
      ),
    };

    final resolvedSources = [
      for (final source in sources) _resolvePath(packageRoot, source),
    ];
    final resolvedIncludes = [
      for (final directory in includes)
        _resolveDirectory(packageRoot, directory),
    ];
    final resolvedForcedIncludes = [
      for (final file in forcedIncludes) _resolvePath(packageRoot, file),
    ];
    final resolvedDartBuildFiles = [
      // ignore: deprecated_member_use_from_same_package
      for (final source in dartBuildFiles) packageRoot.resolve(source),
    ];
    final resolvedLibraryDirectories = [
      for (final directory in libraryDirectories)
        _resolveDirectory(outDir, directory),
    ];

    final generatedBuild = await NinjaBuildGenerator(
      input: input,
      logger: logger,
      artifact: artifact,
      type: type,
      sources: resolvedSources,
      includes: resolvedIncludes,
      forcedIncludes: resolvedForcedIncludes,
      frameworks: frameworks,
      libraries: libraries,
      libraryDirectories: resolvedLibraryDirectories,
      installName: installName,
      flags: flags,
      defines: {
        ...defines,
        if (buildModeDefine) buildMode.name.toUpperCase(): null,
        if (ndebugDefine && buildMode != BuildMode.debug) 'NDEBUG': null,
      },
      pic: pic,
      std: std,
      language: language,
      cppLinkStdLib: cppLinkStdLib,
      optimizationLevel: optimizationLevel,
      linkMode: linkMode,
    ).generate();
    final ninjaExecutable = await NinjaBuildDownloader(
      buildFile: generatedBuild.buildFile,
      logger: logger,
    ).ensureAvailable();
    final ninjaDependencies = await NinjaBuildRunner(
      buildFile: generatedBuild.buildFile,
      ninjaExecutable: ninjaExecutable,
      packageRoot: packageRoot,
      logger: logger,
    ).run();

    output.metadata['native_toolchain_ninja'] = {
      'buildFile': generatedBuild.buildFile.toFilePath(),
      'target': artifact.toFilePath(),
      'kind': type.name,
    };

    if (assetName != null && await File.fromUri(artifact).exists()) {
      for (final route in routing) {
        output.assets.code.add(
          CodeAsset(
            package: packageName ?? input.packageName,
            name: assetName!,
            file: artifact,
            linkMode: linkMode,
          ),
          routing: route,
        );
      }
    } else if (assetName != null) {
      logger.info(
        'Generated and ran ${generatedBuild.buildFile.toFilePath()} for $name. '
        'Skipping CodeAsset emission until ${artifact.toFilePath()} exists.',
      );
    }

    output.dependencies.addAll({
      ...ninjaDependencies,
      ...resolvedSources,
      ...resolvedDartBuildFiles,
    });
  }

  LinkMode _resolveLinkMode(LinkModePreference defaultPreference) {
    final effectivePreference = linkModePreference ?? defaultPreference;
    if (effectivePreference == LinkModePreference.dynamic ||
        effectivePreference == LinkModePreference.preferDynamic) {
      return DynamicLoadingBundled();
    }
    return StaticLinking();
  }

  Uri _resolvePath(Uri base, String path) {
    if (_isAbsolutePath(path)) {
      return Uri.file(path);
    }
    return base.resolveUri(Uri(path: path.replaceAll('\\', '/')));
  }

  Uri _resolveDirectory(Uri base, String path) {
    if (_isAbsolutePath(path)) {
      return Directory(path).uri;
    }
    final normalized = path.replaceAll('\\', '/');
    final suffixed = normalized.endsWith('/') ? normalized : '$normalized/';
    return base.resolve(suffixed);
  }

  bool _isAbsolutePath(String path) =>
      path.startsWith('/') ||
      path.startsWith('\\') ||
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);
}
