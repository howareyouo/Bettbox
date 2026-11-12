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
import 'package:bett_box/common/profile_recovery.dart';
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

class _RecoveryApplyException implements Exception {
  const _RecoveryApplyException(this.error);

  final Object error;
}

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
  static const _managedScriptBackupKey = 'managedScript';
  static const _backupDesktopKey = 'backupDesktop';
  static const _configBackupName = 'config.json';
  static const _profilesBackupName = 'profiles.json';
  static const _profileBackupKeys = {
    'profiles',
    'currentProfileId',
    'scriptProps',
    'managedProps',
    'nodes',
    _managedScriptBackupKey,
  };

  Future<List<int>> backupData({
    String password = '',
    BackupScope scope = BackupScope.all,
  }) async {
    final homeDirPath = await appPath.homeDirPath;
    final profilesPath = await appPath.profilesPath;
    final scripts = await Future.wait(
      globalState.config.scriptProps.scripts.map(
        (script) async => script.copyWith(content: await script.readContent()),
      ),
    );
    final configJson = json.decode(
      json.encode(globalState.config.copyWith.scriptProps(scripts: scripts)),
    ) as Map<String, dynamic>;
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
    configJson[_backupDesktopKey] = system.isDesktop;
    final managedProps = globalState.config.managedProps;
    if (ManagedScript.isCustom(managedProps)) {
      configJson[_managedScriptBackupKey] = await ManagedScript.read(
        managedProps,
      );
    }
    final onlyProfiles = scope == BackupScope.onlyProfiles;
    if (onlyProfiles) {
      configJson.removeWhere((key, _) => !_profileBackupKeys.contains(key));
    }
    final configName = onlyProfiles ? _profilesBackupName : _configBackupName;

    // Get valid profile IDs
    final validProfileIds = globalState.config.profiles
        .map((p) => p.id)
        .toSet();
    final currentProfileId = globalState.config.currentProfileId;

    commonPrint.log(
      'Backing up ${validProfileIds.length} profiles',
      module: 'Backup',
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
      await encoder.addFile(tempConfigFile, configName);
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

      unawaited(encoder.close());

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
      _ref.read(nodesProvider),
      _ref.read(scriptStateProvider),
      _ref.read(managedSettingProvider),
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

  Future<bool> backupToWebDAV(
    DAVClient client,
    DAV dav, {
    BackupScope scope = BackupScope.all,
  }) async {
    final fingerprint = await _webDAVBackupFingerprint(dav);
    final data = await backupData(
      password: _ref.read(
        appSettingProvider.select((state) => state.backupPassword),
      ),
      scope: scope,
    );
    final res = await client.backup(Uint8List.fromList(data));
    if (res && scope == BackupScope.all) {
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
        commonPrint.debug('Auto backup skipped, no changes', module: 'Backup');
        return;
      }
      final res = await backupToWebDAV(DAVClient(dav), dav);
      if (res) {
        globalState.showNotifier(appLocalizations.autoBackupSuccess);
      }
    } catch (e) {
      commonPrint.error(
        'Auto backup failed: ${e.formatErrorLog}',
        module: 'Backup',
      );
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
    BackupScope recoveryOption,
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
          commonPrint.debug(
            'Archive has ${archive.files.length} files',
            module: 'Backup',
          );
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
    } on _RecoveryApplyException catch (e) {
      commonPrint.error(
        'Apply after restore failed: ${e.error}',
        module: 'Backup',
      );
      throw e.error;
    } catch (e) {
      commonPrint.error('Restore failed: $e', module: 'Backup');
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
    BackupScope recoveryOption,
  ) async {
    commonPrint.log(
      'Restoring backup of ${data.length} bytes',
      module: 'Backup',
    );
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
    BackupScope recoveryOption,
  ) async {
    commonPrint.log('Restoring from $path', module: 'Backup');
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
          commonPrint.warn('Decode stream failed: $e', module: 'Backup');
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
    BackupScope recoveryOption,
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
    BackupScope recoveryOption,
    String homeDirPath,
  ) async {
    // Separate config and profile files
    final configs = archive.files
        .where(
          (item) =>
              item.name.endsWith('.json') && item.name != '.bettbox_marker',
        )
        .toList();
    final profileFiles = archive.files.where(
      (item) => !item.name.endsWith('.json') && item.name != '.bettbox_marker',
    );

    // Find config.json
    final configIndex = configs.indexWhere(
      (config) =>
          config.name == _configBackupName ||
          config.name == _profilesBackupName,
    );
    if (configIndex == -1) throw 'invalid backup file';

    // Parse config
    final configFile = configs[configIndex];
    final scope = configFile.name == _profilesBackupName
        ? BackupScope.onlyProfiles
        : recoveryOption;
    final configContent = configFile.content;
    if (configContent.isEmpty) {
      throw 'Config file is empty or corrupted';
    }
    final configJson =
        json.decode(utf8.decode(configContent)) as Map<String, Object?>;
    var tempConfig = Config.compatibleFromJson(configJson);
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
    ProfileRecovery? recovery;
    if (recoveryStrategy == RecoveryStrategy.override) {
      await _cleanProfilesDirForOverride();
    } else {
      recovery = ProfileRecovery.compatible(
        tempConfig.profiles,
        _ref.read(profilesProvider),
      );
      tempConfig = tempConfig.copyWith(
        profiles: recovery.profiles,
        currentProfileId: recovery.targetId(tempConfig.currentProfileId),
      );
    }

    await _restoreArchiveProfiles(
      tempConfig.profiles,
      profileFiles,
      homeDirPath,
      recovery: recovery,
    );

    tempConfig = tempConfig.copyWith(
      scriptProps: await tempConfig.scriptProps.externalize(),
    );
    final managedProps = configJson['managedProps'] is Map
        ? await _restoreManagedProps(
            tempConfig.managedProps,
            configJson[_managedScriptBackupKey],
          )
        : null;

    _recovery(
      tempConfig,
      scope,
      recovery: recovery,
      fromDesktop: switch (configJson[_backupDesktopKey]) {
        final bool value => value,
        _ => null,
      },
    );
    if (managedProps != null) {
      _ref.read(managedSettingProvider.notifier).value = managedProps;
    }
    await _controller.savePreferences();
    await _applyRecoveredProfile();
  }

  Future<void> _applyRecoveredProfile() async {
    if (!globalState.isStart) return;
    try {
      await _controller.applyProfile(silence: true);
    } catch (e) {
      throw _RecoveryApplyException(e);
    }
  }

  Future<ManagedProps> _restoreManagedProps(
    ManagedProps props,
    Object? script,
  ) async {
    if (script is String &&
        script.isNotEmpty &&
        ManagedScript.isCustom(props)) {
      return props.copyWith(syncedVersion: await ManagedScript.save(script));
    }
    await ManagedScript.restore();
    return props.copyWith(syncedVersion: null);
  }

  Future<void> _restoreArchiveProfiles(
    List<Profile> profiles,
    Iterable<ArchiveFile> files,
    String homeDirPath, {
    ProfileRecovery? recovery,
  }) async {
    final fileMap = <String, ArchiveFile>{};
    final otherFiles = <ArchiveFile>[];
    for (final file in files) {
      final name = file.name.replaceAll('\\', '/');
      if (!name.contains('/providers/') &&
          (name.endsWith('.yaml') || name.endsWith('.yml'))) {
        fileMap[basenameWithoutExtension(name)] = file;
      } else if (recovery == null) {
        otherFiles.add(file);
      } else if (recovery.providerFile(file, name) case final entry?) {
        otherFiles.add(entry);
      }
    }
    await restoreBackupFiles(otherFiles, homeDirPath);
    for (final profile in profiles) {
      for (final id in recovery?.sourceIds(profile.id) ?? [profile.id]) {
        final file = fileMap[id];
        if (file == null) continue;
        await profile.saveFile(file.content);
        break;
      }
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
            commonPrint.warn(
              'Delete profile file failed: $e',
              module: 'Backup',
            );
          }
        }
      }
    } catch (e) {
      commonPrint.warn('Clean profiles dir failed: $e', module: 'Backup');
    }
  }

  /// Restore legacy
  Future<void> _recoveryLegacyBackup(
    Archive archive,
    BackupScope recoveryOption,
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
      json.decode(utf8.decode(configContent)) as Map<String, Object?>,
    );

    final recoveryStrategy = _ref.read(
      appSettingProvider.select((state) => state.recoveryStrategy),
    );
    if (recoveryStrategy == RecoveryStrategy.override) {
      await _cleanProfilesDirForOverride();
    }

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

    final recovery = recoveryStrategy == RecoveryStrategy.compatible
        ? ProfileRecovery.compatible(profiles, _ref.read(profilesProvider))
        : null;
    profiles = recovery?.profiles ?? profiles;
    await _restoreArchiveProfiles(
      profiles,
      profileFiles,
      homeDirPath,
      recovery: recovery,
    );

    Config limitedConfig = globalState.config.copyWith(profiles: profiles);

    if (system.isAndroid) {
      final vpnProps = backupConfig.vpnProps;
      AccessControl? accessControl;

      try {
        accessControl = vpnProps.accessControl;
      } catch (_) {
        try {
          final configJson = json.decode(
            utf8.decode(configFile.content),
          ) as Map<String, dynamic>;
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
    await _applyRecoveredProfile();

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
      commonPrint.warn('Read profile label failed: $e', module: 'Profile');
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
  void _recoveryLimited(Config config, BackupScope recoveryOption) {
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
    _controller.repairBundleScripts();
  }

  /// Full restore
  void _recovery(
    Config config,
    BackupScope recoveryOption, {
    ProfileRecovery? recovery,
    bool? fromDesktop,
  }) {
    final profiles = config.profiles;
    final override =
        _ref.read(appSettingProvider).recoveryStrategy ==
        RecoveryStrategy.override;

    _restoreProfiles(profiles);
    if (config.currentProfileId case final id?) {
      _ref.read(currentProfileIdProvider.notifier).value = id;
    }
    _restoreScripts(config.scriptProps, override);
    _restoreNodes(config.nodes, recovery, override);

    if (recoveryOption == BackupScope.all) {
      _restoreSettings(config, fromDesktop);
    }

    _ensureCurrentProfile(profiles);
    _controller.repairBundleScripts();
  }

  void _restoreScripts(ScriptProps scriptProps, bool override) {
    final scriptIds = scriptProps.scripts.map((e) => e.id).toSet();
    final localScripts = _ref
        .read(scriptStateProvider)
        .scripts
        .where((script) => !scriptIds.contains(script.id));
    if (override) {
      for (final script in localScripts) {
        unawaited(script.deleteContent());
      }
      _ref.read(scriptStateProvider.notifier).value = scriptProps;
    } else {
      _ref.read(scriptStateProvider.notifier).value = scriptProps.copyWith(
        scripts: [...scriptProps.scripts, ...localScripts],
      );
    }
  }

  void _restoreNodes(
    List<ProxyNode> nodes,
    ProfileRecovery? recovery,
    bool override,
  ) {
    final restored = [
      for (final node in nodes)
        recovery == null
            ? node
            : node.copyWith(
                bindings: {
                  for (final entry in node.bindings.entries)
                    recovery.targetId(entry.key) ?? entry.key: entry.value,
                },
              ),
    ];
    if (override) {
      _ref.read(nodesProvider.notifier).value = restored;
      return;
    }
    final ids = {for (final node in restored) node.id};
    final names = {for (final node in restored) node.name};
    _ref.read(nodesProvider.notifier).value = [
      ...restored,
      for (final node in _ref.read(nodesProvider))
        if (!ids.contains(node.id) && !names.contains(node.name)) node,
    ];
  }

  void _restoreSettings(Config config, bool? fromDesktop) {
    final sameOrigin = fromDesktop == system.isDesktop;
    final foreign = fromDesktop != null && !sameOrigin;
    final localAppSetting = _ref.read(appSettingProvider);
    final localVpnProps = _ref.read(vpnSettingProvider);
    final localNetworkProps = _ref.read(networkSettingProvider);

    var appSetting = config.appSetting.copyWith(
      backupPassword: localAppSetting.backupPassword,
      recoveryStrategy: localAppSetting.recoveryStrategy,
    );
    var vpnProps = config.vpnProps;
    var networkProps = sameOrigin
        ? config.networkProps
        : config.networkProps.copyWith(
            bypassPrivateRouteAddress:
                localNetworkProps.bypassPrivateRouteAddress,
          );

    if (system.isDesktop) {
      vpnProps = vpnProps.copyWith(enable: localVpnProps.enable);
      if (foreign) {
        appSetting = appSetting.copyWith(
          silentLaunch: localAppSetting.silentLaunch,
          minimizeOnExit: localAppSetting.minimizeOnExit,
          closeConnections: localAppSetting.closeConnections,
          keepDockIcon: localAppSetting.keepDockIcon,
          enableHighPriority: localAppSetting.enableHighPriority,
          sidebarCollapsed: localAppSetting.sidebarCollapsed,
          sidebarFlyout: localAppSetting.sidebarFlyout,
          sidebarFlyoutOutsideTools: localAppSetting.sidebarFlyoutOutsideTools,
          sidebarFlyoutDelay: localAppSetting.sidebarFlyoutDelay,
          sidebarFlyoutEntries: localAppSetting.sidebarFlyoutEntries,
          desktopDashboardWidgets: localAppSetting.desktopDashboardWidgets,
          desktopDashboardSizes: localAppSetting.desktopDashboardSizes,
        );
        vpnProps = vpnProps.copyWith(
          networkFix: localVpnProps.networkFix,
          trayEnhancement: localVpnProps.trayEnhancement,
          trayLeftClickBehavior: localVpnProps.trayLeftClickBehavior,
          trayRightClickBehavior: localVpnProps.trayRightClickBehavior,
          enableTraySpeed: localVpnProps.enableTraySpeed,
          alwaysShowTitleBar: localVpnProps.alwaysShowTitleBar,
        );
        networkProps = networkProps.copyWith(
          systemProxy: localNetworkProps.systemProxy,
          profileSwitchMode: localNetworkProps.profileSwitchMode,
        );
      }
      _ref.read(patchClashConfigProvider.notifier).value = config
          .patchClashConfig
          .copyWith
          .tun(enable: _ref.read(patchClashConfigProvider).tun.enable);
      if (!foreign) {
        _ref.read(windowSettingProvider.notifier).value = config.windowProps;
        _ref.read(hotKeyActionsProvider.notifier).value = config.hotKeyActions;
      }
    } else {
      final accessControl = vpnProps.accessControl;
      final hasBackupAccessControl =
          accessControl.enable ||
          accessControl.acceptList.isNotEmpty ||
          accessControl.rejectList.isNotEmpty;
      if (!hasBackupAccessControl) {
        vpnProps = vpnProps.copyWith(
          accessControl: localVpnProps.accessControl,
        );
      }
      if (foreign) {
        appSetting = appSetting.copyWith(
          hidden: localAppSetting.hidden,
          enableNavBarHapticFeedback:
              localAppSetting.enableNavBarHapticFeedback,
          mobileDashboardWidgets: localAppSetting.mobileDashboardWidgets,
          mobileDashboardSizes: localAppSetting.mobileDashboardSizes,
        );
        vpnProps = vpnProps.copyWith(
          enable: localVpnProps.enable,
          systemProxy: localVpnProps.systemProxy,
          allowBypass: localVpnProps.allowBypass,
          dozeSuspend: localVpnProps.dozeSuspend,
          quickResponse: localVpnProps.quickResponse,
          storeFix: localVpnProps.storeFix,
          highPriorityNotification: localVpnProps.highPriorityNotification,
          networkSpeedNotification: localVpnProps.networkSpeedNotification,
        );
      }
      _ref.read(patchClashConfigProvider.notifier).value =
          config.patchClashConfig;
    }

    _ref.read(appSettingProvider.notifier).value = appSetting.copyWith(
      dashboardWidgets: system.isAndroid
          ? appSetting.mobileDashboardWidgets
          : appSetting.desktopDashboardWidgets,
    );
    _ref.read(vpnSettingProvider.notifier).value = vpnProps;
    _ref.read(networkSettingProvider.notifier).value = networkProps;
    if (config.dav case final dav?) {
      _ref.read(appDAVSettingProvider.notifier).value = dav;
    }
    _ref.read(themeSettingProvider.notifier).value = config.themeProps;
    _ref.read(proxiesStyleSettingProvider.notifier).value = config.proxiesStyle;
    _ref.read(trafficStatsSettingProvider.notifier).value =
        config.trafficStatsProps;
    _ref.read(overrideNtpProvider.notifier).value = config.overrideNtp;
    _ref.read(overrideSnifferProvider.notifier).value = config.overrideSniffer;
    _ref.read(overrideTunnelProvider.notifier).value = config.overrideTunnel;
    _ref.read(overrideExperimentalProvider.notifier).value =
        config.overrideExperimental;
    _ref.read(nodeExcludeFilterProvider.notifier).value =
        config.nodeExcludeFilter;
    _ref.read(healthCheckTimeoutProvider.notifier).value =
        config.healthCheckTimeout;
  }
}
