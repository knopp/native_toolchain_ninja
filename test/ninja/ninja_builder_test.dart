// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_ninja/native_toolchain_ninja.dart';
import 'package:test/test.dart';

import '../helpers.dart';

void main() {
  test('NinjaBuilder generates clang-style Ninja files', () async {
    if (Platform.isWindows) {
      return;
    }

    final toolchain = await _createFakePosixToolchain();
    final tempUri = await tempDirForTest();
    final tempUri2 = await tempDirForTest();
    final includeDirectoryUri = packageUri.resolve(
      'test/cbuilder/testfiles/includes/include',
    );
    final includeFileUri = packageUri.resolve(
      'test/cbuilder/testfiles/includes/include/includes.h',
    );
    final sourceUri = packageUri.resolve(
      'test/cbuilder/testfiles/includes/src/includes.c',
    );
    final forcedIncludeUri = packageUri.resolve(
      'test/cbuilder/testfiles/defines/src/forcedInclude.c',
    );

    final buildInputBuilder = BuildInputBuilder()
      ..setupShared(
        packageName: 'includes',
        packageRoot: tempUri,
        outputFile: tempUri.resolve('output.json'),
        outputDirectoryShared: tempUri2,
      )
      ..config.setupBuild(linkingEnabled: false)
      ..addExtension(
        CodeAssetExtension(
          targetOS: OS.linux,
          targetArchitecture: Architecture.current,
          linkModePreference: LinkModePreference.dynamic,
          cCompiler: toolchain,
        ),
      );

    final buildInput = buildInputBuilder.build();
    await _installLocalNinja(buildInput.outputDirectory);
    final debugDir = Directory.fromUri(
      buildInput.outputDirectory.resolve('debug/'),
    );
    await debugDir.create(recursive: true);
    await File.fromUri(
      debugDir.uri.resolve(OS.linux.dylibFileName('debug')),
    ).writeAsString('placeholder');

    final output = BuildOutputBuilder();
    final builder = NinjaBuilder.library(
      name: 'includes',
      assetName: 'includes',
      sources: [sourceUri.toFilePath()],
      includes: [includeDirectoryUri.toFilePath()],
      forcedIncludes: [forcedIncludeUri.toFilePath()],
      libraries: ['debug'],
      libraryDirectories: ['debug'],
      buildMode: BuildMode.debug,
    );

    await builder.run(input: buildInput, output: output);

    final buildFile = File.fromUri(
      buildInput.outputDirectory.resolve('build.ninja'),
    );
    final ninja = await buildFile.readAsString();

    expect(ninja, contains('deps = gcc'));
    expect(ninja, contains(r'depfile = $out.d'));
    expect(ninja, contains(toolchain.compiler.toFilePath()));
    expect(ninja, isNot(contains('compile_0.sh')));
    expect(ninja, contains(r"'-MF' $out.d '-c' $in '-o' $out"));
    expect(
      ninja,
      contains(
        RegExp(
          r'build obj/includes_[0-9a-f]{16}\.o: compile '
          '${RegExp.escape(sourceUri.toFilePath())}',
        ),
      ),
    );
    expect(
      ninja,
      contains(
        RegExp(
          r'build libincludes\.so: link '
          r'obj/includes_[0-9a-f]{16}\.o \| debug/libdebug\.so',
        ),
      ),
    );
    expect(ninja, contains('-MMD'));
    expect(ninja, contains('-MF'));
    expect(ninja, contains(r'$out.d'));
    expect(ninja, contains('-fPIC'));
    expect(ninja, contains('-DDEBUG'));
    expect(ninja, contains('-I${includeDirectoryUri.toFilePath()}'));
    expect(ninja, contains(forcedIncludeUri.toFilePath()));
    expect(output.build().dependencies, contains(includeFileUri));
    expect(output.build().dependencies, contains(forcedIncludeUri));
  });

  test(
    'NinjaBuilder generates direct archive commands for static libraries',
    () async {
      if (Platform.isWindows) {
        return;
      }

      final toolchain = await _createFakePosixToolchain();
      final tempUri = await tempDirForTest();
      final tempUri2 = await tempDirForTest();
      final sourceUri = packageUri.resolve(
        'test/cbuilder/testfiles/add/src/add.c',
      );

      final buildInputBuilder = BuildInputBuilder()
        ..setupShared(
          packageName: 'add',
          packageRoot: tempUri,
          outputFile: tempUri.resolve('output.json'),
          outputDirectoryShared: tempUri2,
        )
        ..config.setupBuild(linkingEnabled: false)
        ..addExtension(
          CodeAssetExtension(
            targetOS: OS.linux,
            targetArchitecture: Architecture.current,
            linkModePreference: LinkModePreference.dynamic,
            cCompiler: toolchain,
          ),
        );

      final buildInput = buildInputBuilder.build();
      await _installLocalNinja(buildInput.outputDirectory);
      final output = BuildOutputBuilder();
      final builder = NinjaBuilder.library(
        name: 'add',
        assetName: 'add',
        sources: [sourceUri.toFilePath()],
        linkModePreference: LinkModePreference.static,
      );

      await builder.run(input: buildInput, output: output);

      final ninja = await File.fromUri(
        buildInput.outputDirectory.resolve('build.ninja'),
      ).readAsString();

      expect(ninja, contains(toolchain.archiver.toFilePath()));
      expect(ninja, contains('rcs'));
      expect(ninja, contains('build libadd.a: link'));
      expect(ninja, contains(RegExp(r'obj/add_[0-9a-f]{16}\.o')));
    },
  );

  test('NinjaBuilder uses -L. for the build output directory', () async {
    if (Platform.isWindows) {
      return;
    }

    final toolchain = await _createFakePosixToolchain();
    final tempUri = await tempDirForTest();
    final tempUri2 = await tempDirForTest();
    final sourceUri = packageUri.resolve(
      'test/cbuilder/testfiles/hello_world/src/hello_world.c',
    );

    final buildInputBuilder = BuildInputBuilder()
      ..setupShared(
        packageName: 'hello_world',
        packageRoot: tempUri,
        outputFile: tempUri.resolve('output.json'),
        outputDirectoryShared: tempUri2,
      )
      ..config.setupBuild(linkingEnabled: false)
      ..addExtension(
        CodeAssetExtension(
          targetOS: OS.linux,
          targetArchitecture: Architecture.current,
          linkModePreference: LinkModePreference.dynamic,
          cCompiler: toolchain,
        ),
      );

    final buildInput = buildInputBuilder.build();
    await _installLocalNinja(buildInput.outputDirectory);
    final output = BuildOutputBuilder();
    final builder = NinjaBuilder.executable(
      name: 'hello_world',
      sources: [sourceUri.toFilePath()],
    );

    await builder.run(input: buildInput, output: output);

    final ninja = await File.fromUri(
      buildInput.outputDirectory.resolve('build.ninja'),
    ).readAsString();

    expect(ninja, contains('-L${buildInput.outputDirectory.toFilePath()}'));
  });

  test(
    'NinjaBuilder writes compile_commands.json when output is inside package',
    () async {
      if (Platform.isWindows) {
        return;
      }

      final toolchain = await _createFakePosixToolchain();
      final packageRoot = await tempDirForTest();
      final outputDirectory = packageRoot.resolve('.dart_tool/hooks/output/');
      final sourceUri = packageUri.resolve(
        'test/cbuilder/testfiles/hello_world/src/hello_world.c',
      );

      final buildInputBuilder = BuildInputBuilder()
        ..setupShared(
          packageName: 'hello_world',
          packageRoot: packageRoot,
          outputFile: packageRoot.resolve('output.json'),
          outputDirectoryShared: outputDirectory,
        )
        ..config.setupBuild(linkingEnabled: false)
        ..addExtension(
          CodeAssetExtension(
            targetOS: OS.linux,
            targetArchitecture: Architecture.current,
            linkModePreference: LinkModePreference.dynamic,
            cCompiler: toolchain,
          ),
        );

      final buildInput = buildInputBuilder.build();
      await _installLocalNinja(buildInput.outputDirectory);
      final output = BuildOutputBuilder();
      final builder = NinjaBuilder.executable(
        name: 'hello_world',
        sources: [sourceUri.toFilePath()],
      );

      await builder.run(input: buildInput, output: output);

      final compileCommands = File.fromUri(
        packageRoot.resolve('compile_commands.json'),
      );
      final compileCommandsContents = await compileCommands.readAsString();
      expect(await compileCommands.exists(), isTrue);
      expect(compileCommandsContents, contains(sourceUri.toFilePath()));
      expect(
        compileCommandsContents,
        contains(
          buildInput.outputDirectory.toFilePath().replaceFirst(
            RegExp(r'[\\/]$'),
            '',
          ),
        ),
      );
    },
  );

  test(
    'NinjaBuilder reuses build.ninja when constructor args are unchanged',
    () async {
      if (Platform.isWindows && cCompiler == null) {
        return;
      }

      final toolchain = Platform.isWindows
          ? cCompiler!
          : await _createFakePosixToolchain();
      final targetOS = Platform.isWindows ? OS.windows : OS.linux;
      final tempUri = await tempDirForTest();
      final tempUri2 = await tempDirForTest();
      final sourceUri = packageUri.resolve(
        'test/cbuilder/testfiles/hello_world/src/hello_world.c',
      );

      final buildInputBuilder = BuildInputBuilder()
        ..setupShared(
          packageName: 'hello_world',
          packageRoot: tempUri,
          outputFile: tempUri.resolve('output.json'),
          outputDirectoryShared: tempUri2,
        )
        ..config.setupBuild(linkingEnabled: false)
        ..addExtension(
          CodeAssetExtension(
            targetOS: targetOS,
            targetArchitecture: Architecture.current,
            linkModePreference: LinkModePreference.dynamic,
            cCompiler: toolchain,
          ),
        );

      final buildInput = buildInputBuilder.build();
      await _installLocalNinja(buildInput.outputDirectory);
      final builder = NinjaBuilder.executable(
        name: 'hello_world',
        sources: [sourceUri.toFilePath()],
      );

      await builder.run(input: buildInput, output: BuildOutputBuilder());

      final buildFile = File.fromUri(
        buildInput.outputDirectory.resolve('build.ninja'),
      );
      final fingerprintFile = File.fromUri(
        buildInput.outputDirectory.resolve('build.generator.sha256'),
      );
      expect(await buildFile.exists(), isTrue);
      expect(await fingerprintFile.exists(), isTrue);
      final buildModifiedBefore = (await buildFile.stat()).modified;
      final fingerprintModifiedBefore = (await fingerprintFile.stat()).modified;

      await Future<void>.delayed(const Duration(milliseconds: 1200));
      await builder.run(input: buildInput, output: BuildOutputBuilder());

      final buildModifiedAfter = (await buildFile.stat()).modified;
      final fingerprintModifiedAfter = (await fingerprintFile.stat()).modified;
      expect(buildModifiedAfter, buildModifiedBefore);
      expect(fingerprintModifiedAfter, fingerprintModifiedBefore);
    },
  );

  test('NinjaBuilder generates MSVC dependency rules on Windows', () async {
    if (!Platform.isWindows || cCompiler == null) {
      return;
    }

    final tempUri = await tempDirForTest();
    final tempUri2 = await tempDirForTest();
    final sourceUri = packageUri.resolve(
      'test/cbuilder/testfiles/add/src/add.c',
    );

    final buildInputBuilder = BuildInputBuilder()
      ..setupShared(
        packageName: 'add',
        packageRoot: tempUri,
        outputFile: tempUri.resolve('output.json'),
        outputDirectoryShared: tempUri2,
      )
      ..config.setupBuild(linkingEnabled: false)
      ..addExtension(
        CodeAssetExtension(
          targetOS: OS.windows,
          targetArchitecture: Architecture.current,
          linkModePreference: LinkModePreference.dynamic,
          cCompiler: cCompiler,
        ),
      );

    final buildInput = buildInputBuilder.build();
    await _installLocalNinja(buildInput.outputDirectory);
    final output = BuildOutputBuilder();
    final builder = NinjaBuilder.library(
      name: 'add',
      assetName: 'add',
      sources: [sourceUri.toFilePath()],
    );

    await builder.run(input: buildInput, output: output);

    final ninja = await File.fromUri(
      buildInput.outputDirectory.resolve('build.ninja'),
    ).readAsString();

    expect(ninja, contains('deps = msvc'));
    expect(ninja, contains('msvc_deps_prefix = Note: including file:'));
    expect(ninja, contains('/showIncludes'));
    expect(ninja, contains(cCompiler!.compiler.toFilePath()));
    expect(ninja, isNot(contains('cmd /v:off /c')));
  });
}

