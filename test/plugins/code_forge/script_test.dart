import 'dart:convert';
import 'dart:io';

import 'package:code_forge/script.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';

const _libraryStem = 'code_forge';

String get _libraryFile {
  if (Platform.isWindows) return '$_libraryStem.dll';
  if (Platform.isMacOS) return 'lib$_libraryStem.dylib';
  return 'lib$_libraryStem.so';
}

Future<void> _initNative() async {
  final path = 'plugins/code_forge/rust/target/release/$_libraryFile';
  if (!File(path).existsSync()) {
    throw StateError(
      'Native library not found at $path; build it with '
      '`cargo build --release` in plugins/code_forge/rust.',
    );
  }
  await RustLib.init(
    externalLibrary: ExternalLibrary.open(File(path).absolute.path),
  );
}

void main() {
  late Directory directory;

  setUpAll(() async {
    await _initNative();
    directory = await Directory.systemTemp.createTemp('script_test');
  });

  tearDownAll(() async {
    await directory.delete(recursive: true);
  });

  File write(String name, String content) {
    return File('${directory.path}/$name')..writeAsStringSync(content);
  }

  test('evaluates a script from file to file', () async {
    final input = write(
      'input.json',
      json.encode({
        'mode': 'rule',
        'rule': ['MATCH,DIRECT'],
        'proxy-providers': null,
      }),
    );
    final output = File('${directory.path}/output.json');

    final result = await evaluateScriptFile(
      script:
          'const ruleOptionsEnable = { ads: true };\n'
          'function main(config) {\n'
          "  console.log('rules', config.rules.length);\n"
          '  config.flags = ruleOptionsEnable;\n'
          "  config.mode = 'global';\n"
          '  return config;\n'
          '}',
      inputPath: input.path,
      outputPath: output.path,
      customOptions: json.encode({'ads': false}),
      token: 1,
    );

    expect(json.decode(output.readAsStringSync()), {
      'mode': 'global',
      'rules': ['MATCH,DIRECT'],
      'proxy-providers': <String, dynamic>{},
      'flags': {'ads': false},
    });
    expect(result.logs.single.text, 'rules 1');
  });

  test('reports a failing script without writing output', () async {
    final input = write('failing.json', '{}');
    final output = File('${directory.path}/failing-output.json');

    await expectLater(
      evaluateScriptFile(
        script: "function main() { throw new Error('boom') }",
        inputPath: input.path,
        outputPath: output.path,
        token: 2,
      ),
      throwsA(
        isA<ScriptError>()
            .having((e) => e.kind, 'kind', ScriptErrorKind.runtime)
            .having((e) => e.message, 'message', contains('boom')),
      ),
    );
    expect(output.existsSync(), isFalse);
  });

  test('extracts script options', () async {
    final options = json.decode(
      await extractScriptOptions(
        script:
            'const ruleOptionsEnable = { ai: true };\n'
            "const serviceConfigs = [{ name: 'AI', icon: 'ai.png' }];\n"
            "const Compatible_With_Bettbox = { policyGroupOptions: ['AI'] };\n"
            'function main(config) { return config }',
      ),
    );

    expect(options, {
      'options': {'ai': true},
      'icons': {'AI': 'ai.png'},
      'policyGroupOptions': ['AI'],
    });
  });
}
