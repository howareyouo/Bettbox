import 'dart:async';
import 'dart:io';

import 'package:bett_box/enum/enum.dart';

class Debouncer {
  final Map<FunctionTag, Timer?> _operations = {};

  void call(
    FunctionTag tag,
    Function func, {
    List<dynamic>? args,
    Duration duration = const Duration(milliseconds: 600),
  }) {
    final timer = _operations[tag];
    if (timer != null) {
      timer.cancel();
    }
    _operations[tag] = Zone.root.run(() {
      return Timer(duration, () {
        _operations[tag]?.cancel();
        _operations.remove(tag);
        Zone.root.run(() {
          Function.apply(func, args);
        });
      });
    });
  }

  void cancel(dynamic tag) {
    _operations[tag]?.cancel();
    _operations[tag] = null;
  }
}

class Throttler {
  final Map<FunctionTag, Timer?> _operations = {};

  bool call(
    FunctionTag tag,
    Function func, {
    List<dynamic>? args,
    Duration duration = const Duration(milliseconds: 600),
  }) {
    final timer = _operations[tag];
    if (timer != null) {
      return true;
    }
    _operations[tag] = Zone.root.run(() {
      return Timer(duration, () {
        _operations[tag]?.cancel();
        _operations.remove(tag);
        Zone.root.run(() {
          Function.apply(func, args);
        });
      });
    });
    return false;
  }

  void cancel(dynamic tag) {
    _operations[tag]?.cancel();
    _operations[tag] = null;
  }
}

final debouncer = Debouncer();

final throttler = Throttler();

String formatSpeedValue(double bps) {
  final mbps = bps / 1e6;
  if (mbps >= 1000) return (mbps / 1000).toStringAsFixed(2);
  return mbps.toStringAsFixed(1);
}

String formatSpeedUnit(double bps) => bps / 1e6 >= 1000 ? 'Gbps' : 'Mbps';

/// Writes [contents] to [path] via a temp file so readers never observe a torn
/// file; falls back to copy+delete when rename is blocked (e.g. Windows AV).
Future<void> atomicWriteString(String path, String contents) async {
  final tempFile = File('$path.${DateTime.now().microsecondsSinceEpoch}.tmp');
  await tempFile.parent.create(recursive: true);
  await tempFile.writeAsString(contents, flush: true);
  try {
    await tempFile.rename(path);
  } catch (_) {
    await tempFile.copy(path);
    await tempFile.delete();
  }
}
