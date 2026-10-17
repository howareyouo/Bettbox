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

  /// Whether the content can be edited in-app with a plain text field.
  /// Highlighting only applies to preview mode; editing is unhighlighted.
  final bool editable;

  /// Called with the edited content when the save action is used. The page
  /// is not popped automatically; pop after persisting if desired.
  final ValueChanged<String>? onSave;

  const ViewerPage({
    super.key,
    required this.title,
    required this.content,
    this.highlightMode,
    this.editable = false,
    this.onSave,
  });

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  final ScrollController _controller = ScrollController();
  final Highlight _highlight = Highlight();
  final TextEditingController _editController = TextEditingController();
  final FocusNode _editFocus = FocusNode();

  bool _editing = false;

  late String _content = widget.content;

  TextSpan? _span;
  Brightness? _spanBrightness;

  @override
  void initState() {
    super.initState();
    _editController.text = widget.content;
  }

  @override
  void didUpdateWidget(covariant ViewerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content ||
        oldWidget.highlightMode != widget.highlightMode) {
      _span = null;
      _spanBrightness = null;
      if (!_editing) {
        _editController.text = widget.content;
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _editController.dispose();
    _editFocus.dispose();
    super.dispose();
  }

  void _handleToggleEdit() {
    setState(() {
      if (!_editing) {
        _editController.text = widget.content;
      }
      _editing = !_editing;
    });
    if (_editing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _editFocus.requestFocus();
        }
      });
    }
  }

  Future<void> _handleSave() async {
    _content = _editController.text;
    widget.onSave?.call(_content);
    if (!mounted) return;
    setState(() => _editing = false);
  }

  Future<void> _handleCopyAll() async {
    await Clipboard.setData(ClipboardData(text: _content));
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
          .highlight(code: _content, language: id)
          .render(renderer);
      return renderer.span;
    } catch (_) {
      return null;
    }
  }

  Widget _buildContent(BuildContext context) {
    final base = context.textTheme.bodyMedium?.copyWith(
      fontFamily: FontFamily.jetBrainsMono.value,
    );
    if (widget.highlightMode != null) {
      final brightness = context.colorScheme.brightness;
      if (_span == null || _spanBrightness != brightness) {
        _spanBrightness = brightness;
        _span = _buildSpan(brightness, base!);
      }
    }
    final span = _span;
    if (span != null) {
      return SelectableText.rich(span, style: base);
    }
    return SelectableText(_content, style: base);
  }

  @override
  Widget build(BuildContext context) {
    return CommonScaffold(
      scrollEdgeFade: false,
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (_editing) ...[
            IconButton(
              onPressed: _handleSave,
              tooltip: appLocalizations.save,
              icon: const Icon(Icons.save_outlined),
            ),
            IconButton(
              onPressed: _handleToggleEdit,
              tooltip: appLocalizations.cancel,
              icon: const Icon(Icons.close_rounded),
            ),
          ] else ...[
            IconButton(
              onPressed: _handleCopyAll,
              tooltip: appLocalizations.copy,
              icon: const Icon(Icons.copy_all_rounded),
            ),
            if (widget.editable && widget.onSave != null)
              IconButton(
                onPressed: _handleToggleEdit,
                tooltip: appLocalizations.edit,
                icon: const Icon(Icons.edit_outlined),
              ),
          ],
        ],
      ),
      body: _editing ? _buildEditor(context) : _buildViewer(context),
    );
  }

  Widget _buildEditor(BuildContext context) {
    final base = context.textTheme.bodyMedium?.copyWith(
      fontFamily: FontFamily.jetBrainsMono.value,
    );
    return Padding(
      padding: const EdgeInsets.all(16),
      child: TextField(
        controller: _editController,
        focusNode: _editFocus,
        style: base,
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        decoration: const InputDecoration(
          border: InputBorder.none,
          isDense: true,
        ),
      ),
    );
  }

  Widget _buildViewer(BuildContext context) {
    return CommonScrollBar(
      controller: _controller,
      child: SingleChildScrollView(
        controller: _controller,
        padding: const EdgeInsets.all(16),
        child: _buildContent(context),
      ),
    );
  }
}
