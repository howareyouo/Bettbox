import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:bett_box/common/archive.dart'
    show BackupPasswordException, decodeBackupArchive, restoreBackupFiles;
import 'package:bett_box/common/common.dart';
import 'package:bett_box/common/dav_client.dart';
import 'package:bett_box/controller.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/input.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart';
import 'package:yaml/yaml.dart';

/// Backup/restore implementation extracted from [AppController]; owns the
/// auto-backup state machine and all archive assembly/parsing.
class BackupService {
  BackupService(this._controller) : _ref = _controller.ref;

  final AppController _controller;
  final WidgetRef _ref;
  bool _isAutoBackupPending = false;
  bool _isAutoBackupRunning = false;
  bool _isAutoBackupSuppressed = false;

  static const _autoBackupFingerprintKey = 'auto_backup_fingerprint';

  Future<List<int>> backupData({String password = ''}) async {
    final homeDirPath = await appPath.homeDirPath;
    final profilesPath = await appPath.profilesPath;
    final scripts = await Future.wait(
      globalState.config.scriptProps.scripts.map(
        (script) async => script.copyWith(content: await script.readContent()),
      ),
    );
    final configJson =
        json.decode(
              json.encode(
                globalState.config.copyWith.scriptProps(scripts: scripts),
              ),
            )
            as Map<String, dynamic>;
    if (configJson['dav'] is Map) {
      final davMap = Map<String, dynamic>.from(configJson['dav'] as Map);
      if (davMap['user'] is String) {
        davMap['user'] = utils.encryptSecret(davMap['user'] as String);
      }
      if (davMap['password'] is String) {
        davMap['password'] = utils.encryptSecret(davMap['password'] as String);
      }
      configJson['dav'] = davMap;
    }
    if (configJson['appSetting'] case final Map<String, dynamic> appSetting) {
      appSetting.remove('backupPassword');
    }

    // Get valid profile IDs
    final validProfileIds = globalState.config.profiles
        .map((p) => p.id)
        .toSet();
    final currentProfileId = globalState.config.currentProfileId;

    commonPrint.log(
      'Starting backup: ${validProfileIds.length} profiles, current: $currentProfileId',
    );

    return Isolate.run<List<int>>(() async {
      // Use ZipFileEncoder like FLClash - more reliable than ZipEncoder + Archive
      final tempDir = Directory.systemTemp;
      final tempZipPath = join(
        tempDir.path,
        'bettbox_backup_${DateTime.now().millisecondsSinceEpoch}.zip',
      );
      final encoder = ZipFileEncoder(
        password: password.isEmpty ? null : password,
      );
      encoder.create(tempZipPath);

      // Add marker file
      final markerData = json.encode({
        'app': 'Bettbox',
        'version': '1.0',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      final markerBytes = utf8.encode(markerData);
      final tempMarkerFile = File(
        join(
          tempDir.path,
          'bettbox_marker_${DateTime.now().millisecondsSinceEpoch}.tmp',
        ),
      );
      await tempMarkerFile.writeAsBytes(markerBytes);
      await encoder.addFile(tempMarkerFile, '.bettbox_marker');
      await tempMarkerFile.delete();

      // Add config file
      final configStr = json.encode(configJson);
      final tempConfigFile = File(
        join(
          tempDir.path,
          'bettbox_config_${DateTime.now().millisecondsSinceEpoch}.tmp',
        ),
      );
      await tempConfigFile.writeAsString(configStr);
      await encoder.addFile(tempConfigFile, 'config.json');
      await tempConfigFile.delete();

      // Add profiles dir (valid subscriptions only)
      final profilesDir = Directory(profilesPath);
      if (await profilesDir.exists()) {
        final files = await profilesDir
            .list(recursive: false)
            .toList(); // First level only

        for (final file in files) {
          if (file is File) {
            // Check if valid subscription config
            final fileName = basename(file.path);
            final profileId = fileName.replaceAll(RegExp(r'\.(yaml|yml)$'), '');

            if (validProfileIds.contains(profileId)) {
              // Normalize path: use Unix-style / separator
              final relativePath = relative(
                file.path,
                from: homeDirPath,
              ).replaceAll('\\', '/');
              await encoder.addFile(file, relativePath);
            }
          }
        }

        // Add current active subscription Providers
        if (currentProfileId != null &&
            validProfileIds.contains(currentProfileId)) {
          final providersDir = Directory(
            join(profilesPath, 'providers', currentProfileId),
          );

          if (await providersDir.exists()) {
            final providerFiles = await providersDir
                .list(recursive: true)
                .toList();

            for (final providerFile in providerFiles) {
              if (providerFile is File) {
                final relativePath = relative(
                  providerFile.path,
                  from: homeDirPath,
                ).replaceAll('\\', '/');
                await encoder.addFile(providerFile, relativePath);
              }
            }
          }
        }
      }

      encoder.close();

      // Read the zip file and return bytes
      final zipFile = File(tempZipPath);
      final bytes = await zipFile.readAsBytes();
      await zipFile.delete();
      return bytes;
    });
  }

  Future<String> _webDAVBackupFingerprint(DAV dav) async {
    final profiles = _ref.read(profilesProvider);
    final profilesPath = await appPath.profilesPath;
    final meta = json.encode([
      dav.uri,
      dav.fileName,
      ...profiles.map(
        (profile) => profile.backupView.copyWith(lastUpdateDate: null),
      ),
    ]);
    final ids = profiles.map((profile) => profile.id).toList();
    return Isolate.run(() {
      final builder = BytesBuilder(copy: false)..add(utf8.encode(meta));
      for (final id in ids) {
        final file = File(join(profilesPath, '$id.yaml'));
        if (!file.existsSync()) continue;
        final bytes = file.readAsBytesSync();
        builder
          ..add(utf8.encode('\n$id:${bytes.length}\n'))
          ..add(bytes);
      }
      return sha256.convert(builder.takeBytes()).toString();
    });
  }

  Future<bool> backupToWebDAV(DAVClient client, DAV dav) async {
    final fingerprint = await _webDAVBackupFingerprint(dav);
    final data = await backupData(
      password: _ref.read(
        appSettingProvider.select((state) => state.backupPassword),
      ),
    );
    final res = await client.backup(Uint8List.fromList(data));
    if (res) {
      final prefs = await preferences.sharedPreferencesCompleter.future;
      await prefs?.setString(_autoBackupFingerprintKey, fingerprint);
    }
    return res;
  }

  void autoBackupDebounce() {
    if (_isAutoBackupSuppressed) return;
    if (_ref.read(appDAVSettingProvider)?.autoBackup != true) return;
    debouncer.call(FunctionTag.autoBackup, () {
      _isAutoBackupPending = true;
      unawaited(flushAutoBackup());
    }, duration: const Duration(seconds: 10));
  }

  Future<void> flushAutoBackup() async {
    if (!_isAutoBackupPending ||
        _isAutoBackupRunning ||
        _isAutoBackupSuppressed) {
      return;
    }
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    if (lifecycleState != null && lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    final dav = _ref.read(appDAVSettingProvider);
    _isAutoBackupPending = false;
    if (dav == null || !dav.autoBackup) return;
    _isAutoBackupRunning = true;
    try {
      final fingerprint = await _webDAVBackupFingerprint(dav);
      final prefs = await preferences.sharedPreferencesCompleter.future;
      if (prefs?.getString(_autoBackupFingerprintKey) == fingerprint) {
        commonPrint.log('Auto backup skipped: no changes');
        return;
      }
      final res = await backupToWebDAV(DAVClient(dav), dav);
      if (res) {
        commonPrint.log('Auto backup finished');
        globalState.showNotifier(appLocalizations.autoBackupSuccess);
      }
    } catch (e) {
      commonPrint.error('Auto backup failed: ${e.formatErrorLog}');
      globalState.showNotifier(
        appLocalizations.autoBackupFailed(e.formatError),
      );
    } finally {
      _isAutoBackupRunning = false;
    }
    if (_isAutoBackupPending) {
      unawaited(flushAutoBackup());
    }
  }

  Future<String?> _requestBackupPassword(bool wrong) async {
    if (wrong) {
      globalState.showNotifier(appLocalizations.backupPasswordWrong);
    }
    final loading = _ref.read(loadingProvider);
    if (loading) {
      _ref.read(loadingProvider.notifier).value = false;
    }
    final password = await globalState.showCommonDialog<String>(
      child: InputDialog(
        title: appLocalizations.backupPassword,
        value: '',
        hintText: appLocalizations.backupPasswordRequired,
        obscureText: true,
        autofocus: true,
        validator: (value) {
          if (value == null || value.isEmpty) {
            return appLocalizations.emptyTip(appLocalizations.password);
          }
          return null;
        },
      ),
    );
    if (loading) {
      _ref.read(loadingProvider.notifier).value = true;
    }
    return password;
  }

  Future<({bool decrypted})?> _processRecoveryArchive(
    Future<({Archive archive, bool encrypted})> Function(String? password)
    getArchive,
    RecoveryOption recoveryOption,
  ) async {
    final savedPassword = _ref.read(
      appSettingProvider.select((state) => state.backupPassword),
    );
    String? password = savedPassword.isEmpty ? null : savedPassword;
    var userInput = false;
    _isAutoBackupSuppressed = true;
    try {
      while (true) {
        try {
          final (:archive, :encrypted) = await getArchive(password);
          commonPrint.log('Archive decoded: ${archive.files.length} files');
          await _recoveryFromArchive(archive, recoveryOption);
          if (userInput && password != null && savedPassword.isEmpty) {
            final value = password;
            _ref
                .read(appSettingProvider.notifier)
                .updateState((state) => state.copyWith(backupPassword: value));
          }
          return (decrypted: encrypted);
        } on BackupPasswordException catch (e) {
          final value = await _requestBackupPassword(e.wrong && userInput);
          if (value == null) return null;
          password = value;
          userInput = true;
        }
      }
    } catch (e) {
      commonPrint.error('Recovery failed: $e');
      throw 'Backup file is corrupted or invalid: $e';
    } finally {
      debouncer.cancel(FunctionTag.autoBackup);
      _isAutoBackupPending = false;
      _isAutoBackupSuppressed = false;
    }
  }

  /// Restore data from bytes
  Future<({bool decrypted})?> recoveryData(
    List<int> data,
    RecoveryOption recoveryOption,
  ) async {
    commonPrint.log('Starting recovery from bytes: ${data.length} bytes');
    return _processRecoveryArchive(
      (password) => Isolate.run(
        () => decodeBackupArchive(InputMemoryStream(data), password),
      ),
      recoveryOption,
    );
  }

  /// Restore data from file path
  Future<({bool decrypted})?> recoveryDataFromFile(
    String path,
    RecoveryOption recoveryOption,
  ) async {
    commonPrint.log('Starting recovery from file: $path');
    return _processRecoveryArchive(
      (password) => Isolate.run(() {
        try {
          final input = InputFileStream(path);
          try {
            final result = decodeBackupArchive(input, password);
            if (result.archive.files.isNotEmpty) {
              return result;
            }
          } finally {
            input.close();
          }
        } on BackupPasswordException {
          rethrow;
        } catch (e) {
          commonPrint.warn('Stream decoding failed: $e');
        }

        final bytes = File(path).readAsBytesSync();
        return decodeBackupArchive(InputMemoryStream(bytes), password);
      }),
      recoveryOption,
    );
  }

  /// Unified recovery entry: check marker and dispatch to recovery logic
  Future<void> _recoveryFromArchive(
    Archive archive,
    RecoveryOption recoveryOption,
  ) async {
    if (archive.files.isEmpty) {
      throw 'Backup file is empty or corrupted';
    }

    final homeDirPath = await appPath.homeDirPath;

    // Check for Bettbox marker
    final hasBettboxMarker = archive.files.any(
      (file) => file.name == '.bettbox_marker',
    );

    if (hasBettboxMarker) {
      // Bettbox backup
      await _recoveryBettboxBackup(archive, recoveryOption, homeDirPath);
    } else {
      // Legacy backup
      await _recoveryLegacyBackup(archive, recoveryOption, homeDirPath);
    }
  }

  /// Restore Bettbox
  Future<void> _recoveryBettboxBackup(
    Archive archive,
    RecoveryOption recoveryOption,
    String homeDirPath,
  ) async {
    // Separate config and profile files
    final configs = archive.files
        .where(
          (item) =>
              item.name.endsWith('.json') && item.name != '.bettbox_marker',
        )
        .toList();
    final profiles = archive.files.where(
      (item) => !item.name.endsWith('.json') && item.name != '.bettbox_marker',
    );

    // Find config.json
    final configIndex = configs.indexWhere(
      (config) => config.name == 'config.json',
    );
    if (configIndex == -1) throw 'invalid backup file';

    // Parse config
    final configFile = configs[configIndex];
    final configContent = configFile.content;
    if (configContent.isEmpty) {
      throw 'Config file is empty or corrupted';
    }
    var tempConfig = Config.compatibleFromJson(
      json.decode(utf8.decode(configContent)),
    );
    if (tempConfig.dav != null) {
      tempConfig = tempConfig.copyWith(
        dav: tempConfig.dav!.copyWith(
          user: utils.decryptSecret(tempConfig.dav!.user),
          password: utils.decryptSecret(tempConfig.dav!.password),
        ),
      );
    }

    final recoveryStrategy = _ref.read(
      appSettingProvider.select((state) => state.recoveryStrategy),
    );
    if (recoveryStrategy == RecoveryStrategy.override) {
      await _cleanProfilesDirForOverride();
    }

    await restoreBackupFiles(profiles, homeDirPath);

    if (recoveryOption != RecoveryOption.onlyProfiles) {
      tempConfig = tempConfig.copyWith(
        scriptProps: await tempConfig.scriptProps.externalize(),
      );
    }

    _recovery(tempConfig, recoveryOption);
    await _controller.savePreferences();
    if (globalState.isStart) {
      await _controller.applyProfile(silence: true);
    }
  }

  Future<void> _cleanProfilesDirForOverride() async {
    try {
      final profilesDirPath = await appPath.profilesPath;
      final dir = Directory(profilesDirPath);
      if (await dir.exists()) {
        await for (final entity in dir.list(followLinks: false)) {
          try {
            await entity.delete(recursive: true);
          } catch (e) {
            commonPrint.warn('Delete profile entity failed: $e');
          }
        }
      }
    } catch (e) {
      commonPrint.warn('Clean profiles dir for override failed: $e');
    }
  }

  /// Restore legacy
  Future<void> _recoveryLegacyBackup(
    Archive archive,
    RecoveryOption recoveryOption,
    String homeDirPath,
  ) async {
    // Separate config and profile files
    final configs = archive.files
        .where((item) => item.name.endsWith('.json'))
        .toList();
    final profileFiles = archive.files
        .where(
          (item) =>
              !item.name.endsWith('.json') && !item.name.endsWith('.sqlite'),
        )
        .toList();

    // Find config.json
    final configIndex = configs.indexWhere(
      (config) => config.name == 'config.json',
    );
    if (configIndex == -1) throw 'invalid backup file';

    // Parse backup config
    final configFile = configs[configIndex];
    final configContent = configFile.content;
    if (configContent.isEmpty) {
      throw 'Config file is empty or corrupted';
    }
    final backupConfig = Config.compatibleFromJson(
      json.decode(utf8.decode(configContent)),
    );

    final recoveryStrategy = _ref.read(
      appSettingProvider.select((state) => state.recoveryStrategy),
    );
    if (recoveryStrategy == RecoveryStrategy.override) {
      await _cleanProfilesDirForOverride();
    }

    await restoreBackupFiles(profileFiles, homeDirPath);

    List<Profile> profiles = [];

    if (backupConfig.profiles.isNotEmpty) {
      profiles = backupConfig.profiles;
    } else {
      for (final profileFile in profileFiles) {
        final fileName = profileFile.name.split('/').last;
        if (fileName.endsWith('.yaml') || fileName.endsWith('.yml')) {
          final id = fileName.replaceAll(RegExp(r'\.(yaml|yml)$'), '');
          final label = await _extractLabelFromYaml(profileFile) ?? id;

          profiles.add(
            Profile(
              id: id,
              label: label,
              autoUpdateDuration: defaultUpdateDuration,
              url: '',
            ),
          );
        }
      }
    }

    Config limitedConfig = globalState.config.copyWith(profiles: profiles);

    if (system.isAndroid) {
      final vpnProps = backupConfig.vpnProps;
      AccessControl? accessControl;

      try {
        accessControl = vpnProps.accessControl;
      } catch (_) {
        try {
          final configJson = json.decode(utf8.decode(configFile.content));
          final vpnPropsJson = configJson['vpnProps'];
          if (vpnPropsJson != null && vpnPropsJson is Map) {
            final accessControlPropsJson = vpnPropsJson['accessControlProps'];
            if (accessControlPropsJson != null &&
                accessControlPropsJson is Map) {
              accessControl = AccessControl.fromJson(
                Map<String, dynamic>.from(accessControlPropsJson),
              );
            }
          }
        } catch (_) {}
      }

      if (accessControl != null) {
        limitedConfig = limitedConfig.copyWith.vpnProps(
          accessControl: accessControl,
        );
      }
    }

    _recoveryLimited(limitedConfig, recoveryOption);
    await _controller.savePreferences();
    if (globalState.isStart) {
      await _controller.applyProfile(silence: true);
    }

    _showRecoveryResultMessage(profiles);
  }

  /// Extract label
  Future<String?> _extractLabelFromYaml(ArchiveFile profileFile) async {
    try {
      final yamlContent = utf8.decode(profileFile.content);

      // Try to extract from comments
      final lines = yamlContent.split('\n');
      for (final line in lines) {
        if (line.trim().startsWith('#')) {
          final comment = line.trim().substring(1).trim();
          if (comment.isNotEmpty &&
              comment.length < 50 &&
              !comment.startsWith('!')) {
            return comment;
          }
        }
      }

      // Try to extract from first proxy name
      final yamlMap = loadYaml(yamlContent);
      if (yamlMap is Map && yamlMap['proxies'] is List) {
        final proxies = yamlMap['proxies'] as List;
        if (proxies.isNotEmpty && proxies[0] is Map) {
          final firstProxy = proxies[0] as Map;
          final name = firstProxy['name'];
          if (name != null && name.toString().isNotEmpty) {
            return 'Sub - $name';
          }
        }
      }
    } catch (e) {
      commonPrint.warn('Failed to extract label from YAML: $e');
    }
    return null;
  }

  /// Show results
  void _showRecoveryResultMessage(List<Profile> profiles) {
    if (profiles.isEmpty) return;

    final hasEmptyUrl = profiles.any((p) => p.url.isEmpty);

    String message;
    if (hasEmptyUrl) {
      // Partial recovery, missing URLs
      message =
          'Restored ${profiles.length} subscriptions.\n\n'
          'Warning: URLs not included. Edit subscriptions to add URLs for auto-update.';
    } else {
      // Complete recovery
      message = 'Restored ${profiles.length} subscriptions.';
    }

    globalState.showMessage(
      title: appLocalizations.recoverySuccess,
      message: TextSpan(text: message),
      cancelable: false,
    );
  }

  void _restoreProfiles(List<Profile> profiles) {
    final recoveryStrategy = _ref.read(
      appSettingProvider.select((state) => state.recoveryStrategy),
    );
    if (recoveryStrategy == RecoveryStrategy.override) {
      _ref.read(profilesProvider.notifier).value = profiles;
    } else {
      for (final profile in profiles) {
        _ref.read(profilesProvider.notifier).setProfile(profile);
      }
    }
  }

  void _ensureCurrentProfile(List<Profile> profiles) {
    final currentProfile = _ref.read(currentProfileProvider);
    if (currentProfile == null && profiles.isNotEmpty) {
      _ref.read(currentProfileIdProvider.notifier).value = profiles.first.id;
    }
  }

  /// Partial restore
  void _recoveryLimited(Config config, RecoveryOption recoveryOption) {
    final profiles = config.profiles;

    // Restore subscriptions
    _restoreProfiles(profiles);

    // Android: restore app list
    if (system.isAndroid) {
      _ref
          .read(vpnSettingProvider.notifier)
          .updateState(
            (state) =>
                state.copyWith(accessControl: config.vpnProps.accessControl),
          );
    }

    // Ensure current profile exists
    _ensureCurrentProfile(profiles);
  }

  /// Full restore
  void _recovery(Config config, RecoveryOption recoveryOption) {
    final profiles = config.profiles;

    // Restore subscriptions
    _restoreProfiles(profiles);

    final onlyProfiles = recoveryOption == RecoveryOption.onlyProfiles;
    if (!onlyProfiles) {
      // Restore settings

      // 1. Clash config
      if (system.isDesktop) {
        // Desktop: preserve current TUN state, avoid mobile backup override
        final currentTunEnable = _ref.read(patchClashConfigProvider).tun.enable;
        _ref.read(patchClashConfigProvider.notifier).value = config
            .patchClashConfig
            .copyWith
            .tun(enable: currentTunEnable);
      } else {
        // Mobile: restore directly
        _ref.read(patchClashConfigProvider.notifier).value =
            config.patchClashConfig;
      }

      // 2. App settings
      final backupAppSetting = config.appSetting;
      final currentAppSetting = _ref.read(appSettingProvider);

      _ref.read(appSettingProvider.notifier).value = backupAppSetting.copyWith(
        backupPassword: currentAppSetting.backupPassword,
        recoveryStrategy: currentAppSetting.recoveryStrategy,
        mobileDashboardWidgets: backupAppSetting.mobileDashboardWidgets,
        desktopDashboardWidgets: backupAppSetting.desktopDashboardWidgets,
        dashboardWidgets: system.isAndroid
            ? backupAppSetting.mobileDashboardWidgets
            : backupAppSetting.desktopDashboardWidgets,
      );

      // 3. Restore current profile ID
      _ref.read(currentProfileIdProvider.notifier).value =
          config.currentProfileId;

      // 4. Restore WebDAV settings
      if (config.dav case final dav?) {
        _ref.read(appDAVSettingProvider.notifier).value = dav;
      }

      // 5. Restore theme settings
      _ref.read(themeSettingProvider.notifier).value = config.themeProps;

      // 6. Restore window settings (desktop only)
      if (system.isDesktop) {
        _ref.read(windowSettingProvider.notifier).value = config.windowProps;
      }

      // 7. VPN settings
      if (system.isAndroid) {
        final currentVpnProps = _ref.read(vpnSettingProvider);
        final hasBackupAccessControl =
            config.vpnProps.accessControl.enable ||
            config.vpnProps.accessControl.acceptList.isNotEmpty ||
            config.vpnProps.accessControl.rejectList.isNotEmpty;
        _ref.read(vpnSettingProvider.notifier).value = config.vpnProps.copyWith(
          accessControl: hasBackupAccessControl
              ? config.vpnProps.accessControl
              : currentVpnProps.accessControl,
        );
      } else if (system.isDesktop) {
        // Desktop: restore network settings, preserve TUN state
        final currentVpnProps = _ref.read(vpnSettingProvider);
        _ref.read(networkSettingProvider.notifier).value = config.networkProps;

        // Only restore non-platform-specific VPN settings
        _ref.read(vpnSettingProvider.notifier).value = config.vpnProps.copyWith(
          enable: currentVpnProps.enable, // Preserve current TUN state
        );
      }

      // 8. Restore proxy style
      _ref.read(proxiesStyleSettingProvider.notifier).value =
          config.proxiesStyle;

      // 9. Restore DNS override settings
      _ref.read(overrideDnsProvider.notifier).value = config.overrideDns;

      // 10. Restore hotkey settings (desktop only)
      if (system.isDesktop) {
        _ref.read(hotKeyActionsProvider.notifier).value = config.hotKeyActions;
      }

      // 11. Restore script settings
      final scriptIds = config.scriptProps.scripts.map((e) => e.id).toSet();
      final currentScriptProps = _ref.read(scriptStateProvider);
      final localScripts = currentScriptProps.scripts.where(
        (script) => !scriptIds.contains(script.id),
      );
      if (_ref.read(appSettingProvider).recoveryStrategy ==
          RecoveryStrategy.override) {
        for (final script in localScripts) {
          unawaited(script.deleteContent());
        }
        _ref.read(scriptStateProvider.notifier).value = config.scriptProps;
      } else {
        _ref.read(scriptStateProvider.notifier).value = config.scriptProps
            .copyWith(
              currentId:
                  config.scriptProps.currentId ?? currentScriptProps.currentId,
              scripts: [...config.scriptProps.scripts, ...localScripts],
            );
      }
    }

    // Ensure current profile exists
    _ensureCurrentProfile(profiles);
  }
}
