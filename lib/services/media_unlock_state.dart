import 'dart:async';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/foundation.dart';

/// 流媒体解锁检测状态机：单平台/批量/置顶检测、节点切换与前台恢复触发、
/// 进度节流合并。
class MediaUnlockStateNotifier {
  static MediaUnlockStateNotifier? _instance;
  final _checker = MediaUnlockChecker();
  int _requestId = 0;
  int _epoch = 0;
  Timer? _nodeChangeTimer;
  static const _nodeChangeDelay = Duration(milliseconds: 800);
  String? _lastCheckedOutboundNode;
  bool? _preIsStart;

  final state = ValueNotifier<MediaUnlockState>(const MediaUnlockState());
  final Set<MediaPlatform> _batchTestingPlatforms = {};

  bool isBatchChecking([Iterable<MediaPlatform>? platforms]) {
    if (state.value.isLoading) return true;
    if (platforms == null) {
      return state.value.testingPlatforms.any(_batchTestingPlatforms.contains);
    }
    return platforms.any(
      (p) =>
          state.value.testingPlatforms.contains(p) &&
          _batchTestingPlatforms.contains(p),
    );
  }

  MediaUnlockStateNotifier._internal();

  factory MediaUnlockStateNotifier() {
    _instance ??= MediaUnlockStateNotifier._internal();
    return _instance!;
  }

  List<MediaPlatform> get pinnedPlatforms {
    final pinned = globalState.config.appSetting.pinnedMediaPlatforms;
    return (pinned.isNotEmpty ? pinned : defaultPinnedMediaPlatforms)
        .take(3)
        .toList();
  }

  void cancelUnattended() {
    if (globalState.hasMediaUnlockWidget) return;
    if (!state.value.isLoading && state.value.testingPlatforms.isEmpty) return;
    _epoch++;
    _requestId++;
    _checker.cancel();
    state.value = state.value.copyWith(isLoading: false);
  }

  void checkSingle(MediaPlatform platform) async {
    final epoch = _epoch;
    _batchTestingPlatforms.remove(platform);
    if (state.value.testingPlatforms.contains(platform)) return;
    final currentTesting = Set<MediaPlatform>.from(state.value.testingPlatforms)
      ..add(platform);
    state.value = state.value.copyWith(testingPlatforms: currentTesting);

    try {
      final res = await _checker
          .checkPlatform(platform)
          .timeout(
            const Duration(seconds: 8),
            onTimeout: () => MediaUnlockResult(
              platform: platform,
              status: MediaUnlockStatus.failed,
            ),
          );
      if (epoch != _epoch) return;
      final finalMap = Map<MediaPlatform, MediaUnlockResult>.from(
        state.value.results,
      );
      finalMap[platform] = res;
      state.value = state.value.copyWith(
        results: finalMap,
        lastChecked: DateTime.now(),
      );
    } catch (_) {
      if (epoch != _epoch) return;
      final finalMap = Map<MediaPlatform, MediaUnlockResult>.from(
        state.value.results,
      );
      finalMap.putIfAbsent(
        platform,
        () => MediaUnlockResult(
          platform: platform,
          status: MediaUnlockStatus.failed,
        ),
      );
      state.value = state.value.copyWith(
        results: finalMap,
        lastChecked: DateTime.now(),
      );
    } finally {
      final nextTesting = Set<MediaPlatform>.from(state.value.testingPlatforms)
        ..remove(platform);
      state.value = state.value.copyWith(testingPlatforms: nextTesting);
    }
  }

