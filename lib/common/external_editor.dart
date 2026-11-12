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

/// Whether [command] resolves to an executable on the current system.
///
/// Accepts either a command name on `PATH` or an absolute path to an
/// executable file.
Future<bool> editorCommandExists(String command) async {
  final trimmed = command.trim();
  // `where`/`which` treat path-like patterns as path:pattern specs and fail
  // on explicit paths, so check those directly as files.
  if (trimmed.contains(Platform.pathSeparator) || trimmed.contains('/')) {
    return File(trimmed).existsSync();
  }
  try {
    final result = await Process.run(
      system.isWindows ? 'where' : 'which',
      [trimmed],
    );
    return result.exitCode == 0;
  } on Object catch (_) {
    return false;
  }
}

/// Launches the editor without waiting for it to exit.
///
/// On Windows the command is started through `start /B` so no console window
/// flashes on screen; every other platform spawns the editor detached.
Future<bool> launchExternalEditor(String path, String configured) async {
  final command = configured.isNotEmpty ? configured : 'code';
  try {
    if (system.isWindows) {
      final result = await Process.run('cmd', [
        '/c',
        'start',
        '',
        '/B',
        command,
        path,
      ]);
      return result.exitCode == 0;
    }
    await Process.start(
      command,
      [path],
      mode: ProcessStartMode.detached,
    );
    return true;
  } on Object catch (e) {
    commonPrint.error('Failed to launch external editor: $e');
    return false;
  }
}