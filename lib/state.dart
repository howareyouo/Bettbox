import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/common/theme.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/l10n/l10n.dart';
import 'package:bett_box/plugins/app.dart';
import 'package:bett_box/plugins/service.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/providers/state.dart' as providers_state;

import 'package:bett_box/widgets/dialog.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as flutter_riverpod;
import 'package:material_color_utilities/palettes/core_palette.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'clash/config_compiler.dart';
import 'common/common.dart';
import 'controller.dart';
import 'models/models.dart';
import 'services/dashboard_refresh_manager.dart';

// 仪表盘/检测/解锁三个状态单体的新家；再导出维持既有消费方导入路径。
export 'services/dashboard_refresh_manager.dart';
export 'services/media_unlock_state.dart';
export 'services/network_detection_state.dart';

typedef UpdateTasks = List<FutureOr Function()>;

class GlobalState {
  static GlobalState? _instance;
  Map<CacheTag, FixedMap<String, double>> computeHeightMapCache = {};
  bool isService = false;
  bool isExiting = false;
  bool isScreenOn = true;
  Timer? timer;
  Timer? groupsUpdateTimer;
  Config? _config;

  bool get hasConfig => _config != null;

  Config get config =>
      _config ??
      Config(
        themeProps: defaultThemeProps,
        patchClashConfig: system.isAndroid
            ? const ClashConfig(findProcessMode: FindProcessMode.always)
            : defaultClashConfig,
        networkProps: defaultNetworkProps,
        appSetting: defaultAppSettingProps,
      );

  set config(Config value) => _config = value;
  late AppState appState;
  bool isPre = true;
  String? coreSHA256;
  late PackageInfo packageInfo;
  Function? updateCurrentDelayDebounce;
  VoidCallback? focusDashboardStartSwitch;
  bool isDashboardStartSwitchFocused = false;
  late Measure measure;
  late CommonTheme theme;
  late Color accentColor;
  // ignore: deprecated_member_use
  CorePalette? corePalette;
  DateTime? startTime;
  UpdateTasks tasks = [];
  final navigatorKey = GlobalKey<NavigatorState>();
  final backgroundMode = ValueNotifier<bool>(false);
  final animationEnabled = ValueNotifier<bool>(true);
  AppController? _appController;
  bool? _isAndroidTV;
  int _taskLoopToken = 0;
  bool _isExecutingTasks = false;
  bool _needsTaskRestart = false;
  Timer? _backgroundCoreGcTimer;
  Timer? _backgroundCleanupTimer;
  /// 配置编译器：内核 setup/patch 参数编译与脚本求值（clash/ 层）。
  late final ConfigCompiler _compiler = ConfigCompiler(
    version: () => packageInfo.version,
    buildNumber: () => packageInfo.buildNumber,
    onScriptError: showNotifier,
  );
  bool isInit = false;

  bool get hasMediaUnlockWidget {
    final widgets = system.isAndroid
        ? config.appSetting.mobileDashboardWidgets
        : config.appSetting.desktopDashboardWidgets;
    return widgets.contains(DashboardWidget.mediaUnlock) ||
        widgets.contains(DashboardWidget.mediaUnlockSmall);
  }

  bool get hasNetworkDetectionWidget {
    final widgets = system.isAndroid
        ? config.appSetting.mobileDashboardWidgets
        : config.appSetting.desktopDashboardWidgets;
    return widgets.contains(DashboardWidget.networkDetection);
  }

  String getCurrentOutboundNode() {
    final mode = config.patchClashConfig.mode;
    if (mode == Mode.direct) {
      return UsedProxy.DIRECT.name;
    }
    final profile = config.currentProfile;
    final selectedMap = profile?.selectedMap ?? const <String, String>{};
    final groups = appState.groups;
    if (mode == Mode.global) {
      var name = UsedProxy.GLOBAL.name;
      final visited = <String>{};
      while (visited.add(name)) {
        final next = groups.getGroup(name)?.now ?? selectedMap[name];
        if (next == null || next.isEmpty) break;
        name = next;
      }
      return '${profile?.id}|${mode.name}|$name';
    }
    final selected = groups.isEmpty
        ? selectedMap.entries.map((e) => '${e.key}:${e.value}')
        : groups.map((g) => '${g.name}:${g.realNow}');
    return '${profile?.id}|${mode.name}|${selected.join(';')}';
  }

  bool get isStart => startTime != null && startTime!.isBeforeNow;

  AppController get appController => _appController!;