  void checkPlatforms(
    List<MediaPlatform> platforms, {
    bool force = false,
    bool isFullCheck = false,
    bool isBatchCheck = false,
  }) async {
    final isRunning = globalState.appState.runTime != null;
    if (!isRunning && !force) return;

    if (force) {
      _checker.cancel();
    }

    final targetPlatforms = force
        ? platforms.toList()
        : platforms
              .where((p) => !state.value.testingPlatforms.contains(p))
              .toList();
    if (targetPlatforms.isEmpty) return;

    final requestId = ++_requestId;
    if (isBatchCheck) {
      _batchTestingPlatforms.addAll(targetPlatforms);
    }
    final pendingTesting = Set<MediaPlatform>.from(state.value.testingPlatforms)
      ..addAll(targetPlatforms);

    state.value = state.value.copyWith(
      isLoading: isFullCheck ? true : state.value.isLoading,
      testingPlatforms: pendingTesting,
    );

    Timer? throttleTimer;
    final bufferResults = <MediaPlatform, MediaUnlockResult>{};

    void flushUpdates() {
      throttleTimer?.cancel();
      throttleTimer = null;
      if (bufferResults.isEmpty) return;
      final updates = Map<MediaPlatform, MediaUnlockResult>.from(bufferResults);
      bufferResults.clear();
      final nextResults = Map<MediaPlatform, MediaUnlockResult>.from(
        state.value.results,
      )..addAll(updates);
      final nextTesting = Set<MediaPlatform>.from(state.value.testingPlatforms)
        ..removeAll(updates.keys);
      state.value = state.value.copyWith(
        results: nextResults,
        testingPlatforms: nextTesting,
      );
    }

    try {
      final results = await _checker
          .checkAll(
            platforms: targetPlatforms,
            onProgress: (res) {
              if (requestId != _requestId) return;
              bufferResults[res.platform] = res;
              throttleTimer ??= Timer(
                const Duration(milliseconds: 100),
                flushUpdates,
              );
            },
          )
          .timeout(
            Duration(seconds: (targetPlatforms.length / 8).ceil() * 8 + 5),
            onTimeout: () {
              _checker.cancel();
              final timeoutMap = <MediaPlatform, MediaUnlockResult>{};
              for (final p in targetPlatforms) {
                timeoutMap[p] =
                    bufferResults[p] ??
                    state.value.results[p] ??
                    MediaUnlockResult(
                      platform: p,
                      status: MediaUnlockStatus.failed,
                    );
              }
              return timeoutMap;
            },
          );
      if (requestId != _requestId) return;
      flushUpdates();
      final nextResults = Map<MediaPlatform, MediaUnlockResult>.from(
        state.value.results,
      );
      for (final p in targetPlatforms) {
        nextResults[p] =
            results[p] ??
            bufferResults[p] ??
            state.value.results[p] ??
            MediaUnlockResult(platform: p, status: MediaUnlockStatus.failed);
      }
      _lastCheckedOutboundNode = globalState.getCurrentOutboundNode();
      state.value = state.value.copyWith(
        isLoading: isFullCheck ? false : state.value.isLoading,
        results: nextResults,
        lastChecked: DateTime.now(),
      );
    } catch (_) {
      throttleTimer?.cancel();
      if (requestId != _requestId) return;
      flushUpdates();
      final fallbackResults = Map<MediaPlatform, MediaUnlockResult>.from(
        state.value.results,
      );
      for (final p in targetPlatforms) {
        fallbackResults.putIfAbsent(
          p,
          () =>
              MediaUnlockResult(platform: p, status: MediaUnlockStatus.failed),
        );
      }
      _lastCheckedOutboundNode = globalState.getCurrentOutboundNode();
      state.value = state.value.copyWith(
        isLoading: isFullCheck ? false : state.value.isLoading,
        results: fallbackResults,
        lastChecked: DateTime.now(),
      );
    } finally {
      throttleTimer?.cancel();
      _batchTestingPlatforms.removeAll(targetPlatforms);
      final nextTesting = Set<MediaPlatform>.from(state.value.testingPlatforms)
        ..removeAll(targetPlatforms);
      state.value = state.value.copyWith(
        isLoading: (requestId == _requestId && isFullCheck)
            ? false
            : state.value.isLoading,
        testingPlatforms: nextTesting,
      );
    }
  }

  void checkPinned({bool force = false, List<MediaPlatform>? platforms}) {
    checkPlatforms(platforms ?? pinnedPlatforms, force: force);
  }

