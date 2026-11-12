import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/helper/helper.dart';

import 'package:bett_box/plugins/app.dart';
import 'package:bett_box/plugins/service.dart' as vpn_service;
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/dialog.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart';
import 'package:synchronized/synchronized.dart';
import 'package:tray_manager/tray_manager.dart';

import 'package:wakelock_plus/wakelock_plus.dart';

import 'common/common.dart';
import 'common/dav_client.dart';
import 'models/models.dart';
import 'services/backup_service.dart';
import 'views/profiles/override_profile.dart';
import 'views/proxies/common.dart' show cancelDelayTests;

class AppController {
  int? lastProfileModified;

  final BuildContext context;
  final WidgetRef _ref;
  WidgetRef get ref => _ref;

  Timer? _wakelockSyncTimer;
  final List<Log> _pendingLogs = [];
  Completer<void>? _exitLock;
  final Lock _coreLifecycleLock = Lock(reentrant: true);
  int _backgroundLoadVersion = 0;

  int _updateGroupsRetryCount = 0;
  bool _isUpdatingGroups = false;
  Timer? _updateGroupsRetryTimer;
  int _coreGeneration = 0;
  int _setupGeneration = 0;
  String? _loadedProfileId;
  final Set<String> _updatingProfileIds = {};
  final Lock _bundleLock = Lock();
  final Set<String> _pendingBundleIds = {};
  final Set<String> _refreshingBundleIds = {};
  int _localNetworkId = 0;
  Timer? _idleGcTimer;
  late final BackupService _backup = BackupService(this);

  AppController(this.context, WidgetRef ref) : _ref = ref;

  DateTime _lastModeChangeTime = DateTime.fromMillisecondsSinceEpoch(0);

  void scheduleIdleGc({Duration delay = const Duration(seconds: 2)}) {
    _idleGcTimer?.cancel();
    _idleGcTimer = Timer(delay, () {
      _idleGcTimer = null;
      unawaited(clashCore.requestGc(forceFreeOSMemory: true));
    });
  }

  void setupClashConfigDebounce() {
    debouncer.call(FunctionTag.setupClashConfig, () async {
      await safeRun(() async {
        await setupClashConfig();
      }, needLoading: true);
    });
  }

  void updateClashConfigDebounce() {
    debouncer.call(FunctionTag.updateClashConfig, () async {
      await updateClashConfig();
    });
  }

  void updateGroupsDebounce() {
    debouncer.call(FunctionTag.updateGroups, updateGroups);
  }

  void addCheckIpNumDebounce() {
    debouncer.call(FunctionTag.addCheckIpNum, () {
      _ref.read(checkIpNumProvider.notifier).add();
    });
  }

  void addCheckIp() {
    _ref.read(checkIpNumProvider.notifier).add();
  }

  void applyProfileDebounce({bool silence = false}) {
    debouncer.call(FunctionTag.applyProfile, (silence) {
      applyProfile(silence: silence);
    }, args: [silence]);
  }

  void savePreferencesDebounce() {
    debouncer.call(FunctionTag.savePreferences, () async {
      await routeIdleObserver.whenIdle();
      await savePreferences();
    });
  }

  void changeProxyDebounce(String groupName, String proxyName) {
    debouncer.call(FunctionTag.changeProxy, (
      String groupName,
      String proxyName,
    ) async {
      await changeProxy(groupName: groupName, proxyName: proxyName);
      await updateGroups();
      addCheckIp();
    }, args: [groupName, proxyName]);
  }

  void _invalidateCoreReads() {
    _coreGeneration++;
    _backgroundLoadVersion++;
    _updateGroupsRetryTimer?.cancel();
    _updateGroupsRetryTimer = null;
    _updateGroupsRetryCount = 0;
  }

  void _cancelDelayTests() {
    cancelDelayTests();
    _ref.read(delayDataSourceProvider.notifier).dropTesting();
  }

  Future<void> flushDns() async {
    await clashCore.flushFakeIP();
    await clashCore.flushDnsCache();
  }

  Future<void> restartCore() {
    return _coreLifecycleLock.synchronized(() async {
      _ref.read(isRestartingCoreProvider.notifier).state = true;
      try {
        await _restartCore();
      } catch (err) {
        _reportCoreRestartFailure(err);
        rethrow;
      } finally {
        _ref.read(isRestartingCoreProvider.notifier).state = false;
      }
    });
  }

