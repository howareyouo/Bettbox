import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:synchronized/synchronized.dart';

/// 把「当前 Config + 目标 Profile + 补丁配置」编译成内核 setup/patch 参数，
/// 并负责脚本化配置的求值、缓存与清理（relay 目录）。
///
/// 归属 clash/ 层：它只面向内核契约（SetupParams / clashCore），不感知
/// UI 控制器。Config 按请求传入，应用身份与脚本错误出口注入。
class ConfigCompiler {
  final String Function() version;
  final String Function() buildNumber;
  final void Function(String message) onScriptError;

  /// 脚本求值串行锁：同一时刻只允许一个脚本跑（共享 JS 运行时）。
  final Lock _scriptEvaluateLock = Lock();

  ConfigCompiler({
    required this.version,
    required this.buildNumber,
    required this.onScriptError,
  });

  Future<SetupParams> buildSetupParams(
    Config config, {
    required ClashConfig patchConfig,
    Profile? profile,
  }) async {
    final targetProfile = profile ?? config.currentProfile;
    final params = SetupParams(
      selectedMap: targetProfile?.selectedMap ?? {},
      testUrl: config.appSetting.testUrl,
      overrideTestUrl: config.overrideTestUrl,
    );
    if (targetProfile == null) {
      return params;
    }
    return params.copyWith(
      profilePath: await appPath.getProfilePath(targetProfile.id),
      ageSecretKey: targetProfile.ageSecretKey ?? '',
      scriptedConfig: await writeScriptedConfig(config, targetProfile),
      patch: await buildPatchParams(
        config,
        patchConfig: patchConfig,
        profile: targetProfile,
      ),
    );
  }

  /// 编辑校验用的参数：服务模式、脚本接管或非当前 profile 一律不校验。
  Future<SetupParams?> buildValidateParams(
    Config config, {
    required Profile profile,
    required bool isService,
    required bool realTunEnable,
  }) async {
    final currentProfileId = config.currentProfileId;
    final scriptActive =
        config.scriptProps.currentScript != null && profile.useScriptOverride;
    if (isService ||
        scriptActive ||
        (currentProfileId != null && currentProfileId != profile.id)) {
      return null;
    }
    final patchConfig = config.patchClashConfig;
    return buildSetupParams(
      config,
      patchConfig: patchConfig.copyWith.tun(
        enable: patchConfig.tun.enable && realTunEnable,
      ),
      profile: profile,
    );
  }

  Future<String> writeScriptedConfig(Config config, Profile profile) async {
    if (config.scriptProps.currentScript == null ||
        !profile.useScriptOverride) {
      return '';
    }
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final relayPath = await appPath.relayPath;
    final separator = Platform.pathSeparator;
    final file = File('$relayPath${separator}scripted-$stamp.json');
    return _scriptEvaluateLock.synchronized(() async {
      final currentScript = config.scriptProps.currentScript;
      if (currentScript == null) return '';
      unawaited(_sweepRelay(relayPath));
      final cache = File('$relayPath${separator}cache-${profile.id}.json');
      final cacheKey = File('$relayPath${separator}cache-${profile.id}.key');
      String? content;
      var digest = currentScript.digest;
      var volatile = currentScript.volatile;
      if (digest == null || volatile == null) {
        content = await currentScript.readContent();
        digest = content.toMd5();
        volatile = volatileScriptPattern.hasMatch(content);
      }
      final key = volatile
          ? null
          : await _scriptedCacheKey(profile, currentScript, digest);
      final exported = File('$relayPath${separator}profile-$stamp.json');
      try {
        if (key != null &&
            await cache.exists() &&
            await cacheKey.exists() &&
            await cacheKey.readAsString() == key) {
          await cache.copy(file.path);
          return file.path;
        }
        await _exportProfileConfig(profile, exported.path);
        await JavaScriptRuntimeManager.evaluateScriptFile(
          scriptContent: content ?? await currentScript.readContent(),
          inputPath: exported.path,
          outputPath: file.path,
          customOptions: currentScript.customOptions,
        );
        if (key != null) {
          if (await cacheKey.exists()) {
            await cacheKey.delete();
          }
          await file.copy(cache.path);
          await cacheKey.writeAsString(key, flush: true);
        }
        return file.path;
      } catch (e) {
        commonPrint.error('Script execution failed: $e');
        onScriptError('${appLocalizations.profileParseErrorDesc}: $e');
        return '';
      } finally {
        if (await exported.exists()) {
          try {
            await exported.delete();
          } catch (_) {}
        }
      }
    });
  }

