import 'dart:io';

import 'package:bett_box/common/common.dart';

const List<String> externalEditorCandidates = [
  'code',
  'subl',
  'codium',
  'notepad++',
];

const Map<String, String> externalEditorDescriptions = {
  'code': 'VS Code',
  'subl': 'Sublime Text',
  'codium': 'VSCodium',
  'notepad++': 'Notepad++',
};

String externalEditorLabel(String command) {
  if (command.isEmpty) return '';
  final description = externalEditorDescriptions[command];
  if (description == null) return command;
  return '$command ($description)';
}

Future<List<String>> detectExternalEditors() async {
  final available = <String>[];
  for (final command in externalEditorCandidates) {
    if (await _commandExists(command)) {
      available.add(command);
    }
  }
  return available;
}

Future<bool> _commandExists(String command) async {
  try {
    final result = await Process.run(
      system.isWindows ? 'where' : 'which',
      [command],
    );
    return result.exitCode == 0;
  } on Object catch (_) {
    return false;
  }
}

Future<bool> launchExternalEditor(String path, String configured) async {
  final command = configured.isNotEmpty ? configured : 'code';
  try {
    final result = await Process.run(
      system.isWindows ? 'cmd' : command,
      system.isWindows ? ['/c', command, path] : [path],
    );
    return result.exitCode == 0;
  } on Object catch (e) {
    commonPrint.error('Failed to launch external editor: $e');
    return false;
  }
}
