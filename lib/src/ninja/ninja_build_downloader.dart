// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';

/// Ensures a Ninja executable exists next to the generated build file.
final class NinjaBuildDownloader {
  final Uri buildFile;
  final Logger? logger;
  final Uri? releasesFile;
  final Future<Uint8List> Function(Uri archiveUri)? _downloadOverride;
  final Future<Uri?> Function()? _systemNinjaOverride;
  final HttpClient Function() _httpClientFactory;
  final Map<String, String> _environment;

  NinjaBuildDownloader({
    required this.buildFile,
    required this.logger,
    this.releasesFile,
    Future<Uint8List> Function(Uri archiveUri)? downloadOverride,
    Future<Uri?> Function()? systemNinjaOverride,
    HttpClient Function()? httpClientFactory,
    Map<String, String>? environment,
  }) : _downloadOverride = downloadOverride,
       _systemNinjaOverride = systemNinjaOverride,
       _httpClientFactory = httpClientFactory ?? HttpClient.new,
       _environment = environment ?? Platform.environment;

  /// Reuses a system or local Ninja binary, otherwise downloads it.
  Future<Uri> ensureAvailable() async {
    final systemNinja = await (_systemNinjaOverride?.call() ?? _systemNinja());
    if (systemNinja != null) {
      logger?.finer('Using system Ninja at ${systemNinja.toFilePath()}.');
      return systemNinja;
    }

    final binary = _binaryUri;
    if (await File.fromUri(binary).exists()) {
      return binary;
    }

    final manifest = await _loadManifest();
    final release = manifest.releaseForCurrentPlatform();
    final archiveUri = manifest.archiveUriFor(release);
    final archiveBytes =
        await _downloadOverride?.call(archiveUri) ??
        await _downloadArchive(archiveUri);
    _verifySha256(archiveBytes, release.sha256);
    await _extractBinary(archiveBytes, binary);

    logger?.info('Downloaded ${binary.toFilePath()}.');
    return binary;
  }

  /// Resolves a usable Ninja executable from the host PATH.
  Future<Uri?> _systemNinja() async {
    final candidates = _pathCandidates();
    for (final candidate in candidates) {
      if (_isUsableSystemNinja(candidate)) {
        return candidate;
      }
    }
    return null;
  }

  bool _isUsableSystemNinja(Uri candidate) => Platform.isWindows
      ? candidate.path.toLowerCase().endsWith('.exe')
      : !_isShebangScript(candidate);

  bool _isShebangScript(Uri candidate) {
    RandomAccessFile? file;
    try {
      file = File.fromUri(candidate).openSync(mode: FileMode.read);
      final bytes = file.readSync(2);
      return bytes.length >= 2 && bytes[0] == 0x23 && bytes[1] == 0x21;
    } on FileSystemException {
      return false;
    } finally {
      file?.closeSync();
    }
  }

  Uri get _workingDirectory => File.fromUri(buildFile).parent.uri;

  Uri get _binaryUri => _workingDirectory.resolve(_binaryName);

  String get _binaryName => Platform.isWindows ? 'ninja.exe' : 'ninja';

  /// Enumerates all Ninja candidates from PATH in search order.
  List<Uri> _pathCandidates() {
    final path = _environment['PATH'];
    if (path == null || path.isEmpty) {
      return const [];
    }

    final separator = Platform.isWindows ? ';' : ':';
    final result = <Uri>[];
    for (final entry in path.split(separator)) {
      var trimmed = entry.trim();
      if (trimmed.length > 1 &&
          trimmed.startsWith('"') &&
          trimmed.endsWith('"')) {
        trimmed = trimmed.substring(1, trimmed.length - 1);
      }
      if (trimmed.isEmpty) {
        continue;
      }
      final file = File.fromUri(Directory(trimmed).uri.resolve(_binaryName));
      if (!file.existsSync()) {
        continue;
      }
      result.add(file.uri);
    }
    return result;
  }

  /// Loads the release manifest shipped with this package.
  Future<_NinjaReleaseManifest> _loadManifest() async {
    final uri = releasesFile ?? await _defaultReleasesFile();
    final contents = await File.fromUri(uri).readAsString();
    final json = jsonDecode(contents);
    if (json is! Map<String, Object?>) {
      throw FormatException('Expected a JSON object in ${uri.toFilePath()}.');
    }
    return _NinjaReleaseManifest.fromJson(json);
  }

  /// Resolves the bundled release manifest from the package configuration.
  Future<Uri> _defaultReleasesFile() async {
    final uri = await Isolate.resolvePackageUri(
      Uri.parse('package:native_toolchain_ninja/src/ninja/ninja_releases.json'),
    );
    if (uri == null) {
      throw BuildError(
        message: 'Could not resolve bundled ninja_releases.json.',
      );
    }
    return uri;
  }

