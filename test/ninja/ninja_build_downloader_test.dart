// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_ninja/src/ninja/ninja_build_downloader.dart';
import 'package:test/test.dart';

import '../helpers.dart';

void main() {
  test('NinjaBuildDownloader downloads and verifies Ninja archive', () async {
    final tempUri = await tempDirForTest();
    final buildFile = tempUri.resolve('build.ninja');
    await File.fromUri(
      buildFile,
    ).writeAsString('ninja_required_version = 1.10');

    final archiveBytes = _ninjaArchiveBytes();
    final manifestFile = File.fromUri(tempUri.resolve('releases.json'));
    await manifestFile.writeAsString(
      jsonEncode({
        'prefix': 'https://example.invalid/ninja',
        _releaseKey: {
          'name': 'ninja.zip',
          'sha256': sha256.convert(archiveBytes).toString(),
        },
      }),
    );

    final downloader = NinjaBuildDownloader(
      buildFile: buildFile,
      logger: Logger('test'),
      releasesFile: manifestFile.uri,
      systemNinjaOverride: () async => null,
      downloadOverride: (_) async => archiveBytes,
    );

    final executable = await downloader.ensureAvailable();
    expect(executable, tempUri.resolve(_binaryName));
    expect(await File.fromUri(executable).exists(), isTrue);
    expect(await File.fromUri(executable).readAsString(), 'fake ninja');
  });

  test('NinjaBuildDownloader rejects archives with the wrong hash', () async {
    final tempUri = await tempDirForTest();
    final buildFile = tempUri.resolve('build.ninja');
    await File.fromUri(
      buildFile,
    ).writeAsString('ninja_required_version = 1.10');

    final archiveBytes = _ninjaArchiveBytes();
    final manifestFile = File.fromUri(tempUri.resolve('releases.json'));
    await manifestFile.writeAsString(
      jsonEncode({
        'prefix': 'https://example.invalid/ninja',
        _releaseKey: {'name': 'ninja.zip', 'sha256': '00'},
      }),
    );

    final downloader = NinjaBuildDownloader(
      buildFile: buildFile,
      logger: Logger('test'),
      releasesFile: manifestFile.uri,
      systemNinjaOverride: () async => null,
      downloadOverride: (_) async => archiveBytes,
    );

    await expectLater(downloader.ensureAvailable(), throwsA(isA<BuildError>()));
  });

  test('NinjaBuildDownloader prefers system ninja over download', () async {
    final tempUri = await tempDirForTest();
    final buildFile = tempUri.resolve('build.ninja');
    await File.fromUri(
      buildFile,
    ).writeAsString('ninja_required_version = 1.10');
    final systemNinja = tempUri.resolve('system/$_binaryName');
    await File.fromUri(systemNinja).create(recursive: true);

    final downloader = NinjaBuildDownloader(
      buildFile: buildFile,
      logger: Logger('test'),
      systemNinjaOverride: () async => systemNinja,
      downloadOverride: (_) async {
        fail('Download should not be called when system ninja exists.');
      },
    );

    final executable = await downloader.ensureAvailable();
    expect(executable, systemNinja);
    expect(await File.fromUri(tempUri.resolve(_binaryName)).exists(), isFalse);
  });
}

String get _binaryName => Platform.isWindows ? 'ninja.exe' : 'ninja';

String get _releaseKey => switch (Abi.current()) {
  Abi.linuxArm64 => 'linux-arm64',
  Abi.linuxX64 => 'linux-x64',
  Abi.macosArm64 || Abi.macosX64 => 'mac',
  Abi.windowsArm64 => 'win-arm64',
  Abi.windowsX64 => 'win-x64',
  _ => throw UnsupportedError('Unsupported host for downloader test.'),
};

Uint8List _ninjaArchiveBytes() {
  final archive = Archive()
    ..addFile(ArchiveFile(_binaryName, 10, utf8.encode('fake ninja')));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