  Future<Map<String, dynamic>?> readScriptedConfig(
    Config config,
    Profile profile,
  ) async {
    final path = await writeScriptedConfig(config, profile);
    if (path.isEmpty) return null;
    final file = File(path);
    try {
      final content = await file.readAsString();
      return await Isolate.run(
        () => Map<String, dynamic>.from(json.decode(content) as Map),
      );
    } finally {
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  Future<void> _sweepRelay(String relayPath) async {
    final expire = DateTime.now().subtract(const Duration(minutes: 10));
    try {
      await for (final entity in Directory(relayPath).list()) {
        if (entity is! File ||
            entity.uri.pathSegments.last.startsWith('cache-') ||
            (await entity.stat()).modified.isAfter(expire)) {
          continue;
        }
        await entity.delete();
      }
    } catch (_) {}
  }

  Future<String?> _scriptedCacheKey(
    Profile profile,
    Script script,
    String digest,
  ) async {
    final profileFile = File(await appPath.getProfilePath(profile.id));
    if (!await profileFile.exists()) {
      return null;
    }
    final stat = await profileFile.stat();
    return [
      version(),
      buildNumber(),
      stat.modified.microsecondsSinceEpoch,
      stat.size,
      profile.ageSecretKey ?? '',
      digest,
      json.encode(script.customOptions ?? const <String, bool>{}),
    ].join('\n').toMd5();
  }

  Future<void> _exportProfileConfig(Profile profile, String output) async {
    final handler = clashLibHandler;
    if (handler != null) {
      return handler.exportConfig(
        profile.id,
        output,
        ageSecretKey: profile.ageSecretKey,
      );
    }
    return clashCore.exportConfig(
      profile.id,
      output,
      ageSecretKey: profile.ageSecretKey,
    );
  }

  Future<Map<String, dynamic>> buildPatchParams(
    Config config, {
    required ClashConfig patchConfig,
    required Profile profile,
  }) async {
    final fakeIpRangeV6 = patchConfig.dns.effectiveFakeIpRangeV6(
      ipv6Enabled: patchConfig.ipv6,
    );
    final dns = patchConfig.dns.copyWith(fakeIpRangeV6: fakeIpRangeV6);
    final tun = patchConfig.tun.getRealTun(
      config.networkProps.bypassPrivateRoute,
      fakeIpRange: patchConfig.dns.fakeIpRange,
      fakeIpRangeV6: fakeIpRangeV6,
      bypassPrivateRouteAddress:
          config.networkProps.realBypassPrivateRouteAddress,
    );
    final externalController = patchConfig.externalController;
    final secret = patchConfig.secret;
    final hasAuthentication = patchConfig.authentication.isNotEmpty;
    final general = <String, dynamic>{
      'external-controller': patchConfig.allowLan
          ? externalController.value.replaceAll('127.0.0.1', '0.0.0.0')
          : externalController.value,
      if (externalController == ExternalControllerStatus.open &&
          secret != null &&
          secret.isNotEmpty)
        'secret': secret,
      'external-ui': await appPath.uiPath,
      'external-ui-url':
          'https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip',
      'external-ui-name': '',
      'tcp-concurrent': patchConfig.tcpConcurrent,
      'unified-delay': patchConfig.unifiedDelay,
      'ipv6': patchConfig.ipv6,
      'log-level': patchConfig.logLevel.name,
      'keep-alive-interval': patchConfig.keepAliveInterval,
      'mixed-port': patchConfig.mixedPort,
      'port': patchConfig.port,
      'socks-port': patchConfig.socksPort,
      'redir-port': patchConfig.redirPort,
      'tproxy-port': patchConfig.tproxyPort,
      'find-process-mode': patchConfig.findProcessMode.name,
      'allow-lan': patchConfig.allowLan,
      'authentication': patchConfig.authentication,
      'skip-auth-prefixes':
          hasAuthentication && patchConfig.skipAuthPrefixes.isNotEmpty
          ? patchConfig.skipAuthPrefixes
          : null,
      'mode': patchConfig.mode.name,
      'tun': {
        'enable': tun.enable,
        'device': tun.device,
        if (tun.dnsMode case final dnsMode?) 'dns-mode': dnsMode.name,
        'dns-hijack': tun.dnsHijack.isEmpty ? const ['any:53'] : tun.dnsHijack,
        'stack': tun.stack.name,
        'congestion-controller': tun.congestionController.name,
        'route-address': tun.routeAddress,
        'route-exclude-address': tun.routeExcludeAddress,
        'auto-route': !system.isAndroid,
        'auto-detect-interface': !system.isAndroid,
        'auto-redirect': system.isLinux,
        'strict-route': tun.strictRoute,
        'endpoint-independent-nat': tun.endpointIndependentNat,
        'disable-icmp-forwarding': tun.disableIcmpForwarding,
        'mtu': tun.mtu,
      },
      'geodata-loader': 'memconservative',
      'geodata-mode': false,
      'global-ua': patchConfig.globalUa,
    };

    final scriptActive =
        config.scriptProps.currentScript != null && profile.useScriptOverride;
    final overrideData = profile.overrideData;
    final isRussian =
        config.appSetting.locale?.toLowerCase().startsWith('ru') ?? false;
    final listenPorts = patchConfig.listenPorts;

    return {
      'general': general,
      'geox-url': patchConfig.geoXUrl.toJson(),
      'hosts': [
        for (final host in patchConfig.hosts.entries)
          if (system.isAndroid || host.key != 'services.googleapis.cn')
            {'key': host.key, 'value': host.value.splitByMultipleSeparators},
        {
          'key': 'dns.msftncsi.com',
          'value': ['131.107.255.255', 'fd3e:4f5a:5b81::1'],
        },
      ],
      'override-dns': config.overrideDns,
      'dns': {
        ...dns.toJson(),
        'nameserver-policy': {
          for (final entry in dns.nameserverPolicy.entries)
            entry.key: entry.value.splitByMultipleSeparators,
        },
      },
      'ntp': config.overrideNtp ? patchConfig.ntp.toJson() : null,
      'sniffer': config.overrideSniffer ? patchConfig.sniffer.toJson() : null,
      'experimental': config.overrideExperimental
          ? patchConfig.experimental.toJson()
          : null,
      'tunnels': patchConfig.tunnels.isEmpty
          ? null
          : patchConfig.tunnels.map((item) => item.toClashJson()).toList(),
      'providers-path': await appPath.getProvidersDirPath(profile.id),
      'node-exclude-filter': config.nodeExcludeFilter,
      'health-check-timeout': config.healthCheckTimeout,
      'override-rules': overrideData.enable
          ? {
              'override': overrideData.rule.type == OverrideRuleType.override,
              'rules': overrideData.runningRule,
            }
          : null,
      'prepend-rules': [
        if (config.vpnProps.loopbackProtection) ...[
          if (listenPorts.isNotEmpty) ...[
            'AND,((DST-PORT,$listenPorts),(IP-CIDR,127.0.0.0/8,no-resolve)),REJECT',
            'AND,((DST-PORT,$listenPorts),(IP-CIDR6,::1/128,no-resolve)),REJECT',
          ],
          if (system.isAndroid)
            'AND,((DST-PORT,853),(IP-CIDR,198.51.100.0/30,no-resolve)),REJECT',
        ],
        if (config.vpnProps.disableQuic)
          config.vpnProps.excludeChina && !isRussian
              ? 'AND,((NETWORK,UDP),(DST-PORT,443),(NOT,((OR,((GEOSITE,geolocation-cn),(GEOIP,CN,no-resolve)))))),REJECT'
              : 'AND,((NETWORK,UDP),(DST-PORT,443)),REJECT',
      ],
      'disabled-groups': scriptActive
          ? const []
          : [
              for (final entry in profile.groupSwitches.entries)
                if (!entry.value) entry.key,
            ],
      'select-global': profile.selectedMap['GLOBAL'] == null,
    };
  }
}