  /// Downloads the Ninja release archive into memory.
  Future<Uint8List> _downloadArchive(Uri archiveUri) async {
    const maxAttempts = 5;
    Object? lastError;
    StackTrace? lastStackTrace;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      final client = _httpClientFactory();
      try {
        final request = await client.getUrl(archiveUri);
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) {
          final message =
              'Failed to download $archiveUri: '
                      '${response.statusCode} ${response.reasonPhrase}'
                  .trim();
          throw HttpException(message, uri: archiveUri);
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response) {
          bytes.add(chunk);
        }
        return bytes.takeBytes();
      } catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
        if (attempt == maxAttempts) {
          break;
        }
        logger?.warning(
          'Failed to download $archiveUri '
          '(attempt $attempt of $maxAttempts): $error',
        );
        await Future<void>.delayed(Duration(milliseconds: 200 * attempt));
      } finally {
        client.close(force: true);
      }
    }
    Error.throwWithStackTrace(lastError!, lastStackTrace!);
  }

  /// Verifies the downloaded archive matches the expected SHA-256.
  void _verifySha256(Uint8List archiveBytes, String expectedHash) {
    final actual = sha256.convert(archiveBytes).toString();
    final normalizedExpected = expectedHash.toLowerCase().replaceFirst(
      'sha256:',
      '',
    );
    if (actual != normalizedExpected) {
      throw BuildError(
        message:
            'Downloaded Ninja archive hash mismatch. '
            'Expected $normalizedExpected, got $actual.',
      );
    }
  }

  /// Extracts the Ninja executable from the release archive.
  Future<void> _extractBinary(Uint8List archiveBytes, Uri binary) async {
    final archive = ZipDecoder().decodeBytes(archiveBytes);
    ArchiveFile? binaryFile;
    for (final file in archive) {
      if (!file.isFile) {
        continue;
      }
      final name = file.name.replaceAll('\\', '/').split('/').last;
      if (name == _binaryName) {
        binaryFile = file;
        break;
      }
    }
    if (binaryFile == null) {
      throw BuildError(
        message: 'Downloaded Ninja archive did not contain $_binaryName.',
      );
    }

    final output = File.fromUri(binary);
    await output.parent.create(recursive: true);
    final data = binaryFile.content;
    await output.writeAsBytes(data, flush: true);
    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', output.path]);
    }
  }
}

final class _NinjaReleaseManifest {
  final Uri prefix;
  final Map<String, _NinjaRelease> releases;

  _NinjaReleaseManifest({required this.prefix, required this.releases});

  factory _NinjaReleaseManifest.fromJson(Map<String, Object?> json) {
    final prefix = json['prefix'];
    if (prefix is! String) {
      throw const FormatException('Missing Ninja release prefix.');
    }
    final releases = <String, _NinjaRelease>{};
    for (final entry in json.entries) {
      if (entry.key == 'prefix') {
        continue;
      }
      final releaseJson = entry.value;
      if (releaseJson is! Map<String, Object?>) {
        throw FormatException('Invalid release entry for ${entry.key}.');
      }
      releases[entry.key] = _NinjaRelease.fromJson(releaseJson);
    }
    return _NinjaReleaseManifest(
      prefix: Uri.parse(prefix.endsWith('/') ? prefix : '$prefix/'),
      releases: releases,
    );
  }

  /// Selects the archive matching the current host OS and architecture.
  _NinjaRelease releaseForCurrentPlatform() {
    final key = switch (Abi.current()) {
      Abi.linuxArm64 => 'linux-arm64',
      Abi.linuxX64 => 'linux-x64',
      Abi.macosArm64 || Abi.macosX64 => 'mac',
      Abi.windowsArm64 => 'win-arm64',
      Abi.windowsX64 => 'win-x64',
      _ => null,
    };
    if (key == null || !releases.containsKey(key)) {
      throw UnsupportedError(
        'No bundled Ninja release for ${Platform.operatingSystem} '
        '${Abi.current()}.',
      );
    }
    return releases[key]!;
  }

  Uri archiveUriFor(_NinjaRelease release) => prefix.resolve(release.name);
}

final class _NinjaRelease {
  final String name;
  final String sha256;

  _NinjaRelease({required this.name, required this.sha256});

  factory _NinjaRelease.fromJson(Map<String, Object?> json) {
    final name = json['name'];
    final sha256 = json['sha256'];
    if (name is! String || sha256 is! String) {
      throw const FormatException(
        'Ninja release entries need name and sha256.',
      );
    }
    return _NinjaRelease(name: name, sha256: sha256);
  }
}