  void checkAll({bool force = false, List<MediaPlatform>? platforms}) {
    final showMoreStreaming =
        globalState.config.appSetting.mediaUnlockMoreStreamingPlatforms;
    final allAvailable = MediaPlatform.values
        .where((p) => showMoreStreaming || !moreStreamingPlatforms.contains(p))
        .toList();
    final targets = platforms ?? allAvailable;
    final isFull = targets.length >= allAvailable.length;
    checkPlatforms(
      targets,
      force: force,
      isFullCheck: isFull,
      isBatchCheck: true,
    );
  }

  void startCheckOnNodeChange() async {
    final isRunning = globalState.appState.runTime != null;
    if (!isRunning) {
      _preIsStart = false;
      _nodeChangeTimer?.cancel();
      return;
    }
    final isStartup = _preIsStart != true;
    _preIsStart = true;

    if (!globalState.hasMediaUnlockWidget) return;
    if (!globalState.config.appSetting.mediaUnlockRefreshOnNodeChange) return;

    if (isStartup) {
      _nodeChangeTimer?.cancel();
      _checker.cancel();
      final requestId = ++_requestId;

      if (globalState.hasNetworkDetectionWidget) {
        var waited = 0;
        while (detectionState.state.value.isLoading &&
            waited < 6000 &&
            globalState.appState.runTime != null &&
            requestId == _requestId) {
          await Future.delayed(const Duration(milliseconds: 150));
          waited += 150;
        }
      } else {
        await Future.delayed(const Duration(seconds: 2));
      }
      if (requestId != _requestId || globalState.appState.runTime == null) {
        return;
      }
      final nextResults = Map<MediaPlatform, MediaUnlockResult>.from(
        state.value.results,
      );
      for (final p in pinnedPlatforms) {
        nextResults.remove(p);
      }
      state.value = state.value.copyWith(
        results: nextResults,
        testingPlatforms: {},
        isLoading: false,
      );
      _lastCheckedOutboundNode = globalState.getCurrentOutboundNode();
      checkPinned(force: true);
      return;
    }

    _nodeChangeTimer?.cancel();
    _nodeChangeTimer = Timer(_nodeChangeDelay, () {
      if (globalState.appState.runTime == null) return;
      if (globalState.backgroundMode.value) return;

      final currentNode = globalState.getCurrentOutboundNode();
      if (_lastCheckedOutboundNode == currentNode &&
          state.value.results.isNotEmpty) {
        return;
      }
      _lastCheckedOutboundNode = currentNode;
      final nextResults = Map<MediaPlatform, MediaUnlockResult>.from(
        state.value.results,
      );
      for (final p in pinnedPlatforms) {
        nextResults.remove(p);
      }
      state.value = state.value.copyWith(
        results: nextResults,
        testingPlatforms: {},
        isLoading: false,
      );
      checkPinned(force: true);
    });
  }

  void checkOnForegroundResume() {
    final isRunning = globalState.appState.runTime != null;
    if (!isRunning) return;
    if (!globalState.hasMediaUnlockWidget) return;
    if (!globalState.config.appSetting.mediaUnlockRefreshOnNodeChange) return;
    if (state.value.isLoading || state.value.testingPlatforms.isNotEmpty) {
      return;
    }
    final currentNode = globalState.getCurrentOutboundNode();
    if (state.value.results.isNotEmpty &&
        _lastCheckedOutboundNode == currentNode) {
      return;
    }
    _lastCheckedOutboundNode = currentNode;
    final nextResults = Map<MediaPlatform, MediaUnlockResult>.from(
      state.value.results,
    );
    for (final p in pinnedPlatforms) {
      nextResults.remove(p);
    }
    state.value = state.value.copyWith(
      results: nextResults,
      testingPlatforms: {},
      isLoading: false,
    );
    checkPinned(force: true);
  }

  void tryStartCheck() {
    final isRunning = globalState.appState.runTime != null;
    if (!isRunning) return;
    if (!globalState.hasMediaUnlockWidget) return;
    if (state.value.isLoading || state.value.testingPlatforms.isNotEmpty) {
      return;
    }
    if (state.value.results.isNotEmpty) return;
    final needsInitialCheck = pinnedPlatforms.any(
      (p) => !state.value.results.containsKey(p),
    );
    if (!needsInitialCheck) return;
    checkPinned();
  }
}

final mediaUnlockState = MediaUnlockStateNotifier();
