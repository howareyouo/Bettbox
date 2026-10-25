import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';

class TvQrImportDialog extends StatefulWidget {
  const TvQrImportDialog({super.key});

  @override
  State<TvQrImportDialog> createState() => _TvQrImportDialogState();
}

class _TvQrImportDialogState extends State<TvQrImportDialog> {
  HttpServer? _server;
  String? _ip;
  int? _port;
  bool _isLoading = true;
  bool _isSuccess = false;
  String? _successName;

  String get _lanUrl {
    if (_ip == null || _ip!.isEmpty || _port == null) return '';
    return 'http://$_ip:$_port';
  }

  @override
  void initState() {
    super.initState();
    _startServer();
  }

  @override
  void dispose() {
    _server?.close(force: true);
    super.dispose();
  }

  Future<void> _startServer() async {
    try {
      final ip = await utils.getLocalIpAddress();
      if (!mounted) return;

      HttpServer? server;
      try {
        server = await HttpServer.bind(InternetAddress.anyIPv4, 9870);
      } catch (_) {
        server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      }

      if (!mounted) {
        server.close(force: true);
        return;
      }

      _server = server;
      _ip = ip;
      _port = server.port;
      _isLoading = false;
      setState(() {});

      server.listen(_handleHttpRequest);
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _handleHttpRequest(HttpRequest request) async {
    request.response.headers.add('Access-Control-Allow-Origin', '*');
    request.response.headers.add(
      'Access-Control-Allow-Methods',
      'GET, POST, OPTIONS',
    );
    request.response.headers.add(
      'Access-Control-Allow-Headers',
      'Content-Type',
    );

    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
      return;
    }

    final path = request.uri.path;
    if (request.method == 'GET' && (path == '/' || path.isEmpty)) {
      request.response.headers.contentType = ContentType(
        'text',
        'html',
        charset: 'utf-8',
      );
      request.response.headers.add(
        'Cache-Control',
        'no-cache, no-store, must-revalidate',
      );
      request.response.headers.add('Pragma', 'no-cache');
      request.response.headers.add('Expires', '0');
      final acceptLang =
          request.headers
              .value(HttpHeaders.acceptLanguageHeader)
              ?.toLowerCase() ??
          '';
      final isZh = acceptLang.contains('zh');
      request.response.write(await _getHtml(isZh: isZh));
      await request.response.close();
      return;
    }

    if (request.method == 'POST' && path == '/api/upload') {
      try {
        final body = await utf8.decodeStream(request);
        final data = jsonDecode(body) as Map<String, dynamic>;
        final type = data['type'] as String?;

        if (type == 'file' || data.containsKey('content')) {
          final content = data['content'] as String? ?? '';
          final rawName = data['name'] as String? ?? 'config.yaml';
          final name = rawName.isEmpty ? 'config.yaml' : rawName;

          if (content.trim().isEmpty) {
            _respondJson(
              request,
              statusCode: 400,
              success: false,
              message: 'Content is empty',
            );
            return;
          }

          _respondJson(request, statusCode: 200, success: true, message: 'ok');
          _onReceivedProfileFile(name, content);
          return;
        }

        final url = (data['url'] as String? ?? '').trim();
        if (url.isEmpty || !url.isUrl) {
          _respondJson(
            request,
            statusCode: 400,
            success: false,
            message: 'Invalid URL',
          );
          return;
        }

        _respondJson(request, statusCode: 200, success: true, message: 'ok');
        _onReceivedProfileUrl(url);
      } catch (e) {
        _respondJson(
          request,
          statusCode: 500,
          success: false,
          message: e.toString(),
        );
      }
      return;
    }

    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  void _respondJson(
    HttpRequest request, {
    required int statusCode,
    required bool success,
    required String message,
  }) async {
    request.response.statusCode = statusCode;
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({'success': success, 'message': message}),
    );
    await request.response.close();
  }

  void _onReceivedProfileUrl(String url) {
    if (!mounted) return;
    setState(() {
      _isSuccess = true;
      _successName = url;
    });

    Future.delayed(const Duration(milliseconds: 1200), () {
      if (mounted) {
        Navigator.of(context).pop();
        globalState.appController.addProfileFormURL(url);
      }
    });
  }

  void _onReceivedProfileFile(String name, String content) async {
    if (!mounted) return;
    setState(() {
      _isSuccess = true;
      _successName = name;
    });

    Future.delayed(const Duration(milliseconds: 1200), () async {
      if (!mounted) return;
      Navigator.of(context).pop();
      try {
        final profile = await Profile.normal(
          label: name,
        ).saveFileWithString(content);
        await globalState.appController.addProfile(profile);
        globalState.appController.toProfiles();
      } catch (e) {
        globalState.showMessage(
          title: appLocalizations.file,
          message: TextSpan(text: e.toString()),
          cancelable: false,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final hasNetwork = _ip != null && _ip!.isNotEmpty;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      backgroundColor: context.colorScheme.surfaceContainerHigh,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680, minHeight: 340),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: _isLoading
              ? const SizedBox(
                  height: 280,
                  child: Center(
                    child: SyncedLoading(
                      size: 40,
                      child: CircularProgressIndicator(),
                    ),
                  ),
                )
              : !hasNetwork
              ? _buildNoNetworkView()
              : _buildMainView(),
        ),
      ),
    );
  }

  Widget _buildNoNetworkView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.wifi_off_rounded,
          size: 64,
          color: context.colorScheme.error,
        ),
        const SizedBox(height: 16),
        Text(
          appLocalizations.tvScanNoNetwork,
          style: context.textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton.icon(
              autofocus: true,
              onPressed: () {
                setState(() {
                  _isLoading = true;
                });
                _startServer();
              },
              icon: const Icon(Icons.refresh),
              label: Text(appLocalizations.retry),
            ),
            const SizedBox(width: 16),
            OutlinedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(appLocalizations.cancel),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildMainView() {
    if (_isSuccess) {
      return SizedBox(
        height: 280,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.check_circle_rounded,
                size: 64,
                color: context.colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                appLocalizations.tvScanSuccess,
                style: context.textTheme.headlineSmall?.toBold,
              ),
              if (_successName != null) ...[
                const SizedBox(height: 8),
                Text(
                  _successName!,
                  style: context.textTheme.bodyMedium?.copyWith(
                    color: context.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: QrCodeWidget(data: _lanUrl, size: 210),
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: SyncedLoading(
                    size: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: context.colorScheme.primary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  appLocalizations.tvScanWaiting,
                  style: context.textTheme.bodySmall?.copyWith(
                    color: context.colorScheme.primary,
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(width: 32),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                appLocalizations.qrcode,
                style: context.textTheme.titleLarge?.toBold,
              ),
              const SizedBox(height: 4),
              Text(
                appLocalizations.qrcodeDesc,
                style: context.textTheme.bodyMedium?.copyWith(
                  color: context.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              _buildStepRow(
                icon: Icons.wifi,
                text: appLocalizations.tvScanStep1,
              ),
              const SizedBox(height: 10),
              _buildStepRow(
                icon: Icons.qr_code_scanner,
                text: appLocalizations.tvScanStep2,
              ),
              const SizedBox(height: 10),
              _buildStepRow(
                icon: Icons.send_to_mobile,
                text: appLocalizations.tvScanStep3,
              ),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: context.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: context.colorScheme.outlineVariant.withValues(
                      alpha: 0.3,
                    ),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      appLocalizations.tvScanManualUrl,
                      style: context.textTheme.labelSmall?.copyWith(
                        color: context.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _lanUrl,
                      style: context.textTheme.titleSmall?.copyWith(
                        color: context.colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Align(
                alignment: Alignment.centerRight,
                child: ElevatedButton(
                  autofocus: true,
                  onPressed: () => Navigator.of(context).pop(),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 10,
                    ),
                  ),
                  child: Text(appLocalizations.close),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStepRow({required IconData icon, required String text}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: context.colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: context.textTheme.bodyMedium?.copyWith(
              color: context.colorScheme.onSurface,
            ),
          ),
        ),
      ],
    );
  }

  static final Map<bool, String> _htmlCache = {};

  static Future<String> _getHtml({required bool isZh}) async {
    return _htmlCache[isZh] ??= await rootBundle.loadString(
      'assets/tv_upload/${isZh ? 'zh' : 'en'}.html',
    );
  }
}