  set appController(AppController appController) {
    _appController = appController;
    clashService?.onCoreLostRestart = appController.restartCore;
    isInit = true;
  }

  GlobalState._internal();

  factory GlobalState() {
    _instance ??= GlobalState._internal();
    return _instance!;
  }

  Future<void> initApp(int version) async {
    isExiting = false;
    if (system.isLinux && appPath.isAppImage) {
      await appPath.ensureAppImageCoreSynced();
    }
    coreSHA256 = const String.fromEnvironment('CORE_SHA256');
    if (system.isWindows &&
        !kDebugMode &&
        (coreSHA256 == null || coreSHA256!.isEmpty)) {
      coreSHA256 = await _calcCoreSHA256();
    }
    isPre = const String.fromEnvironment('APP_ENV') != 'stable';
    appState = AppState(
      brightness: WidgetsBinding.instance.platformDispatcher.platformBrightness,
      version: version,
      viewSize: Size.zero,
      requests: FixedList(maxLength),
      logs: FixedList(maxLogLength),
      traffics: FixedList(30),
      totalTraffic: Traffic(),
      systemUiOverlayStyle: const SystemUiOverlayStyle(),
    );
    await _initDynamicColor();
    await init();
  }

  Future<String?> getOrCalcCoreSHA256() async {
    if (coreSHA256 != null && coreSHA256!.isNotEmpty) return coreSHA256;
    coreSHA256 = await _calcCoreSHA256();
    return coreSHA256;
  }

  Future<String?> _calcNativeSHA256(String path) async {
    try {
      ProcessResult result;
      if (Platform.isWindows) {
        result = await Process.run('certutil', ['-hashfile', path, 'SHA256']);
      } else if (Platform.isMacOS) {
        result = await Process.run('shasum', ['-a', '256', path]);
      } else if (Platform.isLinux) {
        result = await Process.run('sha256sum', [path]);
      } else {
        return null;
      }

      if (result.exitCode != 0) return null;
      final output = result.stdout.toString();
      final clean = output.replaceAll(' ', '');
      final match = RegExp(r'[0-9a-fA-F]{64}').firstMatch(clean);
      return match?.group(0)?.toLowerCase();
    } catch (_) {
      return null;
    }
  }

  Future<String?> _calcCoreSHA256() async {
    try {
      final path = appPath.corePath;
      final file = File(path);
      if (!await file.exists()) return null;

      final nativeHash = await _calcNativeSHA256(path);
      if (nativeHash != null && nativeHash.isNotEmpty) {
        return nativeHash;
      }

      return await Isolate.run(() async {
        final digest = await sha256.bind(File(path).openRead()).first;
        return digest.toString();
      });
    } catch (e) {
      commonPrint.warn('Failed to calculate core SHA256: $e');
      return null;
    }
  }

  Future<void> _initDynamicColor() async {
    try {
      corePalette = await DynamicColorPlugin.getCorePalette();
      accentColor =
          await DynamicColorPlugin.getAccentColor() ??
          Color(defaultPrimaryColor);
    } catch (_) {}
  }

  Future<void> init() async {
    packageInfo = await PackageInfo.fromPlatform();
    if (system.isAndroid) {
      _isAndroidTV = await app.isAndroidTV();
    }
    config =
        await preferences.getConfig() ??
        Config(
          themeProps: defaultThemeProps,
          patchClashConfig: system.isAndroid
              ? const ClashConfig(findProcessMode: FindProcessMode.always)
              : defaultClashConfig,
          networkProps: defaultNetworkProps,
          appSetting: defaultAppSettingProps,
        );
    final scriptProps = await config.scriptProps.externalize();
    if (scriptProps != config.scriptProps) {
      config = config.copyWith(scriptProps: scriptProps);
      await preferences.saveConfig(config);
    }
    await globalState.migrateOldData(config);
    final locale =
        utils.getLocaleForString(config.appSetting.locale) ??
        utils.getSystemLocale();
    await AppLocalizations.load(locale);
  }

  bool get isAndroidTV => _isAndroidTV ?? false;

  @visibleForTesting
  set isAndroidTV(bool value) => _isAndroidTV = value;

  String get ua => config.patchClashConfig.globalUa ?? packageInfo.ua;

  Future<void> startUpdateTasks([UpdateTasks? tasks]) async {
    if (tasks != null) {
      this.tasks = tasks;
    }
    final token = ++_taskLoopToken;
    timer?.cancel();
    timer = null;
    if (_isExecutingTasks) {
      _needsTaskRestart = true;
      return;
    }
    await _runUpdateLoop(token);
  }

