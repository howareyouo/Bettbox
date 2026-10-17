import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart' hide Mode;
import 'package:bett_box/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';

class ViewerPage extends StatefulWidget {
  final String title;
  final String content;
  final Mode? highlightMode;

  const ViewerPage({
    super.key,
    required this.title,
    required this.content,
    this.highlightMode,
  });

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  final ScrollController _controller = ScrollController();
  final Highlight _highlight = Highlight();

  TextSpan? _span;
  Brightness? _spanBrightness;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _handleCopyAll() async {
    await Clipboard.setData(ClipboardData(text: widget.content));
    if (!mounted) return;
    context.showNotifier(appLocalizations.copySuccess);
  }

  TextSpan? _buildSpan(Brightness brightness, TextStyle base) {
    final mode = widget.highlightMode;
    if (mode == null) return null;
    try {
      // getLanguage looks up by lowercase name, so the id must be lowercase
      final id = (mode.name ?? mode.hashCode.toString()).toLowerCase();
      _highlight.registerLanguage(id, mode);
      final theme = brightness == Brightness.dark
          ? atomOneDarkTheme
          : atomOneLightTheme;
      final renderer = TextSpanRenderer(base, theme);
      _highlight
          .highlight(code: widget.content, language: id)
          .render(renderer);
      return renderer.span;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final style = context.textTheme.bodyMedium?.copyWith(
      fontFamily: FontFamily.jetBrainsMono.value,
    );
    if (widget.highlightMode != null) {
      final brightness = context.colorScheme.brightness;
      if (_span == null || _spanBrightness != brightness) {
        _spanBrightness = brightness;
        _span = _buildSpan(brightness, style!);
      }
    }
    final span = _span;
    return CommonScaffold(
      scrollEdgeFade: false,
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            onPressed: _handleCopyAll,
            tooltip: appLocalizations.copy,
            icon: const Icon(Icons.copy_all_rounded),
          ),
        ],
      ),
      body: CommonScrollBar(
        controller: _controller,
        child: SingleChildScrollView(
          controller: _controller,
          padding: const EdgeInsets.all(16),
          child: span != null
              ? SelectableText.rich(span, style: style)
              : SelectableText(widget.content, style: style),
        ),
      ),
    );
  }
}
