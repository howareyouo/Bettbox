import 'package:bett_box/common/common.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

class ViewerPage extends StatefulWidget {
  final String title;
  final String content;

  const ViewerPage({super.key, required this.title, required this.content});

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  final ScrollController _controller = ScrollController();

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

  @override
  Widget build(BuildContext context) {
    final style = context.textTheme.bodyMedium?.copyWith(
      fontFamily: FontFamily.jetBrainsMono.value,
    );
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
          child: SelectableText(widget.content, style: style),
        ),
      ),
    );
  }
}
