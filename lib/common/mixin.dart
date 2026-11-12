import 'package:riverpod/riverpod.dart';

mixin AutoDisposeNotifierMixin<T> on AnyNotifier<T, T> {
  set value(T value) {
    state = value;
  }

  @override
  bool updateShouldNotify(previous, next) {
    final res = !identical(previous, next);
    if (res) {
      onUpdate(next);
    }
    return res;
  }

  void onUpdate(T value) {}

  /// `state = builder(state)` 的同构样板收敛；需要额外副作用（如
  /// minimizeOnExit、null 守卫）的 provider 自行覆盖。
  void updateState(T Function(T state) builder) {
    state = builder(state);
  }
}