  Future<void> _runUpdateLoop(int token) async {
    if (token != _taskLoopToken) return;
    _isExecutingTasks = true;
    try {
      await executorUpdateTask();
    } finally {
      _isExecutingTasks = false;
    }
    if (_needsTaskRestart) {
      _needsTaskRestart = false;
      await _runUpdateLoop(_taskLoopToken);
      return;
    }
    if (token != _taskLoopToken) return;
    timer = Timer(const Duration(seconds: 1), () {
      unawaited(_runUpdateLoop(token));
    });
  }

  Future<void> executorUpdateTask() async {
    for (final task in tasks) {
      try {
        await task();
      } catch (e) {
        commonPrint.warn('Background task failed: $e');
      }
    }
    timer = null;
  }

  void stopUpdateTasks() {
    _taskLoopToken++;
    _needsTaskRestart = false;
    timer?.cancel();
    timer = null;
  }

  Future<void> handleBackground() async {
    if (system.isDesktop) {
      final isMinimized = await window?.isMinimized ?? false;
      final isVisible = await window?.isVisible ?? true;
      if (!isMinimized && isVisible) {
        return;
      }
      animationEnabled.value = false;
    }
    if (!backgroundMode.value) {
      backgroundMode.value = true;
      windows?.setBackgroundMemoryPriority(true);
      _scheduleBackgroundCleanup();
    }
    render?.pause();

    final vpnProps = appController.ref.read(vpnSettingProvider);
    final keepTrafficUpdates =
        (system.isAndroid && vpnProps.networkSpeedNotification) ||
        (system.isMacOS && vpnProps.enableTraySpeed);
    if (!keepTrafficUpdates) {
      stopUpdateTasks();
    }

    dashboardRefreshManager.stop();
  }

  void handleForeground() {
    if (system.isDesktop) {
      animationEnabled.value = true;
    }
    if (!backgroundMode.value) {
      return;
    }
    backgroundMode.value = false;
    windows?.setBackgroundMemoryPriority(false);
    _backgroundCoreGcTimer?.cancel();
    _backgroundCoreGcTimer = null;
    _backgroundCleanupTimer?.cancel();
    _backgroundCleanupTimer = null;
    _syncVpnState();
  }

  Future<void> _syncVpnState() async {
    if (!system.isAndroid) return;
    try {
      final actuallyRunning = await service?.getStatus() ?? false;
      final flutterState = appState.runTime != null;

      if (actuallyRunning && !flutterState) {
        await updateStartTime();
        if (startTime != null) {
          appState = appState.copyWith(runTime: 0);
          await startUpdateTasks([appController.updateTraffic]);
        }
      } else if (!actuallyRunning && flutterState) {
        appState = appState.copyWith(runTime: null);
        startTime = null;
      }
    } catch (e) {
      commonPrint.warn('Sync VPN state error: $e');
    }
  }

  Future<void> resumeForegroundUpdates() async {
    dashboardRefreshManager.start();
    if (!isStart) {
      return;
    }

    await appController.updateRunTime();
    await appController.updateTraffic();
    await startUpdateTasks([
      appController.updateRunTime,
      appController.updateTraffic,
    ]);
  }

  void _scheduleBackgroundCleanup() {
    _backgroundCoreGcTimer?.cancel();
    _backgroundCoreGcTimer = Timer(const Duration(seconds: 30), () {
      _backgroundCoreGcTimer = null;
      if (!backgroundMode.value) {
        return;
      }
      _checkAndRunBackgroundCoreGc();
    });

    _backgroundCleanupTimer?.cancel();
    _backgroundCleanupTimer = Timer(const Duration(seconds: 300), () {
      _backgroundCleanupTimer = null;
      if (!backgroundMode.value) {
        return;
      }
      cleanupBackgroundResources();
    });
  }

  Future<void> _checkAndRunBackgroundCoreGc() async {
    if (!backgroundMode.value) return;

    const threshold = 2 * 1024 * 1024;
    var consecutiveBusyCount = 0;

    for (var i = 0; i < 3; i++) {
      if (!backgroundMode.value) return;
      try {
        final traffic = await clashCore.getTraffic();
        if (traffic.down.value > threshold || traffic.speed > threshold) {
          consecutiveBusyCount++;
        }
      } catch (_) {}
      if (i < 2) {
        await Future.delayed(const Duration(seconds: 1));
      }
    }

    if (consecutiveBusyCount == 3) {
      return;
    }

    if (!backgroundMode.value) return;
    await clashCore.requestGc(forceFreeOSMemory: false);
  }