Future<CCompilerConfig> _createFakePosixToolchain() async {
  final toolDir = await tempDirForTest(prefix: 'fake_toolchain');
  final clang = await _writeExecutable(toolDir.resolve('clang'), r'''
#!/bin/sh
if [ "$1" = "--version" ]; then
  echo "clang version 18.1.0"
  exit 0
fi
out=""
depfile=""
infile=""
include_dirs=""
forced_includes=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -I*)
      include_dirs="$include_dirs ${1#-I}"
      ;;
    -include)
      shift
      forced_includes="$forced_includes $1"
      ;;
    -o)
      shift
      out="$1"
      ;;
    -MF)
      shift
      depfile="$1"
      ;;
    -c)
      shift
      infile="$1"
      ;;
  esac
  shift
done
if [ -n "$depfile" ]; then
  mkdir -p "$(dirname "$depfile")"
  deps="$infile$forced_includes"
  source_dir="$(dirname "$infile")"
  quoted_include="$(sed -n 's/^#include "\(.*\)"$/\1/p' "$infile" | head -n 1)"
  if [ -n "$quoted_include" ]; then
    if [ -f "$source_dir/$quoted_include" ]; then
      deps="$deps $source_dir/$quoted_include"
    else
      for dir in $include_dirs; do
        if [ -f "$dir/$quoted_include" ]; then
          deps="$deps $dir/$quoted_include"
          break
        fi
      done
    fi
  fi
  printf '%s: %s\n' "$out" "$deps" > "$depfile"
fi
if [ -n "$out" ]; then
  mkdir -p "$(dirname "$out")"
  : > "$out"
fi
''');
  final ar = await _writeExecutable(toolDir.resolve('llvm-ar'), r'''
#!/bin/sh
if [ "$1" = "--version" ]; then
  echo "LLVM version 18.1.0"
  exit 0
fi
if [ "$1" = "rcs" ] && [ "$#" -ge 2 ]; then
  out="$2"
  mkdir -p "$(dirname "$out")"
  : > "$out"
fi
''');
  final ld = await _writeExecutable(toolDir.resolve('ld.lld'), r'''
#!/bin/sh
echo "LLD 18.1.0"
''');
  return CCompilerConfig(compiler: clang, archiver: ar, linker: ld);
}

Future<Uri> _writeExecutable(Uri uri, String contents) async {
  final file = File.fromUri(uri);
  await file.writeAsString(contents);
  await Process.run('chmod', ['+x', file.path]);
  return file.uri;
}

Future<void> _installLocalNinja(Uri outputDirectory) async {
  final result = await Process.run(Platform.isWindows ? 'where' : 'which', [
    'ninja',
  ]);
  if (result.exitCode != 0) {
    throw StateError('System ninja is required for tests.');
  }
  final source = File(result.stdout.toString().trim().split('\n').first.trim());
  final target = File.fromUri(
    outputDirectory.resolve(Platform.isWindows ? 'ninja.exe' : 'ninja'),
  );
  await target.parent.create(recursive: true);
  await source.copy(target.path);
  if (!Platform.isWindows) {
    await Process.run('chmod', ['+x', target.path]);
  }
}
