import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (input.userDefines['build_assets'] == false) {
      stdout.writeln('Skipping the Rust build: user-define build_assets=false');
      return;
    }
    await FlutterRustBridgeNativeAssetsBuilder(
      cratePath: 'rust',
      extraCargoEnvironmentVariables: _bindgenEnvironment(input),
    ).run(input: input, output: output);
  });
}

// rquickjs runs bindgen on Android, which must load the NDK's libclang; Linux
// NDKs before r26 keep it under lib64, later ones and every macOS NDK under lib.
Map<String, String> _bindgenEnvironment(BuildInput input) {
  if (input.config.buildCodeAssets && input.config.code.targetOS == OS.iOS) {
    final clang = Process.runSync('xcrun', ['--find', 'clang']);
    if (clang.exitCode != 0) {
      throw StateError('Xcode clang is unavailable: ${clang.stderr}');
    }
    final library = File(
      clang.stdout.toString().trim(),
    ).parent.parent.uri.resolve('lib/');
    final simulator = input.config.code.iOS.targetSdk == IOSSdk.iPhoneSimulator;
    final sdk = Process.runSync('xcrun', [
      '--sdk',
      simulator ? 'iphonesimulator' : 'iphoneos',
      '--show-sdk-path',
    ]);
    if (sdk.exitCode != 0) {
      throw StateError('iOS SDK is unavailable: ${sdk.stderr}');
    }
    final arch = input.config.code.targetArchitecture == Architecture.arm64
        ? 'arm64'
        : 'x86_64';
    final target = '$arch-apple-ios15.0${simulator ? '-simulator' : ''}';
    return {
      'LIBCLANG_PATH': Directory.fromUri(library).path,
      'BINDGEN_EXTRA_CLANG_ARGS':
          '-isysroot "${sdk.stdout.toString().trim()}" --target=$target',
    };
  }
  if (!input.config.buildCodeAssets ||
      input.config.code.targetOS != OS.android) {
    return const {};
  }
  final compiler = input.config.code.cCompiler?.compiler;
  if (compiler == null) {
    return const {};
  }
  final llvmRoot = File.fromUri(compiler).parent.parent;
  for (final name in const ['lib', 'lib64']) {
    final directory = Directory(
      '${llvmRoot.path}${Platform.pathSeparator}$name',
    );
    if (directory.existsSync() && directory.listSync().any(_isLibclang)) {
      return {'LIBCLANG_PATH': directory.path};
    }
  }
  throw StateError(
    'No libclang under ${llvmRoot.path} (lib or lib64); the NDK Flutter '
    'passed cannot run bindgen for rquickjs',
  );
}

bool _isLibclang(FileSystemEntity entity) {
  return entity.path.split(Platform.pathSeparator).last.startsWith('libclang.');
}