  void cleanupBackgroundResources() async {
    if (!backgroundMode.value) return;

    final imageCache = PaintingBinding.instance.imageCache;
    imageCache.clearLiveImages();

    await Future.delayed(const Duration(milliseconds: 250));
    if (!backgroundMode.value) return;
    WidgetsBinding.instance.handleMemoryPressure();

    await Future.delayed(const Duration(seconds: 3));
    if (!backgroundMode.value) return;
    android?.purgeMemory();
    system.purgeMemory();
    windows?.emptyWorkingSet();
  }

  Future<void> handleStart([
    UpdateTasks? tasks,
    bool includeVpnService = true,
  ]) async {
    startTime ??= DateTime.now();
    if (system.isAndroid && isService) {
      await clashLibHandler?.startListener();
    } else {
      await clashCore.startListener();
    }
    if (includeVpnService) {
      await service?.startVpn();
    }
    final prefs = await preferences.sharedPreferencesCompleter.future;
    await prefs?.setBool('is_vpn_running', true);

    if (system.isAndroid) {
      await service?.setQuickResponse(config.vpnProps.quickResponse);
      await service?.setHighPriorityNotification(
        config.vpnProps.highPriorityNotification,
      );
    }
    await startUpdateTasks(tasks);
  }

  Future updateStartTime() async {
    startTime = await clashLib?.getRunTime();
  }

  void updateWakelockState(bool enabled) {
    if (_appController != null) {
      final container = _appController!.context;
      if (container.mounted) {
        final providerContainer = flutter_riverpod.ProviderScope.containerOf(
          container,
          listen: false,
        );
        providerContainer
                .read(providers_state.wakelockStateProvider.notifier)
                .state =
            enabled;
      }
    }
  }

  Future handleStop([bool includeVpnService = true]) async {
    startTime = null;
    if (system.isAndroid && isService) {
      await clashLibHandler?.stopListener();
    } else {
      await clashCore.stopListener();
    }
    if (!includeVpnService) {
      stopUpdateTasks();
      return;
    }
    await service?.stopVpn();
    final prefs = await preferences.sharedPreferencesCompleter.future;
    await prefs?.setBool('is_vpn_running', false);
    if (system.isDesktop) {
      await prefs?.setBool('is_tun_running', false);
    }
    stopUpdateTasks();
  }

