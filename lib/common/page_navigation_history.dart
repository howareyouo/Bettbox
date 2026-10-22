import 'package:bett_box/common/system.dart';
import 'package:bett_box/enum/enum.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// 浏览器式页面导航历史(后退/前进),条目为 [PageLabel.name]。
class PageNavigationHistory {
  PageNavigationHistory({this.maxLength = 30});

  final int maxLength;
  final List<String> _entries = [];
  int _index = -1;

  int get length => _entries.length;

  String? get current => _index >= 0 && _index < _entries.length
      ? _entries[_index]
      : null;

  bool get canGoBack => _index > 0;

  bool get canGoForward => _index < _entries.length - 1;

  void visit(String entry) {
    if (_index < _entries.length - 1) {
      _entries.removeRange(_index + 1, _entries.length);
    }
    _entries.add(entry);
    if (_entries.length > maxLength) {
      _entries.removeAt(0);
    }
    _index = _entries.length - 1;
  }

  String? back() {
    if (!canGoBack) return null;
    _index -= 1;
    return current;
  }

  String? forward() {
    if (!canGoForward) return null;
    _index += 1;
    return current;
  }

  void clear() {
    _entries.clear();
    _index = -1;
  }
}

/// 鼠标侧键(后退/前进)页面导航控制器。
///
/// 接入点:
/// - [onNavigate] 由应用层注入([AppController.toPage])
/// - MaterialApp 的 builder 用 Listener 把指针事件交给 [handlePointerDown]
/// - 桌面端每个标签页的私有 Navigator 经 [register] 登记,
///   后退时优先关闭当前标签已打开的子页,再沿历史切回上一个标签
class PageNavigationController {
  PageNavigationController._();

  static final PageNavigationController instance =
      PageNavigationController._();

  /// 页面跳转回调(注入 AppController.toPage,避免与全局状态循环 import)。
  void Function(PageLabel label)? onNavigate;

  final PageNavigationHistory _history = PageNavigationHistory();
  final Map<PageLabel, GlobalKey<NavigatorState>> _navigators = {};
  PageLabel _active = PageLabel.dashboard;
  bool _suppressNextVisit = false;
  bool _pending = false;

  /// 应用启动时把起始页作为历史基准,确保首次后退能回到起点。
  void seed(PageLabel label) {
    if (_history.length == 0) {
      _history.visit(label.name);
    }
    _active = label;
  }

  void register(PageLabel label, GlobalKey<NavigatorState> key) {
    _navigators[label] = key;
  }

  void unregister(PageLabel label) {
    _navigators.remove(label);
  }

  /// 记录一次页面切换,由 [AppController.toPage] 调用。
  /// 由后退/前进触发的切换会被抑制(不污染历史)。
  void visit(PageLabel label) {
    _active = label;
    if (_suppressNextVisit) {
      _suppressNextVisit = false;
      return;
    }
    _history.visit(label.name);
  }

  bool get canGoBack => _history.canGoBack;

  bool get canGoForward => _history.canGoForward;

  void handlePointerDown(PointerDownEvent event) {
    if (!system.isDesktop || _pending || event.kind != PointerDeviceKind.mouse) {
      return;
    }
    final buttons = event.buttons;
    if ((buttons & kBackMouseButton) != 0) {
      goBack();
    } else if ((buttons & kForwardMouseButton) != 0) {
      goForward();
    }
  }

  Future<void> goBack() async {
    if (!system.isDesktop || _pending) return;
    // 当前标签有打开的子页时,后退先关闭子页,不切标签
    final navigator = _navigators[_active]?.currentState;
    if (navigator != null && navigator.canPop()) {
      navigator.pop();
      return;
    }
    if (!_history.canGoBack) return;
    _pending = true;
    try {
      _navigateTo(_history.back());
    } finally {
      _pending = false;
    }
  }

  Future<void> goForward() async {
    if (!system.isDesktop || _pending) return;
    if (!_history.canGoForward) return;
    _pending = true;
    try {
      _navigateTo(_history.forward());
    } finally {
      _pending = false;
    }
  }

  void _navigateTo(String? name) {
    if (name == null) return;
    for (final label in PageLabel.values) {
      if (label.name == name) {
        _suppressNextVisit = true;
        onNavigate?.call(label);
        return;
      }
    }
  }
}

/// 全局鼠标侧键导航控制器单例。
final pageNavigationController = PageNavigationController.instance;