import 'dart:async';
import 'dart:io';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/dialog.dart';
import 'package:bett_box/widgets/input.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

/// Opens scripts in an external editor and watches the file so changes made
/// outside the app are synced back automatically.
class ExternalScriptEditorWatcher {
  final Map<String, StreamSubscription<FileSystemEvent>> _editSubscriptions =
      {};
  final Map<String, Timer> _editDebounces = {};
  bool _disposed = false;

  void dispose() {
    _disposed = true;
    for (final subscription in _editSubscriptions.values) {
      subscription.cancel();
    }
    _editSubscriptions.clear();
    for (final timer in _editDebounces.values) {
      timer.cancel();
    }
    _editDebounces.clear();
  }

  Future<void> open({
    required WidgetRef ref,
    Script? script,
    String? initialContent,
    String? url,
  }) async {
    final res = await globalState.appController.safeRun<bool>(
      () async {
        var target = script;
        if (target == null) {
          final label = ref
              .read(scriptStateProvider.notifier)
              .getAvailableLabel(appLocalizations.unnamed);
          final draft = Script.create(label: label, url: url);
          target = await draft.writeContent(initialContent ?? '');
          ref.read(scriptStateProvider.notifier).setScript(target);
        }
        final path = await appPath.getScriptPath(target.id);
        final content = await target.readContent();
        final file = File(path);
        await file.parent.create(recursive: true);
        await file.writeAsString(content, flush: true);
        final ok = await launchExternalEditor(
          path,
          ref.read(appSettingProvider).externalEditor,
        );
        if (ok) {
          _watchScriptFile(ref, target);
        }
        return ok;
      },
      needLoading: false,
      title: appLocalizations.tip,
    );
    if (res != true) {
      globalState.showMessage(
        message: TextSpan(
          text: appLocalizations.externalEditorLaunchFailed(
            ref.read(appSettingProvider).externalEditor,
          ),
        ),
        cancelable: false,
      );
      return;
    }
    globalState.showNotifier(appLocalizations.externalEditorTip);
  }

  void _watchScriptFile(WidgetRef ref, Script script) {
    if (_editSubscriptions.containsKey(script.id)) {
      return;
    }
    unawaited(() async {
      final path = await appPath.getScriptPath(script.id);
      if (_disposed) {
        return;
      }
      final subscription = File(path)
          .watch(
            events: FileSystemEvent.modify |
                FileSystemEvent.create |
                FileSystemEvent.move,
          )
          .listen(
            (_) => _scheduleScriptSync(ref, script),
            onError: (_) {},
            cancelOnError: false,
          );
      if (_disposed) {
        await subscription.cancel();
        return;
      }
      _editSubscriptions[script.id] = subscription;
    }());
  }

  void _scheduleScriptSync(WidgetRef ref, Script script) {
    _editDebounces.remove(script.id)?.cancel();
    _editDebounces[script.id] = Timer(
      const Duration(milliseconds: 600),
      () => _syncScriptFromFile(ref, script),
    );
  }

  Future<void> _syncScriptFromFile(WidgetRef ref, Script script) async {
    await globalState.appController.safeRun(
      () async {
        final newScript = await script.writeContent(
          await script.readContent(),
        );
        if (newScript == script) {
          return;
        }
        ref.read(scriptStateProvider.notifier).setScript(newScript);
      },
    );
  }
}

/// Dialog for picking the external editor executable.
class ExternalEditorDialog extends ConsumerStatefulWidget {
  const ExternalEditorDialog({super.key});

  @override
  ConsumerState<ExternalEditorDialog> createState() =>
      _ExternalEditorDialogState();
}

class _ExternalEditorDialogState extends ConsumerState<ExternalEditorDialog> {
  late String _selected;
  final _customController = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final configured = ref.read(appSettingProvider).externalEditor;
    _selected = configured;
    _customController.text = configured;
  }

  @override
  void dispose() {
    _customController.dispose();
    super.dispose();
  }

  Future<void> _handleSave() async {
    if (_saving) return;
    _saving = true;
    try {
      final custom = _customController.text.trim();
      var target = custom.isNotEmpty ? custom : _selected;
      if (target.isNotEmpty && !(await editorCommandExists(target))) {
        if (!mounted) return;
        final path = await globalState.showCommonDialog<String>(
          child: InputDialog(
            title: appLocalizations.externalEditorNotFound,
            value: target,
            labelText: appLocalizations.externalEditor,
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return appLocalizations.emptyTip(appLocalizations.value);
              }
              return null;
            },
          ),
        );
        if (!mounted || path == null) return;
        target = path.trim();
      }
      if (!mounted) return;
      ref.read(appSettingProvider.notifier).updateState(
        (state) => state.copyWith(externalEditor: target),
      );
      Navigator.of(context).pop();
    } finally {
      _saving = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return CommonDialog(
      title: appLocalizations.externalEditor,
      child: RadioGroup<String>(
        groupValue: _selected,
        onChanged: (value) {
          setState(() {
            _selected = value ?? '';
            _customController.text = '';
          });
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final option in externalEditorCandidates)
              RadioListTile<String>(
                value: option,
                title: Text(externalEditorLabel(option)),
              ),
            RadioListTile<String>(
              value: '',
              title: Text(appLocalizations.autoDetect),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _customController,
              decoration: InputDecoration(
                hintText: 'Custom Editor',
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(appLocalizations.cancel),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _saving ? null : _handleSave,
                  child: Text(appLocalizations.done),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}