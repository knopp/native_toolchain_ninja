import 'package:native_toolchain_ninja/native_toolchain_ninja.dart';
import 'package:logging/logging.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    final packageName = input.packageName;
    final ninjaBuilder = NinjaBuilder.library(
      name: packageName,
      assetName: '${packageName}_bindings_generated.dart',
      sources: ['src/$packageName.c'],
    );
    await ninjaBuilder.run(
      input: input,
      output: output,
      logger: Logger('')
        ..level = .ALL
        // ignore: avoid_print
        ..onRecord.listen((record) => print(record.message)),
    );
  });
}