  Future<bool?> showMessage({
    String? title,
    required InlineSpan message,
    String? confirmText,
    bool cancelable = true,
  }) async {
    return await showCommonDialog<bool>(
      child: Builder(
        builder: (context) {
          return CommonDialog(
            title: title ?? appLocalizations.tip,
            actions: [
              if (cancelable)
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop(false);
                  },
                  child: Text(appLocalizations.cancel),
                ),
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop(true);
                },
                child: Text(confirmText ?? appLocalizations.confirm),
              ),
            ],
            child: Container(
              width: 300,
              constraints: const BoxConstraints(maxHeight: 200),
              child: SingleChildScrollView(
                child: SelectableText.rich(
                  TextSpan(
                    style: Theme.of(context).textTheme.labelLarge,
                    children: [message],
                  ),
                  style: const TextStyle(overflow: TextOverflow.visible),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<T?> showCommonDialog<T>({
    required Widget child,
    bool dismissible = true,
  }) async {
    final state = navigatorKey.currentState;
    if (state == null) return null;
    final context = state.context;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return await showGeneralDialog<T>(
      context: context,
      barrierColor: isDark ? const Color(0xCC000000) : const Color(0x99000000),
      barrierDismissible: dismissible,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      transitionDuration: const Duration(milliseconds: 250),
      pageBuilder: (context, animation, secondaryAnimation) => child,
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: curved.drive(Tween<double>(begin: 0.94, end: 1.0)),
            child: RepaintBoundary(child: child),
          ),
        );
      },
    );
  }

  bool _dialogWarmedUp = false;

  void warmupCommonDialog() {
    if (_dialogWarmedUp) return;
    _dialogWarmedUp = true;

    final state = navigatorKey.currentState;
    if (state == null) return;
    final overlayState = state.overlay;
    if (overlayState == null) return;

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          entry.remove();
          entry.dispose();
        });
        return Offstage(
          offstage: true,
          child: RepaintBoundary(
            child: Material(
              type: MaterialType.transparency,
              child: FadeTransition(
                opacity: const AlwaysStoppedAnimation(1.0),
                child: ScaleTransition(
                  scale: const AlwaysStoppedAnimation(1.0),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(28),
                      boxShadow: const [
                        BoxShadow(blurRadius: 10, color: Colors.black12),
                      ],
                    ),
                    child: const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.check_circle_outline),
                        SizedBox(height: 8),
                        Text('warmup'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );

    overlayState.insert(entry);
  }

  void showNotifier(
    String text, {
    VoidCallback? onAction,
    String? actionLabel,
    bool showCountdown = false,
  }) {
    if (text.isEmpty) return;
    navigatorKey.currentContext?.showNotifier(
      text,
      onAction: onAction,
      actionLabel: actionLabel,
      showCountdown: showCountdown,
    );
  }

  Future<void> openUrl(String url, {bool needConfirm = false}) async {
    if (needConfirm) {
      final res = await showMessage(
        message: TextSpan(text: url),
        title: appLocalizations.externalLink,
        confirmText: appLocalizations.go,
      );
      if (res != true) {
        return;
      }
    }
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  Future<void> migrateOldData(Config config) async {
    final clashConfig = await preferences.getClashConfig();
    if (clashConfig != null) {
      config = config.copyWith(patchClashConfig: clashConfig);
      preferences.clearClashConfig();
      preferences.saveConfig(config);
    }

    if (config.appSetting.locale == null) {
      final systemLocale = utils.getSystemLocale();
      config = config.copyWith(
        appSetting: config.appSetting.copyWith(locale: systemLocale.toString()),
      );
      preferences.saveConfig(config);
      this.config = config;
    }

    final prefs = await preferences.sharedPreferencesCompleter.future;
    if (prefs != null && prefs.containsKey(customDashboardTitleKey)) {
      config = config.copyWith(
        appSetting: config.appSetting.copyWith(
          dashboardTitle:
              prefs.getString(customDashboardTitleKey) ??
              config.appSetting.dashboardTitle,
        ),
      );
      await preferences.saveConfig(config);
      this.config = config;
      await prefs.remove(customDashboardTitleKey);
    }
    await prefs?.remove(customSidebarIconKey);
  }

  CoreState getCoreState() {
    final currentProfile = config.currentProfile;
    return CoreState(
      vpnProps: config.vpnProps,
      onlyStatisticsProxy: config.appSetting.onlyStatisticsProxy,
      currentProfileName: currentProfile?.label ?? currentProfile?.id ?? '',
      bypassDomain: config.networkProps.bypassDomain,
    );
  }

  Future<SetupParams> getSetupParams({required ClashConfig pathConfig}) =>
      _compiler.buildSetupParams(config, patchConfig: pathConfig);

  Future<SetupParams?> buildValidateParams(Profile profile) {
    return _compiler.buildValidateParams(
      config,
      profile: profile,
      isService: isService,
      realTunEnable: appState.realTunEnable,
    );
  }

  Future<String> getRuntimeConfigContent({
    required ClashConfig patchConfig,
    Profile? profile,
  }) async {
    return clashCore.getRuntimeConfig(
      await _compiler.buildSetupParams(
        config,
        patchConfig: patchConfig,
        profile: profile,
      ),
    );
  }

  Future<String> validatePatchedConfig({
    required ClashConfig patchConfig,
  }) async {
    return clashCore.validateConfig(
      '',
      setup: await getSetupParams(pathConfig: patchConfig),
    );
  }

  Future<Map<String, dynamic>> getProfileConfig(
    String profileId, {
    bool effective = false,
  }) async {
    final profile = config.profiles.getProfile(profileId);
    if (effective && profile != null) {
      final scripted = await _compiler.readScriptedConfig(config, profile);
      if (scripted != null) return scripted;
    }
    final ageSecretKey = profile?.ageSecretKey;
    final disabledGroups = effective && profile != null
        ? [
            for (final entry in profile.groupSwitches.entries)
              if (!entry.value) entry.key,
          ]
        : const <String>[];
    final configMap = await switch (clashLibHandler != null) {
      true => clashLibHandler!.getConfig(
        profileId,
        ageSecretKey: ageSecretKey,
        disabledGroups: disabledGroups,
      ),
      false => clashCore.getConfig(
        profileId,
        ageSecretKey: ageSecretKey,
        disabledGroups: disabledGroups,
      ),
    };
    configMap['rules'] = configMap['rule'];
    configMap.remove('rule');
    return configMap;
  }
}

final globalState = GlobalState();

