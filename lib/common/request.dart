import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/common/helper_auth.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/state.dart';
import 'package:flutter/cupertino.dart';

class Request {
  late final Dio _dio;
  late final Dio _clashDio;

  Request() {
    _dio = Dio(BaseOptions(headers: {'User-Agent': browserUa}));
    _clashDio = Dio();
    _clashDio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.findProxy = (Uri uri) {
          client.userAgent = globalState.ua;
          return BettboxHttpOverrides.handleFindProxy(uri);
        };
        return client;
      },
    );
  }

  Future<Response> getFileResponseForUrl(String url) async {
    return _getResponseForUrl(url, responseType: ResponseType.bytes);
  }

  Future<Response> getTextResponseForUrl(String url) async {
    return _getResponseForUrl(url, responseType: ResponseType.plain);
  }

  Future<Response> _getResponseForUrl(
    String url, {
    required ResponseType responseType,
  }) async {
    final uri = Uri.parse(url);
    final userInfo = uri.userInfo;

    Options? options;
    if (userInfo.isNotEmpty) {
      final auth = base64Encode(utf8.encode(userInfo));
      options = Options(
        responseType: responseType,
        headers: {'Authorization': 'Basic $auth'},
      );
      url = uri.replace(userInfo: '').toString();
    }

    return _clashDio.get(
      url,
      options: options ?? Options(responseType: responseType),
    );
  }

  Future<MemoryImage?> getImage(String url) async {
    if (url.isEmpty) return null;
    final res = await _dio.get<Uint8List>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    final data = res.data;
    return data == null ? null : MemoryImage(data);
  }

  Future<Map<String, dynamic>?> checkForUpdate() async {
    try {
      final res = await _dio.get(
        'https://api.github.com/repos/$repository/releases/latest',
        options: Options(responseType: ResponseType.json),
      );
      if (res.statusCode != 200) return null;
      final data = res.data as Map<String, dynamic>;
      final remoteVersion = data['tag_name'];
      final version = globalState.packageInfo.version;
      final hasUpdate =
          utils.compareVersions(remoteVersion.replaceAll('v', ''), version) > 0;
      if (!hasUpdate) return null;
      return data;
    } on DioException catch (e) {
      commonPrint.log('Check update failed: ${e.message}');
      return null;
    } catch (e) {
      commonPrint.log('Check update error: $e');
      return null;
    }
  }

  static const _ipSources = {
    'global': [
      'https://api.appshub.cc/cdn-cgi/trace',
      'https://cp.cloudflare.com/cdn-cgi/trace',
    ],
    'domestic': [
      'https://www.teamviewer.cn/cdn-cgi/trace',
      'https://www.cloudflare-cn.com/cdn-cgi/trace',
    ],
  };

  Future<Result<IpInfo?>> checkIp({
    CancelToken? cancelToken,
    Duration? timeout,
    bool domestic = false,
  }) async {
    return _checkIpInternal(
      _ipSources[domestic ? 'domestic' : 'global']!,
      cancelToken: cancelToken,
      timeout: timeout,
    );
  }

  Future<Result<IpInfo?>> _checkIpInternal(
    List<String> sources, {
    CancelToken? cancelToken,
    Duration? timeout,
  }) async {
    final effectiveTimeout = timeout ?? const Duration(seconds: 5);
    final futures = sources.map((url) {
      return _makeIpRequest(url, effectiveTimeout, cancelToken);
    }).toList();

    try {
      final res = await Future.any(
        futures,
      ).timeout(effectiveTimeout, onTimeout: () => Result.success(null));
      cancelToken?.cancel();
      return res;
    } catch (e) {
      cancelToken?.cancel();
      return Result.success(null);
    }
  }

  Future<Result<IpInfo?>> _makeIpRequest(
    String url,
    Duration effectiveTimeout,
    CancelToken? cancelToken,
  ) async {
    try {
      final res = await _dio.get<String>(
        url,
        cancelToken: cancelToken,
        options: Options(
          receiveTimeout: effectiveTimeout,
          connectTimeout: effectiveTimeout,
        ),
      );
      if (res.statusCode == HttpStatus.ok && res.data != null) {
        return Result.success(IpInfo.fromCloudflareTrace(res.data!));
      }
      return Result.success(null);
    } catch (e) {
      if (e is DioException && e.type == DioExceptionType.cancel) {
        return Result.error('cancelled');
      }
      return Result.error(e.toString());
    }
  }

  Future<bool> pingHelper() async {
    try {
      final res = await _clashDio
          .get(
            'http://$localhost:$helperPort/ping',
            options: Options(responseType: ResponseType.plain),
          )
          .timeout(Duration(milliseconds: 500));
      return res.statusCode == HttpStatus.ok;
    } catch (_) {
      return false;
    }
  }

  Future<bool> startCoreByHelper(String arg) async {
    final homeDirPath = await appPath.homeDirPath;
    return await _helperRequest(
      'start',
      data: json.encode({
        'path': appPath.corePath,
        'arg': arg,
        'home_dir': homeDirPath,
      }),
      timeout: Duration(seconds: 3),
    );
  }

  Future<bool> stopCoreByHelper() async {
    return await _helperRequest('stop', timeout: Duration(seconds: 2));
  }

  Future<bool> _helperRequest(
    String method, {
    String data = '',
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final url = 'http://$localhost:$helperPort/$method';
    try {
      final res = await _clashDio
          .post(
            url,
            data: data,
            options: Options(
              responseType: ResponseType.plain,
              headers: HelperAuthManager.generateAuthHeaders(data),
            ),
          )
          .timeout(timeout);
      if (res.statusCode == HttpStatus.ok) {
        return (res.data as String).isEmpty;
      }
      return false;
    } catch (e) {
      commonPrint.log('Failed to $method core by helper: $e');
      return false;
    }
  }
}

final request = Request();
