import 'dart:math';
import 'dart:ui' as ui;

import 'package:bett_box/common/common.dart';
import 'package:material_ui/material_ui.dart';

double _computePeak(
  List<(double, double)> download,
  List<(double, double)> upload,
) {
  var peak = 0.0;
  for (var i = 0; i < download.length; i++) {
    final v = download[i].$2;
    if (v > peak) peak = v;
  }
  for (var i = 0; i < upload.length; i++) {
    final v = upload[i].$2;
    if (v > peak) peak = v;
  }
  return peak;
}

class ThroughputChart extends StatelessWidget {
  final List<(double, double)> download;
  final List<(double, double)> upload;
  final double height;

  const ThroughputChart({
    super.key,
    required this.download,
    required this.upload,
    this.height = 140,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final peak = _computePeak(download, upload);
    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _ThroughputPainter(
          download: download,
          upload: upload,
          downloadColor: colorScheme.primary,
          uploadColor: colorScheme.tertiary,
          gridColor: colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
        child: Align(
          alignment: AlignmentDirectional.topEnd,
          child: peak > 0
              ? Text(
                  '${formatSpeedValue(peak)} ${formatSpeedUnit(peak)}',
                  style: context.textTheme.labelSmall?.copyWith(
                    color: colorScheme.outline,
                  ),
                )
              : null,
        ),
      ),
    );
  }
}

class ChartLegend extends StatelessWidget {
  final Color color;
  final String label;

  const ChartLegend({super.key, required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: context.textTheme.labelSmall?.copyWith(
            color: context.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _ThroughputPainter extends CustomPainter {
  static const int _maxRenderPoints = 64;

  static final Path _uploadStrokePath = Path();
  static final Path _uploadFillPath = Path();
  static final Path _downloadStrokePath = Path();
  static final Path _downloadFillPath = Path();

  static final Paint _gridPaint = Paint()..strokeWidth = 1;
  static final Paint _fillPaint = Paint();
  static final Paint _strokePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2
    ..strokeJoin = StrokeJoin.round;

  static final List<(double, double)> _sampleBuffer = List.filled(
    _maxRenderPoints,
    (0.0, 0.0),
  );

  static Size? _cachedSize;
  static Color? _cachedDownloadColor;
  static Color? _cachedUploadColor;
  static ui.Shader? _downloadShader;
  static ui.Shader? _uploadShader;

  final List<(double, double)> download;
  final List<(double, double)> upload;
  final Color downloadColor;
  final Color uploadColor;
  final Color gridColor;

  _ThroughputPainter({
    required this.download,
    required this.upload,
    required this.downloadColor,
    required this.uploadColor,
    required this.gridColor,
  });

  static void _ensureShaders(
    Size size,
    Color downloadColor,
    Color uploadColor,
  ) {
    final sizeChanged = _cachedSize != size;
    if (sizeChanged ||
        _cachedDownloadColor != downloadColor ||
        _downloadShader == null) {
      _downloadShader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          downloadColor.withValues(alpha: 0.28),
          downloadColor.withValues(alpha: 0),
        ],
      ).createShader(Offset.zero & size);
      _cachedDownloadColor = downloadColor;
    }
    if (sizeChanged ||
        _cachedUploadColor != uploadColor ||
        _uploadShader == null) {
      _uploadShader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          uploadColor.withValues(alpha: 0.28),
          uploadColor.withValues(alpha: 0),
        ],
      ).createShader(Offset.zero & size);
      _cachedUploadColor = uploadColor;
    }
    _cachedSize = size;
  }

