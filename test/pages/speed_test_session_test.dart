import 'dart:convert';

import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/pages/speed_test_session.dart';
import 'package:flutter_test/flutter_test.dart';

SpeedTestSession _session({
  Future<IpInfo?> Function(String ip)? queryIpDetail,
  Future<List<String>> Function(String host)? resolveHost,
  Future<Object?> Function(String url)? fetchDoH,
}) => SpeedTestSession(
  queryIpDetail: queryIpDetail ?? (_) async => null,
  resolveHost: resolveHost ?? (_) async => [],
  fetchDoH: fetchDoH ?? (_) async => null,
);

void main() {
  group('pickPublicIpFromDoH', () {
    test('Map 体：跳过私网取第一个公网 A 记录', () {
      final body = {
        'Answer': [
          {'data': '192.168.1.1'},
          {'data': '8.8.8.8'},
        ],
      };
      expect(pickPublicIpFromDoH(body), '8.8.8.8');
    });

    test('JSON 字符串体同样解析', () {
      final body = jsonEncode({
        'Answer': [
          {'data': '1.1.1.1'},
        ],
      });
      expect(pickPublicIpFromDoH(body), '1.1.1.1');
    });

    test('无 Answer / 空 / 均为私网时返回 null', () {
      expect(pickPublicIpFromDoH(null), isNull);
      expect(pickPublicIpFromDoH(<String, dynamic>{}), isNull);
      expect(
        pickPublicIpFromDoH(<String, dynamic>{
          'Answer': [
            {'data': '10.0.0.1'},
          ],
        }),
        isNull,
      );
    });

    test('非公网形态（TUN 段）不算公网', () {
      expect(
        pickPublicIpFromDoH({
          'Answer': [
            {'data': 'fdfe:dcba:9876::1'},
          ],
        }),
        isNull,
      );
    });
  });

  group('addSpeedSample', () {
    test('连续重复点去重，其余追加', () {
      final s = addSpeedSample(const [], (0.1, 2.0));
      expect(s, [(0.1, 2.0)]);
      final s2 = addSpeedSample(s, (0.1, 2.0));
      identical(s, s2); // 重复点返回原实例
      expect(addSpeedSample(s, (0.2, 3.0)), [
        (0.1, 2.0),
        (0.2, 3.0),
      ]);
    });
  });

  group('SpeedTestSession.refineAppleServer', () {
    test('非 apple 提供方与无 server 原样返回', () async {
      final session = _session();
      final cloudflare = SpeedTestState(provider: SpeedTestProvider.cloudflare);
      expect(await session.refineAppleServer(cloudflare, useSystemDns: true, proxy: ''), cloudflare);
      final apple = SpeedTestState(provider: SpeedTestProvider.apple);
      expect(await session.refineAppleServer(apple, useSystemDns: true, proxy: ''), apple);
    });

    test('被代理且不走系统 DNS 时不精修', () async {
      var queried = false;
      final session = _session(
        queryIpDetail: (_) async {
          queried = true;
          return null;
        },
      );
      final state = SpeedTestState(
        provider: SpeedTestProvider.apple,
        server: const SpeedTestServer(ip: '8.8.8.8'),
      );
      final refined = await session.refineAppleServer(
        state,
        useSystemDns: false,
        proxy: 'GLOBAL',
      );
      expect(identical(refined, state), isTrue);
      expect(queried, isFalse);
    });

    test('IP 无效（私网）且走系统 DNS：用 DNS 回退结果查询归属地并合并', () async {
      final session = _session(
        resolveHost: (_) async => ['192.168.1.1', '104.16.1.1'],
        queryIpDetail: (ip) async => IpInfo(
          ip: ip,
          countryCode: 'CN',
          city: 'Shanghai',
        ),
      );
      final state = SpeedTestState(
        provider: SpeedTestProvider.apple,
        server: const SpeedTestServer(ip: '192.168.1.1', country: 'US', colo: 'LAX'),
      );
      final refined = await session.refineAppleServer(
        state,
        useSystemDns: true,
        proxy: 'DIRECT',
      );
      expect(refined?.server?.ip, '104.16.1.1'); // 私网被跳过
      expect(refined?.server?.country, 'CN');
      expect(refined?.server?.city, 'Shanghai');
      expect(refined?.server?.colo, ''); // CN 清空 colo
    });

    test('DNS 回退仍无公网（且 IP 私网）：原样返回，不查询归属地', () async {
      var queried = false;
      final session = _session(
        resolveHost: (_) async => ['10.0.0.1'],
        queryIpDetail: (_) async {
          queried = true;
          return null;
        },
      );
      final state = SpeedTestState(
        provider: SpeedTestProvider.apple,
        server: const SpeedTestServer(ip: '192.168.1.1'),
      );
      final refined = await session.refineAppleServer(
        state,
        useSystemDns: true,
        proxy: '',
      );
      expect(identical(refined, state), isTrue);
      expect(queried, isFalse);
    });

    test('归属地查询为 null：原样返回', () async {
      final session = _session(
        queryIpDetail: (_) async => null,
      );
      final state = SpeedTestState(
        provider: SpeedTestProvider.apple,
        server: const SpeedTestServer(ip: '8.8.8.8'),
      );
      final refined = await session.refineAppleServer(
        state,
        useSystemDns: false,
        proxy: 'DIRECT',
      );
      expect(identical(refined, state), isTrue);
    });
  });

  group('SpeedTestSession.mergeFinalState', () {
    test('结果缺失：以最后流式状态为底，error 记 unavailable，探针补出口', () {
      final initial = SpeedTestState(
        provider: SpeedTestProvider.apple,
        direct: true,
      );
      final probe = SpeedTestState(
        exitInfo: {'chain': 'A'},
        server: const SpeedTestServer(ip: '8.8.8.8'),
      );
      final merged = SpeedTestSession.mergeFinalState(
        result: null,
        lastStreamed: initial,
        probe: probe,
      );
      expect(merged.error, 'unavailable');
      expect(merged.exitInfo, {'chain': 'A'});
      expect(merged.server?.ip, '8.8.8.8');
    });

    test('有结果：error 取结果值，server 以探针优先', () {
      final probe = SpeedTestState(server: const SpeedTestServer(ip: '1.1.1.1'));
      final result = SpeedTestState(
        error: 'timeout',
        server: const SpeedTestServer(ip: '2.2.2.2'),
      );
      final merged = SpeedTestSession.mergeFinalState(
        result: result,
        lastStreamed: SpeedTestState(),
        probe: probe,
      );
      expect(merged.error, 'timeout');
      expect(merged.server?.ip, '1.1.1.1');
    });

    test('无探针时 server 取结果自身', () {
      final result = SpeedTestState(server: const SpeedTestServer(ip: '2.2.2.2'));
      final merged = SpeedTestSession.mergeFinalState(
        result: result,
        lastStreamed: SpeedTestState(),
        probe: null,
      );
      expect(merged.server?.ip, '2.2.2.2');
      expect(merged.error, '');
    });
  });

  group('SpeedTestSession.shouldReprobe', () {
    test('provider / useSystemDns / server 任一变化都要重测', () {
      const base = SpeedTestSettings();
      expect(SpeedTestSession.shouldReprobe(base, base), isFalse);
      expect(
        SpeedTestSession.shouldReprobe(
          base,
          base.copyWith(provider: SpeedTestProvider.cloudflare),
        ),
        isTrue,
      );
      expect(
        SpeedTestSession.shouldReprobe(base, base.copyWith(useSystemDns: true)),
        isTrue,
      );
      expect(
        SpeedTestSession.shouldReprobe(
          base,
          base.copyWith(
            server: const SpeedTestNode(host: 'example.com', name: 'x'),
          ),
        ),
        isTrue,
      );
    });
  });

  group('SpeedTestSession.resolveSystemDnsFallback', () {
    test('系统 DNS 先行，公网地址直接返回，不走 DoH', () async {
      var fetched = false;
      final session = _session(
        resolveHost: (_) async => ['10.0.0.1', '104.16.1.1'],
        fetchDoH: (_) async {
          fetched = true;
          return null;
        },
      );
      expect(await session.resolveSystemDnsFallback(), '104.16.1.1');
      expect(fetched, isFalse);
    });

    test('系统 DNS 无公网时回退 DoH', () async {
      final session = _session(
        resolveHost: (_) async => ['10.0.0.1'],
        fetchDoH: (_) async => {
          'Answer': [
            {'data': '104.16.1.1'},
          ],
        },
      );
      expect(await session.resolveSystemDnsFallback(), '104.16.1.1');
    });

    test('解析抛异常不外泄，继续 DoH；都失败返回 null', () async {
      final session = _session(
        resolveHost: (_) async => throw Exception('dns down'),
        fetchDoH: (_) async => null,
      );
      expect(await session.resolveSystemDnsFallback(), isNull);
    });
  });
}