  Future<void> _restartCore({
    bool setupConfig = true,
    bool refreshData = true,
  }) async {
    commonPrint.log('restart core');
    _invalidateCoreReads();
    _cancelDelayTests();

    final wasRunning = _ref.read(runTimeProvider.notifier).isStart;
    if (wasRunning) {
      await globalState.handleStop();
      _ref.read(runTimeProvider.notifier).value = null;
    }
    if (system.isAndroid) {
      await clashCore.closeConnections();
      await clashCore.flushFakeIP();
      await clashCore.flushDnsCache();
      await clashCore.requestGc(forceFreeOSMemory: true);
      if (wasRunning) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
    if (system.isDesktop) {
      lastProfileModified = null;
      await clashService!.reStart();
    }
    await _initCore();

    final configured = setupConfig ? await _setupCoreConfig() : false;
    if (refreshData && configured) {
      await updateGroups();
      await updateProviders();
      scheduleIdleGc();
    }

    if (wasRunning) {
      await globalState.handleStart([updateRunTime, updateTraffic]);
      _scheduleCheckIpRefresh();
      _backgroundLoad();
    }
  }

  Future<void> updateStatus(bool isStart) {
    return _coreLifecycleLock.synchronized(() => _updateStatus(isStart));
  }

  Future<void> _updateStatus(bool isStart) async {
    if (isStart) {
      await _fastStart();
      if (globalState.isStart && !_ref.read(runTimeProvider.notifier).isStart) {
        _ref.read(runTimeProvider.notifier).value = 0;
      }
    } else {
      await globalState.handleStop();
      clashCore.resetTraffic();
      _ref.read(trafficsProvider.notifier).clear();
      _ref.read(totalTrafficProvider.notifier).value = Traffic();
      _ref.read(runTimeProvider.notifier).value = null;
      addCheckIpNumDebounce();
    }
  }

  Future<void> _fastStart() async {
    final currentProfile = _ref.read(currentProfileProvider);
    if (currentProfile == null) {
      commonPrint.warn('Fast start aborted: No active profile configured.');
      return;
    }

    final patchConfig = _ref.read(patchClashConfigProvider);
    final isDesktop = system.isDesktop;

    if (isDesktop && patchConfig.tun.enable) {
      await _quickSetupConfig(enableTun: false);

      if (system.isMacOS || system.isLinux) {
        try {
          final res = await _requestAdmin(true);
          if (res.needRestart) {
            await restartCore();
            return;
          }
          await globalState.handleStart([updateRunTime, updateTraffic]);
          if (res.data == true) {
            Future.microtask(() async {
              try {
                await _updateClashConfig();
              } catch (e) {
                commonPrint.warn('FastStart desktop TUN update failed: $e');
              }
              _backgroundLoad();
            });
          } else {
            _backgroundLoad();
          }
        } catch (e) {
          commonPrint.warn('FastStart desktop auth error: $e');
          await globalState.handleStart([updateRunTime, updateTraffic]);
          _backgroundLoad();
        }
        _scheduleCheckIpRefresh();
        return;
      }

      await globalState.handleStart([updateRunTime, updateTraffic]);

      Future.microtask(() async {
        try {
          final res = await _requestAdmin(true);
          if (res.needRestart) {
            await restartCore();
            return;
          }
          if (res.data == true) {
            await _updateClashConfig();
          }
        } catch (e) {
          commonPrint.error('FastStart update config failed: $e');
        }
        _backgroundLoad();
      });

      _scheduleCheckIpRefresh();
      return;
    }

    final needReapply = await _needsSetupConfig();
    if (needReapply) {
      final setupResult = await _quickSetupConfig();
      if (setupResult != true) {
        commonPrint.error('Fast start aborted: setupConfig failed');
        return;
      }
    }

    await globalState.handleStart([updateRunTime, updateTraffic]);

    _scheduleCheckIpRefresh();

    _backgroundLoad();
  }

  void _scheduleCheckIpRefresh() {
    Future.delayed(const Duration(seconds: 1), () {
      addCheckIpNumDebounce();
    });
  }

  void _backgroundLoad() {
    final version = ++_backgroundLoadVersion;
    final generation = _coreGeneration;

    Future.microtask(() async {
      try {
        await updateProviders();
        if (version != _backgroundLoadVersion) return;
        if (generation != _coreGeneration) return;

        List<Group> groups = [];
        for (var attempt = 0; attempt < 3; attempt++) {
          if (version != _backgroundLoadVersion) return;
          if (generation != _coreGeneration) return;
          if (attempt > 0) {
            await Future.delayed(Duration(milliseconds: 200 * attempt));
          }
          groups = await clashCore.getProxiesGroups();
          if (groups.isNotEmpty) break;
        }
        if (version != _backgroundLoadVersion) return;
        if (generation != _coreGeneration) return;

        if (groups.isNotEmpty) {
          _ref.read(groupsProvider.notifier).value = groups;
        }

        await Future.delayed(const Duration(seconds: 2));
        if (version != _backgroundLoadVersion) return;
        await clashCore.requestGc(forceFreeOSMemory: true);
      } catch (e) {
        commonPrint.warn('Background load error: $e');
      }
    });
  }

  Future<bool> _checkIfNeedReapply() async {
    final currentLastModified = await _ref
        .read(currentProfileProvider)
        ?.profileLastModified;
    if (currentLastModified != null &&
        lastProfileModified != null &&
        currentLastModified <= lastProfileModified!) {
      return false;
    }
    return true;
  }

  Future<bool> _needsSetupConfig() async {
    if (_setupGeneration != _coreGeneration) {
      return true;
    }
    return _checkIfNeedReapply();
  }

  Future<bool> _setupCoreConfig({bool? enableTun}) async {
    final currentProfile = _ref.read(currentProfileProvider);
    if (currentProfile == null) {
      return false;
    }
    await _initCore();
    final isFileExists = await currentProfile.check();
    if (!isFileExists) {
      await currentProfile.checkAndUpdate();
    }
    final patchConfig = _ref.read(patchClashConfigProvider);
    final targetTun = enableTun ?? patchConfig.tun.enable;

    final realTunEnable = await _prepareTun(targetTun);
    if (realTunEnable == null) return false;

    final realPatchConfig = patchConfig.copyWith.tun(enable: realTunEnable);
    final params = await globalState.getSetupParams(
      pathConfig: realPatchConfig,
    );
    _cancelDelayTests();
    var result = await clashCore.setupConfig(params);
    var message = result.message;
    if (message.isNotEmpty && params.scriptedConfig.isNotEmpty) {
      commonPrint.error('[Core] Scripted setup config failed: $message');
      globalState.showNotifier(
        '${appLocalizations.profileParseErrorDesc}: $message',
      );
      final fallbackScripted =
          currentProfile.runsManagedScript &&
              ManagedScript.syncedVersion(globalState.config.managedProps) !=
                  null
          ? await globalState.writeBundledManagedConfig(currentProfile)
          : '';
      result = await clashCore.setupConfig(
        params.copyWith(scriptedConfig: fallbackScripted),
      );
      message = result.message;
    }
    if (message.isNotEmpty) {
      commonPrint.error('[Core] Setup config failed: $message');
      throw message;
    }
    _applyGlobalSelection(result.global);
    _loadedProfileId = currentProfile.id;
    if (system.isDesktop) {
      final prefs = await preferences.sharedPreferencesCompleter.future;
      await prefs?.setBool('is_tun_running', realTunEnable);
    }
    lastProfileModified = await _ref.read(
      currentProfileProvider.select((state) => state?.profileLastModified),
    );
    _setupGeneration = _coreGeneration;
    return true;
  }

  void _applyGlobalSelection(String global) {
    final profile = _ref.read(currentProfileProvider);
    if (global.isEmpty ||
        profile == null ||
        profile.selectedMap['GLOBAL'] != null) {
      return;
    }
    setProfile(
      profile.copyWith(selectedMap: {...profile.selectedMap, 'GLOBAL': global}),
    );
  }

  Future<bool?> _quickSetupConfig({bool? enableTun}) async {
    return await safeRun(() async {
      return await _setupCoreConfig(enableTun: enableTun);
    }, needLoading: false);
  }

  Future<void> updateRunTime() async {
    if (globalState.backgroundMode.value) return;
    final startTime = globalState.startTime;
    if (startTime == null) {
      if (_ref.read(runTimeProvider) != null) {
        _ref.read(runTimeProvider.notifier).value = null;
      }
      return;
    }

    final startTimeStamp = startTime.millisecondsSinceEpoch;
    final nowTimeStamp = DateTime.now().millisecondsSinceEpoch;
    final elapsed = nowTimeStamp - startTimeStamp;

    final current = _ref.read(runTimeProvider);
    if (current == null) {
      _ref.read(runTimeProvider.notifier).value = elapsed;
      return;
    }
    _ref.read(runTimeProvider.notifier).value = elapsed;
  }

  Future<bool> _shouldUpdateDashboardTick() async {
    return dashboardRefreshManager.isActive();
  }

  String? _speedNotificationProfileToSync() {
    if (!system.isAndroid ||
        !globalState.isScreenOn ||
        !_ref.read(vpnSettingProvider).networkSpeedNotification) {
      return null;
    }
    final currentProfileId = _ref.read(currentProfileIdProvider);
    final profiles = _ref.read(profilesProvider);
    final profile = profiles.where((e) => e.id == currentProfileId).firstOrNull;
    final profileName = profile?.label ?? 'Bettbox';
    final needsSync =
        vpn_service.service?.needsSpeedNotificationSync(profileName) ?? false;
    return needsSync ? profileName : null;
  }

  Future<void> updateTraffic() async {
    final shouldUpdateDashboard = await _shouldUpdateDashboardTick();
    final speedNotificationProfile = _speedNotificationProfileToSync();
    final enableTraySpeed =
        system.isMacOS && _ref.read(vpnSettingProvider).enableTraySpeed;

    if (!shouldUpdateDashboard &&
        speedNotificationProfile == null &&
        !enableTraySpeed) {
      return;
    }

    final snapshot = await clashCore.getTrafficSnapshot();
    _ref.read(totalTrafficProvider.notifier).value = snapshot.total;

    final traffic = snapshot.now;

    if (shouldUpdateDashboard) {
      _ref.read(trafficsProvider.notifier).addTraffic(traffic);
    }

    if (enableTraySpeed) {
      await tray.updateSpeed(traffic);
    }

    if (speedNotificationProfile != null) {
      await vpn_service.service?.updateNotificationSpeed(
        speedNotificationProfile,
        traffic.toString(),
      );
    }
  }

  Future<void> addProfile(Profile profile) async {
    _ref.read(profilesProvider.notifier).setProfile(profile);
    if (_ref.read(currentProfileIdProvider) != null) return;
    _ref.read(currentProfileIdProvider.notifier).value = profile.id;
  }

  Future<void> deleteProfile(String id) async {
    _ref.read(profilesProvider.notifier).deleteProfileById(id);
    await clearEffect(id);
    _detachBundleMember(id);
    if (globalState.config.currentProfileId == id) {
      final profiles = globalState.config.profiles;
      final currentProfileId = _ref.read(currentProfileIdProvider.notifier);
      if (profiles.isNotEmpty) {
        final updateId = profiles.first.id;
        currentProfileId.value = updateId;
      } else {
        currentProfileId.value = null;
        updateStatus(false);
      }
    }
  }

  Future<void> updateProviders() async {
    final providers = await clashCore.getExternalProviders();
    _syncProviderSubscriptions(providers);
    if (listEquals(_ref.read(providersProvider), providers)) return;
    _ref.read(providersProvider.notifier).value = providers;
  }

  void _setProviders(List<ExternalProvider> providers) {
    _ref.read(providersProvider.notifier).value = providers;
    _syncProviderSubscriptions(providers);
  }

  void _syncProviderSubscriptions(List<ExternalProvider> providers) {
    final profileId = _loadedProfileId ?? _ref.read(currentProfileIdProvider);
    final profile = _ref.read(profilesProvider).getProfile(profileId);
    if (profile == null || profile.bundle != null) return;
    final subscriptions = {
      for (final provider in providers)
        if (provider.type == 'Proxy') provider.name: ?provider.subscriptionInfo,
    };
    if (mapEquals(profile.providerSubscriptions, subscriptions)) return;
    setProfile(profile.copyWith(providerSubscriptions: subscriptions));
  }

  Future<void> updateLocalNetwork({bool silent = false}) async {
    final id = ++_localNetworkId;
    if (!silent) {
      _ref.read(localNetworkProvider.notifier).value = null;
      await Future.delayed(commonDuration);
      if (id != _localNetworkId) return;
    }
    final info = await utils.getNetworkInfo();
    if (id != _localNetworkId) return;
    _ref.read(localNetworkProvider.notifier).value = info;
  }

  Future<void> updateProfile(
    Profile profile, {
    bool validate = true,
    bool applyUnchanged = true,
  }) async {
    // A duplicate trigger must not clear isUpdating: an earlier update for
    // this profile is still in flight and owns the flag until it finishes.
    if (_updatingProfileIds.contains(profile.id)) return;
    _updatingProfileIds.add(profile.id);
    setProfile(profile.copyWith(isUpdating: true));
    try {
      final modified = applyUnchanged
          ? null
          : await profile.profileLastModified;
      final newProfile = await profile.update(validate: validate);
      setProfile(newProfile.copyWith(isUpdating: false));
      if (profile.id != _ref.read(currentProfileIdProvider)) return;
      if (modified != null && modified == await profile.profileLastModified) {
        return;
      }
      applyProfileDebounce(silence: true);
    } on Object {
      _clearProfileUpdating(profile.id);
      rethrow;
    } finally {
      _updatingProfileIds.remove(profile.id);
    }
  }

  void _clearProfileUpdating(String profileId) {
    final current = _ref.read(profilesProvider).getProfile(profileId);
    if (current == null || !current.isUpdating) return;
    setProfile(current.copyWith(isUpdating: false));
  }

  void setProfile(Profile profile) {
    _ref.read(profilesProvider.notifier).setProfile(profile);
  }

  void setProfileAndAutoApply(Profile profile) {
    _ref.read(profilesProvider.notifier).setProfile(profile);
    if (profile.id == _ref.read(currentProfileIdProvider)) {
      applyProfileDebounce(silence: true);
    }
  }

  void setProfiles(List<Profile> profiles) {
    _ref.read(profilesProvider.notifier).value = profiles;
  }

  Future<void> createBundle({
    required String label,
    required List<BundleMember> members,
    bool collapsed = false,
    ProfileUsageStyle usageStyle = ProfileUsageStyle.bar,
  }) {
    return _bundleLock.synchronized(() async {
      final profile = Profile.normal(label: label).copyWith(
        autoUpdate: false,
        usageStyle: usageStyle,
        bundle: ProfileBundle(members: members, collapsed: collapsed),
      );
      await addProfile(await _generateBundle(profile, refresh: false));
    });
  }

  Future<void> generateBundle(String id, {bool refresh = false}) {
    return _bundleLock.synchronized(() async {
      final profile = _ref.read(profilesProvider).getProfile(id);
      if (profile == null || profile.bundle == null) return;
      if (refresh) _refreshingBundleIds.add(id);
      setProfile(profile.copyWith(isUpdating: true));
      try {
        final file = File(await appPath.getProfilePath(id));
        final modified = await file.exists()
            ? (await file.stat()).modified
            : null;
        final generated = await _generateBundle(profile, refresh: refresh);
        final latest = _ref.read(profilesProvider).getProfile(id);
        final latestBundle = latest?.bundle;
        if (latest == null || latestBundle == null) return;
        setProfile(
          latest.copyWith(
            isUpdating: false,
            lastUpdateDate: generated.lastUpdateDate,
            providerSubscriptions: generated.providerSubscriptions,
            bundle: latestBundle.copyWith(
              report: generated.bundle?.report ?? latestBundle.report,
              failures: generated.bundle?.failures ?? const {},
            ),
          ),
        );
        if (id != _ref.read(currentProfileIdProvider)) return;
        if (modified != null && modified == (await file.stat()).modified) {
          return;
        }
        applyProfileDebounce(silence: true);
      } finally {
        _refreshingBundleIds.remove(id);
        final latest = _ref.read(profilesProvider).getProfile(id);
        if (latest != null && latest.isUpdating) {
          setProfile(latest.copyWith(isUpdating: false));
        }
      }
    });
  }

  void updateManagedSetting(ManagedProps Function(ManagedProps state) builder) {
    _ref.read(managedSettingProvider.notifier).updateState(builder);
    generateAllBundles();
  }

  void generateAllBundles() {
    scheduleBundles([
      for (final profile in _ref.read(profilesProvider))
        if (profile.bundle != null) profile.id,
    ]);
  }

  Future<void> checkManagedScriptVersionUpgrade() async {
    final currentVersion = ManagedScript.version(
      _ref.read(managedSettingProvider),
    );
    if (currentVersion.isEmpty) return;
    final prefs = await preferences.sharedPreferencesCompleter.future;
    final lastVersion = prefs?.getString(lastManagedScriptVersionKey);
    if (lastVersion == currentVersion) return;
    await prefs?.setString(lastManagedScriptVersionKey, currentVersion);
    final hasBundles = _ref.read(profilesProvider).any((p) => p.bundle != null);
    if (hasBundles) {
      generateAllBundles();
    }
    final current = _ref.read(currentProfileProvider);
    if (current != null && current.runsManagedScript) {
      applyProfileDebounce(silence: true);
    }
  }

  void scheduleBundles(Iterable<String> ids) {
    _pendingBundleIds.addAll(ids);
    if (_pendingBundleIds.isEmpty) return;
    debouncer.call(
      FunctionTag.generateBundles,
      _flushBundles,
      duration: const Duration(seconds: 1),
    );
  }

  Future<void> _flushBundles() async {
    final ids = _pendingBundleIds.toList();
    _pendingBundleIds.clear();
    for (final id in ids) {
      try {
        await generateBundle(id);
      } catch (e) {
        final label = _ref.read(profilesProvider).getProfile(id)?.label ?? id;
        commonPrint.error(
          '[Bundle] Failed to generate $label: ${e.formatErrorLog}',
        );
        globalState.showNotifier('$label: ${e.formatError}');
      }
    }
  }

  void syncBundles(List<Profile> previous, List<Profile> next) {
    final regenerate = <String>{};
    var usageChanged = false;
    for (final profile in next) {
      if (profile.bundle != null) continue;
      final old = previous.getProfile(profile.id);
      if (old == null || old == profile) continue;
      final bundles = next.bundlesOf(profile.id);
      if (bundles.isEmpty) continue;
      if (old.lastUpdateDate != profile.lastUpdateDate ||
          old.label != profile.label ||
          old.ageSecretKey != profile.ageSecretKey) {
        regenerate.addAll(bundles.map((bundle) => bundle.id));
      }
      if (old.subscriptionInfo != profile.subscriptionInfo ||
          !mapEquals(
            old.providerSubscriptions,
            profile.providerSubscriptions,
          )) {
        usageChanged = true;
      }
    }
    if (usageChanged) {
      scheduleMicrotask(_syncBundleUsages);
    }
    regenerate.removeAll(_refreshingBundleIds);
    if (regenerate.isNotEmpty) {
      scheduleBundles(regenerate);
    }
  }

  void _syncBundleUsages() {
    final profiles = _ref.read(profilesProvider);
    for (final profile in profiles) {
      if (profile.bundle == null) continue;
      final usages = _bundleUsages(profile, profiles);
      if (mapEquals(usages, profile.providerSubscriptions)) continue;
      setProfile(profile.copyWith(providerSubscriptions: usages));
    }
  }

  Map<String, SubscriptionInfo> _bundleUsages(
    Profile bundle,
    List<Profile> profiles,
  ) => {
    for (final member in bundle.bundle?.members ?? const <BundleMember>[])
      if (profiles.getProfile(member.id) case final target?)
        for (final usage in target.subscriptionUsages) usage.key: usage.value,
  };

  void _detachBundleMember(String id) {
    final regenerate = <String>[];
    for (final profile in _ref.read(profilesProvider).bundlesOf(id)) {
      final bundle = profile.bundle;
      if (bundle == null) continue;
      final members = [
        for (final member in bundle.members)
          if (member.id != id) member,
      ];
      setProfile(
        profile.copyWith(
          bundle: bundle.copyWith(
            members: members,
            failures: {...bundle.failures}..remove(id),
          ),
        ),
      );
      if (members.isNotEmpty) regenerate.add(profile.id);
    }
    scheduleBundles(regenerate);
  }

  Future<Profile> _generateBundle(
    Profile profile, {
    required bool refresh,
  }) async {
    final members = profile.bundle?.members ?? const <BundleMember>[];
    if (refresh) {
      for (final member in members) {
        final target = _ref.read(profilesProvider).getProfile(member.id);
        if (target == null || target.type != ProfileType.url) continue;
        try {
          await updateProfile(target);
        } catch (e) {
          commonPrint.error(
            '[Bundle] Failed to update ${target.label ?? target.id}: ${e.formatErrorLog}',
          );
        }
      }
    }
    final profiles = _ref.read(profilesProvider);
    final script = await ManagedScript.script(
      _ref.read(managedSettingProvider),
    );
    final inputs = <({String prefix, String path})>[];
    final failures = <String, String>{};
    final files = <File>[];
    try {
      for (final member in members) {
        final target = profiles.getProfile(member.id);
        if (target == null) continue;
        try {
          final path = await globalState.writeScriptedConfig(
            target,
            script,
            managed: true,
            refresh: refresh,
          );
          files.add(File(path));
          inputs.add((
            prefix: member.prefix ?? bundlePrefixOf(target.label ?? target.id),
            path: path,
          ));
        } catch (e) {
          failures[member.id] = e.formatError.split('\n').first;
        }
      }
      if (inputs.isEmpty) {
        if (failures.isEmpty) throw appLocalizations.bundleNoMembers;
        throw [
          for (final entry in failures.entries)
            '${profiles.getProfile(entry.key)?.label ?? entry.key}: ${entry.value}',
        ].join('\n');
      }
      final report = await clashCore.mergeProfiles(
        output: await appPath.getProfilePath(profile.id),
        members: inputs,
        setup: await globalState.buildValidateParams(profile),
      );
      return profile.copyWith(
        lastUpdateDate: DateTime.now(),
        providerSubscriptions: _bundleUsages(
          profile,
          _ref.read(profilesProvider),
        ),
        bundle: profile.bundle?.copyWith(report: report, failures: failures),
      );
    } finally {
      for (final file in files) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    }
  }

  void addLog(Log log) {
    _pendingLogs.add(log);
    throttler.call(
      FunctionTag.logs,
      _flushLogs,
      duration: const Duration(milliseconds: 300),
    );
  }

  void _flushLogs() {
    if (_pendingLogs.isEmpty) return;
    final logs = List.of(_pendingLogs);
    _pendingLogs.clear();
    _ref.read(logsProvider.notifier).addLogs(logs);
  }

  void updateOrAddHotKeyAction(HotKeyAction hotKeyAction) {
    final hotKeyActions = _ref.read(hotKeyActionsProvider);
    final index = hotKeyActions.indexWhere(
      (item) => item.action == hotKeyAction.action,
    );

    final newList = List.of(hotKeyActions);
    if (index == -1) {
      newList.add(hotKeyAction);
    } else {
      newList[index] = hotKeyAction;
    }

    _ref.read(hotKeyActionsProvider.notifier).value = newList;
  }

  List<Group> getCurrentGroups() {
    return _ref.read(currentGroupsStateProvider.select((state) => state.value));
  }

  String getRealTestUrl(String? url) {
    return _ref.read(getRealTestUrlProvider(url));
  }

  int getProxiesColumns() {
    return _ref.read(getProxiesColumnsProvider);
  }

  dynamic addSortNum() {
    _ref.read(delayDataSourceProvider.notifier).flush();
    return _ref.read(sortNumProvider.notifier).add();
  }

  String? getCurrentGroupName() {
    final currentGroupName = _ref.read(
      currentProfileProvider.select((state) => state?.currentGroupName),
    );
    return currentGroupName;
  }

  ProxyCardState getProxyCardState(String proxyName) {
    return resolveProxyCardState(
      _ref.read(groupsProvider),
      _ref.read(selectedMapProvider),
      ProxyCardState(proxyName: proxyName),
    );
  }

  String? getSelectedProxyName(String groupName) {
    return _ref.read(getSelectedProxyNameProvider(groupName));
  }

  void updateCurrentGroupName(String groupName) {
    final profile = _ref.read(currentProfileProvider);
    if (profile == null || profile.currentGroupName == groupName) {
      return;
    }
    setProfile(profile.copyWith(currentGroupName: groupName));
  }

  Future<void> updateClashConfig() {
    return _coreLifecycleLock.synchronized(() async {
      await safeRun(() async {
        await _updateClashConfig();
      }, needLoading: true);
    });
  }

  Future<bool?> _prepareTun(bool targetTun) async {
    final res = await _requestAdmin(targetTun);
    if (res.needRestart) {
      await _restartCore(setupConfig: false, refreshData: false);
    } else if (res.isError) {
      return null;
    }
    return res.data ?? _ref.read(realTunEnableProvider);
  }

  Future<void> _updateClashConfig() async {
    await _initCore();
    if (await vpn_service.service?.isSmartStopped() ?? false) {
      await vpn_service.service?.resumeCore();
    }
    final updateParams = _ref.read(updateParamsProvider);
    final tunResult = await _requestAdmin(updateParams.tun.enable);
    if (tunResult.isError) return;

    final bool realTunEnable =
        tunResult.data ?? _ref.read(realTunEnableProvider);
    if (tunResult.needRestart) {
      await _restartCore();
      return;
    }

    final message = await clashCore.updateConfig(
      updateParams.copyWith.tun(enable: realTunEnable),
    );
    if (message.isNotEmpty) throw message;

    if (system.isDesktop) {
      final prefs = await preferences.sharedPreferencesCompleter.future;
      await prefs?.setBool('is_tun_running', realTunEnable);
    }
    scheduleIdleGc();
  }

  Future<Result<bool>> _requestAdmin(bool enableTun) async {
    final realTunEnable = _ref.read(realTunEnableProvider);
    final hasAdmin = await system.checkIsAdmin();
    if (enableTun && (!realTunEnable || !hasAdmin)) {
      final code = await system.authorizeCore();
      switch (code) {
        case AuthorizeCode.success:
          _ref.read(realTunEnableProvider.notifier).value = enableTun;
          return Result.success(enableTun, needRestart: true);
        case AuthorizeCode.none:
          break;
        case AuthorizeCode.error:
          globalState.showNotifier(
            appLocalizations.tunEnableRequireAdmin,
            actionLabel: appPath.isPortable ? appLocalizations.restart : null,
            onAction: appPath.isPortable ? system.restartAsAdmin : null,
          );
          enableTun = false;
          break;
      }
    }
    _ref.read(realTunEnableProvider.notifier).value = enableTun;
    return Result.success(enableTun);
  }

  Future<void> setupClashConfig() {
    return _coreLifecycleLock.synchronized(() async {
      await safeRun(() async {
        final configured = await _setupCoreConfig();
        if (configured) {
          scheduleIdleGc();
        }
      }, needLoading: false);
    });
  }

  Future<void> _applyProfile() async {
    _invalidateCoreReads();
    unawaited(
      clashCore.requestGc().then<void>(
        (_) {},
        onError: (Object e) => commonPrint.debug('requestGc ignored: $e'),
      ),
    );
    final configured = await _setupCoreConfig();
    if (!configured) return;
    _ref.read(delayDataSourceProvider.notifier).clear();
    _setProviders(await clashCore.getExternalProviders());
    await updateGroups();
    scheduleIdleGc();
  }

  Future<void> applyProfile({bool silence = false}) {
    return _coreLifecycleLock.synchronized(() async {
      if (silence) {
        try {
          await _applyProfile();
        } catch (err) {
          globalState.showNotifier(err.toString());
          rethrow;
        }
      } else {
        await safeRun(() async {
          await _applyProfile();
        }, needLoading: true);
      }
    });
  }

  Future<void> handleChangeProfile({bool hardRestart = false}) {
    return _coreLifecycleLock.synchronized(() async {
      if (hardRestart) {
        _ref.read(isRestartingCoreProvider.notifier).state = true;
        try {
          await _restartCore();
          _ref.read(delayDataSourceProvider.notifier).clear();
        } catch (err) {
          _reportCoreRestartFailure(err);
          rethrow;
        } finally {
          _ref.read(isRestartingCoreProvider.notifier).state = false;
        }
      } else {
        final prevProfileId = _ref.read(currentProfileIdProvider);
        try {
          await _applyProfile();
        } catch (err) {
          _ref.read(currentProfileIdProvider.notifier).value = prevProfileId;
          try {
            await _applyProfile();
          } catch (_) {}
          globalState.showNotifier(err.toString());
        }
        await clashCore.closeConnections();
        await clashCore.flushFakeIP();
        await clashCore.flushDnsCache();
      }
      _ref.read(logsProvider.notifier).value = FixedList(maxLogLength);
      _ref.read(requestsProvider.notifier).value = FixedList(maxLength);
      globalState.computeHeightMapCache = {};
      addCheckIpNumDebounce();
    });
  }

  void _reportCoreRestartFailure(Object error) {
    final message = error.formatError;
    commonPrint.error('[Core] Restart failed: ${error.formatErrorLog}');
    globalState.showNotifier('${appLocalizations.restartCoreTitle}: $message');
  }

  void updateBrightness() {
    _ref.read(systemBrightnessProvider.notifier).value =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
  }

  bool _isProfileUpdateNeeded(Profile profile) {
    if (!profile.autoUpdate) return false;
    if (profile.type != ProfileType.url) return false;
    if (profile.isUpdating) return false;
    final lastUpdate = profile.lastUpdateDate;
    if (lastUpdate == null) return true;
    final expectedNextUpdate = lastUpdate.add(profile.autoUpdateDuration);
    return DateTime.now().difference(expectedNextUpdate) >
        const Duration(minutes: 1);
  }

  Future<void> autoUpdateProfiles() async {
    for (final profile in _ref.read(profilesProvider)) {
      if (!_isProfileUpdateNeeded(profile)) continue;
      try {
        await updateProfile(profile, validate: false, applyUnchanged: false);
      } catch (e) {
        commonPrint.error(
          '[AutoUpdate] Failed to update ${profile.label ?? profile.id}: ${e.formatErrorLog}',
        );
      }
    }
  }

  Future<void> checkAndUpdateMissedProfiles() async {
    final profilesToUpdate = <Profile>[];
    for (final profile in _ref.read(profilesProvider)) {
      if (!_isProfileUpdateNeeded(profile)) continue;
      profilesToUpdate.add(profile);
    }
    if (profilesToUpdate.isNotEmpty) {
      var updated = false;
      for (final profile in profilesToUpdate) {
        try {
          await updateProfile(profile, validate: false, applyUnchanged: false);
          updated = true;
        } catch (e) {
          commonPrint.error(
            '[MissedUpdate] Failed to update ${profile.label ?? profile.id}: ${e.formatErrorLog}',
          );
        }
        if (profilesToUpdate.length > 1) {
          await Future.delayed(const Duration(seconds: 2));
        }
      }
      if (updated) {
        commonPrint.log('Updating external providers');
      }
    }

    await _syncExternalProviders();
  }

  Future<void> _syncExternalProviders() async {
    try {
      final providers = await clashCore.getExternalProviders();
      if (providers.isEmpty) return;
      _setProviders(providers);
    } catch (e) {
      commonPrint.warn('[Sync] Failed to sync external providers: $e');
    }
  }

  Future<void> updateGroups() {
    return _coreLifecycleLock.synchronized(_updateGroups);
  }

  static const List<Duration> _kGroupRetryDelays = [
    Duration.zero,
    Duration(milliseconds: 50),
    Duration(milliseconds: 150),
    Duration(milliseconds: 400),
  ];

  Future<List<Group>> _retryGetProxiesGroups() async {
    for (var attempt = 0; attempt < _kGroupRetryDelays.length; attempt++) {
      if (attempt > 0) {
        await Future.delayed(_kGroupRetryDelays[attempt]);
      }
      final groups = await clashCore.getProxiesGroups();
      if (groups.isNotEmpty) return groups;
    }
    return [];
  }

  void _handleUpdateGroupsError(int generation, dynamic e) {
    if (generation != _coreGeneration) {
      return;
    }
    final currentGroups = _ref.read(groupsProvider);
    final isInitialLoad = currentGroups.isEmpty;
    final maxRetryRounds = isInitialLoad ? 6 : 4;
    final retryDelay = isInitialLoad
        ? const Duration(seconds: 2)
        : const Duration(seconds: 3);
    if (currentGroups.isNotEmpty) {
      commonPrint.warn('updateGroups error: $e');
      return;
    }

    if (_updateGroupsRetryCount >= maxRetryRounds) {
      _updateGroupsRetryCount = 0;
      return;
    }
    _updateGroupsRetryCount++;
    _updateGroupsRetryTimer?.cancel();
    _updateGroupsRetryTimer = Timer(retryDelay, () {
      if (generation != _coreGeneration) return;
      Zone.root.run(() {
        unawaited(updateGroups());
      });
    });
  }

  Future<void> _updateGroups() async {
    if (_isUpdatingGroups) {
      commonPrint.debug('updateGroups already in progress, skipping');
      return;
    }
    _isUpdatingGroups = true;
    final generation = _coreGeneration;

    try {
      final currentGroups = _ref.read(groupsProvider);

      final newGroups = await _retryGetProxiesGroups();

      if (newGroups.isEmpty) {
        _handleUpdateGroupsError(
          generation,
          'getProxiesGroups returned empty after inner retries',
        );
        return;
      }

      try {
        final activeMode = await clashCore.getMode();
        final currentMode = _ref.read(patchClashConfigProvider).mode;
        if (activeMode != currentMode) {
          if (DateTime.now().difference(_lastModeChangeTime) >
              const Duration(seconds: 2)) {
            _ref
                .read(patchClashConfigProvider.notifier)
                .updateState((state) => state.copyWith(mode: activeMode));
            if (activeMode == Mode.global) {
              updateCurrentGroupName(GroupName.GLOBAL.name);
            }
            addCheckIpNumDebounce();
          }
        }
      } catch (e) {
        commonPrint.warn('Failed to sync active mode: $e');
      }

      final currentProfile = _ref.read(currentProfileProvider);
      if (currentProfile != null) {
        final selectedMap = Map<String, String>.from(
          currentProfile.selectedMap,
        );
        bool hasChanged = false;

        for (final newGroup in newGroups) {
          final oldGroup = currentGroups.firstWhereOrNull(
            (g) => g.name == newGroup.name,
          );
          if (oldGroup != null &&
              newGroup.type == GroupType.Selector &&
              newGroup.now != oldGroup.now) {
            if (selectedMap[newGroup.name] != newGroup.realNow) {
              selectedMap[newGroup.name] = newGroup.realNow;
              hasChanged = true;
            }
          }
        }

        if (hasChanged) {
          _ref
              .read(profilesProvider.notifier)
              .setProfile(currentProfile.copyWith(selectedMap: selectedMap));
        }
      }

      if (currentGroups.isNotEmpty) {
        bool activeProxyChanged = false;
        for (final newGroup in newGroups) {
          final oldGroup = currentGroups.firstWhereOrNull(
            (g) => g.name == newGroup.name,
          );
          if (oldGroup != null && oldGroup.now != newGroup.now) {
            activeProxyChanged = true;
            break;
          }
        }
        if (activeProxyChanged) {
          addCheckIpNumDebounce();
        }
      }

      _applyManagedProxiesStyle();
      applyListIconStyle(newGroups);

      if (!listEquals(currentGroups, newGroups)) {
        _ref.read(groupsProvider.notifier).value = newGroups;
      }
      _updateGroupsRetryCount = 0;
      _updateGroupsRetryTimer?.cancel();
      _updateGroupsRetryTimer = null;
      return;
    } catch (e) {
      _handleUpdateGroupsError(generation, e);
    } finally {
      _isUpdatingGroups = false;
    }
  }

  void _applyManagedProxiesStyle() {
    final profile = _ref.read(currentProfileProvider);
    if (profile == null || !profile.isManaged || profile.managedStyleApplied) {
      return;
    }
    _ref
        .read(profilesProvider.notifier)
        .updateProfile(
          profile.id,
          (state) => state.copyWith(managedStyleApplied: true),
        );
    _ref.read(proxiesStyleSettingProvider.notifier).updateState((state) {
      return state.copyWith(
        type: ProxiesType.list,
        iconStyle: ProxiesIconStyle.icon,
        hasCustomizedStyle: true,
      );
    });
  }

  void applyListIconStyle([List<Group>? groups]) {
    final style = _ref.read(proxiesStyleSettingProvider);
    if (style.hasCustomizedStyle || style.type != ProxiesType.list) return;
    final List<Group> current = groups ?? _ref.read(groupsProvider);
    if (!current.any((group) => group.icon.trim().isNotEmpty)) return;
    _ref.read(proxiesStyleSettingProvider.notifier).updateState((state) {
      return state.copyWith(
        iconStyle: ProxiesIconStyle.icon,
        hasCustomizedStyle: true,
      );
    });
  }

  Future<void> updateProfiles() async {
    for (final profile in _ref.read(profilesProvider)) {
      if (profile.type != ProfileType.url) {
        continue;
      }
      try {
        await updateProfile(profile);
      } catch (e) {
        commonPrint.error(
          '[UpdateProfiles] Failed to update ${profile.label ?? profile.id}: ${e.formatErrorLog}',
        );
      }
    }
  }

  Future<void> savePreferences() async {
    debouncer.cancel(FunctionTag.savePreferences);
    await preferences.saveConfig(globalState.config);
  }

  Future<void> changeProxy({
    required String groupName,
    required String proxyName,
  }) async {
    await clashCore.changeProxy(
      ChangeProxyParams(groupName: groupName, proxyName: proxyName),
    );
    final closeConnections = system.isAndroid
        ? _ref.read(vpnSettingProvider).quickResponse
        : _ref.read(appSettingProvider).closeConnections;
    if (closeConnections) {
      await clashCore.closeGroupConnections(groupName);
    }
    addCheckIp();
  }

  Future<void> handleBackOrExit() async {
    if (_ref.read(backBlockProvider)) {
      return;
    }
    if (system.isDesktop) {
      await savePreferences();
    }
    await system.back();
  }

  void backBlock() {
    _ref.read(backBlockProvider.notifier).value = true;
  }

  void unBackBlock() {
    _ref.read(backBlockProvider.notifier).value = false;
  }

  Future<void> setProcessPriority(bool enable) async {
    if (!system.isWindows) return;

    try {
      await system.setProcessPriority(
        '${AppIdentity.mainExecutableName}.exe',
        enable,
      );
      if (kDebugMode || appPath.isPortable) return;
      await helperClient.setProcessPriority(
        '${AppIdentity.coreExecutableName}.exe',
        enable,
      );
    } catch (e) {
      commonPrint.warn('Set process priority error: $e');
      rethrow;
    }
  }

  Future<void> handleExit() async {
    if (_exitLock != null) {
      return _exitLock!.future;
    }

    final exitLock = Completer<void>();
    _exitLock = exitLock;
    globalState.isExiting = true;

    try {
      if (system.isDesktop) {
        try {
          await trayManager.destroy();
        } catch (e) {
          commonPrint.warn('Failed to destroy tray icon on exit: $e');
        }
      }
      stopWakelockAutoRecovery();
      await globalState.handleBackground();
      if (system.isDesktop) {
        final prefs = await preferences.sharedPreferencesCompleter.future;
        await prefs?.setBool('is_tun_running', false);
      }
      await savePreferences();
      if (proxy != null) {
        await proxy!.stopProxy();
      }
      await clashCore.shutdown();
      if (clashService != null) {
        await clashService!.destroy();
      }
    } catch (e) {
      commonPrint.warn('handleExit error: $e');
    } finally {
      try {
        await system.updateDns(true);
      } catch (e) {
        commonPrint.warn('Failed to restore system DNS on exit: $e');
      }
      if (!exitLock.isCompleted) {
        exitLock.complete();
      }
      system.exit();
    }
  }

  Future handleClear() async {
    await preferences.clearPreferences();
    commonPrint.log('clear preferences');
    globalState.config = Config(
      themeProps: defaultThemeProps,
      networkProps: defaultNetworkProps,
    );
  }

  Future<void> autoCheckUpdate() async {
    final prefs = await preferences.sharedPreferencesCompleter.future;
    final lastCheckTime = prefs?.getInt('last_check_update_time') ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    final isAutoCheck = _ref.read(appSettingProvider).autoCheckUpdate;

    final forceCheck =
        (now - lastCheckTime) > const Duration(days: 28).inMilliseconds;

    if (!isAutoCheck && !forceCheck) return;

    final res = await request.checkForUpdate();
    if (res != null) {
      checkUpdateResultHandle(data: res);
    }

    await prefs?.setInt('last_check_update_time', now);
  }

  Future<void> checkUpdateResultHandle({
    Map<String, dynamic>? data,
    bool handleError = false,
  }) async {
    if (globalState.isPre && !handleError) {
      return;
    }
    if (data != null) {
      final tagName = data['tag_name'];
      final body = data['body'];
      final submits = utils.parseReleaseBody(body);
      final textTheme = context.textTheme;
      final res = await globalState.showMessage(
        title: appLocalizations.discoverNewVersion,
        message: TextSpan(
          text: '$tagName \n',
          style: textTheme.headlineSmall,
          children: [
            TextSpan(text: '\n', style: textTheme.bodyMedium),
            for (final submit in submits)
              TextSpan(text: '- $submit \n', style: textTheme.bodyMedium),
          ],
        ),
        confirmText: appLocalizations.goDownload,
      );
      if (res != true) {
        return;
      }
      const String assetSuffix = String.fromEnvironment('APP_ASSET_SUFFIX');
      String downloadUrl = 'https://github.com/$repository/releases/latest';

      if (assetSuffix.isNotEmpty) {
        final versionWithoutV = tagName.startsWith('v')
            ? tagName.substring(1)
            : tagName;
        var finalSuffix = assetSuffix;
        if (appPath.isPortable && system.isWindows) {
          finalSuffix = 'windows-amd64-compatible-portable.zip';
        }
        downloadUrl =
            'https://github.com/$repository/releases/download/$tagName/Bettbox-$versionWithoutV-$finalSuffix';
      }

      globalState.openUrl(downloadUrl);
    } else if (handleError) {
      globalState.showMessage(
        title: appLocalizations.checkUpdate,
        message: TextSpan(text: appLocalizations.checkUpdateError),
        cancelable: false,
      );
    }
  }

  Future<void> _handlePreference() async {
    if (await preferences.isInit) {
      return;
    }
    final res = await globalState.showMessage(
      title: appLocalizations.tip,
      message: TextSpan(text: appLocalizations.cacheCorrupt),
    );
    if (res == true) {
      final file = File(await appPath.sharedPreferencesPath);
      if (await file.exists()) {
        await file.delete();
      }
      final configFile = File(await appPath.appConfigPath);
      if (await configFile.exists()) {
        await configFile.delete();
      }
    }
    await handleExit();
  }

  Future<void>? _initCoreFuture;

  Future<void> _initCore() {
    return _initCoreFuture ??= () async {
      try {
        if (!await _waitForCoreConnection()) {
          commonPrint.debug('core not connected yet, skipping init');
          return;
        }
        final isInit = await clashCore.isInit;
        if (!isInit) {
          await clashCore.init();
          await clashCore.setState(globalState.getCoreState());
        }
      } finally {
        _initCoreFuture = null;
      }
    }();
  }

  Future<bool> _waitForCoreConnection() async {
    final completer = clashService?.socketCompleter;
    if (completer == null || completer.isCompleted) return true;
    try {
      await completer.future.timeout(const Duration(seconds: 15));
      return true;
    } on TimeoutException {
      return false;
    }
  }

  void startWakelockAutoRecovery() {
    _wakelockSyncTimer?.cancel();
    _wakelockSyncTimer = Timer.periodic(const Duration(seconds: 168), (
      _,
    ) async {
      try {
        final userEnabled = _ref.read(wakelockStateProvider);

        if (!userEnabled) {
          stopWakelockAutoRecovery();
          return;
        }

        await syncWakelockIfNeeded();
      } catch (_) {}
    });
  }

  void stopWakelockAutoRecovery() {
    _wakelockSyncTimer?.cancel();
    _wakelockSyncTimer = null;
  }

  Future<void> holdWakelock(bool hold) async {
    try {
      if (hold) {
        await WakelockPlus.enable();
      } else if (!_ref.read(wakelockStateProvider)) {
        await WakelockPlus.disable();
      }
    } catch (e) {
      commonPrint.warn('Failed to update wake lock: $e');
    }
  }

  Future<void> syncWakelockIfNeeded() async {
    final userEnabled = _ref.read(wakelockStateProvider);
    if (!userEnabled) {
      stopWakelockAutoRecovery();
      return;
    }
    final actualState = await WakelockPlus.enabled;
    if (actualState) {
      return;
    }
    await WakelockPlus.enable();
  }

  Future<void> init() async {
    FlutterError.onError = (details) {
      if (kDebugMode) {
        FlutterError.dumpErrorToConsole(details);
      }
    };

    vpn_service.service?.addNativeEventCallback((method, arguments) async {
      if (method == 'vpnStartFailed') {
        globalState.showNotifier('Failed, Please try again later');
        await updateStatus(false);
      } else if (method == 'runStateChanged') {
        final state = arguments as String?;
        if (state == 'STOP' && globalState.isStart) {
          await updateStatus(false);
        }
      } else if (method == 'screenStateChanged') {
        await globalState.handleScreenStateChanged(arguments as bool? ?? true);
      }
    });

    try {
      final wakelockEnabled = await WakelockPlus.enabled;
      _ref.read(wakelockStateProvider.notifier).state = wakelockEnabled;

      if (wakelockEnabled) {
        startWakelockAutoRecovery();
      }
    } catch (e) {
      commonPrint.warn('Failed to check wake lock status: $e');
    }

    await updateTray(true);

    await _initCore();
    try {
      await _initStatus();
    } catch (e) {
      commonPrint.warn('_initStatus failed, falling back to basic startup: $e');
      try {
        await applyProfile(silence: true);
      } catch (e2) {
        commonPrint.error('Fallback applyProfile also failed: $e2');
      }
    }

    await updateGroups();
    unawaited(checkManagedScriptVersionUpgrade());

    autoLaunch?.updateStatus(_ref.read(appSettingProvider).autoLaunch);
    Future.delayed(const Duration(seconds: 5), () {
      autoUpdateProfiles();
    });
    autoCheckUpdate();

    final isWindowVisible = await window?.isVisible ?? false;
    if (isWindowVisible) {
      window?.show();
    } else {
      if (!_ref.read(appSettingProvider).silentLaunch) {
        window?.show();
      } else {
        window?.hide();
      }
    }
    await syncDesktopRuntimeState(preferCurrentState: true);
    await updateTray(true, false, true);

    await _handlePreference();
    await _handlerDisclaimer();
    if (system.isWindows) {
      unawaited(
        setProcessPriority(
          _ref.read(appSettingProvider).enableHighPriority,
        ).catchError((e) {
          commonPrint.warn('Failed to set initial process priority: $e');
        }),
      );
    }
    _ref.read(initProvider.notifier).value = true;
  }

  Future<void> _initStatus() async {
    if (system.isAndroid) {
      await globalState.updateStartTime();
      if (globalState.isStart && _ref.read(runTimeProvider) == null) {
        _ref.read(runTimeProvider.notifier).value = 0;
      }
    } else if (system.isDesktop) {
      await syncDesktopRuntimeState();
    }

    final needRecovery = await _detectAbnormalExit();

    if (needRecovery) {
      commonPrint.warn('Abnormal exit detected');
      if (system.isAndroid) {
        final prefs = await preferences.sharedPreferencesCompleter.future;
        await prefs?.setBool('is_vpn_running', false);
      }
    }
    if (!globalState.isStart) {
      await system.updateDns(true);
    }
    if (system.isAndroid && globalState.isStart) {
      await _coreLifecycleLock.synchronized(() async {
        await globalState.handleStart([updateRunTime, updateTraffic]);
      });
      _scheduleCheckIpRefresh();
      _backgroundLoad();
      return;
    }
    final hasProfile = _ref.read(currentProfileProvider) != null;
    final isSmartStopped =
        system.isAndroid &&
        (await vpn_service.service?.isSmartStopped() ?? false);
    final shouldStart =
        hasProfile &&
        !isSmartStopped &&
        (globalState.isStart || _ref.read(appSettingProvider).autoRun);

    if (shouldStart) {
      try {
        await updateStatus(true);
      } catch (e) {
        commonPrint.error('Auto start failed: $e');
        await applyProfile();
        addCheckIpNumDebounce();
      }
    } else {
      await applyProfile();
      addCheckIpNumDebounce();
    }
  }

  Future<void> syncDesktopRuntimeState({
    bool preferCurrentState = false,
  }) async {
    if (!system.isDesktop) return;
    if (!preferCurrentState || !globalState.isStart) {
      await globalState.updateStartTime();
    }

    if (globalState.isStart) {
      if (_ref.read(runTimeProvider) == null) {
        _ref.read(runTimeProvider.notifier).value = 0;
      }
      await globalState.startUpdateTasks([updateTraffic]);
      return;
    }

    if (_ref.read(runTimeProvider) != null) {
      _ref.read(runTimeProvider.notifier).value = null;
    }
    globalState.stopUpdateTasks();
  }

  Future<bool> _detectAbnormalExit() async {
    final prefs = await preferences.sharedPreferencesCompleter.future;

    if (system.isAndroid) {
      final isVpnRunningFlag = prefs?.getBool('is_vpn_running') ?? false;
      return !globalState.isStart && isVpnRunningFlag;
    }

    if (system.isDesktop) {
      final wasTunRunning = prefs?.getBool('is_tun_running') ?? false;
      return !globalState.isStart && wasTunRunning;
    }

    return false;
  }

  void setDelay(Delay delay) {
    _ref.read(delayDataSourceProvider.notifier).setDelay(delay);
  }

  int? getTrayProxyDelay({required String proxyName, String? testUrl}) {
    return _ref.read(getDelayProvider(proxyName: proxyName, testUrl: testUrl));
  }

  void toPage(PageLabel pageLabel) {
    final context = globalState.navigatorKey.currentState?.context;
    if (context != null && context.mounted) {
      final navigator = Navigator.of(context, rootNavigator: true);
      if (navigator.canPop()) {
        navigator.popUntil((route) => route.isFirst);
      }
    }
    _ref.read(currentPageLabelProvider.notifier).value = pageLabel;
    pageNavigationController.visit(pageLabel);
  }

  void toProfiles() {
    toPage(PageLabel.profiles);
  }

  bool _isRemoteFileUri(Uri uri) {
    if (!uri.isScheme('file')) return false;
    final host = uri.host.toLowerCase();
    final remoteHost =
        host.isNotEmpty &&
        host != 'localhost' &&
        !RegExp(r'^[a-z]$').hasMatch(host);
    return remoteHost ||
        uri.pathSegments.any((segment) => segment.contains('\\'));
  }

  void initLink() {
    linkManager.initAppLinksListen((url) async {
      final uri = Uri.tryParse(url);
      if (uri == null || _isRemoteFileUri(uri)) {
        globalState.showNotifier(
          appLocalizations.profileUrlInvalidValidationDesc,
        );
        return;
      }
      final res = await globalState.showMessage(
        title: appLocalizations.add,
        message: TextSpan(
          children: [
            TextSpan(text: appLocalizations.doYouWantToPass),
            TextSpan(
              text: ' $url ',
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                decoration: TextDecoration.underline,
                decorationColor: Theme.of(context).colorScheme.primary,
              ),
            ),
            TextSpan(text: appLocalizations.create),
          ],
        ),
      );

      if (res != true) {
        return;
      }
      addProfileFormURL(url);
    });
  }