  static int _downsample(
    List<(double, double)> points,
    double width,
    double scaleY,
  ) {
    final len = points.length;
    if (len < 2) return 0;

    if (len <= _maxRenderPoints) {
      _sampleBuffer[0] = points[0];
      var outCount = 1;
      var prevX = points[0].$1.clamp(0.0, 1.0) * width;
      var prevY = points[0].$2 * scaleY;
      final lastIndex = len - 1;
      for (var i = 1; i < lastIndex; i++) {
        final pt = points[i];
        final curX = pt.$1.clamp(0.0, 1.0) * width;
        final curY = pt.$2 * scaleY;
        if ((curX - prevX).abs() < 0.25 && (curY - prevY).abs() < 0.25) {
          continue;
        }
        _sampleBuffer[outCount++] = pt;
        prevX = curX;
        prevY = curY;
      }
      _sampleBuffer[outCount++] = points[lastIndex];
      return outCount;
    }

    var peakIndex = 0;
    var peakValue = -1.0;
    for (var i = 0; i < len; i++) {
      final y = points[i].$2;
      if (y > peakValue) {
        peakValue = y;
        peakIndex = i;
      }
    }

    _sampleBuffer[0] = points[0];
    final bucketCount = _maxRenderPoints - 2;
    final bucketSize = (len - 2) / bucketCount;
    var a = 0;

    for (var i = 0; i < bucketCount; i++) {
      final rangeStart = (i * bucketSize).floor() + 1;
      final rangeEnd = min(((i + 1) * bucketSize).floor() + 1, len - 1);

      if (peakIndex >= rangeStart && peakIndex < rangeEnd) {
        _sampleBuffer[i + 1] = points[peakIndex];
        a = peakIndex;
        continue;
      }

      final avgStart = rangeEnd;
      final avgEnd = min(((i + 2) * bucketSize).floor() + 1, len);
      var avgX = 0.0;
      var avgY = 0.0;
      final avgLen = avgEnd - avgStart;
      if (avgLen > 0) {
        for (var j = avgStart; j < avgEnd; j++) {
          final pt = points[j];
          avgX += pt.$1;
          avgY += pt.$2;
        }
        avgX /= avgLen;
        avgY /= avgLen;
      } else {
        final last = points[len - 1];
        avgX = last.$1;
        avgY = last.$2;
      }

      final pointA = points[a];
      final ax = pointA.$1;
      final ay = pointA.$2;
      var maxArea = -1.0;
      var nextA = rangeStart;

      for (var j = rangeStart; j < rangeEnd; j++) {
        final pt = points[j];
        final area = ((ax - avgX) * (pt.$2 - ay) - (ax - pt.$1) * (avgY - ay))
            .abs();
        if (area > maxArea) {
          maxArea = area;
          nextA = j;
        }
      }

      _sampleBuffer[i + 1] = points[nextA];
      a = nextA;
    }

    _sampleBuffer[_maxRenderPoints - 1] = points[len - 1];
    return _maxRenderPoints;
  }

  static void _drawSeries(
    Canvas canvas,
    Size size,
    List<(double, double)> points,
    double scaleY,
    Color color,
    ui.Shader shader,
    Path strokePath,
    Path fillPath,
  ) {
    final count = _downsample(points, size.width, scaleY);
    if (count < 2) return;

    strokePath.reset();
    fillPath.reset();

    final width = size.width;
    final height = size.height;

    final p0 = _sampleBuffer[0];
    var prevX = p0.$1.clamp(0.0, 1.0) * width;
    var prevY = height - p0.$2 * scaleY;
    final firstX = prevX;

    strokePath.moveTo(prevX, prevY);
    for (var i = 1; i < count; i++) {
      final pt = _sampleBuffer[i];
      final curX = pt.$1.clamp(0.0, 1.0) * width;
      final curY = height - pt.$2 * scaleY;
      final midX = (prevX + curX) * 0.5;
      strokePath.cubicTo(midX, prevY, midX, curY, curX, curY);
      prevX = curX;
      prevY = curY;
    }

    fillPath
      ..addPath(strokePath, Offset.zero)
      ..lineTo(prevX, height)
      ..lineTo(firstX, height)
      ..close();

    _fillPaint.shader = shader;
    canvas.drawPath(fillPath, _fillPaint);

    _strokePaint.color = color;
    canvas.drawPath(strokePath, _strokePaint);
  }

  static bool _seriesChanged(
    List<(double, double)> a,
    List<(double, double)> b,
  ) {
    if (identical(a, b)) return false;
    final len = a.length;
    if (len != b.length) return true;
    if (len == 0) return false;
    return a.last != b.last || a.first != b.first || a[len >> 1] != b[len >> 1];
  }

  @override
  void paint(Canvas canvas, Size size) {
    _gridPaint.color = gridColor;
    final quarterHeight = size.height * 0.25;
    for (var i = 1; i <= 3; i++) {
      final y = quarterHeight * i;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), _gridPaint);
    }

    final peak = _computePeak(download, upload);
    if (peak <= 0) return;

    final scaleY = size.height / (peak * 1.15);
    _ensureShaders(size, downloadColor, uploadColor);

    if (upload.length >= 2) {
      _drawSeries(
        canvas,
        size,
        upload,
        scaleY,
        uploadColor,
        _uploadShader!,
        _uploadStrokePath,
        _uploadFillPath,
      );
    }
    if (download.length >= 2) {
      _drawSeries(
        canvas,
        size,
        download,
        scaleY,
        downloadColor,
        _downloadShader!,
        _downloadStrokePath,
        _downloadFillPath,
      );
    }
  }

  @override
  bool shouldRepaint(_ThroughputPainter oldDelegate) {
    return _seriesChanged(oldDelegate.download, download) ||
        _seriesChanged(oldDelegate.upload, upload) ||
        oldDelegate.downloadColor != downloadColor ||
        oldDelegate.uploadColor != uploadColor ||
        oldDelegate.gridColor != gridColor;
  }
}
