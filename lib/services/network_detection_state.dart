import 'dart:async';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/state.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// 网络检测（本机 IP 归属地）状态机：请求去重、出口节点变更重查、
/// IP 隐私打码与失败后的手动刷新引导。
class DetectionState {
  static DetectionState? _instance;
  bool? _preIsStart;
  int _requestId = 0;
  CancelToken? _cancelToken;
  bool _isIpMasked = false;
  IpInfo? _rawIpInfo;
  bool _isFirstLaunch = true;
  String? _lastCheckedOutboundNode;
  String? _pendingCheckKey;
  bool _recheckOnFailure = false;
  bool _pendingInit = false;

  final state = ValueNotifier<NetworkDetectionState>(
    const NetworkDetectionState(
      isLoading: true,
      ipInfo: null,
      errorMessage: null,
    ),
  );

  DetectionState._internal();

  factory DetectionState() {
    _instance ??= DetectionState._internal();
    return _instance!;
  }

  bool get isIpMasked => _isIpMasked;
  IpInfo? get rawIpInfo => _rawIpInfo;

  IpInfo? _maskIpInfo(IpInfo? ipInfo) {
    if (ipInfo == null) return null;
    return _isIpMasked ? ipInfo.copyWith(ip: '*** *** *** ***') : ipInfo;
  }

  void toggleIpPrivacy() {
    _isIpMasked = !_isIpMasked;
    if (_rawIpInfo != null) {
      state.value = state.value.copyWith(ipInfo: _maskIpInfo(_rawIpInfo));
    }
  }

  void manualRefresh() {
    _rawIpInfo = null;
    _isIpMasked = false;
    state.value = state.value.copyWith(
      isLoading: true,
      ipInfo: null,
      errorMessage: null,
    );
    startCheck(immediate: true, showLoading: true, force: true);
  }

  void _onIpProgress(int requestId, IpInfo info) {
    if (requestId != _requestId) return;
    _rawIpInfo = info;
    _lastCheckedOutboundNode = globalState.getCurrentOutboundNode();
    state.value = state.value.copyWith(
      isLoading: false,
      ipInfo: _maskIpInfo(_rawIpInfo),
      errorMessage: null,
    );
  }

  Future<void> switchToDomesticIp() async {
    _rawIpInfo = null;
    _isIpMasked = false;

    _cancelPreviousRequest();
    _cancelToken = CancelToken();
    final requestId = ++_requestId;

    state.value = state.value.copyWith(
      isLoading: true,
      ipInfo: null,
      errorMessage: null,
    );

    final res = await request.checkIpDomestic(
      cancelToken: _cancelToken,
      onUpdate: (info) => _onIpProgress(requestId, info),
    );

    if (requestId != _requestId) return;

    _handleResponse(res);
  }

  void startCheck({
    bool immediate = false,
    bool showLoading = false,
    bool force = false,
  }) {
    final appState = globalState.appState;
    if (!appState.isInit) {
      _pendingInit = true;
      return;
    }

    state.value = state.value.copyWith(isLoading: true, errorMessage: null);

    final delay = immediate
        ? Duration.zero
        : const Duration(milliseconds: 1000);

    debouncer.call(
      FunctionTag.checkIp,
      () => _checkIp(showLoading: showLoading, force: force),
      duration: delay,
    );
  }

  void flushPendingCheck() {
    if (!_pendingInit) return;
    _pendingInit = false;
    debouncer.call(
      FunctionTag.checkIp,
      _checkIp,
      duration: const Duration(seconds: 2),
    );
  }

  void tryStartCheck() {
    if (!globalState.hasNetworkDetectionWidget) return;
    if (!state.value.isLoading &&
        state.value.ipInfo == null &&
        (_preIsStart == null || state.value.errorMessage != null)) {
      startCheck();
    }
  }

  void checkOnForegroundResume() {
    if (!globalState.hasNetworkDetectionWidget) return;
    final currentNode = globalState.getCurrentOutboundNode();
    if (state.value.ipInfo != null &&
        _lastCheckedOutboundNode == currentNode &&
        state.value.errorMessage == null) {
      return;
    }
    _lastCheckedOutboundNode = currentNode;
    startCheck(showLoading: state.value.ipInfo == null);
  }

  void _cancelPreviousRequest() {
    _cancelToken?.cancel();
    _cancelToken = null;
    _pendingCheckKey = null;
  }

  void _handleResponse(Result<IpInfo?> res) {
    if (res.isError) {
      if (res.message == 'cancelled') {
        state.value = state.value.copyWith(
          isLoading: false,
          errorMessage: null,
        );
        return;
      }
      if (state.value.ipInfo == null) {
        _rawIpInfo = null;
        state.value = state.value.copyWith(
          isLoading: false,
          ipInfo: null,
          errorMessage: appLocalizations.tryManualRefresh,
        );
      } else {
        state.value = state.value.copyWith(isLoading: false);
      }
      return;
    }

    if (res.data != null) {
      _rawIpInfo = res.data;
      _lastCheckedOutboundNode = globalState.getCurrentOutboundNode();
    }
    state.value = state.value.copyWith(
      isLoading: false,
      ipInfo: _maskIpInfo(_rawIpInfo),
      errorMessage: _rawIpInfo != null
          ? null
          : (state.value.ipInfo == null
                ? appLocalizations.tryManualRefresh
                : null),
    );
  }

  Future<void> _checkIp({bool showLoading = false, bool force = false}) async {
    final appState = globalState.appState;

    if (!appState.isInit) return;

    final isStart = appState.runTime != null;
    final checkKey = '$isStart|${globalState.getCurrentOutboundNode()}';
    if (!force && _pendingCheckKey == checkKey) {
      _recheckOnFailure = true;
      return;
    }

    final isStateChanged = _preIsStart != isStart;
    _preIsStart = isStart;

    if (!isStart &&
        _rawIpInfo != null &&
        !state.value.isLoading &&
        !isStateChanged) {
      return;
    }

    _cancelPreviousRequest();
    _cancelToken = CancelToken();
    _pendingCheckKey = checkKey;
    _recheckOnFailure = false;
    final requestId = ++_requestId;

    final shouldShowLoading =
        showLoading || state.value.ipInfo == null || isStateChanged;
    if (shouldShowLoading) {
      _rawIpInfo = null;
      state.value = state.value.copyWith(
        isLoading: true,
        errorMessage: null,
        ipInfo: isStateChanged ? null : state.value.ipInfo,
      );
    }

    final timeout = const Duration(seconds: 8);

    final res = isStart
        ? await request.checkIp(
            cancelToken: _cancelToken,
            timeout: timeout,
            onUpdate: (info) => _onIpProgress(requestId, info),
          )
        : await request.checkIpDomestic(
            cancelToken: _cancelToken,
            timeout: timeout,
            onUpdate: (info) => _onIpProgress(requestId, info),
          );

    if (requestId != _requestId) return;
    _pendingCheckKey = null;

    final isFailed = res.isError || res.data == null;
    final isFirstLaunch = _isFirstLaunch;
    _isFirstLaunch = false;
    _handleResponse(res);
    if (!isFailed) return;

    if (_recheckOnFailure) {
      startCheck();
      return;
    }
    if (isFirstLaunch) {
      Future.delayed(const Duration(seconds: 3), () {
        if (state.value.ipInfo == null && !state.value.isLoading) {
          startCheck();
        }
      });
    }
  }
}

final detectionState = DetectionState();