  Future<bool> showDisclaimer() async {
    return await globalState.showCommonDialog<bool>(
          dismissible: false,
          child: CommonDialog(
            title: appLocalizations.disclaimer,
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop<bool>(false);
                },
                child: Text(appLocalizations.exit),
              ),
              TextButton(
                onPressed: () {
                  _ref
                      .read(appSettingProvider.notifier)
                      .updateState(
                        (state) => state.copyWith(disclaimerAccepted: true),
                      );
                  Navigator.of(context).pop<bool>(true);
                },
                child: Text(appLocalizations.agree),
              ),
            ],
            child: SelectableText(appLocalizations.disclaimerDesc),
          ),
        ) ??
        false;
  }

  Future<void> _handlerDisclaimer() async {
    if (_ref.read(appSettingProvider).disclaimerAccepted) {
      return;
    }
    final isDisclaimerAccepted = await showDisclaimer();
    if (!isDisclaimerAccepted) {
      await handleExit();
    }
    return;
  }

  Future<void> addProfileFormURL(String url, {String? ageSecretKey}) async {
    _ref.read(loadingProvider.notifier).value = true;
    try {
      final profile = await Profile.normal(
        url: url,
        ageSecretKey: ageSecretKey,
      ).update();
      if (globalState.navigatorKey.currentState?.canPop() ?? false) {
        globalState.navigatorKey.currentState?.popUntil(
          (route) => route.isFirst,
        );
      }
      toProfiles();
      await addProfile(profile);
    } on Object catch (e) {
      await globalState.showMessage(
        title: appLocalizations.add,
        message: TextSpan(text: e.formatError),
        cancelable: false,
      );
    } finally {
      _ref.read(loadingProvider.notifier).value = false;
    }
  }

  Future<void> addProfileFormFile() async {
    final platformFiles = await safeRun(
      () => picker.pickerFiles(
        allowMultiple: true,
        allowedExtensions: ['yaml', 'yml'],
      ),
    );
    if (platformFiles == null || platformFiles.isEmpty) {
      return;
    }
    if (!context.mounted) return;

    final validFiles = platformFiles.where((file) {
      final name = file.name.toLowerCase();
      return name.endsWith('.yaml') || name.endsWith('.yml');
    }).toList();

    if (validFiles.isEmpty) {
      return;
    }

    _ref.read(loadingProvider.notifier).value = true;
    int successCount = 0;
    try {
      for (final platformFile in validFiles) {
        try {
          final bytes = await platformFile.readAsBytes();
          if (bytes.isEmpty) continue;
          final profile = await Profile.normal(
            label: platformFile.name,
          ).saveFile(bytes);
          await addProfile(profile);
          successCount++;
        } on Object catch (e) {
          if (!context.mounted) break;
          await globalState.showMessage(
            title: '${platformFile.name} (${appLocalizations.add})',
            message: TextSpan(text: e.formatError),
            cancelable: false,
          );
        }
      }

      if (successCount > 0) {
        globalState.navigatorKey.currentState?.popUntil(
          (route) => route.isFirst,
        );
        toProfiles();
      }
    } finally {
      _ref.read(loadingProvider.notifier).value = false;
    }
  }

  Future<void> addProfileFormQrCode() async {
    final url = await safeRun(picker.pickerConfigQRCode);
    if (url == null) return;
    addProfileFormURL(url);
  }

  void updateViewSize(Size size) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_ref.read(viewSizeProvider) == size) return;
      _ref.read(viewSizeProvider.notifier).value = size;
    });
  }

  void setProvider(ExternalProvider? provider) {
    _ref.read(providersProvider.notifier).setProvider(provider);
    if (provider == null || provider.isUpdating) return;
    _syncProviderSubscriptions(_ref.read(providersProvider));
  }

  /// Non-widget entry for the tray menu. Reads the same in-flight-safe
  /// snapshot as the UI path (SortedGroupProxies), so a delay test in
  /// flight cannot make a proxy jump to the front of the tray either.
  List<Proxy> getSortProxies({
    required List<Proxy> proxies,
    required ProxiesSortType sortType,
    String? testUrl,
  }) {
    if (sortType != ProxiesSortType.delay) {
      return sortProxies(proxies, sortType);
    }
    final delayOf = createDelayLookup(
      groups: _ref.read(groupsProvider),
      selectedMap: _ref.read(selectedMapProvider),
      delayMap: _ref.read(delaySortSnapshotProvider),
      defaultTestUrl: _ref.read(appSettingProvider).testUrl,
    );
    return sortProxies(
      proxies,
      sortType,
      delayOf: (proxyName) => delayOf(proxyName, testUrl),
    );
  }

  Future<void> clearEffect(String profileId) async {
    final profilePath = await appPath.getProfilePath(profileId);
    final providersDirPath = await appPath.getProvidersDirPath(profileId);
    final relayPath = await appPath.relayPath;
    await Isolate.run(() async {
      final profileFile = File(profilePath);
      final isExists = await profileFile.exists();
      if (isExists) {
        await profileFile.delete(recursive: true);
      }
      for (final stem in ['cache-$profileId', 'cache-$profileId-managed']) {
        for (final extension in const ['json', 'key']) {
          final cacheFile = File(join(relayPath, '$stem.$extension'));
          if (await cacheFile.exists()) {
            await cacheFile.delete();
          }
        }
      }
      final providersFileDir = Directory(providersDirPath);
      final providersFileIsExists = await providersFileDir.exists();
      if (providersFileIsExists) {
        await providersFileDir.delete(recursive: true);
      }
    });
  }

  void updateTun() {
    _ref
        .read(patchClashConfigProvider.notifier)
        .updateState((state) => state.copyWith.tun(enable: !state.tun.enable));
    if (system.isLinux && globalState.backgroundMode.value) {
      unawaited(updateClashConfig());
    } else {
      updateClashConfigDebounce();
    }
  }

  void updateSystemProxy() {
    _ref
        .read(networkSettingProvider.notifier)
        .updateState(
          (state) => state.copyWith(systemProxy: !state.systemProxy),
        );
  }

  Future<List<Package>> getPackages({bool forceRefresh = false}) async {
    final cached = _ref.read(packagesProvider);
    if (!forceRefresh && cached.isNotEmpty) return cached;

    final packages = await app.getPackages(forceRefresh: forceRefresh);
    _ref.read(packagesProvider.notifier).value = packages;
    return packages;
  }

  void updateStart() {
    updateStatus(!_ref.read(runTimeProvider.notifier).isStart);
  }

  void updateCurrentSelectedMap(String groupName, String proxyName) {
    final currentProfile = _ref.read(currentProfileProvider);
    if (currentProfile != null &&
        currentProfile.selectedMap[groupName] != proxyName) {
      final SelectedMap selectedMap = Map.from(currentProfile.selectedMap)
        ..[groupName] = proxyName;
      _ref
          .read(profilesProvider.notifier)
          .setProfile(currentProfile.copyWith(selectedMap: selectedMap));
    }
  }

  void updateCurrentUnfoldSet(Set<String> value) {
    final currentProfile = _ref.read(currentProfileProvider);
    if (currentProfile == null) {
      return;
    }
    _ref
        .read(profilesProvider.notifier)
        .setProfile(currentProfile.copyWith(unfoldSet: value));
  }

  void changeMode(Mode mode) {
    _lastModeChangeTime = DateTime.now();
    _ref
        .read(patchClashConfigProvider.notifier)
        .updateState((state) => state.copyWith(mode: mode));
    if (mode == Mode.global) {
      updateCurrentGroupName(GroupName.GLOBAL.name);
    }
    if (system.isLinux && globalState.backgroundMode.value) {
      unawaited(updateClashConfig());
    } else {
      updateClashConfigDebounce();
    }
    updateGroupsDebounce();
    addCheckIpNumDebounce();
  }

  void updateAutoLaunch() {
    _ref
        .read(appSettingProvider.notifier)
        .updateState((state) => state.copyWith(autoLaunch: !state.autoLaunch));
  }

  Future<void> updateVisible() async {
    final visible = await window?.isVisible;
    if (visible != null && !visible) {
      window?.show();
    } else {
      window?.hide();
    }
  }

  void updateMode() {
    _lastModeChangeTime = DateTime.now();
    _ref.read(patchClashConfigProvider.notifier).updateState((state) {
      final index = Mode.values.indexWhere((item) => item == state.mode);
      if (index == -1) {
        return null;
      }
      final nextIndex = index + 1 > Mode.values.length - 1 ? 0 : index + 1;
      return state.copyWith(mode: Mode.values[nextIndex]);
    });
  }

  Future<void> handleAddOrUpdate(WidgetRef ref, [Rule? rule]) async {
    final res = await globalState.showCommonDialog<Rule>(
      child: AddRuleDialog(
        rule: rule,
        snippet: ref.read(
          profileOverrideStateProvider.select((state) => state.snippet!),
        ),
      ),
    );
    if (res == null) {
      return;
    }
    ref.read(profileOverrideStateProvider.notifier).updateState((state) {
      final model = state.copyWith.overrideData!(
        rule: state.overrideData!.rule.updateRules((rules) {
          final index = rules.indexWhere((item) => item.id == res.id);
          if (index == -1) {
            return List.from([res, ...rules]);
          }
          return List.from(rules)..[index] = res;
        }),
      );
      return model;
    });
  }

  Future<bool> exportLogs() async {
    final logsRaw = _ref
        .read(filteredLogsProvider)
        .logs
        .map((item) => item.line)
        .toList();
    final data = await Isolate.run<List<int>>(() async {
      final logsRawString = logsRaw.join('\n');
      return utf8.encode(logsRawString);
    });
    return await picker.saveFile(utils.logFile, Uint8List.fromList(data)) !=
        null;
  }

  Future<List<int>> backupData({String password = ''}) =>
      _backup.backupData(password: password);

  Future<bool> backupToWebDAV(DAVClient client, DAV dav) =>
      _backup.backupToWebDAV(client, dav);

  void autoBackupDebounce() => _backup.autoBackupDebounce();

  Future<void> flushAutoBackup() => _backup.flushAutoBackup();

  Future<({bool decrypted})?> recoveryData(
    List<int> data,
    RecoveryOption recoveryOption,
  ) => _backup.recoveryData(data, recoveryOption);

  Future<({bool decrypted})?> recoveryDataFromFile(
    String path,
    RecoveryOption recoveryOption,
  ) => _backup.recoveryDataFromFile(path, recoveryOption);

  Future<void> updateTray([
    bool focus = false,
    bool silent = false,
    bool force = false,
  ]) async {
    var trayState = _ref.read(trayStateProvider);
    if (tray.showHiddenGroups) {
      trayState = trayState.copyWith(
        groups: getVisibleGroups(
          mode: trayState.mode,
          groups: _ref.read(groupsProvider),
          showHiddenItems: true,
        ),
      );
    }
    await tray.update(
      trayState: trayState,
      focus: focus,
      silent: silent,
      force: force,
    );
  }

  Future<T?> safeRun<T>(
    FutureOr<T> Function() futureFunction, {
    String? title,
    bool needLoading = false,
    bool silence = true,
  }) async {
    try {
      if (needLoading) {
        _ref.read(loadingProvider.notifier).value = true;
      }
      final res = await futureFunction();
      return res;
    } on Object catch (e) {
      commonPrint.error(e.formatErrorLog);
      final errorMessage = e.formatError;
      if (needLoading) {
        _ref.read(loadingProvider.notifier).value = false;
      }
      if (silence) {
        globalState.showNotifier(errorMessage);
      } else {
        try {
          await globalState.showMessage(
            title: title ?? appLocalizations.tip,
            message: TextSpan(text: errorMessage),
            cancelable: false,
          );
        } catch (_) {
          globalState.showNotifier(errorMessage);
        }
      }
      return null;
    } finally {
      if (needLoading) {
        _ref.read(loadingProvider.notifier).value = false;
      }
    }
  }
}
