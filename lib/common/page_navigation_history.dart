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
