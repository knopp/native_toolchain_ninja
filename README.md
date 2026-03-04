[![pub package](https://img.shields.io/pub/v/native_toolchain_ninja.svg)](https://pub.dev/packages/native_toolchain_ninja)
[![package publisher](https://img.shields.io/pub/publisher/native_toolchain_ninja.svg)](https://pub.dev/packages/native_toolchain_ninja/publisher)

A library to invoke the native C compiler installed on the host machine through [ninja](https://ninja-build.org) build.

## Status: Experimental

This package copies the syntax of [native_toolchain_c](https://pub.dev/packages/native_toolchain_c). Simply replace `CBuilder` with `NinjaBuilder` and the build will be run through `ninja` instead of invoking the compiler directly.

Building through `ninja` allows for incremental builds, better dependency tracking and automatic `compile_commands.json` generation.

Ninja does not need to be installed on the host system, if missing it will be downloaded during the build. The download is checked against
original sha256 checksum to ensure integrity. See [ninja_releases.json](lib/src/ninja/ninja_releases.json) for more information.

## Example

An example can be found in [example/package](example/package/hook).
