import 'dart:convert';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';

/// 测速会话的纯规则层：Apple 服务器精修、系统 DNS 回退、终态合并、
/// 重测判定与曲线采样。IO 全部以函数注入，可脱离 UI 单测；
/// 页面只负责编排（serial 守卫、mounted 检查）与渲染。
class SpeedTestSession {
  /// 按 IP 查询归属地信息。
  final Future<IpInfo?> Function(String ip) queryIpDetail;

  /// 系统 DNS 解析主机名，返回全部地址。
  final Future<List<String>> Function(String host) resolveHost;

  /// 拉取 DoH 响应体（Map 或 JSON 字符串）。
  final Future<Object?> Function(String url) fetchDoH;

  static const _appleProbeHost = 'mensura.cdn-apple.com';
  static const _aliDoHUrl =
      'https://223.5.5.5/resolve?name=$_appleProbeHost&type=A';

  const SpeedTestSession({
    required this.queryIpDetail,
    required this.resolveHost,
    required this.fetchDoH,
  });

  /// 系统 DNS 回退：先 A 记录取第一个公网地址，失败走阿里 DoH。
  Future<String?> resolveSystemDnsFallback() async {
    try {
      for (final address in await resolveHost(_appleProbeHost)) {
        if (utils.classifyIp(address) == IpCategory.public) {
          return address;
        }
      }
    } catch (_) {}
    try {
      return pickPublicIpFromDoH(await fetchDoH(_aliDoHUrl));
    } catch (_) {}
    return null;
  }

  /// Apple 测速节点的归属地精修：仅 apple 提供方，且未被代理（或走系统
  /// DNS）时，把无效 IP 交给 DNS 回退，再用归属地查询补全国 家/城市/colo。
  Future<SpeedTestState?> refineAppleServer(
    SpeedTestState? state, {
    required bool useSystemDns,
    required String proxy,
  }) async {
    if (state == null || state.provider != SpeedTestProvider.apple) {
      return state;
    }
    final server = state.server;
    if (server == null) return state;
    if (!useSystemDns && proxy.isNotEmpty && proxy != 'DIRECT') {
      return state;
    }

    var ip = server.ip;
    if ((ip.isEmpty || utils.classifyIp(ip) != IpCategory.public) &&
        useSystemDns) {
      final resolved = await resolveSystemDnsFallback();
      if (resolved != null && resolved.isNotEmpty) {
        ip = resolved;
      }
    }
    if (ip.isEmpty || utils.classifyIp(ip) != IpCategory.public) {
      return state;
    }

    final ipInfo = await queryIpDetail(ip);
    if (ipInfo == null) {
      return state;
    }

    final country = ipInfo.countryCode;
    final city = ipInfo.city?.isNotEmpty == true
        ? ipInfo.city!
        : (ipInfo.province ?? '');
    return state.copyWith(
      server: server.copyWith(
        ip: ip,
        country: country.isNotEmpty ? country : server.country,
        city: city.isNotEmpty ? city : server.city,
        colo: country == 'CN' ? '' : server.colo,
      ),
    );
  }

  /// 测速结束后的终态合并：结果缺失记为 unavailable；出口信息与
  /// server 以探针结果补齐。
  static SpeedTestState mergeFinalState({
    required SpeedTestState? result,
    required SpeedTestState lastStreamed,
    required SpeedTestState? probe,
  }) {
    return (result ?? lastStreamed).copyWith(
      error: result == null ? 'unavailable' : result.error,
      exitInfo: probe?.exitInfo,
      server: probe?.server ?? result?.server,
    );
  }

  /// 设置变化是否需要重新探测出口。
  static bool shouldReprobe(SpeedTestSettings old, SpeedTestSettings next) {
    return old.provider != next.provider ||
        old.useSystemDns != next.useSystemDns ||
        old.server != next.server;
  }
}

/// 从 DoH 响应体（Map 或 JSON 字符串）里挑第一个公网 A 记录。
String? pickPublicIpFromDoH(Object? body) {
  final json = body is Map
      ? body as Map<String, dynamic>
      : (body is String ? jsonDecode(body) as Map<String, dynamic> : null);
  final answers = json?['Answer'];
  if (answers is List) {
    for (final item in answers) {
      final data = item is Map ? item['data']?.toString() ?? '' : '';
      if (utils.classifyIp(data) == IpCategory.public) {
        return data;
      }
    }
  }
  return null;
}

/// 曲线采样：连续重复点去重（无变化时返回原实例，便于调用方省略重建）。
List<(double, double)> addSpeedSample(
  List<(double, double)> series,
  (double, double) point,
) => series.isNotEmpty && series.last == point ? series : [...series, point];
